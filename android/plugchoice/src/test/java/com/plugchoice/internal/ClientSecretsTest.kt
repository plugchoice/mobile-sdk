package com.plugchoice.internal

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** `auth.clientSecret` (PROTOCOL.md §7): the prefetch, refreshes, failures and the 30 s timeout. */
@OptIn(ExperimentalCoroutinesApi::class) // the virtual clock
class ClientSecretsTest {

    private suspend fun ClientSecrets.failure(): BridgeException {
        try {
            val secret = next()
            fail("answered $secret")
        } catch (e: BridgeException) {
            assertEquals(ErrorCode.CLIENT_SECRET_UNAVAILABLE, e.code)
            return e
        }
        error("unreachable")
    }

    private fun TestScope.counting(vararg answers: String, delayMs: Long = 0): Pair<ClientSecrets, () -> Int> {
        var calls = 0
        val secrets = ClientSecrets(this, {
            if (delayMs > 0) delay(delayMs)
            answers[calls++.coerceAtMost(answers.size - 1)]
        })
        return secrets to { calls }
    }

    @Test
    fun `the first call gets the secret fetched when the screen opened`() = runTest {
        val (secrets, calls) = counting("cs_first", "cs_second")
        secrets.prefetch()
        runCurrent()
        assertEquals("fetched before the page asked", 1, calls())
        assertEquals("cs_first", secrets.next())
        assertEquals(1, calls())
    }

    @Test
    fun `every later call runs the callback again`() = runTest {
        val (secrets, calls) = counting("cs_1", "cs_2", "cs_3")
        secrets.prefetch()
        assertEquals("cs_1", secrets.next())
        assertEquals("cs_2", secrets.next())
        assertEquals("cs_3", secrets.next())
        assertEquals(3, calls())
    }

    @Test
    fun `prefetch runs once`() = runTest {
        val (secrets, calls) = counting("cs_1", "cs_2")
        secrets.prefetch()
        secrets.prefetch()
        runCurrent()
        assertEquals(1, calls())
    }

    @Test
    fun `the first call waits for a fetch still running`() = runTest {
        val (secrets, calls) = counting("cs_slow", delayMs = 5_000)
        secrets.prefetch()
        advanceTimeBy(2_000)
        val answer = async { secrets.next() }
        runCurrent()
        assertFalse(answer.isCompleted)
        advanceTimeBy(3_001)
        assertEquals("cs_slow", answer.await())
        assertEquals(1, calls())
    }

    @Test
    fun `without a prefetch the first call fetches`() = runTest {
        val (secrets, calls) = counting("cs_1")
        assertEquals("cs_1", secrets.next())
        assertEquals(1, calls())
    }

    @Test
    fun `a throwing callback is clientSecretUnavailable, and Try again fetches again`() = runTest {
        var calls = 0
        val secrets = ClientSecrets(this, {
            calls++
            if (calls == 1) throw IllegalStateException("backend said no: cs_should_not_leak")
            "cs_ok"
        })
        secrets.prefetch()
        val error = secrets.failure()
        assertFalse("never the callback's message", error.message!!.contains("cs_should_not_leak"))
        assertEquals("cs_ok", secrets.next())
        assertEquals(2, calls)
    }

    @Test
    fun `an empty secret is clientSecretUnavailable`() = runTest {
        for (empty in listOf("", "  ")) {
            val secrets = ClientSecrets(this, { empty })
            secrets.failure()
        }
    }

    @Test
    fun `a callback that cancels itself is clientSecretUnavailable`() = runTest {
        val secrets = ClientSecrets(this, { throw CancellationException("the host's call was cancelled") })
        secrets.failure()
    }

    @Test
    fun `a callback slower than 30 s is clientSecretUnavailable`() = runTest {
        val secrets = ClientSecrets(this, {
            delay(31_000)
            "cs_late"
        })
        val started = testScheduler.currentTime
        val error = secrets.failure()
        assertEquals(30_000L, testScheduler.currentTime - started)
        assertTrue(error.message!!.contains("30000"))
    }

    @Test
    fun `the prefetch's 30 s count from when the screen opened`() = runTest {
        val (secrets, _) = counting("cs_late", delayMs = 60_000)
        secrets.prefetch()
        advanceTimeBy(25_000)
        val started = testScheduler.currentTime
        secrets.failure()
        assertEquals(5_000L, testScheduler.currentTime - started)
    }

    @Test
    fun `a failed prefetch answers the first call, then the callback runs again`() = runTest {
        var calls = 0
        val secrets = ClientSecrets(this, {
            calls++
            if (calls == 1) "" else "cs_2"
        })
        secrets.prefetch()
        secrets.failure()
        assertEquals("cs_2", secrets.next())
    }
}
