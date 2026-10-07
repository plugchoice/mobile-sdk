import CryptoKit
import Security
import XCTest
@testable import PlugchoiceSDK

/// Trust objects (PROTOCOL §9.8), checked with test CAs standing in for a
/// device's.
///
/// `Certificates/` holds test-only certificates (never shipped):
/// - `test-ca.pem`: "Test charger CA", valid 2020-01-01 to 2045-01-01;
/// - `test-leaf-expired.pem` (+ `.p12`): signed by it, valid 2020-06-10 to
///   2021-06-10 (expired, as some devices' leaves are), for
///   `not-this-host.example`;
/// - `test-self-signed.pem` (+ `.p12`): a self-signed certificate with the
///   same key as `test-leaf-expired`;
/// - `test-device-ca.pem`: "Test device CA", valid 2025-01-01 to 2050-01-01;
/// - `test-leaf-localhost.pem` (+ `.p12`): signed by it, valid 2025 to 2050,
///   for `localhost` and `127.0.0.1`;
/// - `test-ec-self-signed.pem`: a self-signed P-256 certificate.
/// The `.p12` files (password `test`) let the TLS tests run a server. The
/// fingerprints below come from
/// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`.
@MainActor
final class TrustTests: XCTestCase {
    static let expiredLeafFingerprint = "sha256/vNQt1uNNxWu/kAo8BzdtZ4KDrJa+J3Uvv/ml17oFdiA="
    static let localhostLeafFingerprint = "sha256/xKCBVXpRBbnr4RrCCF6Wy684ooocrTmB30ntVqZ6k34="
    static let ecFingerprint = "sha256/EuWtBN31v6RWm/2hquOcBw7LkcCuCF8w7Pee2RNPyUE="
    static let deviceCAFingerprint = "sha256/2YYtZ8nlyXTCei2o50ob83YMTMqIV/vPI66W/v3jJNM="

    static func pem(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pem", subdirectory: "Certificates"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func certificate(_ name: String) throws -> SecCertificate {
        try XCTUnwrap(Trust.certificate(fromPEM: try pem(name)))
    }

    /// The test CA as the anchor, without date or host-name checks (as a
    /// page trusts a charger maker's CA whose leaves have expired).
    static func chargerCATrust() throws -> Trust {
        try XCTUnwrap(try Trust.parse(["anchors": [try pem("test-ca")], "ignoreExpiry": true, "ignoreHostname": true]))
    }

    static func trust(_ object: JSONObject) throws -> Trust {
        try XCTUnwrap(try Trust.parse(object))
    }

