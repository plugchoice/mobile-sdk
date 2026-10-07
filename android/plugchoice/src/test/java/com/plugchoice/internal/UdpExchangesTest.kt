package com.plugchoice.internal

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.Base64

/** `udp.exchange` (PROTOCOL.md §9.7) against a server on 127.0.0.1: params, replies, timeouts, unicast only. */
class UdpExchangesTest {
    private val exchanges = UdpExchanges()
    private var server: UdpServer? = null

    @After
    fun tearDown() {
        exchanges.dispose()
        server?.close()
    }

    private fun json(vararg pairs: Pair<String, Any?>) = JSONObject().apply { for ((key, value) in pairs) put(key, value) }

    private fun b64(text: String) = Base64.getEncoder().encodeToString(text.toByteArray())

    private fun assertCode(code: String, body: () -> Unit) {
        try {
            body()
            fail("expected $code")
        } catch (e: BridgeException) {
            assertEquals(code, e.code)
        }
    }

    private fun exchange(request: UdpExchanges.Request, route: SocketRoute = SocketRoute.DEFAULT): Result<JSONObject> {
        val answers = Answers()
        exchanges.exchange(request, route, answers::add)
        return answers.next()
    }

    private fun replies(result: Result<JSONObject>): List<JSONObject> {
        val array = result.getOrThrow().getJSONArray("replies")
        return List(array.length()) { array.getJSONObject(it) }
    }

    // Params

    @Test
    fun `exchange params`() {
        val request = UdpExchanges.parse(json("host" to "192.168.1.10", "port" to 7090, "data" to b64("report 1"), "timeoutMs" to 2000))
        assertEquals("192.168.1.10", request.host)
        assertEquals(7090, request.port)
        assertArrayEquals("report 1".toByteArray(), request.data)
        assertEquals(2000L, request.timeoutMs)
        assertEquals(1, request.maxReplies)
        assertEquals(5, UdpExchanges.parse(json("host" to "10.0.0.2", "port" to 1, "data" to "", "timeoutMs" to 1, "maxReplies" to 5)).maxReplies)
        assertEquals("at least 100 ms", 100L, UdpExchanges.parse(json("host" to "10.0.0.2", "port" to 1, "data" to "", "timeoutMs" to 1)).timeoutMs)
        assertEquals("at most 30 s", 30_000L, UdpExchanges.parse(json("host" to "10.0.0.2", "port" to 1, "data" to "", "timeoutMs" to 99_000)).timeoutMs)
        assertArrayEquals("padding optional", "ab".toByteArray(), UdpExchanges.parse(json("host" to "10.0.0.2", "port" to 1, "data" to "YWI", "timeoutMs" to 1)).data)
    }

    @Test
    fun `exchange rejects bad params`() {
        val ok = json("host" to "10.0.0.2", "port" to 7090, "data" to b64("x"), "timeoutMs" to 1000)
        for ((key, value) in listOf(
            "host" to null,
            "host" to "",
            "port" to null,
            "port" to 0,
            "port" to 65_536,
            "data" to null,
            "data" to "not base64!",
            "data" to 7,
            "data" to Base64.getEncoder().encodeToString(ByteArray(UdpExchanges.MAX_DATAGRAM_BYTES + 1)),
            "timeoutMs" to null,
            "timeoutMs" to 0,
            "timeoutMs" to "1000",
            "maxReplies" to 0,
            "maxReplies" to 1.5,
            "maxReplies" to 5_000,
        )) {
            val bad = JSONObject(ok.toString()).apply { if (value == null) remove(key) else put(key, value) }
            assertCode(ErrorCode.INVALID_PARAMS) { UdpExchanges.parse(bad) }
        }
    }

    @Test
    fun `unicast to local hosts only`() {
        for (host in listOf("10.0.0.2", "192.168.1.255", "127.0.0.1", "localhost", "keba.local")) {
            UdpExchanges.parse(json("host" to host, "port" to 7090, "data" to "", "timeoutMs" to 100))
        }
        for (host in listOf("224.0.0.251", "239.255.255.250", "255.255.255.255", "ff02::1", "[ff02::fb]", "8.8.8.8", "example.com")) {
            assertCode(ErrorCode.FORBIDDEN_HOST) { UdpExchanges.parse(json("host" to host, "port" to 7090, "data" to "", "timeoutMs" to 100)) }
        }
    }

    // Exchanges

