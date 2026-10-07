package com.plugchoice.internal

import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException

/**
 * `http.request` and `ws.open` with a `trust` object (PROTOCOL.md §9.8): OkHttp with the
 * [TrustEvaluator] as its only trust ([trusting]), against a local HTTPS server.
 */
class OkHttpTrustTest {
    private val server = LocalTlsServer("test-leaf-local")
    private val deviceCa = listOf(TestCertificates.certificate("test-local-ca"))

    @After
    fun tearDown() = server.close()

    private fun get(host: String, trust: Trust): Pair<Int?, TrustEvaluator> {
        server.responses += "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        val evaluator = TrustEvaluator(trust, host)
        val client = OkHttpClient.Builder().trusting(evaluator).build()
        val code = try {
            client.newCall(Request.Builder().url("https://$host:${server.port}/api").build()).execute().use { it.code }
        } catch (_: IOException) {
            null
        }
        return code to evaluator
    }

    @Test
    fun `the page's anchor and the certificate's IP address`() {
        val (code, evaluator) = get("127.0.0.1", Trust(deviceCa, emptySet(), ignoreExpiry = false, ignoreHostname = false))
        assertEquals(200, code)
        assertFalse(evaluator.rejected)
    }

    @Test
    fun `another name fails unless ignoreHostname`() {
        val (refused, evaluator) = get("localhost", Trust(deviceCa, emptySet(), ignoreExpiry = false, ignoreHostname = false))
        assertEquals(null, refused)
        assertTrue(evaluator.rejected)
        assertEquals(ErrorCode.TLS, evaluator.tlsError().code)
        val (code, _) = get("localhost", Trust(deviceCa, emptySet(), ignoreExpiry = false, ignoreHostname = true))
        assertEquals(200, code)
    }

    @Test
    fun `another CA fails with the presented fingerprint`() {
        val (code, evaluator) = get("127.0.0.1", Trust(listOf(TestCertificates.certificate("test-ca")), emptySet(), ignoreExpiry = true, ignoreHostname = true))
        assertEquals(null, code)
        assertEquals(
            Trust.fingerprint(TestCertificates.certificate("test-leaf-local")),
            evaluator.tlsError().details!!.getString("presentedFingerprint"),
        )
    }

    @Test
    fun `a pinned key`() {
        val fingerprint = Trust.fingerprint(TestCertificates.certificate("test-leaf-local"))
        val (code, _) = get("127.0.0.1", Trust(emptyList(), setOf(fingerprint), ignoreExpiry = false, ignoreHostname = false))
        assertEquals(200, code)
        try {
            Trust(emptyList(), emptySet(), ignoreExpiry = false, ignoreHostname = false)
            fail("a trust without anchors or fingerprints")
        } catch (_: IllegalArgumentException) {
        }
    }
}
