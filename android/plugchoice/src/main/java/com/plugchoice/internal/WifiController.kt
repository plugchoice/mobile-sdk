package com.plugchoice.internal

import android.Manifest
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CompletableDeferred
import org.json.JSONObject

/**
 * `wifi.*`: joins the charger's own hotspot with [WifiNetworkSpecifier] and keeps the resulting
 * [Network] so HTTP/WebSocket traffic can be bound to it per socket.
 *
 * The process is never bound to the network (`bindProcessToNetwork`): the WebView and the host app
 * keep using the default network (and its internet) the whole time.
 *
 * State is confined to the main thread (network callbacks are delivered on it); [network] and
 * [routeTraffic] are also read from OkHttp threads.
 *
 * The join timeout is ours, not `requestNetwork`'s, and it is paused while the screen doesn't
 * have window focus: the first join of an SSID shows the system "connect to device" dialog, and
 * its scan plus the user's answer must not eat the page's `timeoutMs` (with `requestNetwork`'s
 * own timeout they would, and a slow first answer would end in a failed join).
 */
internal class WifiController(
    private val host: BridgeHost,
    /** Called on the main thread whenever [network] changes or routing is turned off. */
    private val onNetworkChanged: () -> Unit,
) {
    private val context = host.hostContext.applicationContext
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val wifiManager = context.getSystemService(WifiManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scheduler = HandlerScheduler(mainHandler)

    /** The registered request; it holds the connection to the charger until [leave]. */
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var pendingJoin: CompletableDeferred<Network>? = null
    private var joinedSsid: String? = null
    private var windowLostFocusDuringJoin = false
    private var windowHasFocus = true
    private var joinTimeout: PausableTimeout? = null

    /** The charger network while it is available. */
    @Volatile
    var network: Network? = null
        private set

    /** `wifi.routeTraffic`: whether HTTP/WebSocket go over [network]. */
    @Volatile
    var routeTraffic: Boolean = false
        private set

    /**
     * The system's "connect to device" dialog is a separate window, so the activity losing window
     * focus while a join is pending is how we tell that it was shown (`pickerShown`), and the join
     * timeout stands still until the focus is back.
     */
    fun onWindowFocusChanged(hasFocus: Boolean) {
        windowHasFocus = hasFocus
        if (pendingJoin == null) return
        if (hasFocus) {
            joinTimeout?.resume()
        } else {
            windowLostFocusDuringJoin = true
            joinTimeout?.pause()
        }
    }

    // wifi.ensurePermissions

    suspend fun ensurePermissions(): JSONObject {
        if (!hasJoinPermission()) {
            host.requestPermissions(joinPermissions())
            if (!hasJoinPermission()) {
                throw BridgeException(
                    ErrorCode.LOCATION_PERMISSION_DENIED,
                    "${joinPermissionLabel()} permission was not granted",
                )
            }
        }
        requireLocationServicesIfNeeded()
        return JSONObject()
    }

    // wifi.join

    suspend fun join(ssid: String, password: String, timeoutMs: Long): JSONObject {
        if (!hasJoinPermission()) {
            throw BridgeException(
                ErrorCode.LOCATION_PERMISSION_DENIED,
                "${joinPermissionLabel()} permission missing; call wifi.ensurePermissions first",
            )
        }
        requireLocationServicesIfNeeded()

        if (callback != null && network != null && joinedSsid == ssid) {
            return joinResult(pickerShown = false)
        }
        release(reason = "superseded by a new wifi.join", resetRouting = false)

        val builder = WifiNetworkSpecifier.Builder()
        try {
            builder.setSsid(ssid)
        } catch (e: IllegalArgumentException) {
            throw BridgeException.invalidParams("invalid ssid: ${e.message}")
        }
        if (password.isNotEmpty()) {
            try {
                builder.setWpa2Passphrase(password)
            } catch (e: IllegalArgumentException) {
                throw BridgeException(ErrorCode.INVALID_PASSPHRASE, "invalid WPA2 passphrase: ${e.message}")
            }
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // The charger hotspot has no internet, so a peer-to-peer request must not ask for it
            // (as in the platform docs for WifiNetworkSpecifier).
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(builder.build())
            .build()

        val joined = CompletableDeferred<Network>()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(available: Network) {
                if (callback !== this) return
                Log.i(TAG, "charger network available")
                network = available
                joinedSsid = ssid
                onNetworkChanged()
                joined.complete(available)
            }

            override fun onLost(lost: Network) {
                if (callback !== this || network != lost) return
                Log.i(TAG, "charger network lost")
                network = null
                onNetworkChanged()
            }

            override fun onUnavailable() {
                if (callback !== this) return
                // Android doesn't say why: the user cancelled the dialog, the network wasn't found,
                // or the passphrase was wrong all look the same. (Timeouts are ours, below.)
                joined.completeExceptionally(
                    BridgeException(
                        ErrorCode.UNABLE_TO_CONNECT,
                        "network request for $ssid was declined or failed " +
                            "(dialog cancelled, network not found or wrong passphrase)",
                    ),
                )
            }
        }

        callback = cb
        pendingJoin = joined
        windowLostFocusDuringJoin = false
        val timedOut: () -> Unit = {
            joined.completeExceptionally(
                BridgeException(ErrorCode.TIMEOUT_OCCURRED, "not connected to $ssid within ${timeoutMs}ms"),
            )
        }
        // Counts only while the Link screen has focus, i.e. not while the approval dialog is up...
        val timeout = PausableTimeout(timeoutMs, scheduler, SystemClock::elapsedRealtime, timedOut)
        // ...with a cap, so a dialog left open (or focus lost for another reason) can't hang the join.
        val cap = scheduler.schedule(timeoutMs + MAX_APPROVAL_WAIT_MS, timedOut)
        joinTimeout = timeout
        if (windowHasFocus) timeout.resume()
        try {
            // Without requestNetwork's own timeout: that one runs while the dialog is showing.
            connectivity.requestNetwork(request, cb, mainHandler)
        } catch (e: SecurityException) {
            endJoin(joined, timeout, cap)
            clearIfCurrent(cb)
            throw BridgeException(ErrorCode.LOCATION_PERMISSION_DENIED, "requestNetwork: ${e.message}")
        } catch (e: RuntimeException) {
            endJoin(joined, timeout, cap)
            clearIfCurrent(cb)
            throw BridgeException(ErrorCode.UNABLE_TO_CONNECT, "requestNetwork failed: $e")
        }

        try {
            joined.await()
        } catch (e: Throwable) {
            // BridgeException from onUnavailable / the timeout / a newer join / leave, or the scope
            // being cancelled. Unregistering also takes the approval dialog down.
            releaseIfCurrent(cb)
            throw e
        } finally {
            endJoin(joined, timeout, cap)
        }
        return joinResult(pickerShown = windowLostFocusDuringJoin)
    }

    private fun endJoin(joined: CompletableDeferred<Network>, timeout: PausableTimeout, cap: Cancellable) {
        timeout.cancel()
        cap.cancel()
        if (joinTimeout === timeout) joinTimeout = null
        if (pendingJoin === joined) pendingJoin = null
    }

    private fun joinResult(pickerShown: Boolean): JSONObject =
        JSONObject()
            .put("via", "specifier")
            .put("pickerShown", pickerShown)
            // Android remembers the approval per app + SSID, so later joins don't prompt.
            .put("silentRejoin", true)

    // wifi.leave

    fun leave() {
        release(reason = "wifi.leave", resetRouting = true)
    }

    fun dispose() {
        release(reason = "Link screen closed", resetRouting = true)
    }

    // wifi.currentSsid

    fun currentSsid(): String? {
        val joined = joinedSsid
        if (joined != null && network != null) return joined
        return try {
            @Suppress("DEPRECATION")
            normalizeSsid(wifiManager?.connectionInfo?.ssid)
        } catch (_: SecurityException) {
            null
        }
    }

    // wifi.routeTraffic

    fun setRouteTraffic(enabled: Boolean) {
        if (enabled && network == null) {
            throw BridgeException(ErrorCode.UNABLE_TO_CONNECT, "no joined charger network; call wifi.join first")
        }
        routeTraffic = enabled
        onNetworkChanged()
    }

    // Internals

    private fun release(reason: String, resetRouting: Boolean) {
        pendingJoin?.completeExceptionally(BridgeException(ErrorCode.UNABLE_TO_CONNECT, "join cancelled: $reason"))
        pendingJoin = null
        callback?.let(::unregister)
        callback = null
        joinedSsid = null
        network = null
        if (resetRouting) routeTraffic = false
        onNetworkChanged()
    }

    private fun releaseIfCurrent(cb: ConnectivityManager.NetworkCallback) {
        if (callback === cb) {
            unregister(cb)
            clearIfCurrent(cb)
            onNetworkChanged()
        } else {
            // onUnavailable already ended the request, or a newer join replaced it.
            unregister(cb)
        }
    }

    private fun clearIfCurrent(cb: ConnectivityManager.NetworkCallback) {
        if (callback !== cb) return
        callback = null
        joinedSsid = null
        network = null
    }

    private fun unregister(cb: ConnectivityManager.NetworkCallback) {
        try {
            connectivity.unregisterNetworkCallback(cb)
        } catch (_: IllegalArgumentException) {
            // Not registered (anymore).
        }
    }

    private fun joinPermissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
            arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        // Android 12+ ignores a FINE request that doesn't also ask for COARSE.
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        else -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun hasJoinPermission(): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }
        return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun joinPermissionLabel(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) "Nearby Wi-Fi devices" else "Precise location"

    /** Up to API 32 Wi-Fi scans (and so network requests) need location services switched on. */
    private fun requireLocationServicesIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
        val location = context.getSystemService(LocationManager::class.java)
        if (location != null && !location.isLocationEnabled) {
            throw BridgeException(ErrorCode.LOCATION_SERVICES_OFF, "location services are switched off")
        }
    }

    companion object {
        private const val TAG = "Plugchoice"

        /**
         * How much longer than `timeoutMs` a join may take in all while the screen lacks focus.
         * Under the Link UI's own deadline for the call (`timeoutMs` + 120 s), so the shell answers
         * first and takes the dialog down.
         */
        private const val MAX_APPROVAL_WAIT_MS = 110_000L

        fun normalizeSsid(raw: String?): String? {
            if (raw == null) return null
            val ssid = if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
                raw.substring(1, raw.length - 1)
            } else {
                raw
            }
            return ssid.takeUnless { it.isEmpty() || it == "<unknown ssid>" }
        }
    }
}
