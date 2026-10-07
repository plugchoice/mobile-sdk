package com.plugchoice.internal

/**
 * What happens when the user tries to leave natively (back, the native close button), PROTOCOL.md
 * §6.2.
 *
 * Before `hello` (still loading, a load error) the screen closes at once. After it, the page
 * decides: the shell sends `ui.closeRequested` and waits [timeoutMs] for `session.close` or
 * `ui.closeHandled` ([onPageAnswered]); if neither comes (a hung page), it closes anyway.
 *
 * Main thread only.
 */
internal class CloseRequests(
    private val scheduler: Scheduler,
    /** Sends the `ui.closeRequested` event to the page. */
    private val sendCloseRequested: () -> Unit,
    /** Closes the screen as `cancelled`. */
    private val close: () -> Unit,
    private val timeoutMs: Long = TIMEOUT_MS,
) {
    /** True after `hello` on the current document. */
    var pageHandlesClose: Boolean = false

    private var pending: Cancellable? = null

    /** Whether a `ui.closeRequested` is waiting for the page's answer. */
    val isWaitingForPage: Boolean
        get() = pending != null

    /** The user tried to leave natively. */
    fun request() {
        if (!pageHandlesClose) {
            close()
            return
        }
        // Already asked: pressing again doesn't extend the deadline (or flood the page).
        if (pending != null) return
        pending = scheduler.schedule(timeoutMs) {
            pending = null
            close()
        }
        sendCloseRequested()
    }

    /** `session.close` or `ui.closeHandled` arrived: the page is alive and owns closing. */
    fun onPageAnswered() {
        pending?.cancel()
        pending = null
    }

    fun dispose() {
        onPageAnswered()
    }

    companion object {
        const val TIMEOUT_MS = 1_000L
    }
}
