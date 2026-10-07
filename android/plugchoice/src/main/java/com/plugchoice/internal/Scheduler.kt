package com.plugchoice.internal

import android.os.Handler

/** Runs an action later. Main-thread only in the shell; a fake clock in unit tests. */
internal fun interface Scheduler {
    fun schedule(delayMs: Long, action: () -> Unit): Cancellable
}

internal fun interface Cancellable {
    /** Idempotent; a no-op once the action ran. */
    fun cancel()
}

/** [Scheduler] on a [Handler] (the main looper in the shell). */
internal class HandlerScheduler(private val handler: Handler) : Scheduler {
    override fun schedule(delayMs: Long, action: () -> Unit): Cancellable {
        val runnable = Runnable(action)
        handler.postDelayed(runnable, delayMs)
        return Cancellable { handler.removeCallbacks(runnable) }
    }
}

/**
 * A timeout of [budgetMs] that only counts down while running: [pause] stops the clock and
 * [resume] restarts it with what is left. Fires [onTimeout] at most once. Not thread-safe; use it
 * from the scheduler's thread.
 */
internal class PausableTimeout(
    private val budgetMs: Long,
    private val scheduler: Scheduler,
    private val now: () -> Long,
    private val onTimeout: () -> Unit,
) {
    private var remainingMs = budgetMs
    private var runningSince = 0L
    private var pending: Cancellable? = null
    private var done = false

    val isRunning: Boolean
        get() = pending != null

    /** Starts (or restarts) the clock. No-op when already running, fired or cancelled. */
    fun resume() {
        if (done || pending != null) return
        runningSince = now()
        pending = scheduler.schedule(remainingMs) {
            pending = null
            done = true
            onTimeout()
        }
    }

    /** Stops the clock, keeping the time left. No-op when not running. */
    fun pause() {
        val running = pending ?: return
        running.cancel()
        pending = null
        remainingMs = (remainingMs - (now() - runningSince)).coerceAtLeast(0)
    }

    /** Never fires after this. */
    fun cancel() {
        done = true
        pending?.cancel()
        pending = null
    }
}
