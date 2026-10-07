package com.plugchoice.internal

import com.plugchoice.LinkAction
import com.plugchoice.Plugchoice
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * The registry behind open screens (PROTOCOL.md §2, §7): the callback gets the action the
 * screen was opened with, for the prefetch and every refresh, and nothing is kept after release.
 */
class InstancesTest {

    @Test
    fun `the prefetch and every refresh pass the screen's action`() = runTest {
        val seen = mutableListOf<LinkAction>()
        val plugchoice = Plugchoice(fetchClientSecret = { action ->
            seen += action
            "cs_${action.name}_${action.chargerId}"
        })
        val action = LinkAction.network("42")
        val id = Instances.register(plugchoice, action)
        try {
            val secrets = ClientSecrets(this, Instances.clientSecretSource(id)!!)
            secrets.prefetch()
            assertEquals("cs_network_42", secrets.next())
            assertEquals("cs_network_42", secrets.next())
            assertEquals(2, seen.size)
            seen.forEach { assertSame("the very action launched", action, it) }
        } finally {
            Instances.release(id)
        }
    }

    @Test
    fun `each screen gets its own action from one instance`() = runTest {
        val plugchoice = Plugchoice(fetchClientSecret = { action -> "cs_${action.name}_${action.siteId ?: action.chargerId}" })
        val add = Instances.register(plugchoice, LinkAction.addCharger("site_1"))
        val reconnect = Instances.register(plugchoice, LinkAction.reconnect("7"))
        try {
            assertEquals("cs_add_site_1", Instances.clientSecretSource(add)!!())
            assertEquals("cs_reconnect_7", Instances.clientSecretSource(reconnect)!!())
        } finally {
            Instances.release(add)
            Instances.release(reconnect)
        }
    }

    @Test
    fun `a released or unknown screen has no source`() {
        val id = Instances.register(Plugchoice(fetchClientSecret = { "cs" }), LinkAction.addCharger())
        Instances.release(id)
        Instances.release(id)
        assertNull(Instances.clientSecretSource(id))
        assertNull(Instances.clientSecretSource("never-registered"))
        assertNull(Instances.clientSecretSource(null))
    }
}
