package com.plugchoice.internal

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * `http.session.*` (PROTOCOL.md §9.5) over a scripted connection: params, the session limit,
 * unknown sessions, per-session ordering, timeouts and a device dropping the connection.
 */
class HttpSessionsTest {

    private lateinit var connector: FakeConnector
    private lateinit var sessions: HttpSessions
    private var nextId = 0

    @Before
    fun setUp() {
        connector = FakeConnector()
        nextId = 0
        sessions = HttpSessions(connector) { "s${++nextId}" }
    }

    @After
    fun tearDown() {
        sessions.dispose()
    }

    private val openRequest = HttpSessions.OpenRequest("192.168.1.10", 443, TestCertificates.chargerCaTrust())

    private fun open(): Pair<String, FakeConnection> {
        val answers = Answers()
        sessions.open(openRequest, SocketRoute.DEFAULT, answers::add)
        val id = answers.next().getOrThrow().getString("sessionId")
        return id to connector.connections.last()
    }

    private fun get(path: String, timeoutMs: Long = 5_000) = HttpSessions.Request("GET", path, emptyMap(), null, timeoutMs)

    private fun assertCode(code: String, body: () -> Unit) {
        try {
            body()
            fail("expected $code")
        } catch (e: BridgeException) {
            assertEquals(code, e.code)
        }
    }

    // Params

    private fun params(vararg pairs: Pair<String, Any?>) = JSONObject().apply { for ((key, value) in pairs) put(key, value) }

    @Test
    fun `open params`() {
        val request = HttpSessions.parseOpen(params("host" to "192.168.1.10"))
        assertEquals("192.168.1.10", request.host)
        assertEquals(443, request.port)
        assertEquals("::1", HttpSessions.parseOpen(params("host" to "[::1]", "port" to 8443)).host)
        assertEquals(8443, HttpSessions.parseOpen(params("host" to "charger.local", "port" to 8443)).port)
    }

    @Test
    fun `the open timeout is optional and clamped`() {
        fun timeout(value: Any?) = HttpSessions.parseOpen(params("host" to "10.0.0.2", "timeoutMs" to value)).timeoutMs
        assertEquals(10_000L, timeout(null))
        assertEquals(10_000L, timeout(JSONObject.NULL))
        assertEquals("a subnet-sweep probe", 2_500L, timeout(2_500))
        assertEquals(2_501L, timeout(2_500.2))
        assertEquals("at least 500 ms", 500L, timeout(100))
        assertEquals("at most 30 s", 30_000L, timeout(60_000))
        assertEquals(30_000L, timeout(1e300))
        for (bad in listOf(0, -1, "2500", true)) {
            assertCode(ErrorCode.INVALID_PARAMS) { timeout(bad) }
        }
    }

    @Test
    fun `open uses the host allow-list of http request`() {
        for (host in listOf("10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.50.10", "169.254.1.1", "127.0.0.1", "localhost", "ng910-60623-ace0870096.local")) {
            HttpSessions.parseOpen(params("host" to host))
        }
        for (host in listOf("8.8.8.8", "172.32.0.1", "example.com", "plugchoice.com", "192.168.1", "167772161", "192.168.1.10:443", "fe80::1")) {
            assertCode(ErrorCode.FORBIDDEN_HOST) { HttpSessions.parseOpen(params("host" to host)) }
        }
    }

    @Test
    fun `open takes a trust object or nothing`() {
        assertNull("the system's trust", HttpSessions.parseOpen(params("host" to "10.0.0.1")).trust)
        assertNull(HttpSessions.parseOpen(params("host" to "10.0.0.1", "trust" to JSONObject.NULL)).trust)
        val fingerprint = Trust.fingerprint(TestCertificates.certificate("test-self-signed"))
        val custom = HttpSessions.parseOpen(
            params("host" to "10.0.0.1", "trust" to JSONObject().put("fingerprints", org.json.JSONArray().put(fingerprint)).put("ignoreHostname", true)),
        ).trust!!
        assertEquals(setOf(fingerprint), custom.fingerprints)
        assertTrue(custom.ignoreHostname)
    }

    @Test
    fun `open rejects bad params`() {
        for (bad in listOf(
            params(),
            params("host" to ""),
            params("host" to 10),
            params("host" to "10.0.0.1", "trust" to JSONObject()),
            params("host" to "10.0.0.1", "trust" to 1),
            params("host" to "10.0.0.1", "trust" to "system"),
            params("host" to "10.0.0.1", "trust" to "none"),
            // No trust names: the page passes a CA itself.
            params("host" to "10.0.0.1", "trust" to "alfen"),
            params("host" to "10.0.0.1", "port" to 0),
            params("host" to "10.0.0.1", "port" to 65_536),
            params("host" to "10.0.0.1", "port" to 443.5),
            params("host" to "10.0.0.1", "port" to "443"),
            // A bad trust is invalidParams before the host is looked at.
            params("host" to "8.8.8.8", "trust" to "system"),
            params("host" to "8.8.8.8", "trust" to JSONObject().put("ignoreExpiry", true)),
        )) {
            assertCode(ErrorCode.INVALID_PARAMS) { HttpSessions.parseOpen(bad) }
        }
    }

