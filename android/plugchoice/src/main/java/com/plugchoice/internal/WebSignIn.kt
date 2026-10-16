package com.plugchoice.internal

import android.content.Context
import android.net.Uri
import androidx.browser.auth.AuthTabIntent
import androidx.browser.customtabs.CustomTabsClient
import org.json.JSONObject
import java.net.URI
import java.net.URISyntaxException

/**
 * `auth.webSession` (PROTOCOL.md §7.1): Google or Apple sign-in in Chrome's Auth Tab, since Google
 * refuses an embedded web view. The tab closes on the `plugchoice-link` scheme and hands that URL
 * straight back to the activity that opened it, so no intent filter is involved and apps with the
 * SDK never compete for the scheme. Browsers without Auth Tab don't get the capability. The URL
 * holds a one-time code: never logged.
 */
internal class WebSignIn(private val host: BridgeHost) {

    private var showing = false

    suspend fun signIn(params: JSONObject): JSONObject {
        val value = params.optStringOrNull("url")
        if (!isWebSessionUrl(value)) throw BridgeException.invalidParams("url must be an https URL")
        val url = Uri.parse(value)
        if (showing) throw BridgeException(ErrorCode.UNAVAILABLE, "a sign-in is already showing")
        if (!isAvailable(host.hostContext)) throw BridgeException(ErrorCode.UNAVAILABLE, "the browser has no Auth Tab")

        showing = true
        try {
            val result = host.openAuthTab(url, CALLBACK_SCHEME)
            return when (result.resultCode) {
                AuthTabIntent.RESULT_OK -> {
                    val callback = result.resultUri ?: throw BridgeException(ErrorCode.UNAVAILABLE, "the sign-in returned no URL")
                    JSONObject().put("callbackUrl", callback.toString())
                }
                AuthTabIntent.RESULT_CANCELED -> throw BridgeException(ErrorCode.USER_CANCELLED, "sign-in closed")
                else -> throw BridgeException(ErrorCode.UNAVAILABLE, "sign-in failed (${result.resultCode})")
            }
        } finally {
            showing = false
        }
    }

    companion object {
        const val CALLBACK_SCHEME = "plugchoice-link"

        /** Whether the default browser (or another Custom Tabs browser) supports Auth Tab. */
        fun isAvailable(context: Context): Boolean {
            val browser = CustomTabsClient.getPackageName(context, null) ?: return false
            return CustomTabsClient.isAuthTabSupported(context, browser)
        }

        /** `url`: an `https` URL with a host (core's sign-in hop). Plain JVM, so tests can run it. */
        fun isWebSessionUrl(value: String?): Boolean {
            if (value.isNullOrEmpty()) return false
            val uri = try {
                URI(value)
            } catch (_: URISyntaxException) {
                return false
            }
            return uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrEmpty()
        }
    }
}
