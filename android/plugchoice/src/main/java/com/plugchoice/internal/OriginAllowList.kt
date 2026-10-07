package com.plugchoice.internal

import android.net.Uri
import androidx.core.net.toUri
import java.util.Locale

/**
 * The one origin whose pages may use the bridge (PROTOCOL.md §2): `https://connect.plugchoice.com`,
 * or the debug `hostOverride`.
 *
 * [rules] goes to `WebViewCompat.addWebMessageListener` as `allowedOriginRules`, so WebView
 * itself drops messages from other origins. [allows] applies the same check on the way back,
 * so responses and events are only evaluated in a page from the allowed origin, and is used to
 * keep main-frame navigation on it.
 */
internal class OriginAllowList(
    /** `scheme://host[:port]`, lower case, default port left out (as `LinkDestination.origin`). */
    origin: String,
) {
    val rules: Set<String> = setOf(origin)

    private val allowed: Origin = requireNotNull(parse(origin)) { "not an http(s) origin: $origin" }

    fun allows(url: String?): Boolean = url?.let(::parse) == allowed

    fun allows(uri: Uri): Boolean = allows(uri.toString())

    private data class Origin(val scheme: String, val host: String, val port: Int)

    private companion object {
        fun parse(url: String): Origin? {
            val uri = url.toUri()
            val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return null
            if (scheme != "http" && scheme != "https") return null
            val host = uri.host?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() } ?: return null
            val port = if (uri.port != -1) uri.port else if (scheme == "https") 443 else 80
            return Origin(scheme, host, port)
        }
    }
}