    private fun requestParams(vararg overrides: Pair<String, Any?>): JSONObject {
        val json = params("sessionId" to "s1", "method" to "GET", "path" to "/api/info", "headers" to JSONObject(), "timeoutMs" to 2500)
        for ((key, value) in overrides) json.put(key, value)
        return json
    }

    @Test
    fun `request params`() {
        val (sessionId, request) = HttpSessions.parseRequest(
            requestParams(
                "method" to "post",
                "path" to "/api/prop?ids=2053_0,20F0_3",
                "headers" to JSONObject().put("Content-Type", "application/json"),
                "body" to "{\"a\":1}",
            ),
        )
        assertEquals("s1", sessionId)
        assertEquals("POST", request.method)
        assertEquals("/api/prop?ids=2053_0,20F0_3", request.path)
        assertEquals(mapOf("Content-Type" to "application/json"), request.headers)
        assertEquals("{\"a\":1}", request.body)
        assertEquals(2500L, request.timeoutMs)
        assertNull("an empty body on GET is no body", HttpSessions.parseRequest(requestParams("body" to "")).second.body)
        assertEquals(emptyMap<String, String>(), HttpSessions.parseRequest(requestParams().apply { remove("headers") }).second.headers)
    }

    @Test
    fun `request rejects bad params`() {
        for (bad in listOf(
            requestParams().apply { remove("sessionId") },
            requestParams().apply { remove("timeoutMs") },
            requestParams("method" to "PATCH"),
            requestParams("method" to "DELETE"),
            requestParams("path" to "api/info"),
            requestParams("path" to "https://192.168.1.10/api/info"),
            requestParams("path" to "/api info"),
            requestParams("path" to "/api#info"),
            requestParams("path" to "/api/é"),
            requestParams("headers" to JSONObject().put("X-Evil", "a\r\nHost: elsewhere")),
            requestParams("headers" to JSONObject().put("Bad Name", "x")),
            requestParams("headers" to JSONObject().put("Accept", JSONObject())),
            requestParams("body" to "{}"),
            requestParams("method" to "POST", "body" to 1),
            requestParams("timeoutMs" to -1),
        )) {
            assertCode(ErrorCode.INVALID_PARAMS) { HttpSessions.parseRequest(bad) }
        }
    }

    // Open

    @Test
    fun `open answers a session id`() {
        val (id, _) = open()
        assertEquals("s1", id)
        assertEquals(Triple("192.168.1.10", 443, 10_000L), connector.connects.single())
    }

