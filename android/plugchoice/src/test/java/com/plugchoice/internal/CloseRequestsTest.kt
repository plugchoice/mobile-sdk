package com.plugchoice.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class CloseRequestsTest {

    private lateinit var scheduler: FakeScheduler
    private lateinit var closeRequests: CloseRequests
    private var events = 0
    private var closes = 0

    @Before
    fun setUp() {
        scheduler = FakeScheduler()
        events = 0
        closes = 0
        closeRequests = CloseRequests(scheduler, sendCloseRequested = { events++ }, close = { closes++ })
    }

    @Test
    fun `before hello the screen closes at once`() {
        closeRequests.request()

        assertEquals(0, events)
        assertEquals(1, closes)
        assertEquals(0, scheduler.pendingCount)
    }

    @Test
    fun `after hello the page is asked and gets 1 s`() {
        closeRequests.pageHandlesClose = true

        closeRequests.request()
        assertEquals(1, events)
        assertEquals(0, closes)
        assertTrue(closeRequests.isWaitingForPage)

        scheduler.advanceBy(999)
        assertEquals(0, closes)

        scheduler.advanceBy(1)
        assertEquals(1, closes)
        assertFalse(closeRequests.isWaitingForPage)
    }

    @Test
    fun `an answer within 1 s keeps the screen open`() {
        closeRequests.pageHandlesClose = true

        closeRequests.request()
        scheduler.advanceBy(400)
        closeRequests.onPageAnswered() // ui.closeHandled
        scheduler.advanceBy(10_000)

        assertEquals(0, closes)
        assertFalse(closeRequests.isWaitingForPage)
    }

    @Test
    fun `asking again after an answer starts a new 1 s`() {
        closeRequests.pageHandlesClose = true
        closeRequests.request()
        closeRequests.onPageAnswered()

        scheduler.advanceBy(5_000)
        closeRequests.request()
        assertEquals(2, events)

        scheduler.advanceBy(999)
        assertEquals(0, closes)
        scheduler.advanceBy(1)
        assertEquals(1, closes)
    }

    @Test
    fun `pressing again while waiting neither re-sends nor extends the deadline`() {
        closeRequests.pageHandlesClose = true

        closeRequests.request()
        scheduler.advanceBy(600)
        closeRequests.request()
        closeRequests.request()
        assertEquals(1, events)

        scheduler.advanceBy(400)
        assertEquals(1, closes)
    }

    @Test
    fun `a new document falls back to closing at once`() {
        closeRequests.pageHandlesClose = true
        closeRequests.pageHandlesClose = false // what onNewDocument does

        closeRequests.request()
        assertEquals(0, events)
        assertEquals(1, closes)
    }

    @Test
    fun `dispose cancels a waiting request`() {
        closeRequests.pageHandlesClose = true
        closeRequests.request()

        closeRequests.dispose()
        scheduler.advanceBy(10_000)

        assertEquals(0, closes)
    }

    @Test
    fun `the default timeout is 1 s`() {
        assertEquals(1_000L, CloseRequests.TIMEOUT_MS)
    }
}
