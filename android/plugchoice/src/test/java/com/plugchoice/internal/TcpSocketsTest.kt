package com.plugchoice.internal

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketTimeoutException
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import javax.net.ServerSocketFactory

/** `tcp.*` (PROTOCOL.md §9.6) against servers on 127.0.0.1: params, data, close, limits, TLS. */
class TcpSocketsTest {
    private val events = LinkedBlockingQueue<Pair<String, JSONObject>>()
    private val sockets = TcpSockets(emit = { event, params -> events.put(event to params) })
    private val servers = CopyOnWriteArrayList<EchoServer>()

    @After
    fun tearDown() {
        sockets.dispose()
        servers.forEach { it.close() }
    }

    private fun json(vararg pairs: Pair<String, Any?>) = JSONObject().apply { for ((key, value) in pairs) put(key, value) }

    private fun assertCode(code: String, body: () -> Unit) {
        try {
            body()
            fail("expected $code")
        } catch (e: BridgeException) {
            assertEquals(code, e.code)
        }
    }

    private fun code(result: Result<*>): String? = (result.exceptionOrNull() as? BridgeException)?.code

    private fun server(identity: String? = null) = EchoServer(identity).also { servers += it }

    private fun open(id: String, port: Int, tls: TlsOptions? = null, host: String = "127.0.0.1", route: SocketRoute = SocketRoute.DEFAULT, timeoutMs: Long = 5_000): Result<JSONObject> {
        val answers = Answers()
        sockets.open(TcpSockets.OpenRequest(id, host, port, timeoutMs, tls), route, answers::add)
        return answers.next()
    }

    private fun write(id: String, text: String): Result<JSONObject> {
        val answers = Answers()
        sockets.write(id, text.toByteArray(), answers::add)
        return answers.next()
    }

    private fun nextEvent(): Pair<String, JSONObject> = events.poll(5, TimeUnit.SECONDS) ?: throw AssertionError("no event within 5 s")

    /** `tcp.data` events until [text] arrived in full. */
    private fun receive(id: String, text: String) {
        val received = StringBuilder()
        while (received.length < text.length) {
            val (event, params) = nextEvent()
            assertEquals("tcp.data", event)
            assertEquals(id, params.getString("socketId"))
            received.append(String(Base64.getDecoder().decode(params.getString("data"))))
        }
        assertEquals(text, received.toString())
    }

    // Params

    @Test
    fun `open params`() {
        val request = TcpSockets.parseOpen(json("socketId" to "t1", "host" to "192.168.1.10", "port" to 502))
        assertEquals("t1", request.socketId)
        assertEquals(502, request.port)
        assertEquals(10_000L, request.timeoutMs)
        assertNull(request.tls)
        val tls = TcpSockets.parseOpen(
            json("socketId" to "t1", "host" to "[::1]", "port" to 8443, "timeoutMs" to 100, "tls" to json("serverName" to "charger.local")),
        )
        assertEquals("::1", tls.host)
        assertEquals("at least 500 ms", 500L, tls.timeoutMs)
        assertEquals("charger.local", tls.tls!!.serverName)
        assertNull("the system's trust", tls.tls.trust)
        assertEquals(30_000L, TcpSockets.parseOpen(json("socketId" to "t", "host" to "10.0.0.2", "port" to 1, "timeoutMs" to 1e9)).timeoutMs)
        val pinned = TcpSockets.parseOpen(
            json("socketId" to "t", "host" to "10.0.0.2", "port" to 1, "tls" to json("trust" to json("fingerprints" to org.json.JSONArray().put(Trust.fingerprint(TestCertificates.certificate("test-self-signed")))))),
        )
        assertEquals(1, pinned.tls!!.trust!!.fingerprints.size)
    }

    @Test
    fun `open rejects bad params before the host`() {
        for (bad in listOf(
            json("host" to "10.0.0.2", "port" to 80),
            json("socketId" to "", "host" to "10.0.0.2", "port" to 80),
            json("socketId" to "t", "port" to 80),
            json("socketId" to "t", "host" to "10.0.0.2"),
            json("socketId" to "t", "host" to "10.0.0.2", "port" to 0),
            json("socketId" to "t", "host" to "10.0.0.2", "port" to 70_000),
            json("socketId" to "t", "host" to "10.0.0.2", "port" to "80"),
            json("socketId" to "t", "host" to "10.0.0.2", "port" to 80, "timeoutMs" to 0),
            json("socketId" to "t", "host" to "10.0.0.2", "port" to 80, "tls" to true),
            json("socketId" to "t", "host" to "10.0.0.2", "port" to 80, "tls" to json("serverName" to "")),
            json("socketId" to "t", "host" to "10.0.0.2", "port" to 80, "tls" to json("serverName" to "bad name")),
            json("socketId" to "t", "host" to "10.0.0.2", "port" to 80, "tls" to json("trust" to json())),
            json("socketId" to "t", "host" to "8.8.8.8", "port" to 80, "tls" to json("trust" to "alfen")),
        )) {
            assertCode(ErrorCode.INVALID_PARAMS) { TcpSockets.parseOpen(bad) }
        }
    }

