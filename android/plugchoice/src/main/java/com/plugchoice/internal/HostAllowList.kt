package com.plugchoice.internal

import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.Locale

/**
 * Which hosts `http.request`, `ws.open`, `http.session`, `tcp.open` and `udp.exchange` may reach
 * (PROTOCOL.md §9.1): IPv4 private ranges (10/8, 172.16/12, 192.168/16), link-local
 * (169.254/16), loopback, and `*.local` names.
 * Without it the bridge would be an open, CORS-free proxy for any page that got loaded.
 */
internal object HostAllowList {

    /**
     * [host] as OkHttp's `HttpUrl.host` gives it (lower case, IPv6 without brackets) or as a page
     * sends it. IPv4 literals must be strict dotted quads (no leading zeros), and a `*.local` name
     * holds letters, digits, `-`, `_` and dots only.
     */
    fun isAllowed(host: String): Boolean {
        var name = host.lowercase(Locale.ROOT).removePrefix("[").removeSuffix("]")
        if (name.isEmpty() || '%' in name) return false
        // IPv6 literal: loopback only.
        if (name == "::1" || name == "0:0:0:0:0:0:0:1") return true
        parseIpv4(name)?.let { return isLocalIpv4(it) }
        name = name.removeSuffix(".")
        if (name == "localhost") return true
        if (name.endsWith(".local")) {
            val label = name.removeSuffix(".local")
            return label.isNotEmpty() && !label.endsWith(".") && label.all { it in 'a'..'z' || it in '0'..'9' || it in "-_." }
        }
        return false
    }

    /**
     * [raw] as a URL OkHttp can use (`ws`/`wss` read as `http`/`https`): `invalidParams` when it
     * isn't an absolute URL, `forbiddenHost` for a scheme outside [schemes], a percent-encoded host
     * or a host outside the local network (PROTOCOL.md §9.1).
     */
    fun checkedUrl(raw: String, schemes: Set<String>): HttpUrl {
        val scheme = raw.substringBefore(':', missingDelimiterValue = "")
        if (scheme.isEmpty() || !scheme.all { it.isLetterOrDigit() || it in "+-." }) {
            throw BridgeException.invalidParams("url is not an absolute URL")
        }
        val lowerScheme = scheme.lowercase(Locale.ROOT)
        if (lowerScheme !in schemes) {
            throw BridgeException(ErrorCode.FORBIDDEN_HOST, "the scheme of $raw is not one of ${schemes.sorted().joinToString()}")
        }
        // OkHttp decodes a percent-encoded host; such a host is refused instead (as on iOS).
        val authority = raw.substringAfter(':').removePrefix("//").substringBefore('/').substringBefore('?').substringBefore('#')
        if ('%' in authority.substringAfterLast('@')) {
            throw BridgeException(ErrorCode.FORBIDDEN_HOST, "a percent-encoded host is not a local network host")
        }
        val httpForm = when (lowerScheme) {
            "ws" -> "http" + raw.substring(scheme.length)
            "wss" -> "https" + raw.substring(scheme.length)
            else -> raw
        }
        val url = httpForm.toHttpUrlOrNull() ?: throw BridgeException.invalidParams("url is not an absolute URL")
        if (!isAllowed(url.host)) {
            throw BridgeException(ErrorCode.FORBIDDEN_HOST, "${url.host} is not a local network host")
        }
        return url
    }

    val HTTP_SCHEMES = setOf("http", "https")
    val WEB_SOCKET_SCHEMES = setOf("ws", "wss")

    /** `forbiddenHost` unless [isAllowed]. */
    fun requireAllowed(host: String) {
        if (!isAllowed(host)) throw BridgeException(ErrorCode.FORBIDDEN_HOST, "$host is not a local network host")
    }

    /** A dotted-quad IPv4 address or an IPv6 literal (with or without brackets), not a name. */
    fun isIpLiteral(host: String): Boolean = parseIpv4(host) != null || ':' in host

    /**
     * Not an address a unicast datagram may go to (PROTOCOL.md §9.7): IPv4 multicast
     * (224.0.0.0/4), `255.255.255.255`, and IPv6 multicast. A subnet's directed broadcast can't be
     * told from a host address without the netmask; it fails when sent (no `SO_BROADCAST`).
     */
    fun isMulticastOrBroadcast(host: String): Boolean {
        val name = host.removePrefix("[").removeSuffix("]").lowercase(Locale.ROOT)
        parseIpv4(name)?.let { octets -> return octets[0] in 224..239 || octets.all { it == 255 } }
        return name.startsWith("ff") && ':' in name
    }

    /** Whether a resolved address is on the local network (used to vet what `*.local` names resolve to). */
    fun isLocalAddress(address: InetAddress): Boolean = when (address) {
        is Inet4Address -> isLocalIpv4(address.address.map { it.toInt() and 0xff }.toIntArray())
        // mDNS often answers with IPv6 link-local or unique-local (fc00::/7) addresses.
        is Inet6Address -> address.isLoopbackAddress ||
            address.isLinkLocalAddress ||
            (address.address[0].toInt() and 0xfe) == 0xfc
        else -> false
    }

    private fun isLocalIpv4(octets: IntArray): Boolean {
        val (a, b) = octets
        return a == 10 ||
            (a == 172 && b in 16..31) ||
            (a == 192 && b == 168) ||
            (a == 169 && b == 254) ||
            a == 127
    }

    private fun parseIpv4(name: String): IntArray? {
        val parts = name.split('.')
        if (parts.size != 4) return null
        val octets = IntArray(4)
        for ((i, part) in parts.withIndex()) {
            if (part.isEmpty() || part.length > 3 || !part.all { it in '0'..'9' }) return null
            if (part.length > 1 && part.startsWith('0')) return null
            val value = part.toInt()
            if (value > 255) return null
            octets[i] = value
        }
        return octets
    }
}

/**
 * Resolves names with [resolve] and keeps only local-network addresses, so a `*.local` name
 * that DNS points at a public address can't be used to escape the allow-list.
 */
internal class LocalOnlyDns(private val resolve: (String) -> List<InetAddress>) : Dns {
    override fun lookup(hostname: String): List<InetAddress> {
        val local = resolve(hostname).filter(HostAllowList::isLocalAddress)
        if (local.isEmpty()) throw UnknownHostException("$hostname did not resolve to a local network address")
        return local
    }
}
