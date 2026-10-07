import CryptoKit
import Foundation
import Security

/// What a TLS connection to a device trusts (PROTOCOL §9.8): a page's
/// `trust` object. Without one the system's trust applies
/// (`Trust.evaluateSystem`).
///
/// A certificate is trusted when its leaf's SubjectPublicKeyInfo hash is in
/// `fingerprints` (a pinned device key), or when its chain verifies against
/// `anchors` and nothing else (the system's roots don't count). Either way:
/// - the leaf's validity dates are checked as of now unless `ignoreExpiry`;
///   with it, an anchored chain is checked as of a moment inside the leaf's
///   validity, so an expired leaf passes while the signatures up to the
///   anchor are still verified;
/// - the host name is checked against the leaf's subject alternative names
///   (DNS names, one `*.` wildcard label, IP addresses) unless
///   `ignoreHostname`.
///
/// An anchored chain is checked with the basic X.509 policy (signatures,
/// validity dates, CA constraints), not the TLS server policy, whose extra
/// rules for public web servers (at most 825 days of validity, a server-auth
/// extended key usage) many devices' long-lived certificates break.
///
/// There is no "accept anything", and the host rules still apply to every
/// call that takes a trust, so a page-supplied anchor never reaches the open
/// internet.
struct Trust {
    let anchors: [SecCertificate]
    /// SHA-256 of a SubjectPublicKeyInfo, each 32 bytes.
    let fingerprints: Set<Data>
    let ignoreExpiry: Bool
    let ignoreHostname: Bool

    static let fingerprintPrefix = "sha256/"

    // MARK: - Params

