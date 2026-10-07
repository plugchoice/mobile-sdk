package com.plugchoice.internal

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.Locale

/**
 * `lan.discover` / `lan.stopDiscovery` (PROTOCOL.md §9.4): browses DNS-SD on the network
 * the phone is on and resolves what it finds, with [NsdManager]. Any service type: Android needs
 * no declaration (`hello`'s `lanServiceTypes` is `null`).
 *
 * Android only delivers multicast while a [WifiManager.MulticastLock] is held, so the browse holds
 * one; and before API 34 NsdManager resolves one service at a time, so resolves are queued.
 * Main thread only.
 */
internal class LanDiscovery(context: Context) {
    private val appContext = context.applicationContext
    private var browse: Browse? = null

    val isRunning: Boolean
        get() = browse != null

    /** Throws `busy` while another browse runs. [callback] runs on the main thread. */
    fun discover(request: DiscoverRequest, callback: (Result<JSONObject>) -> Unit) {
        if (browse != null) throw BridgeException(ErrorCode.BUSY, "a lan.discover is already running")
        lateinit var started: Browse
        started = Browse(appContext, request) { result ->
            if (browse === started) browse = null
            callback(result)
        }
        browse = started
        started.start()
    }

    /** `lan.stopDiscovery`: the running browse answers with what it found. */
    fun stop() {
        browse?.finish()
    }

    /** The page is gone: stops, answering `network`. */
    fun cancel() {
        browse?.finish(BridgeException(ErrorCode.NETWORK, "the page that started the browse went away"))
    }

    class DiscoverRequest(val types: List<String>, val timeoutMs: Long, val stopOnName: String?)

    companion object {
        /** A DNS-SD service type: `_name._tcp` or `_name._udp` (subtype labels allowed), a trailing dot optional. */
        private val SERVICE_TYPE = Regex("^(_[A-Za-z0-9][A-Za-z0-9-]{0,62}\\.)+_(tcp|udp)\\.?$")

        /** `lan.discover` params, checked. Any service type (§9.4). */
        fun parseRequest(params: JSONObject): DiscoverRequest {
            val types = params.requireStringList("types")
            val timeoutMs = params.requireTimeoutMs("timeoutMs")
            val stopOnName = params.optStringOrNull("stopOnName")?.takeIf { it.isNotEmpty() }
            for (type in types) {
                if (!SERVICE_TYPE.matches(type)) throw BridgeException.invalidParams("$type is not a DNS-SD service type")
            }
            return DiscoverRequest(types.map { it.removeSuffix(".") }.distinct(), timeoutMs, stopOnName)
        }
    }
}

/** What a browse found, in the order found. Pure, so tests can drive it. */
internal class DiscoveredServices(private val stopOnName: String?) {
    private class Entry(val name: String) {
        val addresses = mutableListOf<String>()
        var port = 0
        var txt: Map<String, String> = emptyMap()
    }

    private val entries = LinkedHashMap<String, Entry>()

    val isEmpty: Boolean
        get() = entries.isEmpty()

    /** An instance turned up (not resolved yet). */
    fun found(name: String, type: String) {
        entries.getOrPut(key(name, type)) { Entry(name) }
    }

    /**
     * An instance resolved (possibly again, with more addresses). Returns true when the browse
     * should stop: its name matches `stopOnName` and it has an IPv4 address.
     */
    fun resolved(name: String, type: String, addresses: List<String>, port: Int, txt: Map<String, String>?): Boolean {
        val entry = entries.getOrPut(key(name, type)) { Entry(name) }
        for (address in addresses) if (address !in entry.addresses) entry.addresses += address
        val ordered = entry.addresses.filter(::isIpv4) + entry.addresses.filterNot(::isIpv4)
        entry.addresses.clear()
        entry.addresses += ordered
        if (port > 0) entry.port = port
        if (!txt.isNullOrEmpty()) entry.txt = txt
        return matches(name, stopOnName) && entry.addresses.any(::isIpv4)
    }

    /** `[{ name, addresses, port, txt }]`; `addresses` empty and `port` 0 when resolving failed. */
    fun toJson(): JSONArray {
        val list = JSONArray()
        for (entry in entries.values) {
            val txt = JSONObject()
            for ((key, value) in entry.txt) txt.put(key, value)
            list.put(
                JSONObject()
                    .put("name", entry.name)
                    .put("addresses", JSONArray(entry.addresses))
                    .put("port", entry.port)
                    .put("txt", txt),
            )
        }
        return list
    }

    companion object {
        /** The lower-cased name contains the lower-cased `stopOnName`. */
        fun matches(name: String, stopOnName: String?): Boolean =
            stopOnName != null && name.lowercase(Locale.ROOT).contains(stopOnName.lowercase(Locale.ROOT))

        fun isIpv4(address: String): Boolean {
            val parts = address.split('.')
            return parts.size == 4 && parts.all { part -> part.isNotEmpty() && part.length <= 3 && part.all(Char::isDigit) && part.toInt() <= 255 }
        }

        /** "192.168.1.10", or an IPv6 address without its scope ("fe80::1"). */
        fun text(address: InetAddress): String? = when (address) {
            is Inet4Address -> address.hostAddress
            is Inet6Address -> address.hostAddress?.substringBefore('%')
            else -> null
        }

        private fun key(name: String, type: String) = "$type\u0000$name"
    }
}

