package com.plugchoice.internal

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.PortUnreachableException
import java.net.SocketTimeoutException
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit

/**
 * `udp.exchange` (PROTOCOL.md §9.7): one datagram to a unicast address on the local network, and
 * the replies that come back until `maxReplies` arrived or `timeoutMs` passed (what came by then;
 * possibly none). The socket is connected, as on iOS: replies come only from the address and port
 * the datagram went to, and nothing listening there is no error. Broadcast stays off on the
 * socket, so a subnet's directed broadcast fails with `network`, as on iOS.
 *
 * Callbacks come from background threads. Thread-safe.
 */
internal class UdpExchanges(
    private val newSocket: () -> DatagramSocket = { DatagramSocket() },
) {
    class Request(
        val host: String,
        val port: Int,
        val data: ByteArray,
        val timeoutMs: Long,
        val maxReplies: Int = 1,
    )

    private val active: MutableSet<DatagramSocket> = ConcurrentHashMap.newKeySet()
    private val threads: ExecutorService = Executors.newCachedThreadPool(daemonThreads("Plugchoice-udp"))

    fun exchange(request: Request, route: SocketRoute, callback: (Result<JSONObject>) -> Unit) {
        try {
            threads.execute { callback(runCatching { run(request, route) }) }
        } catch (_: RejectedExecutionException) {
            callback(Result.failure(BridgeException(ErrorCode.NETWORK, "the screen is closing")))
        }
    }

    private fun run(request: Request, route: SocketRoute): JSONObject {
        val address = try {
            route.resolve(request.host)
                .filter(HostAllowList::isLocalAddress)
                .sortedBy { if (it is Inet4Address) 0 else 1 }
                .firstOrNull()
        } catch (e: IOException) {
            throw BridgeException(ErrorCode.NETWORK, "could not resolve ${request.host}: ${e.message}")
        } ?: throw BridgeException(ErrorCode.NETWORK, "${request.host} did not resolve to a local network address")

        val socket = try {
            newSocket()
        } catch (e: IOException) {
            throw BridgeException(ErrorCode.NETWORK, "no UDP socket: ${e.message}")
        }
        active += socket
        try {
            route.bindDatagram(socket)
            socket.broadcast = false
            socket.connect(InetSocketAddress(address, request.port))
            socket.send(DatagramPacket(request.data, request.data.size, address, request.port))
        } catch (e: IOException) {
            active -= socket
            socket.close()
            throw BridgeException(ErrorCode.NETWORK, e.message ?: e.toString())
        }
        val replies = JSONArray()
        try {
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(request.timeoutMs)
            val buffer = ByteArray(MAX_DATAGRAM_BYTES)
            while (replies.length() < request.maxReplies) {
                val leftMs = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
                if (leftMs <= 0) break
                socket.soTimeout = leftMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    socket.receive(packet)
                } catch (_: SocketTimeoutException) {
                    break
                } catch (_: PortUnreachableException) {
                    // Nothing listening there: no error, just no replies (as on iOS).
                    continue
                }
                replies.put(
                    JSONObject()
                        .put("from", text(packet.address))
                        .put("port", packet.port)
                        .put("data", Base64.getEncoder().encodeToString(packet.data.copyOfRange(packet.offset, packet.offset + packet.length))),
                )
            }
            return JSONObject().put("replies", replies)
        } catch (e: IOException) {
            // A failure after replies came: answer with those (as on iOS).
            if (replies.length() > 0) return JSONObject().put("replies", replies)
            throw BridgeException(ErrorCode.NETWORK, e.message ?: e.toString())
        } finally {
            active -= socket
            socket.close()
        }
    }

    /** The page is gone: running exchanges end (their answers go nowhere). */
    fun cancelAll() {
        for (socket in active.toList()) socket.close()
    }

    fun dispose() {
        cancelAll()
        threads.shutdown()
    }

    companion object {
        /** The largest UDP payload over IPv4. */
        const val MAX_DATAGRAM_BYTES = 65_507
        val TIMEOUT_RANGE = 100L..30_000L
        val MAX_REPLIES_RANGE = 1..1_000

        private fun text(address: InetAddress): String = DiscoveredServices.text(address) ?: address.hostAddress.orEmpty()

        /** `udp.exchange` params, checked: params first, then the host rules (unicast only). */
        fun parse(params: JSONObject): Request {
            val host = params.requireString("host")
            val port = params.requireWholeNumber("port", 1..65535)
            val data = params.requireBase64("data")
            if (data.size > MAX_DATAGRAM_BYTES) throw BridgeException.invalidParams("data is longer than $MAX_DATAGRAM_BYTES bytes")
            val timeoutMs = params.requireClampedTimeoutMs("timeoutMs", TIMEOUT_RANGE)
            val maxReplies = params.optWholeNumber("maxReplies", MAX_REPLIES_RANGE, 1)
            if (HostAllowList.isMulticastOrBroadcast(host)) {
                throw BridgeException(ErrorCode.FORBIDDEN_HOST, "$host is a multicast or broadcast address; udp.exchange is unicast only")
            }
            HostAllowList.requireAllowed(host)
            return Request(host.removePrefix("[").removeSuffix("]"), port, data, timeoutMs, maxReplies)
        }
    }
}