    /// A `trust` param: nil when absent (the system's trust), or a trust
    /// object. Anything else is `invalidParams`.
    static func parse(_ value: Any?, key: String = "trust") throws -> Trust? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? JSONObject else {
            throw BridgeError.invalidParams("\(key) must be an object")
        }
        do {
            return try parseObject(Params(object), key: key)
        } catch let error as BridgeError where error.code == "invalidParams" && !error.message.hasPrefix("\(key)") {
            // Name the object: "trust.anchors must be …".
            throw BridgeError.invalidParams("\(key).\(error.message)")
        }
    }

    private static func parseObject(_ params: Params, key: String) throws -> Trust {
        var anchors: [SecCertificate] = []
        for (index, pem) in (try params.optionalStringArray("anchors") ?? []).enumerated() {
            guard let anchor = anchor(fromPEM: pem) else {
                throw BridgeError.invalidParams("\(key).anchors[\(index)] is not one PEM certificate")
            }
            anchors.append(anchor)
        }
        var fingerprints: Set<Data> = []
        for (index, text) in (try params.optionalStringArray("fingerprints") ?? []).enumerated() {
            guard let hash = fingerprintHash(text) else {
                throw BridgeError.invalidParams("\(key).fingerprints[\(index)] must be \"sha256/<base64 of 32 bytes>\"")
            }
            fingerprints.insert(hash)
        }
        guard !anchors.isEmpty || !fingerprints.isEmpty else {
            throw BridgeError.invalidParams("\(key) needs anchors or fingerprints")
        }
        return Trust(
            anchors: anchors,
            fingerprints: fingerprints,
            ignoreExpiry: try params.optionalBool("ignoreExpiry") ?? false,
            ignoreHostname: try params.optionalBool("ignoreHostname") ?? false
        )
    }

    /// The 32 bytes of `sha256/<base64>` (padding optional), or nil.
    static func fingerprintHash(_ text: String) -> Data? {
        guard text.hasPrefix(fingerprintPrefix) else { return nil }
        var base64 = String(text.dropFirst(fingerprintPrefix.count))
        guard !base64.isEmpty, base64.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }) else {
            return nil
        }
        if !base64.hasSuffix("=") {
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        }
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return data
    }

    // MARK: - Certificates

    /// Every certificate in a PEM text; anything around the BEGIN/END lines
    /// (such as a comment) is ignored.
    static func certificates(fromPEM pem: String) -> [SecCertificate] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var certificates: [SecCertificate] = []
        var searchFrom = pem.startIndex
        while let start = pem.range(of: begin, range: searchFrom..<pem.endIndex),
              let stop = pem.range(of: end, range: start.upperBound..<pem.endIndex) {
            searchFrom = stop.upperBound
            guard let der = Data(base64Encoded: String(pem[start.upperBound..<stop.lowerBound]), options: .ignoreUnknownCharacters),
                  let certificate = SecCertificateCreateWithData(nil, der as CFData)
            else { continue }
            certificates.append(certificate)
        }
        return certificates
    }

    /// The first certificate in a PEM text.
    static func certificate(fromPEM pem: String) -> SecCertificate? {
        certificates(fromPEM: pem).first
    }

    /// An `anchors` entry: a PEM text with exactly one certificate.
    static func anchor(fromPEM pem: String) -> SecCertificate? {
        guard pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").count == 2 else { return nil }
        let certificates = certificates(fromPEM: pem)
        return certificates.count == 1 ? certificates[0] : nil
    }

    /// SHA-256 of the certificate's DER-encoded SubjectPublicKeyInfo.
    static func spkiHash(_ certificate: SecCertificate) -> Data? {
        guard let spki = DER.subjectPublicKeyInfo(of: SecCertificateCopyData(certificate) as Data) else { return nil }
        return Data(SHA256.hash(data: spki))
    }

    /// `sha256/<base64>` of the certificate's SubjectPublicKeyInfo, the form
    /// pages pin with.
    static func fingerprint(of certificate: SecCertificate) -> String? {
        spkiHash(certificate).map { fingerprintPrefix + $0.base64EncodedString() }
    }

    // MARK: - Evaluation

    struct Evaluation: Equatable {
        let trusted: Bool
        /// The presented leaf's fingerprint, for a `tls` error's details.
        let presentedFingerprint: String?
    }

    /// Whether `secTrust` (a server's chain, with whatever policy the TLS
    /// stack set) is trusted under these rules, for a connection to `host`.
    func evaluate(_ secTrust: SecTrust, host: String, now: Date = Date()) -> Evaluation {
        let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
        let presented = leaf.flatMap(Self.fingerprint)
        let untrusted = Evaluation(trusted: false, presentedFingerprint: presented)
        guard let leaf else { return untrusted }
        let leafDER = SecCertificateCopyData(leaf) as Data
        if !ignoreHostname {
            guard HostName.matches(Self.policyHost(host), certificate: leafDER) else { return untrusted }
        }
        if let hash = Self.spkiHash(leaf), fingerprints.contains(hash) {
            // A pinned key: no chain to check, but the leaf's dates count
            // unless the page forgives them.
            guard !ignoreExpiry else { return Evaluation(trusted: true, presentedFingerprint: presented) }
            guard let validity = DER.validity(of: leafDER) else { return untrusted }
            return Evaluation(trusted: validity.notBefore <= now && now <= validity.notAfter, presentedFingerprint: presented)
        }
        guard !anchors.isEmpty else { return untrusted }
        SecTrustSetPolicies(secTrust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(secTrust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(secTrust, true)
        SecTrustSetNetworkFetchAllowed(secTrust, false)
        if ignoreExpiry, let validity = DER.validity(of: leafDER) {
            // As of the middle of the leaf's validity, so only its dates are
            // forgiven. Without readable dates it's checked as of now (and
            // an expired leaf fails).
            let middle = validity.notBefore.addingTimeInterval(validity.notAfter.timeIntervalSince(validity.notBefore) / 2)
            SecTrustSetVerifyDate(secTrust, middle as CFDate)
        } else {
            SecTrustSetVerifyDate(secTrust, now as CFDate)
        }
        return Evaluation(trusted: SecTrustEvaluateWithError(secTrust, nil), presentedFingerprint: presented)
    }

    /// The system's trust for `host`, as a connection without a trust object
    /// gets it, keeping the fingerprint for a `tls` error.
    static func evaluateSystem(_ secTrust: SecTrust, host: String) -> Evaluation {
        let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
        SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, policyHost(host) as CFString))
        return Evaluation(trusted: SecTrustEvaluateWithError(secTrust, nil), presentedFingerprint: leaf.flatMap(fingerprint))
    }

    /// The name a certificate must carry: an IPv6 literal without brackets,
    /// a name without a trailing dot.
    static func policyHost(_ host: String) -> String {
        var name = host
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// What a `tls` error says, with the presented fingerprint as details.
    func rejection(_ presentedFingerprint: String?) -> BridgeError {
        Self.rejection(pageTrust: true, presentedFingerprint: presentedFingerprint)
    }

    /// `pageTrust`: a page's trust object refused the certificate, rather
    /// than the system's trust.
    static func rejection(pageTrust: Bool, presentedFingerprint: String?) -> BridgeError {
        BridgeError(
            code: "tls",
            message: "the device's certificate did not verify against \(pageTrust ? "the page's trust" : "the system's trust")",
            details: presentedFingerprint.map { ["presentedFingerprint": $0] }
        )
    }
}