/** One `lan.discover` run. Main thread; NsdManager's callbacks are posted to it. */
private class Browse(
    private val context: Context,
    private val request: LanDiscovery.DiscoverRequest,
    private val onFinished: (Result<JSONObject>) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val results = DiscoveredServices(request.stopOnName)
    private val listeners = mutableListOf<NsdManager.DiscoveryListener>()
    private val failures = mutableMapOf<String, String>()
    private val pending = ArrayDeque<Pair<String, NsdServiceInfo>>()
    private var resolving = false
    private var finished = false
    private var lock: WifiManager.MulticastLock? = null
    private val deadline = Runnable { finish() }

    fun start() {
        if (nsd == null) {
            finish(BridgeException(ErrorCode.NETWORK, "this device has no network service discovery"))
            return
        }
        lock = context.getSystemService(WifiManager::class.java)?.createMulticastLock("Plugchoice:lan.discover")?.apply {
            setReferenceCounted(false)
            acquire()
        }
        for (type in request.types) {
            val listener = discoveryListener(type)
            try {
                nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
                listeners += listener
            } catch (e: RuntimeException) {
                failures[type] = "$type: ${e.message}"
            }
        }
        checkAllFailed()
        if (!finished) main.postDelayed(deadline, request.timeoutMs)
    }

    /** Answers with what was found, or with [error]; `network` when nothing could be browsed. */
    fun finish(error: BridgeException? = null) {
        if (finished) return
        finished = true
        main.removeCallbacks(deadline)
        for (listener in listeners) {
            try {
                nsd?.stopServiceDiscovery(listener)
            } catch (_: RuntimeException) {
                // Already stopped, or it never started.
            }
        }
        listeners.clear()
        pending.clear()
        lock?.release()
        lock = null
        val result = when {
            error != null -> Result.failure(error)
            results.isEmpty && failures.size == request.types.size ->
                Result.failure(BridgeException(ErrorCode.NETWORK, failures.values.joinToString("; ")))
            else -> Result.success(JSONObject().put("services", results.toJson()))
        }
        onFinished(result)
    }

    private fun checkAllFailed() {
        if (failures.size == request.types.size) finish()
    }

    private fun discoveryListener(type: String) = object : NsdManager.DiscoveryListener {
        override fun onServiceFound(info: NsdServiceInfo) {
            main.post {
                if (finished) return@post
                results.found(info.serviceName, type)
                pending.addLast(type to info)
                resolveNext()
            }
        }

        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            main.post {
                if (finished) return@post
                failures[type] = "$type: discovery failed to start ($errorCode)"
                checkAllFailed()
            }
        }

        override fun onServiceLost(info: NsdServiceInfo) {}
        override fun onDiscoveryStarted(serviceType: String) {}
        override fun onDiscoveryStopped(serviceType: String) {}
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
    }

    @Suppress("DEPRECATION") // resolveService: its replacement (registerServiceInfoCallback) is API 34+.
    private fun resolveNext() {
        if (resolving || finished) return
        val (type, info) = pending.removeFirstOrNull() ?: return
        resolving = true
        try {
            nsd?.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    main.post {
                        // It stays in the results with no addresses.
                        resolving = false
                        resolveNext()
                    }
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    main.post {
                        resolving = false
                        if (finished) return@post
                        resolved(type, info)
                        resolveNext()
                    }
                }
            })
        } catch (e: RuntimeException) {
            Log.w(TAG, "lan.discover: resolve failed: $e")
            resolving = false
            resolveNext()
        }
    }

    private fun resolved(type: String, info: NsdServiceInfo) {
        val hosts = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            info.hostAddresses
        } else {
            @Suppress("DEPRECATION")
            listOfNotNull(info.host)
        }
        val txt = info.attributes.mapValues { (_, value) -> value?.toString(Charsets.UTF_8).orEmpty() }
        if (results.resolved(info.serviceName, type, hosts.mapNotNull(DiscoveredServices::text), info.port, txt)) {
            finish()
        }
    }

    private companion object {
        const val TAG = "Plugchoice"
    }
}

/** `lan.address` (PROTOCOL.md §9.4). */
internal object LanAddress {
    /**
     * The phone's IPv4 address and netmask on Wi-Fi: the default network when it's Wi-Fi, else
     * another Wi-Fi network, the charger network from `wifi.join` ([joined]) last. Both null off
     * Wi-Fi.
     */
    @Suppress("DEPRECATION") // allNetworks: the alternative is a callback, too much for one lookup.
    fun current(context: Context, joined: Network?): JSONObject {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val candidates = buildList {
            connectivity?.activeNetwork?.let(::add)
            connectivity?.allNetworks?.forEach { if (it !in this && it != joined) add(it) }
            if (joined != null && joined !in this) add(joined)
        }
        for (network in candidates) {
            val capabilities = connectivity?.getNetworkCapabilities(network) ?: continue
            if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            val address = connectivity.getLinkProperties(network)?.linkAddresses?.firstOrNull { it.address is Inet4Address } ?: continue
            return toJson(address)
        }
        return JSONObject().put("ip", JSONObject.NULL).put("netmask", JSONObject.NULL)
    }

    private fun toJson(address: LinkAddress): JSONObject =
        JSONObject().put("ip", address.address.hostAddress).put("netmask", netmask(address.prefixLength))

    /** A prefix length as a dotted netmask: 24 → "255.255.255.0". */
    fun netmask(prefixLength: Int): String {
        val mask = if (prefixLength <= 0) 0L else (0xFFFFFFFFL shl (32 - prefixLength.coerceAtMost(32))) and 0xFFFFFFFFL
        return listOf(24, 16, 8, 0).joinToString(".") { ((mask shr it) and 0xFF).toString() }
    }
}
