package com.plugchoice.internal

import android.annotation.SuppressLint
import okhttp3.internal.tls.OkHostnameVerifier
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.Socket
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertPathValidator
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.PKIXParameters
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.Date
import javax.net.ssl.SSLEngine
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedTrustManager
import javax.net.ssl.X509TrustManager
import java.security.cert.TrustAnchor as PkixTrustAnchor

/**
 * What a TLS connection to a device trusts (PROTOCOL.md §9.8), given by the page as a `trust`
 * object on `http.session.open`, `http.request`, `ws.open` and `tcp.open`. Without one, a
 * connection uses the system's trust.
 *
 * A certificate is trusted when its chain verifies (PKIX) against [anchors], which are then the
 * only anchors (the system's roots don't count), or when its leaf's key is one of
 * [fingerprints] (`sha256/<base64>` of the SubjectPublicKeyInfo). Unless [ignoreExpiry], the
 * dates are checked now; with it, the chain is checked at a moment inside the leaf's validity
 * (signatures still verified up to the anchor, the leaf's own dates forgiven). Unless
 * [ignoreHostname], the leaf must name the host (DNS or IP subject alternative names). Both rules
 * apply to pinned keys too. There is no "accept anything".
 *
 * The host rules (private, link-local and loopback addresses, `*.local`) still apply to every
 * call that takes a `Trust`, so a page-supplied anchor never touches the open internet.
 */
internal class Trust(
    val anchors: List<X509Certificate>,
    /** Canonical `sha256/<base64 with padding>`. */
    val fingerprints: Set<String>,
    val ignoreExpiry: Boolean,
    val ignoreHostname: Boolean,
) {
    init {
        require(anchors.isNotEmpty() || fingerprints.isNotEmpty()) { "a trust needs anchors or fingerprints" }
    }

    /**
     * Throws [CertificateException] unless [chain] (leaf first, as a server sends it) is trusted
     * for [host] (`null`: no host name to match, as in tests of the chain alone).
     */
    fun check(chain: Array<out X509Certificate>, host: String?) {
        val leaf = chain.firstOrNull() ?: throw CertificateException("the device sent no certificate")
        if (fingerprint(leaf) in fingerprints) {
            if (!ignoreExpiry) leaf.checkValidity()
        } else {
            checkChain(leaf, chain)
        }
        if (!ignoreHostname && host != null && !OkHostnameVerifier.verify(host.removePrefix("[").removeSuffix("]"), leaf)) {
            throw CertificateException("the device's certificate is not for $host")
        }
    }

    private fun checkChain(leaf: X509Certificate, chain: Array<out X509Certificate>) {
        if (anchors.isEmpty()) throw CertificateException("the device's key is not one of the trusted fingerprints")
        if (leaf in anchors) {
            // The device presents an anchor itself (a self-signed certificate given as an anchor).
            if (!ignoreExpiry) leaf.checkValidity()
            return
        }
        // A path from the leaf up to (not including) an anchor, out of what the device sent.
        val anchorSubjects = anchors.map { it.subjectX500Principal }.toSet()
        val path = mutableListOf(leaf)
        while (path.last().issuerX500Principal !in anchorSubjects) {
            val issuer = path.last().issuerX500Principal
            val next = chain.firstOrNull { it !in path && it !in anchors && it.subjectX500Principal == issuer } ?: break
            path += next
        }
        val parameters = PKIXParameters(anchors.map { PkixTrustAnchor(it, null) }.toSet()).apply {
            isRevocationEnabled = false
            // The middle of the leaf's validity: only its dates are forgiven.
            if (ignoreExpiry) date = Date((leaf.notBefore.time + leaf.notAfter.time) / 2)
        }
        try {
            val certPath = CertificateFactory.getInstance("X.509").generateCertPath(path)
            CertPathValidator.getInstance("PKIX").validate(certPath, parameters)
        } catch (e: GeneralSecurityException) {
            throw CertificateException("the device's certificate did not verify against the page's anchors: ${e.message}", e)
        }
    }

    companion object {
        /** `sha256/<base64>` of [certificate]'s SubjectPublicKeyInfo. */
        fun fingerprint(certificate: X509Certificate): String =
            "sha256/" + Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(certificate.publicKey.encoded))

        /**
         * A `Trust` param: `null` when absent (the system's trust), otherwise checked
         * (`invalidParams` for anything off-contract, including no anchors and no fingerprints).
         */
        fun parse(value: Any?, name: String = "trust"): Trust? = when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> parseObject(value, name)
            else -> throw BridgeException.invalidParams("$name must be an object")
        }

        private fun parseObject(json: JSONObject, name: String): Trust {
            val anchors = json.optStringList("anchors").mapIndexed { i, pem ->
                if (pem.split(PEM_BEGIN).size != 2) throw BridgeException.invalidParams("$name.anchors[$i] is not one PEM certificate")
                try {
                    certificateFromPem(pem)
                } catch (e: CertificateException) {
                    throw BridgeException.invalidParams("$name.anchors[$i] is not one PEM certificate: ${e.message}")
                }
            }
            val fingerprints = json.optStringList("fingerprints").mapIndexed { i, value ->
                canonicalFingerprint(value) ?: throw BridgeException.invalidParams(
                    "$name.fingerprints[$i] must be \"sha256/\" and the base64 SHA-256 of a SubjectPublicKeyInfo",
                )
            }.toSet()
            val ignoreExpiry = json.optBoolean(name, "ignoreExpiry")
            val ignoreHostname = json.optBoolean(name, "ignoreHostname")
            if (anchors.isEmpty() && fingerprints.isEmpty()) {
                throw BridgeException.invalidParams("$name needs anchors or fingerprints")
            }
            return Trust(anchors, fingerprints, ignoreExpiry, ignoreHostname)
        }

        private fun JSONObject.optBoolean(name: String, key: String): Boolean = when (val value = opt(key)) {
            null, JSONObject.NULL -> false
            is Boolean -> value
            else -> throw BridgeException.invalidParams("$name.$key must be a boolean")
        }

        /** `sha256/` and 32 bytes in base64 (padding optional), as `sha256/<base64 with padding>`. */
        fun canonicalFingerprint(value: String): String? {
            if (!value.startsWith("sha256/")) return null
            val bytes = try {
                Base64.getDecoder().decode(value.removePrefix("sha256/"))
            } catch (_: IllegalArgumentException) {
                return null
            }
            if (bytes.size != 32) return null
            return "sha256/" + Base64.getEncoder().encodeToString(bytes)
        }

        private const val PEM_BEGIN = "-----BEGIN CERTIFICATE-----"

        /** The first certificate in a PEM text; anything around the BEGIN/END lines is ignored. */
        fun certificateFromPem(pem: String): X509Certificate {
            val begin = PEM_BEGIN
            val end = "-----END CERTIFICATE-----"
            val start = pem.indexOf(begin)
            val stop = pem.indexOf(end, startIndex = start + begin.length)
            if (start < 0 || stop < 0) throw CertificateException("no PEM certificate")
            val der = try {
                Base64.getMimeDecoder().decode(pem.substring(start + begin.length, stop))
            } catch (e: IllegalArgumentException) {
                throw CertificateException("bad PEM certificate", e)
            }
            return CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(der)) as X509Certificate
        }
    }
}

