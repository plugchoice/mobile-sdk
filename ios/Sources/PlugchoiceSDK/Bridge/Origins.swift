import Foundation

/// A web origin (scheme, host, port) with the scheme's default port filled in,
/// so `https://connect.plugchoice.com` and `https://connect.plugchoice.com:443`
/// match.
struct Origin: Hashable, CustomStringConvertible {
    let scheme: String
    let host: String
    let port: Int

    init?(scheme: String, host: String, port: Int?) {
        let scheme = scheme.lowercased()
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !scheme.isEmpty, !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        if let port, port > 0 {
            self.port = port
        } else {
            self.port = Origin.defaultPort(for: scheme) ?? 0
        }
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host
        else { return nil }
        self.init(scheme: scheme, host: host, port: components.port)
    }

    /// Parses `scheme://host[:port]`; any path, query or fragment is ignored.
    init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    var description: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        if port == 0 || port == Origin.defaultPort(for: scheme) {
            return "\(scheme)://\(hostPart)"
        }
        return "\(scheme)://\(hostPart):\(port)"
    }
}

/// The origins the shell accepts bridge messages from, delivers replies and
/// events to, and lets the main frame navigate to: one origin,
/// `https://connect.plugchoice.com`, or the debug `hostOverride`.
struct OriginAllowList {
    let origins: Set<Origin>

    init(_ origins: [Origin]) {
        self.origins = Set(origins)
    }

    func allows(_ origin: Origin?) -> Bool {
        guard let origin else { return false }
        return origins.contains(origin)
    }

    func allows(url: URL?) -> Bool {
        guard let url else { return false }
        return allows(Origin(url: url))
    }
}