    /// A server's chain as the TLS stack hands it over: with the SSL policy
    /// for the host that was dialled.
    private func serverTrust(_ certificates: [SecCertificate], host: String = "192.168.1.10") throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(trust)
    }

    private func evaluate(_ trust: Trust, _ names: [String], host: String) throws -> Trust.Evaluation {
        trust.evaluate(try serverTrust(try names.map(Self.certificate), host: host), host: host)
    }

    // MARK: - Fingerprints

    func testFingerprintsAreTheSPKIHash() throws {
        XCTAssertEqual(Trust.fingerprint(of: try Self.certificate("test-leaf-expired")), Self.expiredLeafFingerprint)
        XCTAssertEqual(Trust.fingerprint(of: try Self.certificate("test-self-signed")), Self.expiredLeafFingerprint, "same key")
        XCTAssertEqual(Trust.fingerprint(of: try Self.certificate("test-leaf-localhost")), Self.localhostLeafFingerprint)
        XCTAssertEqual(Trust.fingerprint(of: try Self.certificate("test-device-ca")), Self.deviceCAFingerprint)
        XCTAssertEqual(Trust.fingerprint(of: try Self.certificate("test-ec-self-signed")), Self.ecFingerprint, "an EC key")
    }

    func testFingerprintParsing() {
        XCTAssertNotNil(Trust.fingerprintHash(Self.ecFingerprint))
        XCTAssertNotNil(Trust.fingerprintHash("sha256/EuWtBN31v6RWm/2hquOcBw7LkcCuCF8w7Pee2RNPyUE"), "padding optional")
        for bad in ["", "sha256/", "EuWtBN31v6RWm/2hquOcBw7LkcCuCF8w7Pee2RNPyUE=", "sha1/EuWtBN31v6RWm/2hquOcBw7LkcCuCF8w7Pee2RNPyUE=",
                    "SHA256/EuWtBN31v6RWm/2hquOcBw7LkcCuCF8w7Pee2RNPyUE=", "sha256/AAAA", "sha256/EuWtBN31v6RWm_2hquOcBw7LkcCuCF8w7Pee2RNPyUE=",
                    "sha256/ EuWtBN31v6RWm/2hquOcBw7LkcCuCF8w7Pee2RNPyUE="] {
            XCTAssertNil(Trust.fingerprintHash(bad), bad)
        }
    }

    func testAPinnedLeafStillHasItsDatesAndHostNameChecked() throws {
        // A pin replaces the chain, not the other checks (as on Android).
        let pinned = try Self.trust(["fingerprints": [Self.localhostLeafFingerprint]])
        XCTAssertEqual(
            try evaluate(pinned, ["test-leaf-localhost"], host: "127.0.0.1"),
            Trust.Evaluation(trusted: true, presentedFingerprint: Self.localhostLeafFingerprint),
            "valid, and for this host"
        )
        XCTAssertTrue(try evaluate(pinned, ["test-leaf-localhost"], host: "localhost").trusted)
        XCTAssertFalse(try evaluate(pinned, ["test-leaf-localhost"], host: "10.0.0.5").trusted, "another host")
        XCTAssertTrue(try evaluate(try Self.trust(["fingerprints": [Self.localhostLeafFingerprint], "ignoreHostname": true]), ["test-leaf-localhost"], host: "10.0.0.5").trusted)

        // test-self-signed has no subject alternative names.
        let selfSigned = try Self.trust(["fingerprints": [Self.expiredLeafFingerprint]])
        XCTAssertFalse(try evaluate(selfSigned, ["test-self-signed"], host: "10.0.0.5").trusted)
        XCTAssertTrue(try evaluate(try Self.trust(["fingerprints": [Self.expiredLeafFingerprint], "ignoreHostname": true]), ["test-self-signed"], host: "10.0.0.5").trusted)
    }

    func testAPinnedExpiredLeafNeedsIgnoreExpiry() throws {
        // test-leaf-expired is for not-this-host.example, so the host matches.
        let pinned = try Self.trust(["fingerprints": [Self.expiredLeafFingerprint]])
        XCTAssertFalse(try evaluate(pinned, ["test-leaf-expired"], host: "not-this-host.example").trusted)
        let forgiving = try Self.trust(["fingerprints": [Self.expiredLeafFingerprint], "ignoreExpiry": true])
        XCTAssertTrue(try evaluate(forgiving, ["test-leaf-expired"], host: "not-this-host.example").trusted)
        XCTAssertFalse(try evaluate(forgiving, ["test-leaf-expired"], host: "10.0.0.5").trusted, "the host is still checked")
        let neither = try Self.trust(["fingerprints": [Self.expiredLeafFingerprint], "ignoreExpiry": true, "ignoreHostname": true])
        XCTAssertTrue(try evaluate(neither, ["test-leaf-expired"], host: "10.0.0.5").trusted)
        XCTAssertTrue(try evaluate(neither, ["test-self-signed"], host: "10.0.0.5").trusted, "the same key")
    }

    func testAPinnedLeafIsCheckedAgainstTheClock() throws {
        let pinned = try Self.trust(["fingerprints": [Self.localhostLeafFingerprint]])
        let leaf = try serverTrust([try Self.certificate("test-leaf-localhost")], host: "127.0.0.1")
        // test-leaf-localhost is valid from 2025 to 2050.
        XCTAssertFalse(pinned.evaluate(leaf, host: "127.0.0.1", now: ISO8601DateFormatter().date(from: "2024-06-01T00:00:00Z")!).trusted, "not yet valid")
        XCTAssertFalse(pinned.evaluate(leaf, host: "127.0.0.1", now: ISO8601DateFormatter().date(from: "2051-01-01T00:00:00Z")!).trusted, "expired")
        XCTAssertTrue(pinned.evaluate(leaf, host: "127.0.0.1", now: ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!).trusted)
    }

    func testAnotherLeafIsRefusedWithItsFingerprint() throws {
        let pinned = try Self.trust(["fingerprints": [Self.ecFingerprint]])
        let evaluation = try evaluate(pinned, ["test-leaf-localhost"], host: "127.0.0.1")
        XCTAssertEqual(evaluation, Trust.Evaluation(trusted: false, presentedFingerprint: Self.localhostLeafFingerprint))
        XCTAssertEqual(
            pinned.rejection(evaluation.presentedFingerprint),
            BridgeError(code: "tls", message: "the device's certificate did not verify against the page's trust", details: ["presentedFingerprint": Self.localhostLeafFingerprint])
        )
    }

    func testAPinnedCAIsNotAPinnedLeaf() throws {
        // Fingerprints match the leaf only.
        let pinnedCA = try Self.trust(["fingerprints": [Self.deviceCAFingerprint]])
        XCTAssertFalse(try evaluate(pinnedCA, ["test-leaf-localhost", "test-device-ca"], host: "127.0.0.1").trusted)
    }

    // MARK: - Anchors

    func testAValidLeafFromTheAnchorVerifiesForItsHost() throws {
        let anchored = try Self.trust(["anchors": [try Self.pem("test-device-ca")]])
        for host in ["127.0.0.1", "localhost"] {
            XCTAssertTrue(try evaluate(anchored, ["test-leaf-localhost"], host: host).trusted, host)
        }
    }

    func testTheHostNameIsCheckedUnlessIgnored() throws {
        let anchored = try Self.trust(["anchors": [try Self.pem("test-device-ca")]])
        let wrongHost = try evaluate(anchored, ["test-leaf-localhost"], host: "10.0.0.5")
        XCTAssertFalse(wrongHost.trusted)
        XCTAssertEqual(wrongHost.presentedFingerprint, Self.localhostLeafFingerprint)

        let anyHost = try Self.trust(["anchors": [try Self.pem("test-device-ca")], "ignoreHostname": true])
        for host in ["10.0.0.5", "charger.local", "example.com"] {
            XCTAssertTrue(try evaluate(anyHost, ["test-leaf-localhost"], host: host).trusted, host)
        }
    }

    func testAnExpiredLeafNeedsIgnoreExpiry() throws {
        // test-leaf-expired is for not-this-host.example, so the host matches.
        let strict = try Self.trust(["anchors": [try Self.pem("test-ca")]])
        XCTAssertFalse(try evaluate(strict, ["test-leaf-expired"], host: "not-this-host.example").trusted)
        let forgiving = try Self.trust(["anchors": [try Self.pem("test-ca")], "ignoreExpiry": true])
        XCTAssertTrue(try evaluate(forgiving, ["test-leaf-expired"], host: "not-this-host.example").trusted)
        XCTAssertFalse(try evaluate(forgiving, ["test-leaf-expired"], host: "10.0.0.5").trusted, "the host is still checked")
    }

    func testACAWithoutDateOrHostChecks() throws {
        let anchor = try Self.chargerCATrust()
        let leaf = try Self.certificate("test-leaf-expired")
        XCTAssertTrue(anchor.evaluate(try serverTrust([leaf]), host: "192.168.1.10").trusted)
        XCTAssertTrue(anchor.evaluate(try serverTrust([leaf, try Self.certificate("test-ca")]), host: "192.168.1.10").trusted, "with the CA sent along")
        for host in ["10.206.2.88", "ng910-60623-ace0870096.local", "example.com"] {
            XCTAssertTrue(anchor.evaluate(try serverTrust([leaf], host: host), host: host).trusted, host)
        }
    }

    func testOnlyTheAnchorsCount() throws {
        XCTAssertFalse(try evaluate(try Self.chargerCATrust(), ["test-self-signed"], host: "10.0.0.5").trusted)
        // A leaf from another CA fails, whatever the exceptions.
        let otherCA = try Self.trust(["anchors": [try Self.pem("test-device-ca")], "ignoreExpiry": true, "ignoreHostname": true])
        XCTAssertFalse(try evaluate(otherCA, ["test-leaf-expired", "test-ca"], host: "10.0.0.5").trusted)
    }

    func testAnchorsOrFingerprints() throws {
        let both = try Self.trust(["anchors": [try Self.pem("test-device-ca")], "fingerprints": [Self.expiredLeafFingerprint], "ignoreHostname": true])
        XCTAssertTrue(try evaluate(both, ["test-leaf-localhost"], host: "127.0.0.1").trusted, "by the anchor")
        XCTAssertTrue(try evaluate(both, ["test-self-signed"], host: "127.0.0.1").trusted, "by the pin")
        XCTAssertFalse(try evaluate(both, ["test-ec-self-signed"], host: "127.0.0.1").trusted)
    }

    func testTheSystemsTrustRefusesADevicesOwnCertificate() throws {
        let evaluation = Trust.evaluateSystem(try serverTrust([try Self.certificate("test-leaf-localhost")], host: "127.0.0.1"), host: "127.0.0.1")
        XCTAssertEqual(evaluation, Trust.Evaluation(trusted: false, presentedFingerprint: Self.localhostLeafFingerprint))
        XCTAssertEqual(Trust.rejection(pageTrust: false, presentedFingerprint: nil).message, "the device's certificate did not verify against the system's trust")
        XCTAssertNil(Trust.rejection(pageTrust: false, presentedFingerprint: nil).details)
    }

    // MARK: - Params

    func testAbsentTrustIsTheSystems() throws {
        XCTAssertNil(try Trust.parse(nil))
        XCTAssertNil(try Trust.parse(NSNull()))
    }

    func testTrustObjectParsing() throws {
        let trust = try Self.trust([
            "anchors": [try Self.pem("test-device-ca"), try Self.pem("test-ca")],
            "fingerprints": [Self.ecFingerprint, Self.ecFingerprint],
            "ignoreExpiry": true,
            "ignoreHostname": false,
            "somethingNew": 1,
        ])
        XCTAssertEqual(trust.anchors.count, 2)
        XCTAssertEqual(trust.fingerprints.count, 1)
        XCTAssertTrue(trust.ignoreExpiry)
        XCTAssertFalse(trust.ignoreHostname)
    }

    func testTrustObjectsRejectBadParams() throws {
        let ca = try Self.pem("test-device-ca")
        for value: Any in [
            [:] as JSONObject,
            ["anchors": []] as JSONObject,
            ["fingerprints": []] as JSONObject,
            ["ignoreExpiry": true] as JSONObject,
            ["anchors": ca] as JSONObject,
            ["anchors": ["not a certificate"]] as JSONObject,
            // One certificate per entry (as on Android).
            ["anchors": [ca + (try Self.pem("test-ca"))]] as JSONObject,
            ["anchors": [ca, 1]] as JSONObject,
            ["fingerprints": ["sha256/AAAA"]] as JSONObject,
            ["fingerprints": Self.ecFingerprint] as JSONObject,
            ["anchors": [ca], "ignoreExpiry": "yes"] as JSONObject,
            ["anchors": [ca], "ignoreHostname": 1] as JSONObject,
            "system",
            42,
            [ca],
        ] {
            XCTAssertThrowsCode("invalidParams") { _ = try Trust.parse(value) }
        }
    }

    func testParamsErrorsNameTheTrust() {
        XCTAssertThrowsError(try Trust.parse(["anchors": "x"], key: "tls.trust")) { error in
            XCTAssertEqual((error as? BridgeError)?.message, "tls.trust.anchors must be an array of strings")
        }
    }

    func testALongLivedDeviceCertificateIsFine() throws {
        // test-leaf-localhost is valid for 25 years and verifies with its host
        // name checked: the TLS server policy's 825-day limit doesn't apply.
        XCTAssertGreaterThan(try XCTUnwrap(DER.validity(of: SecCertificateCopyData(try Self.certificate("test-leaf-localhost")) as Data)).notAfter,
                             Date().addingTimeInterval(825 * 86_400))
        let anchored = try Self.trust(["anchors": [try Self.pem("test-device-ca")]])
        XCTAssertTrue(try evaluate(anchored, ["test-leaf-localhost"], host: "127.0.0.1").trusted)
    }

    // MARK: - Host names

    func testSubjectAltNamesAreRead() throws {
        func names(_ name: String) throws -> DER.SubjectAltNames? {
            DER.subjectAltNames(of: SecCertificateCopyData(try Self.certificate(name)) as Data)
        }
        XCTAssertEqual(try names("test-leaf-localhost"), DER.SubjectAltNames(dnsNames: ["localhost"], ipAddresses: [Data([127, 0, 0, 1])]))
        XCTAssertEqual(try names("test-leaf-expired"), DER.SubjectAltNames(dnsNames: ["not-this-host.example"], ipAddresses: []))
        XCTAssertNil(try names("test-self-signed"), "no subject alternative names")
        XCTAssertNil(DER.subjectAltNames(of: Data()))
    }

    func testHostNameMatching() {
        let names = DER.SubjectAltNames(
            dnsNames: ["charger.local", "*.devices.example", "*"],
            ipAddresses: [Data([192, 168, 1, 10]), HostName.ipAddress("fe80::1")!]
        )
        for host in ["charger.local", "CHARGER.local", "charger.local.", "a.devices.example", "192.168.1.10", "fe80::1", "fe80:0:0::1"] {
            XCTAssertTrue(HostName.matches(host, names), host)
        }
        for host in ["other.local", "devices.example", "a.b.devices.example", "192.168.1.11", "::1", "", "x"] {
            XCTAssertFalse(HostName.matches(host, names), host)
        }
        XCTAssertFalse(HostName.matches("192.168.1.10", DER.SubjectAltNames(dnsNames: ["192.168.1.10"], ipAddresses: [])), "an IP needs an IP name")
    }

    // MARK: - DER

    func testTheLeafsValidityIsRead() throws {
        let leaf = try Self.certificate("test-leaf-expired")
        let validity = try XCTUnwrap(DER.validity(of: SecCertificateCopyData(leaf) as Data))
        XCTAssertEqual(validity, DER.Validity(notBefore: date("2020-06-10T00:00:00Z"), notAfter: date("2021-06-10T00:00:00Z")))
        XCTAssertNil(DER.validity(of: Data([0x30, 0x03, 0x02, 0x01, 0x01])))
        XCTAssertNil(DER.validity(of: Data()))
        XCTAssertNil(DER.subjectPublicKeyInfo(of: Data([0x30, 0x03, 0x02, 0x01, 0x01])))
    }

    func testPEMParsing() throws {
        let pem = try Self.pem("test-ca")
        XCTAssertNotNil(Trust.certificate(fromPEM: "A comment line\n" + pem))
        XCTAssertNil(Trust.certificate(fromPEM: "no certificate here"))
        XCTAssertNil(Trust.certificate(fromPEM: "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"))
        let deviceCA = try Self.pem("test-device-ca")
        XCTAssertEqual(Trust.certificates(fromPEM: pem + "\n" + deviceCA).count, 2)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }
}
