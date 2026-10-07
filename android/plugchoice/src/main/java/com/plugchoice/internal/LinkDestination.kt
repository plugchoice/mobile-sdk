package com.plugchoice.internal

import com.plugchoice.LinkAction
import com.plugchoice.Plugchoice
import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

/**
 * Where the Link screen goes (PROTOCOL.md §2): the [url] to load, and the one [origin] the
 * bridge talks to and the WebView may navigate within.
 *
 * The URL is `https://connect.plugchoice.com/#action=<action>` plus `&charger_id=<id>` and
 * `&site_id=<id>` when given, each value percent-encoded. It never holds the client secret.
 * Plain JVM code (no android.*), so it is unit tested directly.
 */
internal data class LinkDestination(
    val url: String,
    val origin: String,
) {
    companion object {
        /**
         * [hostOverride] (`Options.hostOverride`, e.g. `http://192.168.1.20:5173`) replaces the
         * scheme, host and port and becomes the allowed origin, but only when [overrideAllowed]
         * (the host app is debuggable). Otherwise, or when it isn't a plain `http(s)://host[:port]`,
         * it is ignored and [onOverrideIgnored] gets why (for a log line).
         */
        fun resolve(
            action: LinkAction,
            hostOverride: String?,
            overrideAllowed: Boolean,
            onOverrideIgnored: (String) -> Unit = {},
        ): LinkDestination {
            val origin = overrideOrigin(hostOverride, overrideAllowed, onOverrideIgnored) ?: Plugchoice.ORIGIN
            return LinkDestination("$origin/#${fragment(action)}", origin)
        }

        private fun overrideOrigin(hostOverride: String?, overrideAllowed: Boolean, onOverrideIgnored: (String) -> Unit): String? {
            val override = hostOverride?.takeIf { it.isNotBlank() } ?: return null
            if (!overrideAllowed) {
                onOverrideIgnored("hostOverride is ignored: the host app is not debuggable")
                return null
            }
            return parseOrigin(override).also {
                if (it == null) onOverrideIgnored("hostOverride is ignored: not an http(s)://host[:port] origin: $override")
            }
        }

        /** `action=…&charger_id=…&site_id=…`, the ids only when set. */
        fun fragment(action: LinkAction): String = buildList {
            add("action=" + percentEncode(action.name))
            action.chargerId?.let { add("charger_id=" + percentEncode(it)) }
            action.siteId?.let { add("site_id=" + percentEncode(it)) }
        }.joinToString("&")

        /** UTF-8 percent-encoding of everything but RFC 3986's unreserved characters. */
        fun percentEncode(value: String): String = buildString {
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val c = byte.toInt() and 0xff
                if (c.toChar().isUnreserved()) {
                    append(c.toChar())
                } else {
                    append('%').append(HEX[c shr 4]).append(HEX[c and 0x0f])
                }
            }
        }

        private fun Char.isUnreserved(): Boolean =
            this in 'A'..'Z' || this in 'a'..'z' || this in '0'..'9' || this == '-' || this == '.' || this == '_' || this == '~'

        private const val HEX = "0123456789ABCDEF"

        /**
         * `scheme://host[:port]` (lower case, default port left out) of an `http(s)://host[:port]`
         * origin with at most a trailing `/`; null for anything else.
         */
        fun parseOrigin(value: String): String? {
            val uri = try {
                URI(value.trim())
            } catch (_: URISyntaxException) {
                return null
            }
            val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return null
            if (uri.isOpaque || (scheme != "http" && scheme != "https")) return null
            val host = uri.host?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() } ?: return null
            if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
            if (!uri.rawPath.isNullOrEmpty() && uri.rawPath != "/") return null
            val defaultPort = if (scheme == "https") 443 else 80
            return if (uri.port == -1 || uri.port == defaultPort) "$scheme://$host" else "$scheme://$host:${uri.port}"
        }
    }
}
