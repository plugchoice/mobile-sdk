package com.plugchoice.internal

/** A [Scheduler] on a virtual clock: nothing runs until [advanceBy]. */
internal class FakeScheduler : Scheduler {
    var now: Long = 0
        private set

    private class Task(val at: Long, val order: Int, val action: () -> Unit)

    private val tasks = mutableListOf<Task>()
    private var nextOrder = 0

    val pendingCount: Int
        get() = tasks.size

    override fun schedule(delayMs: Long, action: () -> Unit): Cancellable {
        val task = Task(now + delayMs, nextOrder++, action)
        tasks += task
        return Cancellable { tasks.remove(task) }
    }

    /** Moves the clock forward, running what falls due in order (including tasks scheduled meanwhile). */
    fun advanceBy(ms: Long) {
        val target = now + ms
        while (true) {
            val next = tasks.filter { it.at <= target }.minWithOrNull(compareBy({ it.at }, { it.order })) ?: break
            tasks.remove(next)
            now = next.at
            next.action()
        }
        now = target
    }
}
