package com.plugchoice.internal

import java.security.KeyStore
import java.security.cert.X509Certificate
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext

/**
 * Test-only certificates in `src/test/resources/certificates` (never shipped; the CA keys were
 * thrown away after signing):
 * - `test-ca.pem`: "Test charger CA", valid 2020-01-01 to 2045-01-01;
 * - `test-leaf-expired.pem` (+ `.p12`): signed by it, valid 2020-06-10 to 2021-06-10 (expired,
 *   as some devices' leaves are), for `not-this-host.example`;
 * - `test-self-signed.pem` (+ `.p12`): a self-signed certificate, valid until 2045;
 * - `test-local-ca.pem`: "Test device CA", valid 2026 to 2051, and `test-intermediate.pem`, an
 *   intermediate CA under it;
 * - `test-leaf-local.pem` (+ `.p12`): signed by the device CA, valid until 2051, for
 *   `charger.local` and `127.0.0.1`;
 * - `test-leaf-chained.pem` (+ `.p12` with the intermediate): the same names, signed by the
 *   intermediate.
 * The `.p12` files (password `test`) let the TLS tests run a server.
 */
internal object TestCertificates {
    fun pem(name: String): String =
        javaClass.getResourceAsStream("/certificates/$name.pem")!!.use { it.readBytes().decodeToString() }

    fun certificate(name: String): X509Certificate = Trust.certificateFromPem(pem(name))

    /**
     * The test CA as the anchor, without date or host-name checks (as a page trusts a charger
     * maker's CA whose leaves have expired).
     */
    fun chargerCaTrust(): Trust = Trust(listOf(certificate("test-ca")), emptySet(), ignoreExpiry = true, ignoreHostname = true)

    /** A server-side TLS context presenting [name]'s certificate (and chain) and key. */
    fun serverContext(name: String): SSLContext {
        val keyStore = KeyStore.getInstance("PKCS12")
        javaClass.getResourceAsStream("/certificates/$name.p12")!!.use { keyStore.load(it, "test".toCharArray()) }
        val keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply {
            init(keyStore, "test".toCharArray())
        }.keyManagers
        return SSLContext.getInstance("TLS").apply { init(keyManagers, null, null) }
    }
}
