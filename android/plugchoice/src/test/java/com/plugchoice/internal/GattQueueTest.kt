package com.plugchoice.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** One GATT operation at a time, in order, each with the 10 s operation timeout (PROTOCOL.md §11). */
class GattQueueTest {
    private val scheduler = FakeScheduler()
    private val queue = GattQueue(scheduler)
    private val started = mutableListOf<String>()
    private val answers = mutableListOf<Pair<String, String>>()

    private fun enqueue(key: String, start: () -> Result<JSONObject>? = { null }) {
        queue.enqueue(key, {
            started += key
            start()
        }) { result -> answers += key to ((result.exceptionOrNull() as? BridgeException)?.code ?: "ok") }
    }

    private val ok = Result.success(JSONObject())

    @Test
    fun `one at a time, in order`() {
        enqueue("read a")
        enqueue("write b")
        enqueue("read c")
        assertEquals(listOf("read a"), started)
        assertEquals("read a", queue.runningKey)
        assertTrue(queue.complete("read a", ok))
        assertEquals(listOf("read a", "write b"), started)
        assertTrue(queue.complete("write b", ok))
        assertTrue(queue.complete("read c", ok))
        assertEquals(listOf("read a" to "ok", "write b" to "ok", "read c" to "ok"), answers)
        assertNull(queue.runningKey)
        assertEquals("no timers left", 0, scheduler.pendingCount)
    }

    @Test
    fun `an operation times out after 10 s and the next one starts`() {
        enqueue("read a")
        enqueue("read b")
        scheduler.advanceBy(9_999)
        assertTrue(answers.isEmpty())
        scheduler.advanceBy(1)
        assertEquals(listOf("read a" to ErrorCode.TIMEOUT), answers)
        assertEquals(listOf("read a", "read b"), started)
        assertFalse("a late answer for the timed-out operation is ignored", queue.complete("read a", ok))
        assertEquals("read b", queue.runningKey)
        assertTrue(queue.complete("read b", ok))
    }

    @Test
    fun `onTimeout runs after the timed-out operation answered`() {
        val order = mutableListOf<String>()
        queue.onTimeout = {
            order += "onTimeout after ${answers.size} answer"
            queue.failAll(BridgeException(ErrorCode.NOT_CONNECTED, "gone"))
        }
        enqueue("read a")
        enqueue("read b")
        scheduler.advanceBy(10_000)
        assertEquals(listOf("onTimeout after 1 answer"), order)
        assertEquals(listOf("read a" to ErrorCode.TIMEOUT, "read b" to ErrorCode.NOT_CONNECTED), answers)
        assertEquals("nothing starts after the failAll", listOf("read a"), started)
    }

    @Test
    fun `each operation gets its own 10 s`() {
        enqueue("read a")
        enqueue("read b")
        scheduler.advanceBy(9_000)
        queue.complete("read a", ok)
        scheduler.advanceBy(9_000)
        assertEquals(listOf("read a" to "ok"), answers)
        scheduler.advanceBy(1_000)
        assertEquals(listOf("read a" to "ok", "read b" to ErrorCode.TIMEOUT), answers)
    }

    @Test
    fun `a start that fails or finishes at once moves on`() {
        enqueue("write a") { throw BridgeException(ErrorCode.GATT, "busy") }
        enqueue("cccd b") { ok }
        enqueue("read c")
        assertEquals(listOf("write a" to ErrorCode.GATT, "cccd b" to "ok"), answers)
        assertEquals("read c", queue.runningKey)
        assertEquals("only the waiting operation's timer", 1, scheduler.pendingCount)
    }

    @Test
    fun `a completion for another key is ignored`() {
        enqueue("read a")
        assertFalse(queue.complete("read b", ok))
        assertTrue(answers.isEmpty())
    }

    @Test
    fun `failAll answers the running and the waiting`() {
        enqueue("read a")
        enqueue("read b")
        queue.failAll(BridgeException(ErrorCode.NOT_CONNECTED, "gone"))
        assertEquals(listOf("read a" to ErrorCode.NOT_CONNECTED, "read b" to ErrorCode.NOT_CONNECTED), answers)
        assertEquals(0, queue.size)
        assertEquals(0, scheduler.pendingCount)
        scheduler.advanceBy(20_000)
        assertEquals(2, answers.size)
    }

    @Test
    fun `an operation enqueued from an answer runs next`() {
        queue.enqueue("read a", { null }) { enqueue("read b") }
        queue.complete("read a", ok)
        assertEquals("read b", queue.runningKey)
    }
}
