package com.plugchoice.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The `wifi.join` timeout: it stands still while the approval dialog has the focus. */
class PausableTimeoutTest {

    private lateinit var scheduler: FakeScheduler
    private lateinit var timeout: PausableTimeout
    private var fired = 0

    @Before
    fun setUp() {
        scheduler = FakeScheduler()
        fired = 0
        timeout = PausableTimeout(30_000, scheduler, now = { scheduler.now }, onTimeout = { fired++ })
    }

    @Test
    fun `fires after the budget while running`() {
        timeout.resume()
        scheduler.advanceBy(29_999)
        assertEquals(0, fired)
        scheduler.advanceBy(1)
        assertEquals(1, fired)
        assertFalse(timeout.isRunning)
    }

    @Test
    fun `time paused (approval dialog showing) does not count`() {
        timeout.resume()
        scheduler.advanceBy(2_000) // dialog appears after 2 s
        timeout.pause()
        scheduler.advanceBy(120_000) // user reads, network scan
        assertEquals(0, fired)

        timeout.resume() // dialog gone
        scheduler.advanceBy(27_999)
        assertEquals(0, fired)
        scheduler.advanceBy(1)
        assertEquals(1, fired)
    }

    @Test
    fun `several pauses add up`() {
        var firedAt = -1L
        timeout = PausableTimeout(30_000, scheduler, now = { scheduler.now }, onTimeout = { firedAt = scheduler.now })
        timeout.resume()
        repeat(3) {
            scheduler.advanceBy(10_000)
            timeout.pause()
            scheduler.advanceBy(50_000)
            timeout.resume()
        }
        // 30 s of running time, plus the two pauses that came before it ran out.
        assertEquals(30_000L + 2 * 50_000L, firedAt)
    }

    @Test
    fun `never started (focus already lost) does not fire until resumed`() {
        scheduler.advanceBy(100_000)
        assertEquals(0, fired)

        timeout.resume()
        assertTrue(timeout.isRunning)
        scheduler.advanceBy(30_000)
        assertEquals(1, fired)
    }

    @Test
    fun `pause and resume are idempotent`() {
        timeout.resume()
        timeout.resume()
        scheduler.advanceBy(10_000)
        timeout.pause()
        timeout.pause()
        timeout.resume()
        scheduler.advanceBy(20_000)
        assertEquals(1, fired)
        assertEquals(0, scheduler.pendingCount)
    }

    @Test
    fun `cancel stops it for good`() {
        timeout.resume()
        scheduler.advanceBy(10_000)
        timeout.cancel()
        timeout.resume()
        scheduler.advanceBy(100_000)
        assertEquals(0, fired)
    }

    @Test
    fun `fires once`() {
        timeout.resume()
        scheduler.advanceBy(30_000)
        timeout.resume()
        scheduler.advanceBy(30_000)
        assertEquals(1, fired)
    }
}