    @Test
    fun `only local hosts`() {
        for (host in listOf("10.0.0.1", "172.16.0.1", "192.168.1.10", "169.254.1.1", "127.0.0.1", "localhost", "charger.local")) {
            TcpSockets.parseOpen(json("socketId" to "t", "host" to host, "port" to 80))
        }
        for (host in listOf("8.8.8.8", "example.com", "224.0.0.1", "255.255.255.255", "fe80::1", "167772161")) {
            assertCode(ErrorCode.FORBIDDEN_HOST) { TcpSockets.parseOpen(json("socketId" to "t", "host" to host, "port" to 80)) }
        }
    }

    // A connection

    @Test
    fun `open, write, data, close`() {
        val server = server()
        open("t1", server.port).getOrThrow()
        assertEquals(1, sockets.count)
        write("t1", "hello").getOrThrow()
        receive("t1", "hello")
        write("t1", "again").getOrThrow()
        receive("t1", "again")

        sockets.close("t1")
        val (event, params) = nextEvent()
        assertEquals("tcp.close", event)
        assertEquals("t1", params.getString("socketId"))
        assertFalse("a requested close has no error", params.has("error"))
        assertNull("tcp.close is the last event", events.poll(200, TimeUnit.MILLISECONDS))
        assertEquals(0, sockets.count)
        sockets.close("t1") // idempotent
        assertCode(ErrorCode.UNKNOWN_SOCKET) { sockets.write("t1", byteArrayOf(1)) {} }
    }

    @Test
    fun `the device closing ends the socket with tcp close`() {
        val server = server()
        server.closeAfterEcho = true
        open("t1", server.port).getOrThrow()
        write("t1", "bye").getOrThrow()
        receive("t1", "bye")
        val (event, params) = nextEvent()
        assertEquals("tcp.close", event)
        assertFalse(params.has("error"))
        assertEquals(0, sockets.count)
    }

    @Test
    fun `nothing listening is network`() {
        val port = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        assertEquals(ErrorCode.NETWORK, code(open("t1", port)))
        assertEquals(0, sockets.count)
        assertNull("no events for a socket that never opened", events.poll(100, TimeUnit.MILLISECONDS))
    }

    @Test
    fun `a connect that never finishes times out`() {
        val slow = SocketRoute({ SlowSocket() }, { listOf(InetAddress.getByName("10.0.0.2")) })
        val started = System.nanoTime()
        assertEquals(ErrorCode.TIMEOUT, code(open("t1", 502, host = "10.0.0.2", route = slow, timeoutMs = 500)))
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertTrue("$elapsedMs ms", elapsedMs in 450..3_000)
    }

    @Test
    fun `a name that resolves outside the local network is refused`() {
        val route = SocketRoute({ Socket() }, { listOf(InetAddress.getByName("8.8.8.8")) })
        assertEquals(ErrorCode.NETWORK, code(open("t1", 502, host = "charger.local", route = route)))
    }

    @Test
    fun `socket ids are unique and unknown sockets are refused`() {
        val server = server()
        open("t1", server.port).getOrThrow()
        assertCode(ErrorCode.INVALID_PARAMS) { sockets.open(TcpSockets.OpenRequest("t1", "127.0.0.1", server.port), SocketRoute.DEFAULT) {} }
        assertCode(ErrorCode.UNKNOWN_SOCKET) { sockets.write("nope", byteArrayOf(1)) {} }
    }

    @Test
    fun `at most 16 sockets, opening ones included`() {
        val server = server()
        repeat(TcpSockets.MAX_SOCKETS) { open("t$it", server.port).getOrThrow() }
        assertCode(ErrorCode.TOO_MANY_SOCKETS) { sockets.open(TcpSockets.OpenRequest("t16", "127.0.0.1", server.port), SocketRoute.DEFAULT) {} }
        sockets.close("t0")
        open("t16", server.port).getOrThrow()
    }

