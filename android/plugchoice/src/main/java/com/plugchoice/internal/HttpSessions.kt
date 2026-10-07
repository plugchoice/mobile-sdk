package com.plugchoice.internal

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.SocketTimeoutException
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * `http.session.open` / `.request` / `.close` (PROTOCOL.md §9.5): kept-alive HTTPS connections to
 * devices on the local network whose login lives on the TCP connection rather than in a cookie.
 *
 * - One TCP connection per session: `open` does the TCP and TLS handshake, and the connection is
 *   never shared, pooled or silently replaced. When the device drops it, the next request answers
 *   `network` and the session is gone.
 * - Trust: the page's [Trust] object, or the system's (§9.8).
 * - Requests on a session run one at a time, in the order received (one thread per session).
 * - At most [MAX_SESSIONS] sessions (opening ones included).
 * - A session opened while `wifi.routeTraffic` is on goes over the joined charger network (the
 *   caller passes that [SocketRoute]).
 *
 * Callbacks arrive on background threads. Thread-safe.
 */
internal class HttpSessions(
    private val connector: SessionConnector,
    private val newSessionId: () -> String = { UUID.randomUUID().toString() },
) {
    class OpenRequest(
        val host: String,
        val port: Int,
        /** Null: the system's trust. */
        val trust: Trust?,
        /** For the TCP and TLS handshake. */
        val timeoutMs: Long = DEFAULT_OPEN_TIMEOUT_MS,
    )

    class Request(
        val method: String,
        val path: String,
        val headers: Map<String, String>,
        val body: String?,
        val timeoutMs: Long,
    )

    private val lock = Any()
    private val sessions = HashMap<String, Session>()
    private var opening = 0

    /** Bumped by [closeAll]: connections that finish opening for an older generation are dropped. */
    private var generation = 0
    private val openExecutor: ExecutorService = Executors.newCachedThreadPool(daemonThreads("Plugchoice-session-open"))
    private val timers: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(daemonThreads("Plugchoice-session-timer"))

    /** Open sessions, opening ones included (they count against the limit). */
    val count: Int
        get() = synchronized(lock) { sessions.size + opening }

    fun open(request: OpenRequest, route: SocketRoute, callback: (Result<JSONObject>) -> Unit) {
        val openedFor = synchronized(lock) {
            if (sessions.size + opening >= MAX_SESSIONS) {
                throw BridgeException(ErrorCode.TOO_MANY_SESSIONS, "at most $MAX_SESSIONS sessions can be open")
            }
            opening++
            generation
        }
        openExecutor.execute {
            val result = runCatching { connector.connect(request.host, request.port, request.trust, route, request.timeoutMs) }
            val id = synchronized(lock) {
                opening--
                val connection = result.getOrNull()
                if (connection == null || generation != openedFor) {
                    null
                } else {
                    newSessionId().also { sessions[it] = Session(it, request.host, request.port, connection) }
                }
            }
            when {
                id != null -> callback(Result.success(JSONObject().put("sessionId", id)))
                result.isSuccess -> {
                    // The page went away meanwhile.
                    result.getOrNull()?.close()
                    callback(Result.failure(PAGE_GONE))
                }
                else -> callback(Result.failure(result.exceptionOrNull()!!))
            }
        }
    }

    fun request(sessionId: String, request: Request, callback: (Result<JSONObject>) -> Unit) {
        val session = synchronized(lock) {
            val session = sessions[sessionId]
                ?: throw BridgeException(ErrorCode.UNKNOWN_SESSION, "no open session $sessionId")
            if (session.ended) {
                // The device dropped the connection after the last answer.
                sessions.remove(sessionId)
                throw CONNECTION_GONE
            }
            session
        }
        session.enqueue(request, callback)
    }

    /** Idempotent. Requests still waiting on the session answer `network`. */
    fun close(sessionId: String) {
        val session = synchronized(lock) { sessions.remove(sessionId) } ?: return
        session.end(BridgeException(ErrorCode.NETWORK, "the session was closed"))
    }

    /**
     * The page is gone: closes every session, and connections still opening are closed when they
     * finish. Whatever was waiting answers `network` (the old page's answers go nowhere).
     */
    fun closeAll() {
        val all = synchronized(lock) {
            generation++
            sessions.values.toList().also { sessions.clear() }
        }
        for (session in all) session.end(PAGE_GONE)
    }

    /** The Link screen closed. */
    fun dispose() {
        closeAll()
        openExecutor.shutdown()
        timers.shutdownNow()
    }

    private fun removeIfCurrent(session: Session) {
        synchronized(lock) {
            if (sessions[session.id] === session) sessions.remove(session.id)
        }
    }

    /** One session: a connection, and the requests queued on its own thread. */
    private inner class Session(val id: String, private val host: String, private val port: Int, private val connection: SessionConnection) {
        private val executor = Executors.newSingleThreadExecutor(daemonThreads("Plugchoice-session"))
        private val input: InputStream = BufferedInputStream(connection.input)
        private val output: OutputStream = BufferedOutputStream(connection.output)
        private val outstanding = LinkedHashSet<Pending>()

        /** The connection is gone (dropped, failed, timed out or closed). */
        @Volatile
        var ended = false
            private set

        fun enqueue(request: Request, callback: (Result<JSONObject>) -> Unit) {
            val pending = Pending(request, callback)
            synchronized(outstanding) { outstanding += pending }
            // timeoutMs counts from now, so time spent waiting for earlier requests counts too.
            pending.timer = try {
                timers.schedule({ timedOut(pending) }, request.timeoutMs, TimeUnit.MILLISECONDS)
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                null
            }
            try {
                executor.execute { run(pending) }
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                answer(pending, Result.failure(CONNECTION_GONE))
            }
        }

        private fun run(pending: Pending) {
            if (!pending.state.compareAndSet(QUEUED, RUNNING)) return // timed out while queued, or ended
            if (ended) {
                answer(pending, Result.failure(CONNECTION_GONE))
                return
            }
            val request = pending.request
            try {
                // A backstop: the timer ends the connection on time.
                connection.setReadTimeoutMs(request.timeoutMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                output.write(Http1.encodeRequest(request.method, request.path, host, port, request.headers, request.body))
                output.flush()
                val response = Http1.readResponse(input)
                if (response.closesConnection) {
                    // The device ends the connection after this answer: the next request finds the
                    // session gone.
                    closeConnection()
                }
                answer(pending, Result.success(response.toJson()))
            } catch (e: IOException) {
                closeConnection()
                val error = when {
                    e is SocketTimeoutException -> timeoutError(request)
                    else -> BridgeException(ErrorCode.NETWORK, e.message ?: e.toString())
                }
                answer(pending, Result.failure(error))
                failOutstanding(CONNECTION_GONE)
            }
        }

        private fun timedOut(pending: Pending) {
            if (pending.state.compareAndSet(QUEUED, DONE)) {
                // Never sent: the session carries on.
                deliver(pending, Result.failure(timeoutError(pending.request)))
            } else if (pending.state.compareAndSet(RUNNING, DONE)) {
                // The device may still answer on this connection, which would then be out of step:
                // a timeout ends the session. Claimed and answered before the socket closes: that
                // wakes the request's thread, which then answers what is queued with `network`.
                ended = true
                deliver(pending, Result.failure(timeoutError(pending.request)))
                closeConnection()
                failOutstanding(CONNECTION_GONE)
            }
        }

        /** Ends the connection; everything waiting answers [error]. */
        fun end(error: BridgeException) {
            closeConnection()
            failOutstanding(error)
            executor.shutdown()
        }

        private fun closeConnection() {
            ended = true
            try {
                connection.close()
            } catch (_: IOException) {
            }
        }

        private fun failOutstanding(error: BridgeException) {
            val all = synchronized(outstanding) { outstanding.toList() }
            for (pending in all) answer(pending, Result.failure(error))
        }

        /** Answers once, from whatever state. */
        private fun answer(pending: Pending, result: Result<JSONObject>) {
            while (true) {
                val state = pending.state.get()
                if (state == DONE) return
                if (pending.state.compareAndSet(state, DONE)) break
            }
            deliver(pending, result)
        }

        private fun deliver(pending: Pending, result: Result<JSONObject>) {
            pending.timer?.cancel(false)
            synchronized(outstanding) { outstanding -= pending }
            // A failed request ends the session: the next call is unknownSession.
            if (result.isFailure && ended) removeIfCurrent(this)
            pending.callback(result)
        }
    }

    private class Pending(val request: Request, val callback: (Result<JSONObject>) -> Unit) {
        val state = AtomicInteger(QUEUED)

        @Volatile
        var timer: ScheduledFuture<*>? = null
    }

    companion object {
        const val MAX_SESSIONS = 64

        /** The TCP and TLS handshake of `open`: its `timeoutMs` clamped to this range, or the default. */
        const val DEFAULT_OPEN_TIMEOUT_MS = 10_000L
        val OPEN_TIMEOUT_RANGE = 500L..30_000L
        val METHODS = setOf("GET", "POST", "PUT")

        private const val QUEUED = 0
        private const val RUNNING = 1
        private const val DONE = 2

        private val CONNECTION_GONE: BridgeException
            get() = BridgeException(ErrorCode.NETWORK, "the device closed the connection; open a new session")

        private val PAGE_GONE: BridgeException
            get() = BridgeException(ErrorCode.NETWORK, "the page that opened the session went away")

        private fun timeoutError(request: Request) =
            BridgeException(ErrorCode.TIMEOUT, "${request.method} ${request.path}: no response within ${request.timeoutMs} ms")

        /** `http.session.open` params, checked: the trust first, then the host allow-list. */
        fun parseOpen(params: JSONObject): OpenRequest {
            val host = params.requireString("host")
            val port = params.optWholeNumber("port", 1..65535, 443)
            // Any positive number; the range keeps a page from waiting forever or giving a handshake no chance.
            val timeoutMs = params.optClampedTimeoutMs("timeoutMs", DEFAULT_OPEN_TIMEOUT_MS, OPEN_TIMEOUT_RANGE)
            val trust = Trust.parse(params.opt("trust"))
            HostAllowList.requireAllowed(host)
            return OpenRequest(host.removePrefix("[").removeSuffix("]"), port, trust, timeoutMs)
        }

        /** `http.session.request` params, checked. */
        fun parseRequest(params: JSONObject): Pair<String, Request> {
            val sessionId = params.requireString("sessionId")
            val method = params.requireString("method").uppercase(Locale.ROOT)
            if (method !in METHODS) throw BridgeException.invalidParams("method must be one of $METHODS")
            val path = params.requireString("path")
            if (!Http1.isValidPath(path)) {
                throw BridgeException.invalidParams("path must start with / and hold printable ASCII without spaces or #")
            }
            val headers = params.optHeaders()
            val body = params.optStringOrNull("body")
            if (method == "GET" && !body.isNullOrEmpty()) throw BridgeException.invalidParams("a GET request cannot have a body")
            val timeoutMs = params.requireTimeoutMs("timeoutMs")
            return sessionId to Request(method, path, headers, if (method == "GET") null else body, timeoutMs)
        }
    }
}

/** The byte stream under one session. */
internal interface SessionConnection : Closeable {
    val input: InputStream
    val output: OutputStream

    /** A backstop for blocking reads; the session's timers end the connection on time. */
    fun setReadTimeoutMs(ms: Int)
}

/** Opens session connections: the TCP and TLS handshake, blocking. */
internal fun interface SessionConnector {
    /** Throws [BridgeException] `tls`, `network` or `timeout`. [trust] null: the system's trust. */
    fun connect(host: String, port: Int, trust: Trust?, route: SocketRoute, timeoutMs: Long): SessionConnection
}

/** TLS over TCP through [DeviceConnector], verified against the session's trust only. */
internal object TlsSessionConnector : SessionConnector {
    override fun connect(host: String, port: Int, trust: Trust?, route: SocketRoute, timeoutMs: Long): SessionConnection {
        val connection = DeviceConnector.connect(host, port, route, timeoutMs, TlsOptions(trust))
        return object : SessionConnection {
            override val input: InputStream = connection.input
            override val output: OutputStream = connection.output

            override fun setReadTimeoutMs(ms: Int) {
                connection.socket.soTimeout = ms
            }

            override fun close() = connection.close()
        }
    }
}
