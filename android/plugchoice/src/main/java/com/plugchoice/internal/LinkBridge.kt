package com.plugchoice.internal

import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.WebView
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import com.plugchoice.LinkResult
import com.plugchoice.Plugchoice
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * The native side of the bridge protocol (`bridge/PROTOCOL.md`).
 *
 * Page → native: `window.plugchoiceLinkAndroid.postMessage(json)`, delivered by WebView to
 * [onPostMessage] only for frames whose origin is in [origins] (registered as
 * `allowedOriginRules`). Native → page: `window.PlugchoiceLinkBridge.receive("<json>")` via
 * `evaluateJavascript` on the main thread.
 *
 * Requests run in a main-thread scope; blocking work happens on OkHttp's threads or in
 * suspending system callbacks, never on the main thread.
 */
internal class LinkBridge(
    private val host: BridgeHost,
    private val webView: WebView,
    private val origins: OriginAllowList,
    /** The action the screen opened with: reported when the shell closes by itself, or the page leaves it out. */
    private val action: String,
    /** The host app's callback (`Plugchoice(fetchClientSecret)`) bound to the screen's action, for `auth.clientSecret`. */
    fetchClientSecret: suspend () -> String,
) : WebViewCompat.WebMessageListener {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val wifi: WifiController = WifiController(host, onNetworkChanged = { net.onNetworkChanged() })
    private val net: LocalNetworkClient = LocalNetworkClient(wifi, emit = this::emitEvent)
    private val scanner = CodeScanner(host)
    private val discovery = LanDiscovery(host.hostContext)
    private val sessions = HttpSessions(TlsSessionConnector)
    private val tcp = TcpSockets(emit = this::emitEvent)
    private val udp = UdpExchanges()
    private val ble = BleManager(host, emit = this::emitEvent)
    private val closeRequests = CloseRequests(
        scheduler = HandlerScheduler(mainHandler),
        sendCloseRequested = { emitEvent("ui.closeRequested", JSONObject()) },
        close = { host.closeSession(LinkResult(LinkResult.Status.CANCELLED, action)) },
    )
    private val clientSecrets = ClientSecrets(scope, fetchClientSecret)
    private val bluetoothAvailable: Boolean by lazy { Transports.bluetoothAvailable(host.hostContext) }
    private var disposed = false

    /** Bumped for each new document: answers to the previous document's requests are dropped. */
    private var document = 0

    /** §2: fetch the client secret while the page loads. */
    fun prefetchClientSecret() {
        clientSecrets.prefetch()
    }

    override fun onPostMessage(
        view: WebView,
        message: WebMessageCompat,
        sourceOrigin: Uri,
        isMainFrame: Boolean,
        replyProxy: JavaScriptReplyProxy,
    ) {
        if (disposed) return
        if (!isMainFrame) {
            Log.w(TAG, "dropped a message from a subframe ($sourceOrigin)")
            return
        }
        if (message.type != WebMessageCompat.TYPE_STRING) return
        val request = try {
            JSONObject(message.data ?: return)
        } catch (_: JSONException) {
            Log.w(TAG, "dropped a message that is not a JSON object")
            return
        }
        if (request.opt("type") != "request") return
        // Without an id there is nobody to answer.
        val id = request.opt("id") as? String ?: return
        val method = request.opt("method") as? String
        val params = when (val raw = request.opt("params")) {
            null, JSONObject.NULL -> JSONObject()
            is JSONObject -> raw
            else -> null
        }

        val requestDocument = document
        scope.launch {
            val response = try {
                if (method == null) throw BridgeException.invalidParams("method must be a string")
                if (params == null) throw BridgeException.invalidParams("params must be an object")
                val result = handle(method, params)
                Log.d(TAG, "$method ($id) ok")
                JSONObject().put("type", "response").put("id", id).put("ok", true).put("result", result)
            } catch (e: BridgeException) {
                Log.i(TAG, "$method ($id) failed: ${e.code}: ${e.message}")
                errorResponse(id, e.code, e.message ?: e.code, e.details)
            } catch (e: CancellationException) {
                throw e // the screen is closing; nobody to answer
            } catch (e: Throwable) {
                Log.e(TAG, "$method ($id) crashed", e)
                errorResponse(id, ErrorCode.INTERNAL, e.toString())
            }
            // The page that asked went away (§2): its answer goes nowhere.
            if (requestDocument == document) deliver(response)
        }
    }

    private suspend fun handle(method: String, params: JSONObject): JSONObject = when (method) {
        "hello" -> hello()
        "wifi.ensurePermissions" -> wifi.ensurePermissions()
        "wifi.join" -> {
            val ssid = params.requireString("ssid")
            if (ssid.toByteArray(Charsets.UTF_8).size > MAX_SSID_BYTES) throw BridgeException.invalidParams("ssid must be 1 to 32 bytes")
            val password = params.requireString("password", allowEmpty = true)
            val timeoutMs = params.requireTimeoutMs("timeoutMs")
            // Checked, but the system's approval dialog shows neither.
            params.optStringOrNull("displayName")
            params.optStringOrNull("productImageUrl")
            wifi.join(ssid, password, timeoutMs)
        }
        "wifi.leave" -> {
            // Best effort, never fails; Android drops the one network it joined, whatever `ssid` says.
            params.requireString("ssid")
            wifi.leave()
            JSONObject()
        }
        "wifi.currentSsid" -> JSONObject().put("ssid", wifi.currentSsid() ?: JSONObject.NULL)
        "wifi.routeTraffic" -> {
            wifi.setRouteTraffic(params.requireBoolean("enabled"))
            JSONObject()
        }
        "http.request" -> net.request(params)
        "http.cancel" -> net.cancel(params)
        "ws.open" -> net.openSocket(params)
        "ws.send" -> net.sendOnSocket(params)
        "ws.close" -> net.closeSocket(params)
        "session.close" -> closeSession(params)
        "auth.clientSecret" -> JSONObject().put("clientSecret", clientSecrets.next())
        "ui.closeHandled" -> {
            closeRequests.onPageAnswered()
            JSONObject()
        }
        "camera.scanCode" -> scanner.scan(params)
        "lan.discover" -> discover(LanDiscovery.parseRequest(params))
        "lan.stopDiscovery" -> {
            discovery.stop()
            JSONObject()
        }
        "lan.address" -> LanAddress.current(host.hostContext, wifi.network)
        "http.session.open" -> openSession(HttpSessions.parseOpen(params))
        "http.session.request" -> {
            val (sessionId, request) = HttpSessions.parseRequest(params)
            awaitResult { callback -> sessions.request(sessionId, request, callback) }
        }
        "http.session.close" -> {
            sessions.close(params.requireString("sessionId"))
            JSONObject()
        }
        "tcp.open" -> {
            val request = TcpSockets.parseOpen(params)
            val route = route()
            awaitResult { callback -> tcp.open(request, route, callback) }
        }
        "tcp.write" -> {
            val socketId = params.requireString("socketId")
            val data = params.requireBase64("data")
            awaitResult { callback -> tcp.write(socketId, data, callback) }
        }
        "tcp.close" -> {
            tcp.close(params.requireString("socketId"))
            JSONObject()
        }
        "udp.exchange" -> {
            val request = UdpExchanges.parse(params)
            val route = route()
            awaitResult { callback -> udp.exchange(request, route, callback) }
        }
        "ble.ensurePermissions" -> {
            ble.ensureReady(scanning = true)
            JSONObject()
        }
        "ble.scan" -> {
            val request = BleRequests.scan(params)
            ble.ensureReady(scanning = true)
            awaitResult { callback -> ble.scan(request, callback) }
        }
        "ble.stopScan" -> {
            ble.stopScan()
            JSONObject()
        }
        "ble.connect" -> {
            val request = BleRequests.connect(params)
            ble.ensureReady(scanning = false)
            awaitResult { callback -> ble.connect(request, callback) }
        }
        "ble.read" -> {
            val target = BleRequests.characteristic(params)
            ble.ensureReady(scanning = false)
            awaitResult { callback -> ble.connection(target.deviceId).read(target.service, target.characteristic, callback) }
        }
        "ble.write" -> {
            val write = BleRequests.write(params)
            val target = write.target
            ble.ensureReady(scanning = false)
            awaitResult { callback ->
                ble.connection(target.deviceId).write(target.service, target.characteristic, write.value, write.withResponse, callback)
            }
        }
        "ble.subscribe", "ble.unsubscribe" -> {
            val target = BleRequests.characteristic(params)
            ble.ensureReady(scanning = false)
            awaitResult { callback ->
                ble.connection(target.deviceId).subscribe(target.service, target.characteristic, enable = method == "ble.subscribe", callback)
            }
        }
        "ble.disconnect" -> {
            ble.disconnect(params.requireString("deviceId"))
            JSONObject()
        }
        else -> throw BridgeException(ErrorCode.UNSUPPORTED_METHOD, "unknown method $method")
    }

    private suspend fun discover(request: LanDiscovery.DiscoverRequest): JSONObject =
        awaitResult { callback -> discovery.discover(request, callback) }

    /** The route is fixed when the session opens ([route]). */
    private suspend fun openSession(request: HttpSessions.OpenRequest): JSONObject {
        val route = route()
        return awaitResult { callback -> sessions.open(request, route, callback) }
    }

    /**
     * Over the joined charger network while `wifi.routeTraffic` is on, like `http.request` (sockets
     * bound to it, never the process); `network` when routing is on but that network is gone.
     */
    private fun route(): SocketRoute {
        if (!wifi.routeTraffic) return SocketRoute.DEFAULT
        val network = wifi.network
            ?: throw BridgeException(ErrorCode.NETWORK, "traffic routing is on but the charger network is not connected")
        return SocketRoute({ network.socketFactory.createSocket() }, { network.getAllByName(it).toList() }, network::bindSocket)
    }

    /** Starts a callback-style call (which may throw before it starts) and waits for its result. */
    private suspend fun awaitResult(start: (callback: (Result<JSONObject>) -> Unit) -> Unit): JSONObject =
        suspendCancellableCoroutine { continuation ->
            try {
                start { result -> continuation.resumeWith(result) }
            } catch (e: BridgeException) {
                continuation.resumeWith(Result.failure(e))
            }
        }

    /**
     * `{}` (anything in it is ignored). The page draws its own close control, so the native one
     * goes once this is answered (the response is delivered in the same main-thread turn), and the
     * page decides about native closes from now on (§6.2). `lanServiceTypes` is `null`:
     * `lan.discover` browses any type on Android (§5).
     */
    private fun hello(): JSONObject {
        closeRequests.pageHandlesClose = true
        host.setNativeCloseButtonVisible(false)
        return JSONObject()
            .put("bridgeVersion", BRIDGE_VERSION)
            .put("sdkVersion", Plugchoice.SDK_VERSION)
            .put("platform", "android")
            .put("osVersion", Build.VERSION.RELEASE)
            .put("capabilities", JSONArray(capabilities(bluetoothAvailable)))
            .put("lanServiceTypes", JSONObject.NULL)
    }

    /** `{ status, sessionId?, action?, devices?, error? }` ([SessionClose]). */
    private fun closeSession(params: JSONObject): JSONObject {
        val result = SessionClose.parse(params, action)
        closeRequests.onPageAnswered()
        // Posted, so the {} response is evaluated before the screen goes away.
        mainHandler.post { host.closeSession(result) }
        return JSONObject()
    }

    /**
     * Back or the native close button. Before `hello` the screen closes at once (`cancelled`); after
     * it the page gets `ui.closeRequested` and 1 s to answer (§6.2).
     */
    fun requestClose() {
        if (disposed) return
        closeRequests.request()
    }

    /**
     * Main-frame navigation started a new document: the old page's requests are cancelled and
     * their answers dropped, and the new page hasn't said `hello` yet (native close button, native
     * closing). A close request already waiting keeps its deadline: the user asked to leave.
     */
    fun onNewDocument() {
        document++
        net.resetForNewDocument()
        discovery.cancel()
        sessions.closeAll()
        tcp.closeAll()
        udp.cancelAll()
        ble.onNewDocument()
        closeRequests.pageHandlesClose = false
        host.setNativeCloseButtonVisible(true)
    }

    fun onWindowFocusChanged(hasFocus: Boolean) {
        wifi.onWindowFocusChanged(hasFocus)
    }

    /** Idempotent. Cancels everything, closes every session and leaves the charger network. */
    fun dispose() {
        if (disposed) return
        disposed = true
        closeRequests.dispose()
        scope.cancel()
        discovery.cancel()
        sessions.dispose()
        tcp.dispose()
        udp.dispose()
        ble.dispose()
        net.dispose()
        wifi.dispose()
    }

    private fun errorResponse(id: String, code: String, message: String, details: JSONObject? = null): JSONObject =
        JSONObject()
            .put("type", "response")
            .put("id", id)
            .put("ok", false)
            .put("error", JSONObject().put("code", code).put("message", message).apply { if (details != null) put("details", details) })

    /**
     * Always posted, from any thread: keeps events in order and after the response to the
     * request that caused them (responses are delivered synchronously on the main thread).
     */
    private fun emitEvent(event: String, params: JSONObject) {
        val message = JSONObject().put("type", "event").put("event", event).put("params", params)
        mainHandler.post { deliver(message) }
    }

    private fun deliver(message: JSONObject) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (disposed) return
        // Never hand charger data to a page from an origin that may not use the bridge.
        if (!origins.allows(webView.url)) {
            Log.w(TAG, "dropped a ${message.optString("type")}: the current page's origin is not allowed")
            return
        }
        webView.evaluateJavascript("window.PlugchoiceLinkBridge.receive(${jsStringLiteral(message.toString())})", null)
    }

    companion object {
        const val JS_OBJECT_NAME = "plugchoiceLinkAndroid"
        const val BRIDGE_VERSION = 1
        private const val TAG = "Plugchoice"
        private const val MAX_SSID_BYTES = 32

        /**
         * `hello`'s capabilities (§5). No `wifi.accessory` on Android (that's AccessorySetupKit on
         * iOS); `ble` when [bluetoothAvailable] (the device has Bluetooth LE and the host kept the
         * library's Bluetooth permissions).
         */
        fun capabilities(bluetoothAvailable: Boolean): List<String> = buildList {
            addAll(listOf("wifi.join", "http.request", "ws", "session.close", "camera.scanCode", "ui.closeRequest"))
            addAll(listOf("lan.address", "lan.discover", "http.session", "auth.clientSecret"))
            if (bluetoothAvailable) add("ble")
            addAll(listOf("tcp", "udp", "trust.custom"))
        }

        /** A JSON-encoded JS string literal; U+2028/U+2029 escaped for pre-ES2019 engines. */
        fun jsStringLiteral(value: String): String =
            JSONObject.quote(value).replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    }
}
