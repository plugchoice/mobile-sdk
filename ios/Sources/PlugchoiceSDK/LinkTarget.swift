import Foundation
import os

/// What the Link screen opens (PROTOCOL §2): the hosted page for an
/// action, the only origin allowed for the bridge and for navigation, and
/// the action for the results the shell reports itself.
///
/// The URL is `https://connect.plugchoice.com/#action=<action>`, plus
/// `&charger_id=<id>` and `&site_id=<id>` when given, each value
/// percent-encoded. It never holds the client secret: the page asks for it
/// (`auth.clientSecret`).
struct LinkTarget: Equatable {
    static let host = "connect.plugchoice.com"
    static let origin = Origin(scheme: "https", host: host, port: nil)!

    let url: URL
    let allowedOrigin: Origin
    /// The action Link opened with (`LinkAction.action`).
    let action: String

    static let logger = Logger(subsystem: "com.plugchoice", category: "Plugchoice")

    /// - Parameter honourOverride: true in debug builds of the host app.
    init(action: LinkAction, hostOverride: String?, honourOverride: Bool) {
        self.action = action.action
        let host = Self.override(hostOverride, honour: honourOverride)
        var components = URLComponents()
        if let host {
            Self.logger.notice("[Plugchoice] hostOverride: loading from \(host.origin.description, privacy: .public)")
            components.scheme = host.scheme
            components.percentEncodedHost = host.percentEncodedHost
            components.port = host.port
            allowedOrigin = host.origin
        } else {
            components.scheme = "https"
            components.host = Self.host
            allowedOrigin = Self.origin
        }
        components.path = "/"
        components.percentEncodedFragment = Self.fragment(for: action)
        // Every part is checked or encoded above, so this always builds.
        url = components.url!
    }

    /// `action=…&charger_id=…&site_id=…`; empty ids are left out.
    static func fragment(for action: LinkAction) -> String {
        var pairs = [("action", action.action)]
        if let chargerId = action.chargerId, !chargerId.isEmpty {
            pairs.append(("charger_id", chargerId))
        }
        if let siteId = action.siteId, !siteId.isEmpty {
            pairs.append(("site_id", siteId))
        }
        return pairs.map { "\($0.0)=\(percentEncoded($0.1))" }.joined(separator: "&")
    }

    /// Everything but RFC 3986's unreserved characters, percent-encoded.
    static func percentEncoded(_ value: String) -> String {
        var unreserved = CharacterSet()
        unreserved.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func override(_ string: String?, honour: Bool) -> HostOverride? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        guard honour else {
            logger.notice("[Plugchoice] hostOverride is ignored outside debug builds")
            return nil
        }
        guard let host = HostOverride(string) else {
            logger.notice("[Plugchoice] hostOverride is not scheme://host[:port]; ignored")
            return nil
        }
        return host
    }
}

/// `options.hostOverride` (PROTOCOL §2 step 3): `http` or `https`, a host,
/// an optional port, nothing else (a trailing `/` is fine).
struct HostOverride: Equatable {
    let scheme: String
    let percentEncodedHost: String
    let port: Int?
    let origin: Origin

    init?(_ string: String) {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let encodedHost = components.percentEncodedHost, !encodedHost.isEmpty,
              let host = components.host,
              components.percentEncodedUser == nil,
              components.percentEncodedPassword == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil,
              let origin = Origin(scheme: scheme, host: host, port: components.port)
        else { return nil }
        self.scheme = scheme
        self.percentEncodedHost = encodedHost
        self.port = components.port
        self.origin = origin
    }
}
