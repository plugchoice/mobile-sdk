package com.plugchoice.internal

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.time.Instant
import java.util.Base64

/**
 * Trust objects (PROTOCOL.md §9.8): anchors, fingerprints, `ignoreExpiry`, `ignoreHostname`, the
 * presented fingerprint, and the params.
 */
class TrustTest {

    private val expiredLeaf = TestCertificates.certificate("test-leaf-expired")
    private val chargerCa = TestCertificates.certificate("test-ca")
    private val selfSigned = TestCertificates.certificate("test-self-signed")
    private val deviceCa = TestCertificates.certificate("test-local-ca")
    private val intermediate = TestCertificates.certificate("test-intermediate")
    private val localLeaf = TestCertificates.certificate("test-leaf-local")
    private val chainedLeaf = TestCertificates.certificate("test-leaf-chained")

    private fun trust(
        anchors: List<X509Certificate> = emptyList(),
        fingerprints: Set<String> = emptySet(),
        ignoreExpiry: Boolean = false,
        ignoreHostname: Boolean = false,
    ) = Trust(anchors, fingerprints, ignoreExpiry, ignoreHostname)

    private fun assertRejected(trust: Trust, host: String?, vararg chain: X509Certificate) {
        try {
            trust.check(arrayOf(*chain), host)
            fail("accepted ${chain.map { it.subjectX500Principal }} for $host")
        } catch (_: CertificateException) {
        }
    }

