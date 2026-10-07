package com.plugchoice.reactnative

import com.plugchoice.LinkAction
import kotlinx.coroutines.CompletableDeferred
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * The client secrets the SDK asks JavaScript for: [request] is the SDK's `fetchClientSecret`. Each
 * request gets an id, goes out through [send] as `onClientSecretRequest { requestId, action }`, and
 * waits until JavaScript answers that id ([answer]), the SDK cancels it (its 30 s timeout, or the
 * screen closing), or the module goes away ([close]). A late or unknown answer is dropped.
 *
 * Thread-safe: the SDK asks on the main thread, JavaScript answers on its own. The secret only
 * passes through and is never logged.
 */
internal class ClientSecretRequests(private val send: (Map<String, Any?>) -> Unit) {
    private val waiting = ConcurrentHashMap<String, CompletableDeferred<String>>()

    @Volatile
    private var closed = false

    suspend fun request(action: LinkAction): String {
        val requestId = UUID.randomUUID().toString()
        val answer = CompletableDeferred<String>()
        waiting[requestId] = answer
        try {
            // After registering, so a concurrent close() either sees this request or is seen here.
            if (closed) throw ClientSecretRejected.moduleGone()
            send(mapOf("requestId" to requestId, "action" to action.toPayload()))
            return answer.await()
        } finally {
            waiting.remove(requestId)
        }
    }

    /** Ends the request [requestId], if it is still waiting. */
    fun answer(requestId: String, result: Result<String>) {
        val answer = waiting.remove(requestId) ?: return
        result.fold(answer::complete, answer::completeExceptionally)
    }

    /** Fails every waiting request, and every later one at once. */
    fun close() {
        closed = true
        for (requestId in waiting.keys.toList()) {
            answer(requestId, Result.failure(ClientSecretRejected.moduleGone()))
        }
    }

    companion object {
        const val EVENT = "onClientSecretRequest"
    }
}

/**
 * JavaScript couldn't give a secret: `fetchClientSecret` failed, or JavaScript is gone. The SDK
 * answers the page `clientSecretUnavailable` (and logs only this class's name).
 */
internal class ClientSecretRejected(message: String) : Exception(message) {
    companion object {
        fun moduleGone() = ClientSecretRejected("the React Native module is gone")
    }
}
