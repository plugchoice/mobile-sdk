package com.plugchoice.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The checks every call shares (PROTOCOL.md §4, §9.1): host rules, URLs, headers, string maps and
 * timeouts. The same cases as iOS's RequestParamsTests.
 */
class ParamsTest {

    private fun assertCode(code: String, message: String = "", body: () -> Unit) {
        try {
            body()
            fail("expected $code $message")
        } catch (e: BridgeException) {
            assertEquals(message, code, e.code)
        }
    }

    private fun json(vararg pairs: Pair<String, Any?>) = JSONObject().apply { for ((key, value) in pairs) put(key, value) }

    // Host rules

    @Test
    fun `local hosts are allowed`() {
        for (host in listOf(
            "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.50.10", "169.254.1.1", "127.0.0.1", "localhost", "localhost.",
            "charger.local", "CHARGER.local", "charger.local.", "ng910-60623-ace0870096.local", "a_b.local", "::1", "[::1]",
        )) {
            assertTrue(host, HostAllowList.isAllowed(host))
        }
    }

    @Test
    fun `everything else is refused`() {
        for (host in listOf(
            "8.8.8.8", "172.32.0.1", "example.com", "plugchoice.com", "192.168.1", "010.0.0.1", "10.0.0.01", "167772161",
            "192.168.1.10:443", "", "fe80::1", "fe80::1%en0", ".local", "a..local", "char ger.local", "charger%2elocal", "10.0.0.1.",
        )) {
            assertFalse(host, HostAllowList.isAllowed(host))
        }
    }

    // URLs

    @Test
    fun `urls`() {
        assertEquals("192.168.1.10", HostAllowList.checkedUrl("http://192.168.1.10/api", HostAllowList.HTTP_SCHEMES).host)
        assertEquals(8443, HostAllowList.checkedUrl("HTTPS://charger.local:8443/x", HostAllowList.HTTP_SCHEMES).port)
        val socket = HostAllowList.checkedUrl("wss://charger.local/ws", HostAllowList.WEB_SOCKET_SCHEMES)
        assertTrue("read as https", socket.isHttps)
        assertEquals("charger.local", socket.host)
        for (url in listOf("ftp://192.168.1.10/", "ws://10.0.0.2/", "http://8.8.8.8/", "http://%31%30.0.0.1/", "http://010.0.0.1/")) {
            assertCode(ErrorCode.FORBIDDEN_HOST, url) { HostAllowList.checkedUrl(url, HostAllowList.HTTP_SCHEMES) }
        }
        assertCode(ErrorCode.FORBIDDEN_HOST) { HostAllowList.checkedUrl("http://10.0.0.2/", HostAllowList.WEB_SOCKET_SCHEMES) }
        for (url in listOf("not a url", "/relative", "//10.0.0.2/")) {
            assertCode(ErrorCode.INVALID_PARAMS, url) { HostAllowList.checkedUrl(url, HostAllowList.HTTP_SCHEMES) }
        }
    }

    // Headers and string maps

    @Test
    fun `headers are tokens with visible ASCII values`() {
        assertEquals(
            mapOf("Cookie" to "a=1; b=2", "X-Tab" to "a\tb"),
            json("headers" to json("Cookie" to "a=1; b=2", "X-Tab" to "a\tb")).optHeaders(),
        )
        assertEquals(emptyMap<String, String>(), json().optHeaders())
        for (bad in listOf(
            json("Bad Name" to "x"),
            json("" to "x"),
            json("X-Evil" to "a\r\nHost: elsewhere"),
            json("X-Accent" to "café"),
            json("X-Control" to "a\u0001"),
            json("Accept" to 1),
            json("Accept" to true),
        )) {
            assertCode(ErrorCode.INVALID_PARAMS, bad.toString()) { json("headers" to bad).optHeaders() }
        }
    }

    @Test
    fun `string maps hold strings only`() {
        assertCode(ErrorCode.INVALID_PARAMS) { json("m" to json("a" to 1)).optStringMap("m") }
        assertCode(ErrorCode.INVALID_PARAMS) { json("m" to "x").optStringMap("m") }
    }

    // Timeouts

    @Test
    fun `timeouts are positive and rounded up`() {
        assertEquals(1L, json("t" to 0.5).requireTimeoutMs("t"))
        assertEquals(2_501L, json("t" to 2_500.2).requireTimeoutMs("t"))
        assertEquals(Int.MAX_VALUE.toLong(), json("t" to 1e300).requireTimeoutMs("t"))
        for (bad in listOf(0, -1, "1000", true)) {
            assertCode(ErrorCode.INVALID_PARAMS, "$bad") { json("t" to bad).requireTimeoutMs("t") }
        }
        assertCode(ErrorCode.INVALID_PARAMS) { json().requireTimeoutMs("t") }
    }

    // Strings

    @Test
    fun `ids are non-empty strings`() {
        assertCode(ErrorCode.INVALID_PARAMS) { json("requestId" to "").requireString("requestId") }
        assertCode(ErrorCode.INVALID_PARAMS) { json("requestId" to 1).requireString("requestId") }
        assertEquals("", json("password" to "").requireString("password", allowEmpty = true))
    }
}
