package com.plugchoice.internal

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** `lan.discover` and `lan.address` (PROTOCOL.md §9.4): params, `stopOnName`, results. */
class LanDiscoveryTest {

    private fun assertCode(code: String, body: () -> Unit) {
        try {
            body()
            fail("expected $code")
        } catch (e: BridgeException) {
            assertEquals(code, e.code)
        }
    }

    // lan.discover params

    private fun discover(vararg pairs: Pair<String, Any?>) = JSONObject().apply { for ((key, value) in pairs) put(key, value) }

    @Test
    fun `discover params`() {
        val request = LanDiscovery.parseRequest(discover("types" to JSONArray(listOf("_alfen._tcp", "_alfen._tcp")), "timeoutMs" to 8000, "stopOnName" to "ACE0870096"))
        assertEquals(listOf("_alfen._tcp"), request.types)
        assertEquals(8000L, request.timeoutMs)
        assertEquals("ACE0870096", request.stopOnName)
        assertNull(LanDiscovery.parseRequest(discover("types" to JSONArray(listOf("_alfen._tcp")), "timeoutMs" to 1)).stopOnName)
        assertNull("an empty stopOnName is none", LanDiscovery.parseRequest(discover("types" to JSONArray(listOf("_alfen._tcp")), "timeoutMs" to 1, "stopOnName" to "")).stopOnName)
        assertEquals("a fraction of a millisecond is rounded up", 2L, LanDiscovery.parseRequest(discover("types" to JSONArray(listOf("_alfen._tcp")), "timeoutMs" to 1.5)).timeoutMs)
    }

    @Test
    fun `discover rejects bad params`() {
        for (bad in listOf(
            discover("timeoutMs" to 8000),
            discover("types" to JSONArray(), "timeoutMs" to 8000),
            discover("types" to "_alfen._tcp", "timeoutMs" to 8000),
            discover("types" to JSONArray(listOf("_alfen._tcp", 1)), "timeoutMs" to 8000),
            discover("types" to JSONArray(listOf("_alfen._tcp"))),
            discover("types" to JSONArray(listOf("_alfen._tcp")), "timeoutMs" to 0),
            discover("types" to JSONArray(listOf("_alfen._tcp")), "timeoutMs" to "8000"),
            discover("types" to JSONArray(listOf("_alfen._tcp")), "timeoutMs" to 8000, "stopOnName" to 7),
        )) {
            assertCode(ErrorCode.INVALID_PARAMS) { LanDiscovery.parseRequest(bad) }
        }
    }

    @Test
    fun `discover takes any service type`() {
        val request = LanDiscovery.parseRequest(
            discover("types" to JSONArray(listOf("_alfen._tcp", "_http._tcp", "_https._tcp.", "_keba._udp", "_printer._sub._http._tcp", "_http._tcp")), "timeoutMs" to 8000),
        )
        assertEquals(listOf("_alfen._tcp", "_http._tcp", "_https._tcp", "_keba._udp", "_printer._sub._http._tcp"), request.types)
    }

    @Test
    fun `discover rejects what is not a service type`() {
        for (type in listOf("", "http", "_http", "_http._sctp", "_http._tcp.local.", "_ht tp._tcp", "http._tcp", "_http.._tcp", "_-x._tcp")) {
            assertCode(ErrorCode.INVALID_PARAMS) {
                LanDiscovery.parseRequest(discover("types" to JSONArray(listOf("_alfen._tcp", type)), "timeoutMs" to 8000))
            }
        }
    }

    // stopOnName

    @Test
    fun `stopOnName matches a lower-cased substring`() {
        assertTrue(DiscoveredServices.matches("ng910-60623-ace0870096", "ace0870096"))
        assertTrue(DiscoveredServices.matches("ng910-60623-ace0870096", "ACE0870096"))
        assertTrue(DiscoveredServices.matches("NG910-60623-ACE0870096", "60623-ace"))
        assertFalse(DiscoveredServices.matches("ng910-60623-ace0870096", "ace0870097"))
        assertFalse(DiscoveredServices.matches("ng910-60623-ace0870096", null))
    }

    @Test
    fun `stops only once the match has an IPv4 address`() {
        val services = DiscoveredServices("ACE0870096")
        services.found("ng910-60623-ace0870096", "_alfen._tcp")
        assertFalse(services.resolved("ng910-60623-ace0870096", "_alfen._tcp", emptyList(), 443, null))
        assertFalse(services.resolved("ng910-60623-ace0870096", "_alfen._tcp", listOf("fe80::1"), 443, null))
        assertFalse(services.resolved("ng910-11111-ace0000001", "_alfen._tcp", listOf("10.0.0.9"), 443, null))
        assertTrue(services.resolved("ng910-60623-ace0870096", "_alfen._tcp", listOf("10.206.2.88"), 443, null))
    }

    @Test
    fun `without stopOnName nothing stops`() {
        assertFalse(DiscoveredServices(null).resolved("ng910-60623-ace0870096", "_alfen._tcp", listOf("10.0.0.2"), 443, null))
    }

    @Test
    fun `services list everything found in order`() {
        val services = DiscoveredServices(null)
        services.found("b-unresolved", "_alfen._tcp")
        services.resolved("a", "_alfen._tcp", listOf("fe80::1", "10.0.0.2"), 443, mapOf("FWVersion" to "7.4.4"))
        services.resolved("a", "_alfen._tcp", listOf("10.0.0.2", "10.0.0.3"), 443, emptyMap())
        val list = services.toJson()
        assertEquals(2, list.length())
        val unresolved = list.getJSONObject(0)
        assertEquals("b-unresolved", unresolved.getString("name"))
        assertEquals(0, unresolved.getJSONArray("addresses").length())
        assertEquals(0, unresolved.getInt("port"))
        assertEquals(0, unresolved.getJSONObject("txt").length())
        val resolved = list.getJSONObject(1)
        assertEquals("IPv4 first, no duplicates", listOf("10.0.0.2", "10.0.0.3", "fe80::1"), resolved.getJSONArray("addresses").let { array -> List(array.length()) { array.getString(it) } })
        assertEquals("a resolve without TXT keeps the earlier one", "7.4.4", resolved.getJSONObject("txt").getString("FWVersion"))
    }

    @Test
    fun `addresses as text`() {
        assertEquals("192.168.1.10", DiscoveredServices.text(java.net.InetAddress.getByName("192.168.1.10")))
        val scoped = DiscoveredServices.text(java.net.Inet6Address.getByName("fe80::1%1"))!!
        assertFalse("no scope", '%' in scoped)
        assertEquals(java.net.InetAddress.getByName("fe80::1"), java.net.InetAddress.getByName(scoped))
    }

    // lan.address

    @Test
    fun `netmasks from prefix lengths`() {
        assertEquals("255.255.255.0", LanAddress.netmask(24))
        assertEquals("255.255.0.0", LanAddress.netmask(16))
        assertEquals("255.255.255.252", LanAddress.netmask(30))
        assertEquals("255.255.255.255", LanAddress.netmask(32))
        assertEquals("0.0.0.0", LanAddress.netmask(0))
    }
}