    private fun spki(certificate: X509Certificate): String =
        "sha256/" + Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(certificate.publicKey.encoded))

    // A charger maker's CA

    @Test
    fun `a CA without date or host checks accepts an expired leaf for another host`() {
        assertTrue(expiredLeaf.notAfter.toInstant() < Instant.now())
        val trust = TestCertificates.chargerCaTrust()
        trust.check(arrayOf(expiredLeaf), "192.168.1.10")
        trust.check(arrayOf(expiredLeaf, chargerCa), "192.168.1.10") // with the CA sent along
    }

    @Test
    fun `only the anchors count`() {
        // A leaf from another CA fails, even with its CA sent along.
        val otherCa = trust(anchors = listOf(deviceCa), ignoreExpiry = true, ignoreHostname = true)
        assertRejected(otherCa, null, expiredLeaf, chargerCa)
        assertRejected(otherCa, null, expiredLeaf)
        assertRejected(TestCertificates.chargerCaTrust(), null, selfSigned)
        // Unrelated extra certificates don't help.
        assertRejected(TestCertificates.chargerCaTrust(), null, selfSigned, expiredLeaf)
        assertRejected(TestCertificates.chargerCaTrust(), null)
    }

    // Anchors

    @Test
    fun `a leaf from an anchor verifies, with its name`() {
        val trust = trust(anchors = listOf(deviceCa))
        trust.check(arrayOf(localLeaf), "127.0.0.1")
        trust.check(arrayOf(localLeaf), "charger.local")
        trust.check(arrayOf(localLeaf), "CHARGER.local")
    }

    @Test
    fun `a chain through an intermediate the device sends verifies`() {
        val trust = trust(anchors = listOf(deviceCa))
        trust.check(arrayOf(chainedLeaf, intermediate), "charger.local")
        // Without the intermediate there is no path.
        assertRejected(trust, "charger.local", chainedLeaf)
        // The intermediate as an anchor itself is enough.
        trust(anchors = listOf(intermediate)).check(arrayOf(chainedLeaf), "charger.local")
    }

    @Test
    fun `any of several anchors`() {
        val trust = trust(anchors = listOf(chargerCa, deviceCa), ignoreExpiry = true, ignoreHostname = true)
        trust.check(arrayOf(localLeaf), null)
        trust.check(arrayOf(expiredLeaf), null)
    }

    @Test
    fun `a self-signed certificate given as an anchor verifies`() {
        trust(anchors = listOf(selfSigned), ignoreHostname = true).check(arrayOf(selfSigned), "10.0.0.2")
    }

    @Test
    fun `the host name is matched unless ignoreHostname`() {
        val strict = trust(anchors = listOf(deviceCa))
        assertRejected(strict, "10.0.0.2", localLeaf)
        assertRejected(strict, "other.local", localLeaf)
        trust(anchors = listOf(deviceCa), ignoreHostname = true).check(arrayOf(localLeaf), "10.0.0.2")
    }

    @Test
    fun `an expired leaf fails unless ignoreExpiry`() {
        assertRejected(trust(anchors = listOf(chargerCa), ignoreHostname = true), "not-this-host.example", expiredLeaf)
        trust(anchors = listOf(chargerCa), ignoreExpiry = true).check(arrayOf(expiredLeaf), "not-this-host.example")
        // ignoreExpiry alone still matches the name.
        assertRejected(trust(anchors = listOf(chargerCa), ignoreExpiry = true), "10.0.0.2", expiredLeaf)
    }

    // Fingerprints

    @Test
    fun `a pinned key is trusted without a chain`() {
        val pinned = trust(fingerprints = setOf(spki(selfSigned)), ignoreHostname = true)
        pinned.check(arrayOf(selfSigned), "10.0.0.2")
        assertRejected(pinned, "10.0.0.2", localLeaf)
        // A pinned leaf for this host passes the name check too.
        trust(fingerprints = setOf(spki(localLeaf))).check(arrayOf(localLeaf), "127.0.0.1")
        assertRejected(trust(fingerprints = setOf(spki(localLeaf))), "10.0.0.2", localLeaf)
    }

    @Test
    fun `a pinned expired leaf fails unless ignoreExpiry`() {
        assertRejected(trust(fingerprints = setOf(spki(expiredLeaf)), ignoreHostname = true), null, expiredLeaf)
        trust(fingerprints = setOf(spki(expiredLeaf)), ignoreExpiry = true, ignoreHostname = true).check(arrayOf(expiredLeaf), null)
    }

    @Test
    fun `anchors or fingerprints`() {
        val either = trust(anchors = listOf(deviceCa), fingerprints = setOf(spki(selfSigned)), ignoreHostname = true)
        either.check(arrayOf(localLeaf), "10.0.0.2")
        either.check(arrayOf(selfSigned), "10.0.0.2")
        assertRejected(either, "10.0.0.2", expiredLeaf)
    }

    @Test
    fun `the fingerprint is the base64 SHA-256 of the SubjectPublicKeyInfo`() {
        assertEquals(spki(localLeaf), Trust.fingerprint(localLeaf))
        assertTrue(Trust.fingerprint(localLeaf).matches(Regex("sha256/[A-Za-z0-9+/]{43}=")))
    }

    // The evaluator

    @Test
    fun `the evaluator remembers the presented leaf and a refusal`() {
        val evaluator = TrustEvaluator(trust(anchors = listOf(deviceCa)), "charger.local")
        evaluator.checkServerTrusted(arrayOf(localLeaf), "ECDHE_RSA")
        assertFalse(evaluator.rejected)
        assertEquals(spki(localLeaf), evaluator.presentedFingerprint)
        try {
            evaluator.checkServerTrusted(arrayOf(selfSigned), "ECDHE_RSA")
            fail("accepted a self-signed certificate")
        } catch (_: CertificateException) {
        }
        assertTrue(evaluator.rejected)
        val error = evaluator.tlsError()
        assertEquals(ErrorCode.TLS, error.code)
        assertEquals(spki(selfSigned), error.details!!.getString("presentedFingerprint"))
        assertArrayEquals(arrayOf(deviceCa), evaluator.acceptedIssuers)
        try {
            evaluator.checkClientTrusted(arrayOf(localLeaf), "RSA")
            fail("client certificates are not used")
        } catch (_: CertificateException) {
        }
    }

    @Test
    fun `the system's trust refuses a private CA and still reports the leaf`() {
        val evaluator = TrustEvaluator(null, "127.0.0.1")
        try {
            evaluator.checkServerTrusted(arrayOf(localLeaf), "ECDHE_RSA")
            fail("the system trusts the test CA")
        } catch (_: CertificateException) {
        }
        assertEquals(spki(localLeaf), evaluator.tlsError().details!!.getString("presentedFingerprint"))
    }

    // PEM

    @Test
    fun `PEM parsing ignores what is around the certificate`() {
        assertEquals(chargerCa, Trust.certificateFromPem("A comment line\n" + TestCertificates.pem("test-ca") + "\ntrailing"))
        for (bad in listOf("no certificate here", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----")) {
            try {
                Trust.certificateFromPem(bad)
                fail("parsed $bad")
            } catch (_: CertificateException) {
            }
        }
    }

    // Params

    private fun json(vararg pairs: Pair<String, Any?>) = JSONObject().apply { for ((key, value) in pairs) put(key, value) }

    private fun assertInvalid(value: Any?) {
        try {
            Trust.parse(value)
            fail("accepted $value")
        } catch (e: BridgeException) {
            assertEquals(ErrorCode.INVALID_PARAMS, e.code)
        }
    }

    @Test
    fun `trust params`() {
        assertNull("absent: the system's trust", Trust.parse(null))
        assertNull(Trust.parse(JSONObject.NULL))
        val parsed = Trust.parse(
            json(
                "anchors" to JSONArray().put(TestCertificates.pem("test-local-ca")),
                "fingerprints" to JSONArray().put(spki(selfSigned)).put(spki(localLeaf).removeSuffix("=")),
                "ignoreExpiry" to true,
                "ignoreHostname" to false,
            ),
        )!!
        assertEquals(listOf(deviceCa), parsed.anchors)
        assertEquals("padding is optional, and canonical", setOf(spki(selfSigned), spki(localLeaf)), parsed.fingerprints)
        assertTrue(parsed.ignoreExpiry)
        assertFalse(parsed.ignoreHostname)
        val minimal = Trust.parse(json("fingerprints" to JSONArray().put(spki(selfSigned))))!!
        assertFalse(minimal.ignoreExpiry)
        assertFalse(minimal.ignoreHostname)
    }

    @Test
    fun `bad trust params`() {
        val sha = spki(selfSigned)
        for (bad in listOf(
            "alfen",
            42,
            JSONArray(),
            json(),
            json("anchors" to JSONArray(), "fingerprints" to JSONArray()),
            json("ignoreExpiry" to true, "ignoreHostname" to true),
            json("anchors" to TestCertificates.pem("test-ca")),
            json("anchors" to JSONArray().put("not a certificate")),
            // One certificate per entry (as on iOS).
            json("anchors" to JSONArray().put(TestCertificates.pem("test-ca") + TestCertificates.pem("test-local-ca"))),
            json("anchors" to JSONArray().put(1)),
            json("fingerprints" to JSONArray().put(sha.removePrefix("sha256/"))),
            json("fingerprints" to JSONArray().put("sha1/" + sha.removePrefix("sha256/"))),
            json("fingerprints" to JSONArray().put("sha256/AAAA")),
            json("fingerprints" to JSONArray().put("sha256/!!!")),
            json("fingerprints" to JSONArray().put(sha), "ignoreExpiry" to "yes"),
            json("fingerprints" to JSONArray().put(sha), "ignoreHostname" to 1),
        )) {
            assertInvalid(bad)
        }
    }
}