/// The parts of a DER certificate the shell needs. Security has no public
/// API for the validity dates before iOS 18, nor for the
/// SubjectPublicKeyInfo bytes.
enum DER {
    struct Validity: Equatable {
        let notBefore: Date
        let notAfter: Date
    }

    private struct TLV {
        let tag: UInt8
        /// Where the tag byte is.
        let offset: Int
        /// Where the content starts.
        let start: Int
        let end: Int
    }

    /// The TBSCertificate fields: [0] version (optional), serialNumber,
    /// signature, issuer, validity, subject, subjectPublicKeyInfo, …
    /// Returns the offset of `validity`.
    private static func validityOffset(_ bytes: [UInt8]) -> Int? {
        guard let certificate = read(bytes, at: 0), certificate.tag == 0x30,
              let tbs = read(bytes, at: certificate.start), tbs.tag == 0x30
        else { return nil }
        var offset = tbs.start
        guard let first = read(bytes, at: offset) else { return nil }
        if first.tag == 0xA0 { offset = first.end }
        for _ in 0..<3 {
            guard let skipped = read(bytes, at: offset) else { return nil }
            offset = skipped.end
        }
        return offset
    }

    static func validity(of der: Data) -> Validity? {
        let bytes = [UInt8](der)
        guard let offset = validityOffset(bytes),
              let validity = read(bytes, at: offset), validity.tag == 0x30,
              let before = read(bytes, at: validity.start),
              let after = read(bytes, at: before.end),
              let notBefore = time(bytes, before),
              let notAfter = time(bytes, after)
        else { return nil }
        return Validity(notBefore: notBefore, notAfter: notAfter)
    }

    /// The whole SubjectPublicKeyInfo element (tag, length and content).
    static func subjectPublicKeyInfo(of der: Data) -> Data? {
        let bytes = [UInt8](der)
        guard let spki = spkiElement(bytes) else { return nil }
        return Data(bytes[spki.offset..<spki.end])
    }

    private static func spkiElement(_ bytes: [UInt8]) -> TLV? {
        guard let offset = validityOffset(bytes),
              let validity = read(bytes, at: offset), validity.tag == 0x30,
              let subject = read(bytes, at: validity.end), subject.tag == 0x30,
              let spki = read(bytes, at: subject.end), spki.tag == 0x30
        else { return nil }
        return spki
    }

    struct SubjectAltNames: Equatable {
        var dnsNames: [String] = []
        /// 4 or 16 bytes each.
        var ipAddresses: [Data] = []
    }

    /// The subject alternative names (DNS names and IP addresses), or nil
    /// when the certificate has none or can't be read.
    static func subjectAltNames(of der: Data) -> SubjectAltNames? {
        let bytes = [UInt8](der)
        guard let certificate = read(bytes, at: 0), let tbs = read(bytes, at: certificate.start),
              let spki = spkiElement(bytes)
        else { return nil }
        // After the SubjectPublicKeyInfo: [1] issuerUniqueID, [2]
        // subjectUniqueID, [3] extensions, each optional.
        var offset = spki.end
        while offset < tbs.end, let element = read(bytes, at: offset) {
            offset = element.end
            guard element.tag == 0xA3, let extensions = read(bytes, at: element.start), extensions.tag == 0x30 else { continue }
            var extensionOffset = extensions.start
            while extensionOffset < extensions.end, let ext = read(bytes, at: extensionOffset) {
                extensionOffset = ext.end
                guard ext.tag == 0x30, let oid = read(bytes, at: ext.start), oid.tag == 0x06,
                      Array(bytes[oid.start..<oid.end]) == [0x55, 0x1D, 0x11] // 2.5.29.17
                else { continue }
                // critical BOOLEAN DEFAULT FALSE, then extnValue OCTET STRING.
                var valueOffset = oid.end
                if let critical = read(bytes, at: valueOffset), critical.tag == 0x01 { valueOffset = critical.end }
                guard let value = read(bytes, at: valueOffset), value.tag == 0x04,
                      let names = read(bytes, at: value.start), names.tag == 0x30
                else { return nil }
                var result = SubjectAltNames()
                var nameOffset = names.start
                while nameOffset < names.end, let name = read(bytes, at: nameOffset) {
                    nameOffset = name.end
                    let content = Array(bytes[name.start..<name.end])
                    switch name.tag {
                    case 0x82: // dNSName
                        if let text = String(bytes: content, encoding: .ascii) { result.dnsNames.append(text) }
                    case 0x87: // iPAddress
                        if content.count == 4 || content.count == 16 { result.ipAddresses.append(Data(content)) }
                    default:
                        break
                    }
                }
                return result
            }
        }
        return nil
    }