/**
 * The trust manager of one TLS connection to [host]: the page's [trust], or the system's when it
 * is null (then the host name is always matched). Remembers the presented leaf and a refusal, so
 * a failed handshake answers `tls` with `details.presentedFingerprint` ([tlsError]).
 *
 * No platform host name check is relied on: the checks here are the whole verification (an
 * [X509ExtendedTrustManager] is used as is, without endpoint identification).
 */
@SuppressLint("CustomX509TrustManager")
internal class TrustEvaluator(
    private val trust: Trust?,
    /** The name to match (the host, or `tls.serverName`). */
    private val host: String,
    private val system: () -> X509TrustManager = ::systemTrustManager,
) : X509ExtendedTrustManager() {
    private val systemManager: X509TrustManager by lazy(system)

    @Volatile
    var rejection: String? = null
        private set

    @Volatile
    var presentedFingerprint: String? = null
        private set

    val rejected: Boolean
        get() = rejection != null

    override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String?) =
        check(chain) { systemManager.checkServerTrusted(chain, authType) }

    override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String?, socket: Socket?) =
        check(chain) {
            // The socket variant lets Android's trust manager apply the app's network security config.
            val manager = systemManager
            if (manager is X509ExtendedTrustManager) manager.checkServerTrusted(chain, authType, socket) else manager.checkServerTrusted(chain, authType)
        }

    override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String?, engine: SSLEngine?) =
        check(chain) {
            val manager = systemManager
            if (manager is X509ExtendedTrustManager) manager.checkServerTrusted(chain, authType, engine) else manager.checkServerTrusted(chain, authType)
        }

    override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String?): Unit =
        throw CertificateException("client certificates are not used")

    override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String?, socket: Socket?): Unit =
        throw CertificateException("client certificates are not used")

    override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String?, engine: SSLEngine?): Unit =
        throw CertificateException("client certificates are not used")

    override fun getAcceptedIssuers(): Array<X509Certificate> = trust?.anchors?.toTypedArray() ?: systemManager.acceptedIssuers

    private fun check(chain: Array<out X509Certificate>, systemCheck: () -> Unit) {
        presentedFingerprint = chain.firstOrNull()?.let(Trust::fingerprint)
        try {
            if (trust != null) {
                trust.check(chain, host)
            } else {
                systemCheck()
                val leaf = chain.firstOrNull() ?: throw CertificateException("the device sent no certificate")
                if (!OkHostnameVerifier.verify(host.removePrefix("[").removeSuffix("]"), leaf)) {
                    throw CertificateException("the device's certificate is not for $host")
                }
            }
        } catch (e: CertificateException) {
            rejection = e.message ?: e.toString()
            throw e
        }
    }

    /** `tls`, with the presented leaf's fingerprint when there was one. */
    fun tlsError(): BridgeException = BridgeException(
        ErrorCode.TLS,
        "the device's certificate was not trusted (${if (trust != null) "the page's trust" else "the system's trust"}): $rejection",
        presentedFingerprint?.let { JSONObject().put("presentedFingerprint", it) },
    )

    companion object {
        fun systemTrustManager(): X509TrustManager =
            TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
                .apply { init(null as KeyStore?) }
                .trustManagers
                .filterIsInstance<X509TrustManager>()
                .first()
    }
}
