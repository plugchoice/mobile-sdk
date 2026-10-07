package com.plugchoice.internal

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLServerSocket

/**
 * `http.session` end to end over real TLS (the JVM's), against a local server presenting the
 * test certificates (see [TestCertificates]): the page's trust objects (§9.8) and the system's
 * trust.
 */
class TlsSessionTest {
    private var server: LocalTlsServer? = null

    private val sessions = HttpSessions(TlsSessionConnector)

    @After
    fun tearDown() {
        sessions.dispose()
        server?.close()
    }

    /** The test CA as the anchor, without date or host checks. */
    private val chargerCa = TestCertificates.chargerCaTrust()

    private fun open(
        port: Int,
        trust: Trust? = chargerCa,
        host: String = "127.0.0.1",
    ): Result<String> {
        val answers = Answers()
        sessions.open(HttpSessions.OpenRequest(host, port, trust), SocketRoute.DEFAULT, answers::add)
        return answers.next().map { it.getString("sessionId") }
    }

    private fun presented(result: Result<*>): String? =
        (result.exceptionOrNull() as? BridgeException)?.details?.optString("presentedFingerprint")

    private fun request(sessionId: String, request: HttpSessions.Request): Result<org.json.JSONObject> {
        val answers = Answers()
        sessions.request(sessionId, request, answers::add)
        return answers.next()
    }

    private fun code(result: Result<*>): String? = (result.exceptionOrNull() as? BridgeException)?.code

    @Test
    fun `an expired leaf for another host verifies against its anchor`() {
        val server = LocalTlsServer("test-leaf-expired").also { server = it }
        server.responses += "HTTP/1.1 200 OK\r\nContent-Type: alfen/json\r\nContent-Length: 17\r\n\r\n{\"Model\":\"NG910\"}"
        server.responses += "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        val sessionId = open(server.port).getOrThrow()

        val info = request(sessionId, HttpSessions.Request("GET", "/api/info", mapOf("Accept" to "application/json"), null, 5_000)).getOrThrow()
        assertEquals(200, info.getInt("status"))
        assertEquals("{\"Model\":\"NG910\"}", info.getString("body"))
        assertEquals("alfen/json", info.getJSONObject("headers").getString("content-type"))

        val login = request(sessionId, HttpSessions.Request("POST", "/api/login", mapOf("Content-Type" to "application/json"), "{\"username\":\"admin\"}", 5_000)).getOrThrow()
        assertEquals(200, login.getInt("status"))

        assertEquals(2, server.requests.size)
        assertTrue(server.requests[0], server.requests[0].startsWith("GET /api/info HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n"))
        assertTrue(server.requests[1], server.requests[1].contains("\r\nContent-Length: 20\r\n\r\n{\"username\":\"admin\"}"))
        assertEquals("both requests on the one connection open made", 1, server.connections.get())
    }

    @Test
    fun `a self-signed device fails with tls and its fingerprint`() {
        val server = LocalTlsServer("test-self-signed").also { server = it }
        val result = open(server.port)
        assertEquals(ErrorCode.TLS, code(result))
        assertEquals(Trust.fingerprint(TestCertificates.certificate("test-self-signed")), presented(result))
        assertEquals(0, sessions.count)
    }

    @Test
    fun `the page's anchor verifies a device's certificate for its address`() {
        val server = LocalTlsServer("test-leaf-local").also { server = it }
        server.responses += "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        val trust = Trust(listOf(TestCertificates.certificate("test-local-ca")), emptySet(), ignoreExpiry = false, ignoreHostname = false)
        val sessionId = open(server.port, trust = trust).getOrThrow()
        assertEquals("ok", request(sessionId, HttpSessions.Request("GET", "/", emptyMap(), null, 5_000)).getOrThrow().getString("body"))
    }

    @Test
    fun `a chain through an intermediate the device sends`() {
        val server = LocalTlsServer("test-leaf-chained").also { server = it }
        val trust = Trust(listOf(TestCertificates.certificate("test-local-ca")), emptySet(), ignoreExpiry = false, ignoreHostname = false)
        open(server.port, trust = trust).getOrThrow()
    }

    @Test
    fun `a certificate for another name fails unless ignoreHostname`() {
        val server = LocalTlsServer("test-leaf-local").also { server = it }
        val ca = listOf(TestCertificates.certificate("test-local-ca"))
        // "localhost" resolves to 127.0.0.1, which the certificate names; "localhost" it doesn't.
        val strict = open(server.port, trust = Trust(ca, emptySet(), ignoreExpiry = false, ignoreHostname = false), host = "localhost")
        assertEquals(ErrorCode.TLS, code(strict))
        assertEquals(Trust.fingerprint(TestCertificates.certificate("test-leaf-local")), presented(strict))
        open(server.port, trust = Trust(ca, emptySet(), ignoreExpiry = false, ignoreHostname = true), host = "localhost").getOrThrow()
    }

    @Test
    fun `an expired leaf fails unless ignoreExpiry`() {
        val server = LocalTlsServer("test-leaf-expired").also { server = it }
        val ca = listOf(TestCertificates.certificate("test-ca"))
        assertEquals(ErrorCode.TLS, code(open(server.port, trust = Trust(ca, emptySet(), ignoreExpiry = false, ignoreHostname = true))))
        open(server.port, trust = Trust(ca, emptySet(), ignoreExpiry = true, ignoreHostname = true)).getOrThrow()
    }