    private static func read(_ bytes: [UInt8], at offset: Int) -> TLV? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1])
        var start = offset + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, start + count <= bytes.count else { return nil }
            length = 0
            for index in 0..<count {
                length = (length << 8) | Int(bytes[start + index])
            }
            start += count
        }
        guard length >= 0, start + length <= bytes.count else { return nil }
        return TLV(tag: tag, offset: offset, start: start, end: start + length)
    }

    /// UTCTime (`YYMMDDHHMMSSZ`, years 1950 to 2049 per RFC 5280) or
    /// GeneralizedTime (`YYYYMMDDHHMMSSZ`).
    private static func time(_ bytes: [UInt8], _ tlv: TLV) -> Date? {
        let text = bytes[tlv.start..<tlv.end]
        guard text.last == UInt8(ascii: "Z") else { return nil }
        let digits = text.dropLast()
        guard digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        let numbers = digits.map { Int($0 - UInt8(ascii: "0")) }
        func number(_ from: Int, _ count: Int) -> Int {
            numbers[from..<(from + count)].reduce(0) { $0 * 10 + $1 }
        }
        var components = DateComponents()
        let rest: Int
        switch (tlv.tag, numbers.count) {
        case (0x17, 12):
            let year = number(0, 2)
            components.year = year >= 50 ? 1900 + year : 2000 + year
            rest = 2
        case (0x18, 14):
            components.year = number(0, 4)
            rest = 4
        default:
            return nil
        }
        components.month = number(rest, 2)
        components.day = number(rest + 2, 2)
        components.hour = number(rest + 4, 2)
        components.minute = number(rest + 6, 2)
        components.second = number(rest + 8, 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }
}

/// Matches a host against a certificate's subject alternative names, the
/// way browsers and OkHttp do: DNS names case-insensitively with at most one
/// `*` as the whole left-most label (never matching across dots or a bare
/// suffix), IP addresses byte for byte, and no fallback to the common name.
enum HostName {
    static func matches(_ host: String, certificate der: Data) -> Bool {
        guard let names = DER.subjectAltNames(of: der) else { return false }
        return matches(host, names)
    }

    static func matches(_ host: String, _ names: DER.SubjectAltNames) -> Bool {
        if let address = ipAddress(host) {
            return names.ipAddresses.contains(address)
        }
        let name = normalized(host)
        guard !name.isEmpty else { return false }
        return names.dnsNames.contains { matches(name: name, pattern: normalized($0)) }
    }

    /// The bytes of an IPv4 or IPv6 literal, or nil for a name.
    static func ipAddress(_ host: String) -> Data? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Data($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Data($0) }
        }
        return nil
    }

    private static func normalized(_ name: String) -> String {
        var name = name.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    private static func matches(name: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        guard pattern.hasPrefix("*.") else { return name == pattern }
        let suffix = pattern.dropFirst(1) // ".example.local"
        // At least two labels after the wildcard, and the wildcard covers
        // exactly one non-empty label.
        guard suffix.dropFirst().contains("."), !suffix.dropFirst().contains("*"), name.hasSuffix(String(suffix)) else { return false }
        let label = name.dropLast(suffix.count)
        return !label.isEmpty && !label.contains(".")
    }
}
