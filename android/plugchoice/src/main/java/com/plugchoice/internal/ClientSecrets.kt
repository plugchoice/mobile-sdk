package com.plugchoice.internal

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout

/**
 * `auth.clientSecret` (PROTOCOL.md §7) over the host app's `fetchClientSecret`, bound to the
 * action the screen opened with ([Instances.clientSecretSource]).
 *
 * [prefetch] calls it once when the screen opens, in parallel with loading the page; the page's
 * first `auth.clientSecret` gets that answer (or waits for it), and every later one calls the
 * callback again (the page asks when its secret has expired).
 *
 * The secret is never logged, never put in an error message, and not kept after it was answered.
 * Main thread only (the callback runs in [scope]).
 */
internal class ClientSecrets(
    private val scope: CoroutineScope,
    private val fetch: suspend () -> String,
    private val timeoutMs: Long = TIMEOUT_MS,
) {
    private var prefetched: Deferred<Result<String>>? = null

    /** Starts the first fetch, once. */
    fun prefetch() {
        if (prefetched == null) prefetched = scope.async { fetchOnce() }
    }

    /** The prefetched secret the first time, then a new fetch. Throws `clientSecretUnavailable`. */
    suspend fun next(): String {
        val first = prefetched
        prefetched = null
        return (first?.await() ?: fetchOnce()).getOrThrow()
    }

    private suspend fun fetchOnce(): Result<String> = try {
        val secret = withTimeout(timeoutMs) { fetch() }
        if (secret.isBlank()) unavailable("fetchClientSecret returned an empty client secret") else Result.success(secret)
    } catch (_: TimeoutCancellationException) {
        unavailable("fetchClientSecret did not answer within $timeoutMs ms")
    } catch (e: CancellationException) {
        // The screen is closing: nobody to answer. Otherwise the callback cancelled itself.
        currentCoroutineContext().ensureActive()
        unavailable("fetchClientSecret was cancelled")
    } catch (e: Throwable) {
        // The class only: a message could carry anything the host's networking put in it.
        unavailable("fetchClientSecret threw ${e.javaClass.name}")
    }

    private fun unavailable(message: String): Result<String> =
        Result.failure(BridgeException(ErrorCode.CLIENT_SECRET_UNAVAILABLE, message))

    companion object {
        const val TIMEOUT_MS = 30_000L
    }
}
