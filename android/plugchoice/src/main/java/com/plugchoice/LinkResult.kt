package com.plugchoice

/**
 * How the Link screen ended (PROTOCOL.md §6.1). A convenience for the app's UI: your server
 * confirms with `GET /sdk/v1/link-sessions/{id}`.
 *
 * @property status `success`, `cancelled` or `error`, from the page; or `cancelled` / `error` when
 *   the screen closed by itself (the user left before the page took over, a hung page, the user
 *   leaving after the page failed to load).
 * @property action The action the run did; the one the screen was opened with when the page didn't
 *   say.
 * @property sessionId The run (link session), from the page; null when the screen closed by itself.
 * @property devices The devices the page reported (for `success`, the ones the run finished).
 * @property error Why it ended with `error`: an error code from the page, or one of the SDK's own
 *   in [LinkError.Companion].
 */
public data class LinkResult @JvmOverloads constructor(
    public val status: Status,
    public val action: String,
    public val sessionId: String? = null,
    public val devices: List<Device> = emptyList(),
    public val error: LinkError? = null,
) {
    public enum class Status(public val value: String) {
        SUCCESS("success"),
        CANCELLED("cancelled"),
        ERROR("error");

        public companion object {
            @JvmStatic
            public fun fromValue(value: String?): Status? = entries.firstOrNull { it.value == value }
        }
    }
}

/**
 * A device a run finished.
 *
 * @property type An open string: `"charger"` today. Ignore types you don't know.
 * @property id The device's Plugchoice id.
 */
public data class Device(
    public val type: String,
    public val id: String,
) {
    public companion object {
        public const val TYPE_CHARGER: String = "charger"
    }
}

/** Why a run ended with `error`; [message] is free text for logs. */
public data class LinkError @JvmOverloads constructor(
    public val code: String,
    public val message: String? = null,
) {
    public companion object {
        /**
         * The app's `fetchClientSecret` failed, returned an empty string or took longer than 30 s,
         * so the page could not start. Only the page reports it (when the user leaves its error
         * screen); the SDK never sets it itself.
         */
        public const val CLIENT_SECRET_UNAVAILABLE: String = "clientSecretUnavailable"

        /** The page didn't load (no internet, server unreachable) and the user left the "Try again" screen. */
        public const val PAGE_LOAD_FAILED: String = "pageLoadFailed"

        /** The SDK couldn't run the page (no or outdated Android System WebView, renderer gone). */
        public const val INTERNAL: String = "internal"
    }
}
