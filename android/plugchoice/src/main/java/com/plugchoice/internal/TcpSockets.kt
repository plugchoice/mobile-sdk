package com.plugchoice.internal

import org.json.JSONObject
import java.io.IOException
import java.util.Base64
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SNIHostName

/**
 * `tcp.open` / `tcp.write` / `tcp.close` (PROTOCOL.md §9.6): raw TCP to devices on the local
 * network, optionally with TLS and the page's [Trust]. Bytes travel as base64.
 *
 * - `open` answers once connected (and the handshake done); then `tcp.data` events carry what the
 *   device sends, and `tcp.close { error? }` is always the last event (`error` when the
 *   connection failed rather than ended).
 * - `write` answers once the bytes are handed to the OS; writes on a socket go out in order.
 * - At most [MAX_SOCKETS] sockets, opening ones included.
 * - The page going away closes everything without events.
 *
 * Each socket reads on its own thread; callbacks and events come from background threads.
 * Thread-safe.
 */
internal class TcpSockets(
    /** Sends an event to the page; safe to call from any thread. */
    private val emit: (event: String, params: JSONObject) -> Unit,
    private val connector: (OpenRequest, SocketRoute) -> DeviceConnection = { request, route ->
        DeviceConnector.connect(request.host, request.port, route, request.timeoutMs, request.tls)
    },
) {
    class OpenRequest(
        val socketId: String,
        val host: String,
        val port: Int,
        val timeoutMs: Long = DEFAULT_OPEN_TIMEOUT_MS,
        val tls: TlsOptions? = null,
    )

    private val lock = Any()
    private val sockets = HashMap<String, TcpSocket>()
    private val threads: ExecutorService = Executors.newCachedThreadPool(daemonThreads("Plugchoice-tcp"))

    /** Open sockets, opening ones included. */
    val count: Int
        get() = synchronized(lock) { sockets.size }

    /** Throws `invalidParams` (a socket id in use) or `tooManySockets`; [callback] gets the outcome. */
    fun open(request: OpenRequest, route: SocketRoute, callback: (Result<JSONObject>) -> Unit) {
        val socket = synchronized(lock) {
            if (request.socketId in sockets) throw BridgeException.invalidParams("socketId ${request.socketId} is already open")
            if (sockets.size >= MAX_SOCKETS) throw BridgeException(ErrorCode.TOO_MANY_SOCKETS, "at most $MAX_SOCKETS sockets can be open")
            TcpSocket(request.socketId).also { sockets[request.socketId] = it }
        }
        try {
            threads.execute { socket.run(request, route, callback) }
        } catch (_: RejectedExecutionException) {
            remove(socket)
            callback(Result.failure(PAGE_GONE))
        }
    }

    fun write(socketId: String, data: ByteArray, callback: (Result<JSONObject>) -> Unit) {
        val socket = synchronized(lock) { sockets[socketId] }?.takeIf { it.isOpen }
            ?: throw BridgeException(ErrorCode.UNKNOWN_SOCKET, "no open socket $socketId")
        socket.write(data, callback)
    }

    /** Idempotent. An open socket's last event is `tcp.close` (no error); an opening one's `open` answers `network`. */
    fun close(socketId: String) {
        val socket = synchronized(lock) { sockets.remove(socketId) } ?: return
        socket.close(silently = false, error = null)
    }

    /** The page is gone: closes everything without events. */
    fun closeAll() {
        val all = synchronized(lock) { sockets.values.toList().also { sockets.clear() } }
        for (socket in all) socket.close(silently = true, error = null)
    }

    fun dispose() {
        closeAll()
        threads.shutdown()
    }

    private fun remove(socket: TcpSocket) {
        synchronized(lock) { if (sockets[socket.id] === socket) sockets.remove(socket.id) }
    }

    private inner class TcpSocket(val id: String) {
        @Volatile
        private var connection: DeviceConnection? = null
        private val writer: ExecutorService = Executors.newSingleThreadExecutor(daemonThreads("Plugchoice-tcp-write"))
        private val finished = AtomicBoolean(false)

        @Volatile
        private var silent = false

        /** `open` answered: from now on the socket has events, `tcp.close` last. */
        @Volatile
        private var announced = false

        val isOpen: Boolean
            get() = announced && !finished.get()

        /** On a pool thread: connect, answer, then read until the connection ends. */
        fun run(request: OpenRequest, route: SocketRoute, callback: (Result<JSONObject>) -> Unit) {
            val opened = try {
                connector(request, route)
            } catch (e: BridgeException) {
                finished.set(true)
                remove(this)
                writer.shutdown()
                callback(Result.failure(e))
                return
            }
            // Set before the check, so a close racing with it either sees the connection or is seen.
            connection = opened
            if (finished.get()) {
                // tcp.close (or the page going away) while connecting.
                opened.close()
                callback(Result.failure(BridgeException(ErrorCode.NETWORK, if (silent) PAGE_GONE.message!! else "closed by tcp.close while connecting")))
                return
            }
            announced = true
            // Answered before the first tcp.data is emitted, so the page hears of the socket first.
            callback(Result.success(JSONObject()))
            read(opened)
        }

        private fun read(opened: DeviceConnection) {
            val buffer = ByteArray(READ_BUFFER_BYTES)
            while (true) {
                val count = try {
                    opened.input.read(buffer)
                } catch (e: IOException) {
                    close(silently = false, error = e.message ?: e.toString())
                    return
                }
                if (count < 0) {
                    close(silently = false, error = null)
                    return
                }
                if (count > 0) event("tcp.data", JSONObject().put("data", Base64.getEncoder().encodeToString(buffer.copyOf(count))))
            }
        }

        fun write(data: ByteArray, callback: (Result<JSONObject>) -> Unit) {
            try {
                writer.execute {
                    val opened = connection
                    if (opened == null || finished.get()) {
                        callback(Result.failure(BridgeException(ErrorCode.UNKNOWN_SOCKET, "socket $id is closed")))
                        return@execute
                    }
                    try {
                        opened.output.write(data)
                        opened.output.flush()
                        callback(Result.success(JSONObject()))
                    } catch (e: IOException) {
                        callback(Result.failure(BridgeException(ErrorCode.NETWORK, e.message ?: e.toString())))
                        close(silently = false, error = "write failed: ${e.message ?: e}")
                    }
                }
            } catch (_: RejectedExecutionException) {
                callback(Result.failure(BridgeException(ErrorCode.UNKNOWN_SOCKET, "socket $id is closed")))
            }
        }

        /** Once: ends the connection, and unless [silently] sends the final `tcp.close`. */
        fun close(silently: Boolean, error: String?) {
            if (silently) silent = true
            if (!finished.compareAndSet(false, true)) return
            remove(this)
            connection?.close()
            writer.shutdown()
            // A socket that never opened has no events: its open answers instead.
            if (announced) event("tcp.close", JSONObject().apply { if (error != null) put("error", error) })
        }

        private fun event(name: String, params: JSONObject) {
            if (silent) return
            emit(name, params.put("socketId", id))
        }
    }

    companion object {
        const val MAX_SOCKETS = 16
        const val DEFAULT_OPEN_TIMEOUT_MS = 10_000L
        val OPEN_TIMEOUT_RANGE = 500L..30_000L
        private const val READ_BUFFER_BYTES = 16 * 1024

        private val PAGE_GONE: BridgeException
            get() = BridgeException(ErrorCode.NETWORK, "the page that opened the socket went away")

        /** `tcp.open` params, checked: params first, then the host allow-list. */
        fun parseOpen(params: JSONObject): OpenRequest {
            val socketId = params.requireString("socketId")
            val host = params.requireString("host")
            val port = params.requireWholeNumber("port", 1..65535)
            val timeoutMs = params.optClampedTimeoutMs("timeoutMs", DEFAULT_OPEN_TIMEOUT_MS, OPEN_TIMEOUT_RANGE)
            val tls = params.optObjectOrNull("tls")?.let { tls ->
                val serverName = tls.optStringOrNull("serverName")?.also { name ->
                    if (name.isEmpty()) throw BridgeException.invalidParams("tls.serverName must not be empty")
                    if (!HostAllowList.isIpLiteral(name)) {
                        try {
                            SNIHostName(name)
                        } catch (_: IllegalArgumentException) {
                            throw BridgeException.invalidParams("tls.serverName is not a host name")
                        }
                    }
                }
                TlsOptions(Trust.parse(tls.opt("trust"), "tls.trust"), serverName)
            }
            HostAllowList.requireAllowed(host)
            return OpenRequest(socketId, host.removePrefix("[").removeSuffix("]"), port, timeoutMs, tls)
        }
    }
}