    @Test
    fun `one datagram and its reply`() {
        val server = UdpServer(repliesPerRequest = 1).also { server = it }
        // Answers on the first reply; the generous timeout only matters on a loaded machine.
        val result = exchange(UdpExchanges.Request("127.0.0.1", server.port, "report 1".toByteArray(), 10_000))
        val reply = replies(result).single()
        assertEquals("127.0.0.1", reply.getString("from"))
        assertEquals(server.port, reply.getInt("port"))
        assertEquals("report 1#1", String(Base64.getDecoder().decode(reply.getString("data"))))
    }

    @Test
    fun `replies until maxReplies`() {
        val server = UdpServer(repliesPerRequest = 5).also { server = it }
        val started = System.nanoTime()
        val result = exchange(UdpExchanges.Request("127.0.0.1", server.port, "x".toByteArray(), 10_000, maxReplies = 3))
        assertEquals(listOf("x#1", "x#2", "x#3"), replies(result).map { String(Base64.getDecoder().decode(it.getString("data"))) })
        assertTrue("answers once the replies are in", (System.nanoTime() - started) / 1_000_000 < 5_000)
    }

    @Test
    fun `fewer replies than asked for answer at the timeout`() {
        val server = UdpServer(repliesPerRequest = 2).also { server = it }
        val started = System.nanoTime()
        val result = exchange(UdpExchanges.Request("127.0.0.1", server.port, "x".toByteArray(), 1_500, maxReplies = 10))
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertEquals(2, replies(result).size)
        assertTrue("$elapsedMs ms", elapsedMs in 1_450..4_000)
    }

    @Test
    fun `replies come only from where the datagram went`() {
        // A device that answers from another port (as iOS's connected socket ignores it).
        val device = DatagramSocket(0, InetAddress.getLoopbackAddress())
        val other = DatagramSocket(0, InetAddress.getLoopbackAddress())
        try {
            Thread({
                val packet = DatagramPacket(ByteArray(64), 64)
                device.receive(packet)
                val reply = "from elsewhere".toByteArray()
                other.send(DatagramPacket(reply, reply.size, packet.socketAddress))
            }, "OtherPort").apply { isDaemon = true }.start()
            assertEquals(0, replies(exchange(UdpExchanges.Request("127.0.0.1", device.localPort, "x".toByteArray(), 500))).size)
        } finally {
            device.close()
            other.close()
        }
    }

    @Test
    fun `nobody answering is no replies`() {
        val port = DatagramSocket(0, InetAddress.getLoopbackAddress()).use { it.localPort }
        assertEquals(0, replies(exchange(UdpExchanges.Request("127.0.0.1", port, "x".toByteArray(), 200))).size)
    }

    @Test
    fun `a name that resolves outside the local network is refused`() {
        val route = SocketRoute({ java.net.Socket() }, { listOf(InetAddress.getByName("8.8.8.8")) })
        val result = exchange(UdpExchanges.Request("keba.local", 7090, "x".toByteArray(), 200), route)
        assertEquals(ErrorCode.NETWORK, (result.exceptionOrNull() as BridgeException).code)
    }

    @Test
    fun `the page going away ends a running exchange`() {
        val port = DatagramSocket(0, InetAddress.getLoopbackAddress()).use { it.localPort }
        val answers = Answers()
        exchanges.exchange(UdpExchanges.Request("127.0.0.1", port, "x".toByteArray(), 10_000), SocketRoute.DEFAULT, answers::add)
        Thread.sleep(200)
        val started = System.nanoTime()
        exchanges.cancelAll()
        val result = answers.next()
        assertTrue((System.nanoTime() - started) / 1_000_000 < 2_000)
        assertEquals(ErrorCode.NETWORK, (result.exceptionOrNull() as BridgeException).code)
    }
}

/** Answers each datagram with [repliesPerRequest] replies: the payload plus `#1`, `#2`, … */
private class UdpServer(private val repliesPerRequest: Int) : AutoCloseable {
    private val socket = DatagramSocket(0, InetAddress.getLoopbackAddress())
    val port: Int = socket.localPort

    init {
        Thread({
            val buffer = ByteArray(65_535)
            while (!socket.isClosed) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    socket.receive(packet)
                } catch (_: Exception) {
                    break
                }
                val text = String(packet.data, packet.offset, packet.length)
                for (i in 1..repliesPerRequest) {
                    val reply = "$text#$i".toByteArray()
                    socket.send(DatagramPacket(reply, reply.size, packet.socketAddress))
                }
            }
        }, "UdpServer").apply { isDaemon = true }.start()
    }

    override fun close() = socket.close()
}