    @Test
    fun `open passes its timeout to the handshake`() {
        sessions.open(HttpSessions.OpenRequest("192.168.50.10", 443, TestCertificates.chargerCaTrust(), 2_500), SocketRoute.DEFAULT) {}
        val deadline = System.currentTimeMillis() + 5_000
        while (connector.connects.isEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertEquals(Triple("192.168.50.10", 443, 2_500L), connector.connects.single())
    }

    @Test
    fun `open failures come from the connection`() {
        for (code in listOf(ErrorCode.TLS, ErrorCode.NETWORK, ErrorCode.TIMEOUT)) {
            connector.failWith = BridgeException(code, code)
            val answers = Answers()
            sessions.open(openRequest, SocketRoute.DEFAULT, answers::add)
            assertEquals(code, (answers.next().exceptionOrNull() as BridgeException).code)
        }
        assertEquals(0, sessions.count)
    }

    // Limit

    @Test
    fun `at most 64 sessions`() {
        val ids = List(HttpSessions.MAX_SESSIONS) { open().first }
        assertEquals(64, sessions.count)
        assertCode(ErrorCode.TOO_MANY_SESSIONS) { sessions.open(openRequest, SocketRoute.DEFAULT) {} }
        sessions.close(ids[0])
        open()
    }

    @Test
    fun `opening sessions count towards the limit`() {
        val release = CountDownLatch(1)
        connector.gate = release
        val answers = Answers()
        repeat(HttpSessions.MAX_SESSIONS) { sessions.open(openRequest, SocketRoute.DEFAULT, answers::add) }
        assertCode(ErrorCode.TOO_MANY_SESSIONS) { sessions.open(openRequest, SocketRoute.DEFAULT) {} }
        release.countDown()
        repeat(HttpSessions.MAX_SESSIONS) { answers.next().getOrThrow() }
    }

    // Unknown sessions and close

    @Test
    fun `a request on an unknown session`() {
        assertCode(ErrorCode.UNKNOWN_SESSION) { sessions.request("nope", get("/api/info")) {} }
    }

    @Test
    fun `close is idempotent and ends the session`() {
        val (id, connection) = open()
        sessions.close(id)
        sessions.close(id)
        sessions.close("never-opened")
        assertTrue(connection.closed)
        assertCode(ErrorCode.UNKNOWN_SESSION) { sessions.request(id, get("/api/info")) {} }
    }

    @Test
    fun `close answers waiting requests with network`() {
        val (id, connection) = open()
        val answers = Answers()
        sessions.request(id, get("/a"), answers::add)
        sessions.request(id, get("/b"), answers::add)
        connection.nextRequest()
        sessions.close(id)
        assertEquals(listOf(ErrorCode.NETWORK, ErrorCode.NETWORK), answers.codes(2))
    }

    @Test
    fun `closeAll ends everything`() {
        val (id, connection) = open()
        val answers = Answers()
        sessions.request(id, get("/a"), answers::add)
        connection.nextRequest()
        sessions.closeAll()
        assertTrue(connection.closed)
        assertEquals(listOf(ErrorCode.NETWORK), answers.codes(1))
        assertEquals(0, sessions.count)
    }

    // Requests

    @Test
    fun `a request and its response`() {
        val (id, connection) = open()
        val answers = Answers()
        sessions.request(
            id,
            HttpSessions.Request(
                "POST",
                "/api/login",
                mapOf("Content-Type" to "application/json", "Content-Length" to "999", "Connection" to "close", "Host" to "evil"),
                "{\"username\":\"admin\"}",
                5_000,
            ),
            answers::add,
        )
        assertEquals(
            "POST /api/login HTTP/1.1\r\nHost: 192.168.1.10\r\nContent-Type: application/json\r\nContent-Length: 20\r\n\r\n{\"username\":\"admin\"}",
            connection.nextRequest(),
        )
        connection.respond("HTTP/1.1 200 OK\r\nContent-Type: alfen/json; charset=UTF-8\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 2\r\n\r\nok")
        val result = answers.next().getOrThrow()
        assertEquals(200, result.getInt("status"))
        assertEquals("ok", result.getString("body"))
        assertEquals("a=1, b=2", result.getJSONObject("headers").getString("set-cookie"))
        assertEquals("alfen/json; charset=UTF-8", result.getJSONObject("headers").getString("content-type"))
    }

    @Test
    fun `requests on a session run one at a time in order`() {
        val (id, connection) = open()
        val answers = Answers()
        for (path in listOf("/1", "/2", "/3")) sessions.request(id, get(path), answers::add)

        assertTrue(connection.nextRequest().startsWith("GET /1 "))
        assertNull("the next request waits for the response", connection.pollRequest(100))
        connection.respond("HTTP/1.1 200 OK\r\nContent-Le")
        connection.respond("ngth: 3\r\n\r\none")
        assertTrue(connection.nextRequest().startsWith("GET /2 "))
        connection.respond("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\ntwo\r\n0\r\n\r\n")
        assertTrue(connection.nextRequest().startsWith("GET /3 "))
        connection.respond("HTTP/1.1 404 Not Found\r\nContent-Length: 5\r\n\r\nthree")

        val results = List(3) { answers.next().getOrThrow() }
        assertEquals(listOf("one", "two", "three"), results.map { it.getString("body") })
        assertEquals(404, results[2].getInt("status"))
    }

    @Test
    fun `sessions do not wait for each other`() {
        val (first, firstConnection) = open()
        val (second, secondConnection) = open()
        sessions.request(first, get("/slow")) {}
        firstConnection.nextRequest()
        val answers = Answers()
        sessions.request(second, get("/fast"), answers::add)
        secondConnection.nextRequest()
        secondConnection.respond("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nfast")
        assertEquals("fast", answers.next().getOrThrow().getString("body"))
    }

    // The device dropping the connection

    @Test
    fun `a drop mid-request fails with network and ends the session`() {
        val (id, connection) = open()
        val answers = Answers()
        sessions.request(id, get("/a"), answers::add)
        sessions.request(id, get("/b"), answers::add)
        connection.nextRequest()
        connection.end()
        assertEquals(listOf(ErrorCode.NETWORK, ErrorCode.NETWORK), answers.codes(2))
        assertTrue(connection.closed)
        assertCode(ErrorCode.UNKNOWN_SESSION) { sessions.request(id, get("/c")) {} }
    }

    @Test
    fun `after Connection close the next request fails with network`() {
        val (id, connection) = open()
        val answers = Answers()
        sessions.request(id, get("/a"), answers::add)
        connection.nextRequest()
        connection.respond("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 1\r\n\r\nx")
        assertEquals("x", answers.next().getOrThrow().getString("body"))
        assertTrue(connection.closed)
        assertCode(ErrorCode.NETWORK) { sessions.request(id, get("/b")) {} }
        assertCode(ErrorCode.UNKNOWN_SESSION) { sessions.request(id, get("/c")) {} }
        // Never reconnected behind the page's back.
        assertEquals(1, connector.connects.size)
    }

    @Test
    fun `a garbled response fails with network`() {
        val (id, connection) = open()
        val answers = Answers()
        sessions.request(id, get("/a"), answers::add)
        connection.nextRequest()
        connection.respond("SSH-2.0-OpenSSH\r\n\r\n")
        assertEquals(listOf(ErrorCode.NETWORK), answers.codes(1))
    }

    // Timeouts

    @Test
    fun `a timeout while waiting for the device ends the session`() {
        val (id, connection) = open()
        val answers = Answers()
        sessions.request(id, get("/slow", timeoutMs = 100), answers::add)
        sessions.request(id, get("/next"), answers::add)
        connection.nextRequest()
        assertEquals(listOf(ErrorCode.TIMEOUT, ErrorCode.NETWORK), answers.codes(2))
        assertTrue(connection.closed)
        assertCode(ErrorCode.UNKNOWN_SESSION) { sessions.request(id, get("/c")) {} }
    }

    @Test
    fun `a timeout while queued leaves the session alone`() {
        val (id, connection) = open()
        val answers = Answers()
        sessions.request(id, get("/first"), answers::add)
        sessions.request(id, get("/queued", timeoutMs = 100), answers::add)
        connection.nextRequest()
        assertEquals("timeoutMs counts from when the request arrived", listOf(ErrorCode.TIMEOUT), answers.codes(1))
        connection.respond("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfirst")
        assertEquals("first", answers.next().getOrThrow().getString("body"))
        assertNull("the timed-out request was never sent", connection.pollRequest(100))
        sessions.request(id, get("/after"), answers::add)
        assertTrue(connection.nextRequest().startsWith("GET /after "))
    }
}

// Test doubles

internal class Answers {
    private val results = LinkedBlockingQueue<Result<JSONObject>>()

