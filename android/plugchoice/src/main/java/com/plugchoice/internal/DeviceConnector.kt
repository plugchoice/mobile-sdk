package com.plugchoice.internal

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.SSLSocket

/**
 * How a socket reaches a device: over the joined charger network while `wifi.routeTraffic` is on
 * (the socket is bound to it, never the process), or the default one.
 */
internal class SocketRoute(
    val newSocket: () -> Socket,
    val resolve: (String) -> List<InetAddress>,
    /** Binds a UDP socket to the route's network before it is used. */
    val bindDatagram: (DatagramSocket) -> Unit = {},
) {
    companion object {
        val DEFAULT = SocketRoute({ Socket() }, { InetAddress.getAllByName(it).toList() })
    }
}

/**
 * TLS on a device connection: [trust] (null: the system's trust), and [serverName], the name sent
 * as SNI and matched against the certificate (the host when null).
 */
internal class TlsOptions(val trust: Trust?, val serverName: String? = null)

/** A connected TCP socket, and the TLS socket over it when there is one ([socket] is [raw] otherwise). */
internal class DeviceConnection(private val raw: Socket, val socket: Socket) : Closeable {
    val input: InputStream = socket.getInputStream()
    val output: OutputStream = socket.getOutputStream()

    /** The TCP socket first: that ends a read blocked on another thread at once. */
    override fun close() {
        closeQuietly(raw)
        if (socket !== raw) closeQuietly(socket)
    }

    companion object {
        fun closeQuietly(socket: Socket) {
            try {
                socket.close()
            } catch (_: IOException) {
            }
        }
    }
}

/** Opens TCP (and TLS) connections to devices on the local network, for `http.session` and `tcp`. */
internal object DeviceConnector {
    /**
     * Connects to [host]:[port] within [timeoutMs] (TCP and, with [tls], the handshake), trying
     * each local address the name resolves to. Blocking. Throws [BridgeException] `tls` (with
     * `details.presentedFingerprint`), `network` or `timeout`.
     */
    fun connect(host: String, port: Int, route: SocketRoute, timeoutMs: Long, tls: TlsOptions?): DeviceConnection {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        fun remainingMs(): Int {
            val left = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
            if (left <= 0) throw timeout(timeoutMs, tls)
            return left.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        }

        // Whatever the name resolves to must be on the local network (as http.request's DNS).
        val addresses = try {
            route.resolve(host).filter(HostAllowList::isLocalAddress)
        } catch (e: IOException) {
            throw BridgeException(ErrorCode.NETWORK, "could not resolve $host: ${e.message}")
        }
        if (addresses.isEmpty()) throw BridgeException(ErrorCode.NETWORK, "$host did not resolve to a local network address")

        val peerName = tls?.serverName ?: host
        val evaluator = tls?.let { TrustEvaluator(it.trust, peerName) }
        val context = evaluator?.let { SSLContext.getInstance("TLS").apply { init(null, arrayOf(it), null) } }
        var failure: BridgeException? = null
        for (address in addresses) {
            val raw = route.newSocket()
            try {
                raw.tcpNoDelay = true
                raw.connect(InetSocketAddress(address, port), remainingMs())
                if (context == null) return DeviceConnection(raw, raw)
                val socket = context.socketFactory.createSocket(raw, peerName, port, true) as SSLSocket
                tls.serverName?.takeUnless(HostAllowList::isIpLiteral)?.let { name ->
                    socket.sslParameters = socket.sslParameters.apply { serverNames = listOf(SNIHostName(name)) }
                }
                socket.soTimeout = remainingMs()
                socket.startHandshake()
                socket.soTimeout = 0
                return DeviceConnection(raw, socket)
            } catch (e: BridgeException) {
                DeviceConnection.closeQuietly(raw)
                throw e
            } catch (e: IOException) {
                DeviceConnection.closeQuietly(raw)
                failure = when {
                    evaluator?.rejected == true -> evaluator.tlsError()
                    e is SocketTimeoutException -> timeout(timeoutMs, tls)
                    e is SSLException -> BridgeException(ErrorCode.NETWORK, "TLS handshake failed: ${e.message}")
                    else -> BridgeException(ErrorCode.NETWORK, e.message ?: e.toString())
                }
                if (failure.code == ErrorCode.TLS) throw failure
            }
        }
        throw failure ?: BridgeException(ErrorCode.NETWORK, "could not connect to $host")
    }

    private fun timeout(timeoutMs: Long, tls: TlsOptions?) =
        BridgeException(ErrorCode.TIMEOUT, if (tls != null) "no TCP and TLS handshake within $timeoutMs ms" else "not connected within $timeoutMs ms")
}

/** Daemon threads named `name-1`, `name-2`, … */
internal fun daemonThreads(name: String): java.util.concurrent.ThreadFactory {
    val count = java.util.concurrent.atomic.AtomicInteger()
    return java.util.concurrent.ThreadFactory { runnable -> Thread(runnable, "$name-${count.incrementAndGet()}").apply { isDaemon = true } }
}