    @Test
    fun `a pinned key opens a self-signed device`() {
        val server = LocalTlsServer("test-self-signed").also { server = it }
        val fingerprint = Trust.fingerprint(TestCertificates.certificate("test-self-signed"))
        open(server.port, trust = Trust(emptyList(), setOf(fingerprint), ignoreExpiry = false, ignoreHostname = true)).getOrThrow()
        val otherKey = Trust.fingerprint(TestCertificates.certificate("test-leaf-local"))
        val refused = open(server.port, trust = Trust(emptyList(), setOf(otherKey), ignoreExpiry = false, ignoreHostname = true))
        assertEquals(ErrorCode.TLS, code(refused))
        assertEquals("what to pin from a first contact", fingerprint, presented(refused))
    }

    @Test
    fun `without a trust the system's refuses a private CA`() {
        val server = LocalTlsServer("test-leaf-local").also { server = it }
        val result = open(server.port, trust = null)
        assertEquals(ErrorCode.TLS, code(result))
        assertEquals(Trust.fingerprint(TestCertificates.certificate("test-leaf-local")), presented(result))
    }

    @Test
    fun `another CA's anchor refuses the device`() {
        val server = LocalTlsServer("test-leaf-expired").also { server = it }
        val otherCa = Trust(listOf(TestCertificates.certificate("test-local-ca")), emptySet(), ignoreExpiry = true, ignoreHostname = true)
        assertEquals(ErrorCode.TLS, code(open(server.port, trust = otherCa)))
    }

    @Test
    fun `nothing listening fails with network`() {
        val port = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        assertEquals(ErrorCode.NETWORK, code(open(port)))
    }

    @Test
    fun `open gives up after its timeout`() {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { silent ->
            val answers = Answers()
            val started = System.nanoTime()
            sessions.open(HttpSessions.OpenRequest("127.0.0.1", silent.localPort, chargerCa, 500), SocketRoute.DEFAULT, answers::add)
            assertEquals(ErrorCode.TIMEOUT, code(answers.next()))
            val elapsedMs = (System.nanoTime() - started) / 1_000_000
            assertTrue("$elapsedMs ms", elapsedMs in 450..3_000)
        }
    }

    @Test
    fun `a device that never finishes the handshake times out`() {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { silent ->
            try {
                TlsSessionConnector.connect("127.0.0.1", silent.localPort, TestCertificates.chargerCaTrust(), SocketRoute.DEFAULT, 300)
                fail("connected")
            } catch (e: BridgeException) {
                assertEquals(ErrorCode.TIMEOUT, e.code)
            }
        }
    }

    @Test
    fun `a name that resolves outside the local network is refused`() {
        val route = SocketRoute({ Socket() }, { listOf(InetAddress.getByName("8.8.8.8")) })
        try {
            TlsSessionConnector.connect("charger.local", 443, TestCertificates.chargerCaTrust(), route, 300)
            fail("connected")
        } catch (e: BridgeException) {
            assertEquals(ErrorCode.NETWORK, e.code)
        }
    }

    @Test
    fun `a device dropping the connection ends the session`() {
        val server = LocalTlsServer("test-leaf-expired").also { server = it }
        server.responses += "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        server.dropAfterResponse = true
        val sessionId = open(server.port).getOrThrow()
        val get = HttpSessions.Request("GET", "/api/info", emptyMap(), null, 5_000)
        assertEquals("ok", request(sessionId, get).getOrThrow().getString("body"))
        Thread.sleep(200)

        assertEquals(ErrorCode.NETWORK, code(request(sessionId, get)))
        try {
            sessions.request(sessionId, get) {}
            fail("the session should be gone")
        } catch (e: BridgeException) {
            assertEquals(ErrorCode.UNKNOWN_SESSION, e.code)
        }
        assertEquals("no new connection behind the page's back", 1, server.connections.get())
    }
}

/** A TLS server on 127.0.0.1 that answers each request with the next of [responses] (then 404s). */
internal class LocalTlsServer(identity: String) : AutoCloseable {
    private val socket = TestCertificates.serverContext(identity).serverSocketFactory
        .createServerSocket(0, 50, InetAddress.getLoopbackAddress()) as SSLServerSocket
    val port: Int = socket.localPort
    val connections = AtomicInteger()
    val requests: MutableList<String> = CopyOnWriteArrayList()
    val responses = LinkedBlockingQueue<String>()

    @Volatile
    var dropAfterResponse = false
    private val accepted = CopyOnWriteArrayList<Socket>()

    init {
        Thread({
            while (!socket.isClosed) {
                val client = try {
                    socket.accept()
                } catch (_: Exception) {
                    break
                }
                connections.incrementAndGet()
                accepted += client
                Thread({ serve(client) }, "LocalTlsServer-client").apply { isDaemon = true }.start()
            }
        }, "LocalTlsServer").apply { isDaemon = true }.start()
    }

    private fun serve(client: Socket) {
        try {
            val input = BufferedInputStream(client.getInputStream())
            while (true) {
                val request = readRequest(input) ?: break
                requests += request
                val response = responses.poll() ?: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                client.getOutputStream().apply {
                    write(response.toByteArray())
                    flush()
                }
                if (dropAfterResponse) {
                    client.close()
                    break
                }
            }
        } catch (_: Exception) {
            // The client went away (or failed the handshake).
        }
    }

    private fun readRequest(input: InputStream): String? {
        val head = ByteArrayOutputStream()
        while (!head.toString(Charsets.UTF_8.name()).endsWith("\r\n\r\n")) {
            val byte = input.read()
            if (byte < 0) return null
            head.write(byte)
        }
        val text = head.toString(Charsets.UTF_8.name())
        val length = text.lines().firstOrNull { it.lowercase().startsWith("content-length:") }
            ?.substringAfter(':')?.trim()?.toInt() ?: 0
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) return null
            read += n
        }
        return text + String(body, Charsets.UTF_8)
    }

    override fun close() {
        socket.close()
        accepted.forEach { it.close() }
    }
}