    fun add(result: Result<JSONObject>) {
        results.put(result)
    }

    fun next(): Result<JSONObject> = results.poll(15, TimeUnit.SECONDS) ?: throw AssertionError("no answer within 15 s")

    fun codes(count: Int): List<String> = List(count) { (next().exceptionOrNull() as? BridgeException)?.code ?: "ok" }
}

/** A connection whose responses the test writes, and whose requests it reads. */
internal class FakeConnection : SessionConnection {
    private val requests = LinkedBlockingQueue<String>()
    private val chunks = LinkedBlockingQueue<ByteArray>()

    @Volatile
    var closed = false
        private set

    override val input: InputStream = object : InputStream() {
        private var current = ByteArray(0)
        private var position = 0

        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (position >= current.size) {
                val next = chunks.take()
                if (next === END) return -1
                if (next === CLOSED || closed) throw IOException("socket closed")
                current = next
                position = 0
            }
            val count = minOf(len, current.size - position)
            System.arraycopy(current, position, b, off, count)
            position += count
            return count
        }
    }

    override val output: OutputStream = object : OutputStream() {
        private val buffer = ByteArrayOutputStream()

        override fun write(b: Int) {
            if (closed) throw IOException("socket closed")
            buffer.write(b)
        }

        override fun flush() {
            requests.put(buffer.toString(Charsets.UTF_8.name()))
            buffer.reset()
        }
    }

    override fun setReadTimeoutMs(ms: Int) {}

    override fun close() {
        closed = true
        chunks.put(CLOSED)
    }

    fun nextRequest(): String = requests.poll(5, TimeUnit.SECONDS) ?: throw AssertionError("no request within 5 s")

    fun pollRequest(timeoutMs: Long): String? = requests.poll(timeoutMs, TimeUnit.MILLISECONDS)

    fun respond(text: String) = chunks.put(text.toByteArray())

    /** The device closed the connection. */
    fun end() = chunks.put(END)

    private companion object {
        val END = ByteArray(0)
        val CLOSED = ByteArray(0)
    }
}

internal class FakeConnector : SessionConnector {
    val connects = java.util.concurrent.CopyOnWriteArrayList<Triple<String, Int, Long>>()
    val connections = java.util.concurrent.CopyOnWriteArrayList<FakeConnection>()

    @Volatile
    var failWith: BridgeException? = null

    /** Holds every connect until it opens. */
    @Volatile
    var gate: CountDownLatch? = null

    override fun connect(host: String, port: Int, trust: Trust?, route: SocketRoute, timeoutMs: Long): SessionConnection {
        connects += Triple(host, port, timeoutMs)
        gate?.await()
        failWith?.let { throw it }
        return FakeConnection().also { connections += it }
    }
}
