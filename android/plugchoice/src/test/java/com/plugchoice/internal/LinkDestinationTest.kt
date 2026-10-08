package com.plugchoice.internal

import com.plugchoice.LinkAction
import com.plugchoice.Plugchoice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Opening the screen (PROTOCOL.md §2): the URL, its fragment, the one origin and the debug override. */
class LinkDestinationTest {

    private fun resolve(action: LinkAction, override: String? = null, allowed: Boolean = true, ignored: MutableList<String> = mutableListOf()) =
        LinkDestination.resolve(action, override, allowed) { ignored += it }

    @Test
    fun `the URL carries the action and ids in the fragment`() {
        assertEquals("https://connect.plugchoice.com/#action=add", resolve(LinkAction.addCharger()).url)
        assertEquals("https://connect.plugchoice.com/#action=add&site_id=site_1", resolve(LinkAction.addCharger("site_1")).url)
        assertEquals("https://connect.plugchoice.com/#action=setup&charger_id=42", resolve(LinkAction.setup("42")).url)
        assertEquals("https://connect.plugchoice.com/#action=reconnect&charger_id=42", resolve(LinkAction.reconnect("42")).url)
        assertEquals(
            "https://connect.plugchoice.com/#action=later&charger_id=7&site_id=3",
            resolve(LinkAction.custom("later", chargerId = "7", siteId = "3")).url,
        )
    }

    @Test
    fun `values are percent-encoded`() {
        assertEquals("a%20b%26c%3Dd%23e%2Ff%3Fg%25h", LinkDestination.percentEncode("a b&c=d#e/f?g%h"))
        assertEquals("AZaz09-._~", LinkDestination.percentEncode("AZaz09-._~"))
        assertEquals("%C3%A9%E2%82%AC", LinkDestination.percentEncode("é€"))
        assertEquals("%2B", LinkDestination.percentEncode("+"))
        assertEquals(
            "https://connect.plugchoice.com/#action=x%26site_id%3Devil&charger_id=1%232",
            resolve(LinkAction.custom("x&site_id=evil", chargerId = "1#2")).url,
        )
    }

    @Test
    fun `empty ids are left out`() {
        assertEquals("action=add", LinkDestination.fragment(LinkAction.addCharger("")))
        assertNull(LinkAction.custom("reconnect", chargerId = "").chargerId)
    }

    @Test
    fun `a blank custom action is refused`() {
        for (blank in listOf("", " ")) {
            try {
                LinkAction.custom(blank)
                fail("accepted \"$blank\"")
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    @Test
    fun `actions compare by value`() {
        assertEquals(LinkAction.reconnect("42"), LinkAction.custom("reconnect", "42"))
        assertEquals(LinkAction.reconnect("42").hashCode(), LinkAction.custom("reconnect", "42").hashCode())
        assertEquals("add", LinkAction.addCharger().name)
    }

    @Test
    fun `without an override the connect origin is the only one`() {
        val destination = resolve(LinkAction.addCharger())
        assertEquals(Plugchoice.ORIGIN, destination.origin)
        assertEquals("https://connect.plugchoice.com", destination.origin)
    }

    @Test
    fun `the override replaces scheme, host and port in debug builds`() {
        val ignored = mutableListOf<String>()
        val destination = resolve(LinkAction.reconnect("42"), "http://192.168.1.20:5173", ignored = ignored)
        assertEquals("http://192.168.1.20:5173/#action=reconnect&charger_id=42", destination.url)
        assertEquals("http://192.168.1.20:5173", destination.origin)
        assertTrue(ignored.isEmpty())
    }

    @Test
    fun `the override is ignored unless the host app is debuggable`() {
        val ignored = mutableListOf<String>()
        val destination = resolve(LinkAction.addCharger(), "http://192.168.1.20:5173", allowed = false, ignored = ignored)
        assertEquals("https://connect.plugchoice.com/#action=add", destination.url)
        assertEquals(Plugchoice.ORIGIN, destination.origin)
        assertEquals(1, ignored.size)
    }

    @Test
    fun `a blank override is no override`() {
        val ignored = mutableListOf<String>()
        assertEquals(Plugchoice.ORIGIN, resolve(LinkAction.addCharger(), " ", ignored = ignored).origin)
        assertTrue(ignored.isEmpty())
    }

    @Test
    fun `an invalid override is ignored`() {
        val invalid = listOf(
            "192.168.1.20:5173", // no scheme
            "ftp://192.168.1.20",
            "http://192.168.1.20:5173/s/other",
            "http://192.168.1.20:5173?x=1",
            "http://192.168.1.20:5173#x",
            "http://user@192.168.1.20:5173",
            "http://",
            "not a url",
        )
        for (override in invalid) {
            val ignored = mutableListOf<String>()
            val destination = resolve(LinkAction.addCharger(), override, ignored = ignored)
            assertEquals(override, Plugchoice.ORIGIN, destination.origin)
            assertEquals(override, "https://connect.plugchoice.com/#action=add", destination.url)
            assertEquals(override, 1, ignored.size)
        }
    }

    @Test
    fun `override origins are normalised`() {
        assertEquals("http://192.168.1.20:5173", LinkDestination.parseOrigin("http://192.168.1.20:5173/"))
        assertEquals("https://dev.example", LinkDestination.parseOrigin("HTTPS://Dev.Example:443"))
        assertEquals("http://10.0.2.2", LinkDestination.parseOrigin("http://10.0.2.2:80"))
        assertEquals("http://mac.local:4173", LinkDestination.parseOrigin(" http://mac.local:4173 "))
    }
}