    @Test
    fun `closing a socket still connecting fails its open, without events`() {
        val gate = CountDownLatch(1)
        val gated = TcpSockets(
            emit = { event, params -> events.put(event to params) },
            connector = { request, route ->
                gate.await()
                DeviceConnector.connect(request.host, request.port, route, request.timeoutMs, request.tls)
            },
        )
        try {
            val server = server()
            val answers = Answers()
            gated.open(TcpSockets.OpenRequest("t1", "127.0.0.1", server.port), SocketRoute.DEFAULT, answers::add)
            assertEquals(1, gated.count)
            gated.close("t1")
            gate.countDown()
            assertEquals(ErrorCode.NETWORK, code(answers.next()))
            assertNull(events.poll(200, TimeUnit.MILLISECONDS))
            assertEquals(0, gated.count)
        } finally {
            gated.dispose()
        }
    }

    @Test
    fun `the page going away closes everything without events`() {
        val server = server()
        open("t1", server.port).getOrThrow()
        open("t2", server.port).getOrThrow()
        sockets.closeAll()
        assertEquals(0, sockets.count)
        assertNull(events.poll(300, TimeUnit.MILLISECONDS))
    }

    // TLS

    private val deviceCa = Trust(listOf(TestCertificates.certificate("test-local-ca")), emptySet(), ignoreExpiry = false, ignoreHostname = false)

    @Test
    fun `TLS with the page's anchor`() {
        val server = server("test-leaf-local")
        open("t1", server.port, TlsOptions(deviceCa)).getOrThrow()
        write("t1", "over tls").getOrThrow()
        receive("t1", "over tls")
    }

    @Test
    fun `TLS checks the server name instead of the host`() {
        val server = server("test-leaf-local")
        open("t1", server.port, TlsOptions(deviceCa, serverName = "charger.local")).getOrThrow()
        val other = open("t2", server.port, TlsOptions(deviceCa, serverName = "other.local"))
        assertEquals(ErrorCode.TLS, code(other))
    }

    @Test
    fun `TLS without a trust uses the system's and reports the leaf`() {
        val server = server("test-leaf-local")
        val result = open("t1", server.port, TlsOptions(null))
        assertEquals(ErrorCode.TLS, code(result))
        assertEquals(
            Trust.fingerprint(TestCertificates.certificate("test-leaf-local")),
            (result.exceptionOrNull() as BridgeException).details!!.getString("presentedFingerprint"),
        )
        assertEquals(0, sockets.count)
    }

    @Test
    fun `a TLS handshake that never comes times out`() {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { silent ->
            assertEquals(ErrorCode.TIMEOUT, code(open("t1", silent.localPort, TlsOptions(deviceCa), timeoutMs = 500)))
        }
    }
}

/** Connects after its timeout, never: a device that doesn't answer the SYN. */
private class SlowSocket : Socket() {
    override fun connect(endpoint: SocketAddress?, timeout: Int) {
        Thread.sleep(timeout.toLong())
        throw SocketTimeoutException("connect timed out")
    }
}

/** Echoes what it receives on 127.0.0.1; over TLS when [identity] names a test certificate. */
internal class EchoServer(identity: String?) : AutoCloseable {
    private val socket: ServerSocket = (identity?.let { TestCertificates.serverContext(it).serverSocketFactory } ?: ServerSocketFactory.getDefault())
        .createServerSocket(0, 50, InetAddress.getLoopbackAddress())
    val port: Int = socket.localPort

    @Volatile
    var closeAfterEcho = false
    private val accepted = CopyOnWriteArrayList<Socket>()

    init {
        Thread({
            while (!socket.isClosed) {
                val client = try {
                    socket.accept()
                } catch (_: Exception) {
                    break
                }
                accepted += client
                Thread({ serve(client) }, "EchoServer-client").apply { isDaemon = true }.start()
            }
        }, "EchoServer").apply { isDaemon = true }.start()
    }

    private fun serve(client: Socket) {
        try {
            val buffer = ByteArray(4096)
            while (true) {
                val count = client.getInputStream().read(buffer)
                if (count < 0) break
                client.getOutputStream().apply {
                    write(buffer, 0, count)
                    flush()
                }
                if (closeAfterEcho) {
                    client.close()
                    break
                }
            }
        } catch (_: Exception) {
        }
    }

    override fun close() {
        socket.close()
        accepted.forEach { it.close() }
    }
}
