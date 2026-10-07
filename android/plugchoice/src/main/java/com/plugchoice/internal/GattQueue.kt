package com.plugchoice.internal

import org.json.JSONObject

/**
 * One device's GATT operations, one at a time in the order received (Android allows a single
 * outstanding GATT operation per connection), each with [timeoutMs] (PROTOCOL.md §11: the shell's
 * 10 s operation timeout, then `timeout` and [onTimeout], after which the next one starts).
 *
 * An operation's `start` issues the GATT call: it returns null to wait for [complete] with its
 * key, returns a result to finish at once, or throws a [BridgeException]. A completion for another
 * key (a late callback of an operation that timed out) is ignored.
 *
 * Main thread only (the scheduler's thread in tests).
 */
internal class GattQueue(
    private val scheduler: Scheduler,
    private val timeoutMs: Long = OPERATION_TIMEOUT_MS,
) {
    private class Operation(
        val key: String,
        val start: () -> Result<JSONObject>?,
        val callback: (Result<JSONObject>) -> Unit,
    ) {
        var timer: Cancellable? = null
    }

    private val waiting = ArrayDeque<Operation>()
    private var current: Operation? = null

    /**
     * After an operation timed out (and answered `timeout`): the connection disconnects, since the
     * device may still answer, out of step ([failAll] then leaves nothing to start).
     */
    var onTimeout: (() -> Unit)? = null

    /** The key of the running operation, if any. */
    val runningKey: String?
        get() = current?.key

    val size: Int
        get() = waiting.size + (if (current != null) 1 else 0)

    fun enqueue(key: String, start: () -> Result<JSONObject>?, callback: (Result<JSONObject>) -> Unit) {
        waiting.addLast(Operation(key, start, callback))
        next()
    }

    /** The running operation [key] finished. Returns false when it isn't the one running. */
    fun complete(key: String, result: Result<JSONObject>): Boolean {
        val operation = current?.takeIf { it.key == key } ?: return false
        finish(operation, result)
        return true
    }

    /** Ends everything, running and waiting, with [error]. */
    fun failAll(error: BridgeException) {
        val all = listOfNotNull(current) + waiting
        current?.timer?.cancel()
        current = null
        waiting.clear()
        for (operation in all) operation.callback(Result.failure(error))
    }

    private fun next() {
        if (current != null) return
        val operation = waiting.removeFirstOrNull() ?: return
        current = operation
        operation.timer = scheduler.schedule(timeoutMs) { timedOut(operation) }
        val immediate = try {
            operation.start()
        } catch (e: BridgeException) {
            Result.failure(e)
        }
        if (immediate != null) finish(operation, immediate)
    }

    private fun timedOut(operation: Operation) {
        if (current !== operation) return
        current = null
        operation.callback(Result.failure(BridgeException(ErrorCode.TIMEOUT, "${operation.key}: no answer from the device within $timeoutMs ms")))
        onTimeout?.invoke()
        next()
    }

    private fun finish(operation: Operation, result: Result<JSONObject>) {
        if (current !== operation) return
        operation.timer?.cancel()
        current = null
        operation.callback(result)
        next()
    }

    companion object {
        const val OPERATION_TIMEOUT_MS = 10_000L
    }
}
