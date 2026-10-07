import Foundation

/// The host rules for every call that reaches a device (PROTOCOL §9.1): only
/// devices on the local network. Without it the bridge would be an open, CORS-free proxy for
/// any page that got loaded.
///
/// Allowed hosts: IPv4 literals in 10/8, 172.16/12, 192.168/16, 169.254/16
/// (link-local) and 127/8 (loopback), the IPv6 loopback `::1`, `localhost`,
/// and `*.local` (mDNS) names. IPv4 literals must be strict dotted quads
/// (no leading zeros, no shorthand like `10.1` or `167772161`), because the
/// system resolver would read those forms as other, possibly public, addresses.
enum LocalHostPolicy {
    static let httpSchemes: Set<String> = ["http", "https"]
    static let webSocketSchemes: Set<String> = ["ws", "wss"]

    /// Parses `string` and checks it against the allow-list.
    /// Throws `invalidParams` for an unparseable or relative URL,
    /// `forbiddenHost` for anything outside the allow-list (including another
    /// scheme).
    static func checkedURL(_ string: String, schemes: Set<String>) throws -> URL {
        guard let url = URL(string: string),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme != nil
        else {
            throw BridgeError.invalidParams("url is not an absolute URL")
        }
        guard let scheme = components.scheme?.lowercased(), schemes.contains(scheme) else {
            throw forbidden("scheme of \(string) is not one of \(schemes.sorted().joined(separator: ", "))")
        }
        guard let host = components.percentEncodedHost, isAllowedHost(host) else {
            throw forbidden("\(components.percentEncodedHost ?? "(no host)") is not a local network host")
        }
        return url
    }

    static func isAllowedHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        // Percent-encoded hosts are ambiguous; refuse them.
        if host.isEmpty || host.contains("%") { return false }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        if let octets = ipv4Octets(host) {
            return isPrivateOrLocal(octets)
        }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" { return true }
        if host.hasSuffix(".local") {
            let name = host.dropLast(".local".count)
            return !name.isEmpty && !name.hasSuffix(".") && name.allSatisfy(isHostNameCharacter)
        }
        return false
    }

    private static func isHostNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "." || character == "_")
    }

    /// A strict dotted-quad IPv4 literal, or nil.
    static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            if part.count > 1, part.hasPrefix("0") { return nil }
            guard let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    static func isPrivateOrLocal(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true                    // 10/8
        case (172, 16...31): return true             // 172.16/12
        case (192, 168): return true                 // 192.168/16
        case (169, 254): return true                 // link-local
        case (127, _): return true                   // loopback
        default: return false
        }
    }

    private static func forbidden(_ message: String) -> BridgeError {
        BridgeError(code: "forbiddenHost", message: message)
    }
}
