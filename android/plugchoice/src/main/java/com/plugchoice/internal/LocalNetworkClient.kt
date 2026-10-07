package com.plugchoice.internal

import android.net.Network
import android.util.Log
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionPool
import okhttp3.Dispatcher
import okhttp3.Dns
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.io.IOException
import java.io.InterruptedIOException
import java.net.Proxy
import java.net.SocketTimeoutException
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * `http.*` and `ws.*`: requests to devices on the local network, over the joined charger
 * network when `wifi.routeTraffic` is on (sockets bound per connection, never the process).
 *
 * No cookie jar (OkHttp's default is none), no redirects, no proxy, private hosts only. TLS: the
 * system's trust, or the page's `trust` object for an `https`/`wss` URL (§9.8); a refusal of
 * that trust answers `tls` with `details.presentedFingerprint` (`http.request`) or a `ws.error`
 * with `code: "tls"` and the same `details` (`ws.open`).
 */
internal class LocalNetworkClient(
    private val wifi: WifiController,
    /** Sends an event to the page; safe to call from any thread. */
    private val emit: (event: String, params: JSONObject) -> Unit,
) {
    private val baseClient: OkHttpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .proxy(Proxy.NO_PROXY)
        .dns(LocalOnlyDns(Dns.SYSTEM::lookup))
        .dispatcher(Dispatcher().apply { maxRequestsPerHost = 16 })
        .build()

    private val clientLock = Any()
    private var boundNetwork: Network? = null
    private var boundClient: OkHttpClient? = null

    private val calls = ConcurrentHashMap<String, Call>()
    private val cancelledByPage: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val sockets = ConcurrentHashMap<String, Socket>()

    /** The client for the next call: bound to the charger network when routing is on. */
    private fun client(): OkHttpClient {
        if (!wifi.routeTraffic) return baseClient
        val network = wifi.network
            ?: throw BridgeException(ErrorCode.NETWORK, "traffic routing is on but the charger network is not connected")
        synchronized(clientLock) {
            boundClient?.let { if (boundNetwork == network) return it }
            boundClient?.connectionPool?.evictAll()
            return baseClient.newBuilder()
                .socketFactory(network.socketFactory)
                .dns(LocalOnlyDns { host -> network.getAllByName(host).toList() })
                .connectionPool(ConnectionPool())
                .build()
                .also {
                    boundNetwork = network
                    boundClient = it
                }
        }
    }

    /** The joined network changed or went away: drop pooled connections bound to the old one. */
    fun onNetworkChanged() {
        synchronized(clientLock) {
            if (boundNetwork != null && boundNetwork != wifi.network) {
                boundClient?.connectionPool?.evictAll()
                boundClient = null
                boundNetwork = null
            }
        }
    }

    // http.request

    suspend fun request(params: JSONObject): JSONObject {
        val requestId = params.requireString("requestId")
        val url = HostAllowList.checkedUrl(params.requireString("url"), HostAllowList.HTTP_SCHEMES)
        val method = params.requireString("method").uppercase(Locale.ROOT)
        if (method !in HTTP_METHODS) throw BridgeException.invalidParams("method must be one of $HTTP_METHODS")
        val headers = buildHeaders(params.optHeaders())
        val body = params.optStringOrNull("body")
        val timeoutMs = params.requireTimeoutMs("timeoutMs")
        val evaluator = Trust.parse(params.opt("trust"))?.takeIf { url.isHttps }?.let { TrustEvaluator(it, url.host) }

        val request = Request.Builder()
            .url(url)
            .headers(headers)
            .method(method, requestBody(method, body, headers))
            .build()
        val call = client().newBuilder()
            .callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .writeTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .apply { if (evaluator != null) trusting(evaluator) }
            .build()
            .newCall(request)
        if (calls.putIfAbsent(requestId, call) != null) {
            throw BridgeException.invalidParams("requestId $requestId is already in flight")
        }
        try {
            return call.awaitResult()
        } catch (e: IOException) {
            throw when {
                cancelledByPage.contains(requestId) ->
                    BridgeException(ErrorCode.CANCELLED, "cancelled by http.cancel")
                evaluator?.rejected == true -> evaluator.tlsError()
                e is SocketTimeoutException || (e is InterruptedIOException && e.message == "timeout") ->
                    BridgeException(ErrorCode.TIMEOUT, "no response within ${timeoutMs}ms ($e)")
                else -> BridgeException(ErrorCode.NETWORK, e.toString())
            }
        } finally {
            calls.remove(requestId, call)
            cancelledByPage.remove(requestId)
        }
    }

    // http.cancel

    fun cancel(params: JSONObject): JSONObject {
        val requestId = params.requireString("requestId")
        calls[requestId]?.let { call ->
            cancelledByPage.add(requestId)
            call.cancel()
        }
        return JSONObject()
    }

    // ws.open

    fun openSocket(params: JSONObject): JSONObject {
        val socketId = params.requireString("socketId")
        val url = HostAllowList.checkedUrl(params.requireString("url"), HostAllowList.WEB_SOCKET_SCHEMES)
        val headers = buildHeaders(params.optHeaders())
        val evaluator = Trust.parse(params.opt("trust"))?.takeIf { url.isHttps }?.let { TrustEvaluator(it, url.host) }

        val socket = Socket(socketId, evaluator)
        if (sockets.putIfAbsent(socketId, socket) != null) {
            throw BridgeException.invalidParams("socketId $socketId is already open")
        }
        val client = try {
            client()
        } catch (e: BridgeException) {
            // The attempt "started" and failed: report it as events, like any connect failure.
            socket.fail(e.message ?: "network unavailable")
            return JSONObject()
        }
        val trusted = if (evaluator != null) client.newBuilder().trusting(evaluator).build() else client
        socket.webSocket = trusted.newWebSocket(Request.Builder().url(url).headers(headers).build(), socket)
        return JSONObject()
    }

    // ws.send

    fun sendOnSocket(params: JSONObject): JSONObject {
        val socketId = params.requireString("socketId")
        val data = params.requireString("data", allowEmpty = true)
        val socket = sockets[socketId] ?: throw BridgeException.invalidParams("no open socket $socketId")
        val webSocket = socket.webSocket ?: throw BridgeException(ErrorCode.NETWORK, "socket $socketId is not connected")
        // OkHttp queues frames sent before the handshake completes.
        if (!webSocket.send(data)) throw BridgeException(ErrorCode.NETWORK, "socket $socketId is closing or closed")
        return JSONObject()
    }

    // ws.close

    fun closeSocket(params: JSONObject): JSONObject {
        val socketId = params.requireString("socketId")
        sockets[socketId]?.closeByPage()
        return JSONObject()
    }

    /** A new document was loaded: drop everything the previous page started, without events. */
    fun resetForNewDocument() {
        for (call in calls.values) call.cancel()
        for (socket in sockets.values) socket.abandon()
        sockets.clear()
    }

    fun dispose() {
        resetForNewDocument()
        synchronized(clientLock) {
            boundClient?.connectionPool?.evictAll()
            boundClient = null
            boundNetwork = null
        }
        baseClient.connectionPool.evictAll()
        baseClient.dispatcher.executorService.shutdown()
    }

    // Internals

    /** [map] is checked ([optHeaders]); OkHttp may still refuse a header. */
    private fun buildHeaders(map: Map<String, String>): Headers {
        val builder = Headers.Builder()
        try {
            for ((name, value) in map) builder.add(name, value)
        } catch (e: IllegalArgumentException) {
            throw BridgeException.invalidParams("invalid header: ${e.message}")
        }
        return builder.build()
    }

    private fun requestBody(method: String, body: String?, headers: Headers): RequestBody? {
        if (method == "GET") {
            if (!body.isNullOrEmpty()) throw BridgeException.invalidParams("a GET request cannot have a body")
            return null
        }
        if (body == null) return if (method == "DELETE") null else EMPTY_BODY
        // Bytes, not String.toRequestBody: that would append "; charset=utf-8" to the page's
        // Content-Type, and OkHttp sends the body's content type in place of the header.
        return body.toByteArray(Charsets.UTF_8).toRequestBody(headers["Content-Type"]?.toMediaTypeOrNull())
    }

    private suspend fun Call.awaitResult(): JSONObject = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                val result = try {
                    response.use { toResult(it) }
                } catch (e: IOException) {
                    continuation.resumeWithException(e)
                    return
                }
                continuation.resume(result)
            }
        })
    }

    private fun toResult(response: Response): JSONObject {
        // Lower-cased names; repeated headers (Set-Cookie in particular) joined with ", ".
        val grouped = LinkedHashMap<String, MutableList<String>>()
        for (i in 0 until response.headers.size) {
            grouped.getOrPut(response.headers.name(i).lowercase(Locale.ROOT)) { mutableListOf() }
                .add(response.headers.value(i))
        }
        val headers = JSONObject()
        for ((name, values) in grouped) headers.put(name, values.joinToString(", "))
        val bytes = response.body?.bytes() ?: ByteArray(0)
        return JSONObject()
            .put("status", response.code)
            .put("headers", headers)
            .put("body", String(bytes, Charsets.UTF_8))
    }

    /** One `ws.*` socket. Events go out in OkHttp's order; `ws.close` is always the last one. */
    private inner class Socket(private val socketId: String, private val evaluator: TrustEvaluator? = null) : WebSocketListener() {
        @Volatile
        var webSocket: WebSocket? = null

        @Volatile
        private var opened = false

        @Volatile
        private var silent = false
        private val finished = AtomicBoolean(false)

        /** Keeps events in order across OkHttp's thread and the main thread, `ws.close` last. */
        private val eventLock = Any()

        override fun onOpen(webSocket: WebSocket, response: Response) {
            opened = true
            event("ws.open", JSONObject())
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            event("ws.message", JSONObject().put("data", text))
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            // Text frames only.
            Log.w(TAG, "ws $socketId: dropped a binary frame (${bytes.size} bytes)")
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            // Answer the peer's close frame; onClosed follows.
            try {
                webSocket.close(code, null)
            } catch (_: IllegalArgumentException) {
                webSocket.close(NORMAL_CLOSURE, null) // e.g. 1005 "no status" can't be echoed
            }
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            finish(code, reason)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            if (evaluator?.rejected == true) {
                val error = evaluator.tlsError()
                fail(error.message.orEmpty(), code = error.code, details = error.details)
                return
            }
            val message = if (response != null) "${t.message} (HTTP ${response.code})" else t.toString()
            fail(message)
        }

        fun fail(message: String, code: String? = null, details: JSONObject? = null) {
            if (finished.get()) return
            event(
                "ws.error",
                JSONObject().put("message", message).apply {
                    if (code != null) put("code", code)
                    if (details != null) put("details", details)
                },
            )
            finish(ABNORMAL_CLOSURE, "")
        }

        /**
         * `ws.close`: the final `ws.close` event goes out at once, 1000, or 1006 for a socket still
         * connecting (as a browser reports closing one), without waiting for the device (as on
         * iOS).
         */
        fun closeByPage() {
            val ws = webSocket
            if (ws == null || !opened) {
                ws?.cancel()
                finish(ABNORMAL_CLOSURE, "")
            } else {
                ws.close(NORMAL_CLOSURE, null)
                finish(NORMAL_CLOSURE, "")
            }
        }

        /** Tear down without telling the page (it's gone). */
        fun abandon() {
            silent = true
            finished.set(true)
            webSocket?.cancel()
        }

        private fun finish(code: Int, reason: String) {
            if (!finished.compareAndSet(false, true)) return
            sockets.remove(socketId, this)
            synchronized(eventLock) {
                event("ws.close", JSONObject().put("code", code).put("reason", reason))
                // Always the last event for the socket.
                silent = true
            }
        }

        private fun event(name: String, params: JSONObject) {
            synchronized(eventLock) {
                if (silent) return
                emit(name, params.put("socketId", socketId))
            }
        }
    }

    private companion object {
        const val TAG = "Plugchoice"
        const val NORMAL_CLOSURE = 1000
        const val ABNORMAL_CLOSURE = 1006
        val HTTP_METHODS = setOf("GET", "POST", "PUT", "PATCH", "DELETE")
        val EMPTY_BODY: RequestBody = ByteArray(0).toRequestBody(null)
    }
}

/**
 * TLS for one call or socket checked by [evaluator] alone: it matches the host itself (unless the
 * trust says not to), and the connection is never pooled for another call.
 */
internal fun OkHttpClient.Builder.trusting(evaluator: TrustEvaluator): OkHttpClient.Builder {
    val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(evaluator), null) }
    return sslSocketFactory(context.socketFactory, evaluator)
        .hostnameVerifier { _, _ -> true }
        .connectionPool(ConnectionPool(0, 1, TimeUnit.SECONDS))
}
