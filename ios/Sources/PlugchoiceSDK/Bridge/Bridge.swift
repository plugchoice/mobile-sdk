import Foundation
import UIKit
import WebKit

/// The bridge protocol (PROTOCOL.md) on iOS: parses requests from the page,
/// runs them, and sends exactly one response per request plus unsolicited
/// events.
///
/// Everything is tied to one page load ("generation"). When the main frame
/// commits a new document, `pageDidChange()` drops in-flight work and its
/// answers so nothing leaks into the new page.
@MainActor
final class Bridge {
    static let bridgeVersion = 1

    /// `session.close` (PROTOCOL §6.1).
    struct SessionClose: Equatable {
        let status: LinkResult.Status
        let action: String
        let sessionId: String?
        let devices: [Device]
        let error: LinkError?
    }

    weak var webView: WKWebView?
    /// Presents the `camera.scanCode` scanner.
    weak var presenter: UIViewController?
    /// `hello` was answered: the page draws its own close control and
    /// decides about native closes from now on.
    var onHello: (() -> Void)?
    /// `ui.closeHandled`: the page is asking the user itself.
    var onCloseHandled: (() -> Void)?
    /// The page asked to close (`session.close`).
    var onSessionClose: ((SessionClose) -> Void)?

    private let allowList: OriginAllowList
    private let secrets: ClientSecrets
    private let wifi = WifiService()
    private lazy var http = HTTPService()
    private lazy var scanner = CodeScanner()
    private lazy var webSockets = WebSocketService { [weak self] event, params in
        self?.emit(event, params)
    }
    private lazy var discovery = LanDiscovery()
    private lazy var sessions = HTTPSessions()
    private lazy var tcp = TCPSockets { [weak self] event, params in
        self?.emit(event, params)
    }
    private lazy var udp = UDPExchanges()
    private lazy var bluetooth = BluetoothService { [weak self] event, params in
        self?.emit(event, params)
    }
    private var generation = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// `wifi.routeTraffic`: iOS routes the charger's subnet over Wi-Fi by
    /// itself; sessions opened while it is on stay off cellular.
    private var routeTraffic = false
    private var isShutDown = false

    init(allowList: OriginAllowList, secrets: ClientSecrets) {
        self.allowList = allowList
        self.secrets = secrets
    }

    // MARK: - Incoming

    func didReceive(_ message: WKScriptMessage) {
        guard !isShutDown else { return }
        // Main frame of an allowed origin only; everything else is dropped
        // silently.
        guard message.frameInfo.isMainFrame else { return }
        let securityOrigin = message.frameInfo.securityOrigin
        let origin = Origin(scheme: securityOrigin.protocol, host: securityOrigin.host, port: securityOrigin.port)
        guard allowList.allows(origin) else {
            log("dropped a message from \(origin?.description ?? "an unknown origin")")
            return
        }

        guard let object = Self.decode(message.body) else {
            log("dropped a message that is not a JSON object in a string")
            return
        }
        guard object["type"] as? String == "request", let id = object["id"] as? String else {
            log("dropped a message that is not a request with an id")
            return
        }
        let reply = Reply(bridge: self, id: id, generation: generation)
        guard let method = object["method"] as? String else {
            reply.fail(.invalidParams("method must be a string"))
            return
        }
        let params: JSONObject
        switch object["params"] {
        case nil, is NSNull:
            params = [:]
        case let object as JSONObject:
            params = object
        default:
            reply.fail(.invalidParams("params must be an object"))
            return
        }
        dispatch(method: method, params: Params(params), reply: reply)
    }

    /// The page posts each message as a JSON string (PROTOCOL §3).
    static func decode(_ body: Any) -> JSONObject? {
        guard let string = body as? String, let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    // MARK: - Methods

    private func dispatch(method: String, params: Params, reply: Reply) {
        do {
            switch method {
            case "hello":
                // `{}`; anything else in it is ignored.
                reply.succeed(Self.helloResult())
                onHello?()

            case "wifi.ensurePermissions":
                run(reply) { [wifi] in await wifi.ensurePermissions() }

            case "wifi.join":
                let ssid = try params.string("ssid")
                guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
                    throw BridgeError.invalidParams("ssid must be 1 to 32 bytes")
                }
                let request = WifiService.JoinRequest(
                    ssid: ssid,
                    password: try params.string("password", allowEmpty: true),
                    timeoutMs: try params.timeoutMs(),
                    displayName: try params.optionalString("displayName").flatMap { $0.isEmpty ? nil : $0 },
                    productImageUrl: try params.optionalString("productImageUrl").flatMap { $0.isEmpty ? nil : $0 }
                )
                run(reply) { [wifi] in try await wifi.join(request) }

            case "wifi.leave":
                wifi.leave(ssid: try params.string("ssid"))
                routeTraffic = false
                reply.succeed([:])

            case "wifi.currentSsid":
                run(reply) { [wifi] in
                    let ssid = await wifi.currentSsid()
                    return ["ssid": ssid.map { $0 as Any } ?? NSNull()]
                }

            case "wifi.routeTraffic":
                // iOS routes the hotspot's subnet over Wi-Fi by itself; only
                // http.session takes note (it then stays off cellular).
                routeTraffic = try params.bool("enabled")
                reply.succeed([:])

            case "http.request":
                try http.start(try Self.httpRequest(params)) { result in reply.finish(result) }

            case "http.cancel":
                http.cancel(requestId: try params.string("requestId"))
                reply.succeed([:])

            case "ws.open":
                let request = try Self.webSocketOpenRequest(params)
                try webSockets.open(socketId: request.socketId, url: request.url, headers: request.headers, trust: request.trust)
                reply.succeed([:])

            case "ws.send":
                try webSockets.send(socketId: try params.string("socketId"), data: try params.string("data", allowEmpty: true)) { result in
                    reply.finish(result)
                }

            case "ws.close":
                // Answer first; the socket's final ws.close event follows.
                let socketId = try params.string("socketId")
                reply.succeed([:])
                webSockets.close(socketId: socketId)

            case "session.close":
                let close = try Self.sessionClose(params, openedAction: secrets.action.action)
                reply.succeed([:])
                // Let the response go out before the screen is torn down.
                DispatchQueue.main.async { [weak self] in
                    self?.onSessionClose?(close)
                }

            case "ui.closeHandled":
                reply.succeed([:])
                onCloseHandled?()

            case "auth.clientSecret":
                // Never logged: the secret only goes into the answer.
                run(reply) { [secrets] in
                    ["clientSecret": try await secrets.clientSecret()]
                }

            case "camera.scanCode":
                let request = try Self.scanRequest(params)
                let presenter = presenter
                run(reply) { [scanner, weak presenter] in
                    try await scanner.scan(request, from: presenter)
                }

            case "lan.discover":
                let request = try Self.discoverRequest(params)
                try discovery.discover(types: request.types, timeoutMs: request.timeoutMs, stopOnName: request.stopOnName) { result in
                    reply.finish(result)
                }

            case "lan.stopDiscovery":
                // Answer first; the running lan.discover answers next.
                reply.succeed([:])
                discovery.stop()

            case "lan.address":
                reply.succeed(SocketAddress.wifiAddress())

            case "http.session.open":
                try sessions.open(try Self.sessionOpenRequest(params, routeTraffic: routeTraffic)) { result in
                    reply.finish(result)
                }

            case "http.session.request":
                let (sessionId, request) = try Self.sessionRequest(params)
                try sessions.request(sessionId: sessionId, request) { result in
                    reply.finish(result)
                }

            case "http.session.close":
                sessions.close(sessionId: try params.string("sessionId"))
                reply.succeed([:])

            case "tcp.open":
                try tcp.open(try Self.tcpOpenRequest(params, routeTraffic: routeTraffic)) { result in
                    reply.finish(result)
                }

            case "tcp.write":
                let socketId = try params.string("socketId")
                let data = try params.base64("data")
                try tcp.write(socketId: socketId, data: data) { result in
                    reply.finish(result)
                }

            case "tcp.close":
                // Answer first; the socket's final tcp.close event follows.
                let socketId = try params.string("socketId")
                reply.succeed([:])
                tcp.close(socketId: socketId)

            case "udp.exchange":
                udp.exchange(try Self.udpExchangeRequest(params, routeTraffic: routeTraffic)) { result in
                    reply.finish(result)
                }

            case "ble.ensurePermissions":
                run(reply) { [bluetooth] in
                    try await bluetooth.ensureReady()
                    return [:]
                }

            case "ble.scan":
                let request = try Self.bleScanRequest(params)
                run(reply) { [bluetooth] in try await bluetooth.scan(request) }

            case "ble.stopScan":
                // Answer first; the running ble.scan answers next.
                reply.succeed([:])
                bluetooth.stopScan()

            case "ble.connect":
                let request = try Self.bleConnectRequest(params)
                run(reply) { [bluetooth] in try await bluetooth.connect(deviceId: request.deviceId, timeoutMs: request.timeoutMs) }

            case "ble.read":
                let request = try Self.bleCharacteristicRequest(params)
                run(reply) { [bluetooth] in try await bluetooth.read(request) }

            case "ble.write":
                let (request, value, withResponse) = try Self.bleWriteRequest(params)
                run(reply) { [bluetooth] in try await bluetooth.write(request, value: value, withResponse: withResponse) }

            case "ble.subscribe", "ble.unsubscribe":
                let request = try Self.bleCharacteristicRequest(params)
                let enabled = method == "ble.subscribe"
                run(reply) { [bluetooth] in try await bluetooth.setNotify(enabled, request) }

            case "ble.disconnect":
                // Answer first; a connected device's ble.disconnected follows.
                let deviceId = try params.string("deviceId")
                reply.succeed([:])
                bluetooth.disconnect(deviceId: deviceId)

            default:
                throw BridgeError.unsupportedMethod(method)
            }
        } catch {
            reply.fail(BridgeError.from(error))
        }
    }

    /// `hello`'s answer (PROTOCOL §5). `declaredServiceTypes` and
    /// `bluetoothAvailable` are for tests.
    static func helloResult(
        declaredServiceTypes: [String] = LanDiscovery.declaredServiceTypes,
        bluetoothAvailable: Bool = BluetoothSupport.isAvailable
    ) -> JSONObject {
        var capabilities = ["wifi.join", "http.request", "ws", "session.close"]
        if WifiService.accessoryJoinAvailable {
            capabilities.insert("wifi.accessory", at: 1)
        }
        if CodeScanner.isAvailable {
            capabilities.append("camera.scanCode")
        }
        capabilities += ["ui.closeRequest", "lan.address"]
        // iOS refuses to browse a type the host's Info.plist doesn't declare.
        if LanDiscovery.isAvailable(declared: declaredServiceTypes) {
            capabilities.append("lan.discover")
        }
        capabilities += ["http.session", "auth.clientSecret"]
        if bluetoothAvailable {
            capabilities.append("ble")
        }
        capabilities += ["tcp", "udp", "trust.custom"]
        return [
            "bridgeVersion": bridgeVersion,
            "sdkVersion": Plugchoice.sdkVersion,
            "platform": "ios",
            "osVersion": UIDevice.current.systemVersion,
            "capabilities": capabilities,
            "lanServiceTypes": declaredServiceTypes,
        ]
    }

    /// `session.close` params (PROTOCOL §6.1). Without an `action`, the one
    /// the screen opened with (`openedAction`).
    static func sessionClose(_ params: Params, openedAction: String) throws -> SessionClose {
        let rawStatus = try params.string("status")
        guard let status = LinkResult.Status(rawValue: rawStatus) else {
            throw BridgeError.invalidParams("status must be success, cancelled or error")
        }
        let action = try params.optionalString("action").flatMap { $0.isEmpty ? nil : $0 } ?? openedAction
        var devices: [Device] = []
        if let raw = params.raw["devices"], !(raw is NSNull) {
            guard let list = raw as? [Any] else {
                throw BridgeError.invalidParams("devices must be an array of { type, id }")
            }
            devices = try list.map { item in
                guard let object = item as? JSONObject,
                      let type = object["type"] as? String, !type.isEmpty,
                      let id = object["id"] as? String, !id.isEmpty
                else {
                    throw BridgeError.invalidParams("devices must be an array of { type, id } with non-empty strings")
                }
                return Device(type: type, id: id)
            }
        }
        var error: LinkError?
        if let object = try params.optionalObject("error") {
            guard let code = object["code"] as? String, !code.isEmpty else {
                throw BridgeError.invalidParams("error.code is required and must be a string")
            }
            let message = object["message"]
            guard message == nil || message is NSNull || message is String else {
                throw BridgeError.invalidParams("error.message must be a string")
            }
            error = LinkError(code: code, message: message as? String)
        }
        return SessionClose(
            status: status,
            action: action,
            sessionId: try params.optionalString("sessionId").flatMap { $0.isEmpty ? nil : $0 },
            devices: devices,
            error: error
        )
    }

    static func scanRequest(_ params: Params) throws -> CodeScanner.Request {
        let formats = try params.stringArray("formats")
        guard !formats.isEmpty, formats.allSatisfy({ $0 == "qr" }) else {
            throw BridgeError.invalidParams("formats must be [\"qr\"]")
        }
        return CodeScanner.Request(
            title: try params.optionalString("title").flatMap { $0.isEmpty ? nil : $0 },
            hint: try params.optionalString("hint").flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    struct DiscoverRequest: Equatable {
        let types: [String]
        let timeoutMs: Int
        let stopOnName: String?
    }

    /// `lan.discover` params (PROTOCOL §9.4). `declared`: the types in the
    /// host's `NSBonjourServices`.
    static func discoverRequest(_ params: Params, declared: [String] = LanDiscovery.declaredServiceTypes) throws -> DiscoverRequest {
        let types = try params.stringArray("types")
        let timeoutMs = try params.timeoutMs()
        let stopOnName = try params.optionalString("stopOnName").flatMap { $0.isEmpty ? nil : $0 }
        return DiscoverRequest(
            types: try LanDiscovery.checkedTypes(types, declared: declared),
            timeoutMs: timeoutMs,
            stopOnName: stopOnName
        )
    }

    /// `http.request` params (PROTOCOL §9.2, §9.8).
    static func httpRequest(_ params: Params) throws -> HTTPService.Request {
        let method = try params.string("method").uppercased()
        guard HTTPService.methods.contains(method) else {
            throw BridgeError.invalidParams("method must be one of \(HTTPService.methods.sorted().joined(separator: ", "))")
        }
        let requestId = try params.string("requestId")
        let headers = try checkedHeaders(params)
        let body = try params.optionalString("body")
        if method == "GET", let body, !body.isEmpty {
            throw BridgeError.invalidParams("a GET request cannot have a body")
        }
        let timeoutMs = try params.timeoutMs()
        let trust = try Trust.parse(params.raw["trust"])
        return HTTPService.Request(
            requestId: requestId,
            url: try LocalHostPolicy.checkedURL(try params.string("url"), schemes: LocalHostPolicy.httpSchemes),
            method: method,
            headers: headers,
            body: method == "GET" ? nil : body,
            timeoutMs: timeoutMs,
            trust: trust,
            responseBody: try responseBody(params)
        )
    }

    /// `responseBody` (absent: `text`): the body as UTF-8 text, or as base64
    /// of its bytes (PROTOCOL §9.2).
    static func responseBody(_ params: Params) throws -> HTTP1.ResponseBody {
        guard let value = try params.optionalString("responseBody") else { return .text }
        guard let encoding = HTTP1.ResponseBody(rawValue: value) else {
            throw BridgeError.invalidParams("responseBody must be text or base64")
        }
        return encoding
    }

    struct WebSocketOpenRequest {
        let socketId: String
        let url: URL
        let headers: [String: String]
        let trust: Trust?
    }

    /// `ws.open` params (PROTOCOL §9.3, §9.8).
    static func webSocketOpenRequest(_ params: Params) throws -> WebSocketOpenRequest {
        let socketId = try params.string("socketId")
        let headers = try checkedHeaders(params)
        let trust = try Trust.parse(params.raw["trust"])
        return WebSocketOpenRequest(
            socketId: socketId,
            url: try LocalHostPolicy.checkedURL(try params.string("url"), schemes: LocalHostPolicy.webSocketSchemes),
            headers: headers,
            trust: trust
        )
    }

    /// A connect-and-handshake `timeoutMs` (PROTOCOL §9.5, §9.6): the default when
    /// absent, any positive number clamped to `range`.
    static func handshakeTimeoutMs(_ params: Params, default defaultMs: Int = HTTPSessions.defaultOpenTimeoutMs, range: ClosedRange<Int> = HTTPSessions.openTimeoutRange) throws -> Int {
        guard params.raw["timeoutMs"] != nil, !(params.raw["timeoutMs"] is NSNull) else { return defaultMs }
        // Any positive number; the range keeps a page from waiting forever
        // or giving a handshake no chance.
        let value = try params.number("timeoutMs")
        guard value > 0 else {
            throw BridgeError.invalidParams("timeoutMs must be a positive number")
        }
        return Int(min(max(value.rounded(.up), Double(range.lowerBound)), Double(range.upperBound)))
    }

    /// A device host (PROTOCOL §9.1): private, link-local or loopback IPv4, `::1`,
    /// `localhost` or `*.local`, without IPv6 brackets.
    static func checkedDeviceHost(_ host: String) throws -> String {
        guard LocalHostPolicy.isAllowedHost(host) else {
            throw BridgeError(code: "forbiddenHost", message: "\(host) is not a local network host")
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            return String(host.dropFirst().dropLast())
        }
        return host
    }

    /// `http.session.open` params (PROTOCOL §9.5): the host rules, port 443
    /// by default, the trust (a trust object, or the system's when absent),
    /// and a handshake timeout clamped to `HTTPSessions.openTimeoutRange`.
    /// Params are checked before the host.
    static func sessionOpenRequest(_ params: Params, routeTraffic: Bool = false) throws -> HTTPSessions.OpenRequest {
        let host = try params.string("host")
        let port = try params.optionalInteger("port", in: 1...65535) ?? 443
        let timeoutMs = try handshakeTimeoutMs(params)
        let trust = try Trust.parse(params.raw["trust"])
        return HTTPSessions.OpenRequest(
            host: try checkedDeviceHost(host),
            port: port,
            trust: trust,
            timeoutMs: timeoutMs,
            routeTraffic: routeTraffic
        )
    }

    /// `tcp.open` params (PROTOCOL §9.6): host rules as `http.session`, a port, the
    /// handshake timeout, and optional TLS with a trust and a server name.
    /// Params are checked before the host.
    static func tcpOpenRequest(_ params: Params, routeTraffic: Bool = false) throws -> TCPSockets.OpenRequest {
        let socketId = try params.string("socketId")
        guard !socketId.isEmpty else {
            throw BridgeError.invalidParams("socketId must not be empty")
        }
        let host = try params.string("host")
        guard let port = try params.optionalInteger("port", in: 1...65535) else {
            throw BridgeError.invalidParams("port is required and must be a whole number from 1 to 65535")
        }
        let timeoutMs = try handshakeTimeoutMs(params)
        var tls: DeviceTLS?
        if let object = try params.optionalObject("tls") {
            let options = Params(object)
            let serverName = try options.optionalString("serverName")
            if let serverName {
                guard isServerName(serverName) else {
                    throw BridgeError.invalidParams("tls.serverName must be a host name")
                }
            }
            tls = DeviceTLS(trust: try Trust.parse(object["trust"], key: "tls.trust"), serverName: serverName)
        }
        return TCPSockets.OpenRequest(
            socketId: socketId,
            host: try checkedDeviceHost(host),
            port: port,
            timeoutMs: timeoutMs,
            tls: tls,
            routeTraffic: routeTraffic
        )
    }

    /// A DNS name (letters, digits, `-`, `_`, dots) or an IP literal.
    static func isServerName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        if HostName.ipAddress(name) != nil { return true }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// `udp.exchange` params (PROTOCOL §9.7): host rules as `tcp.open`, unicast only.
    static func udpExchangeRequest(_ params: Params, routeTraffic: Bool = false) throws -> UDPExchanges.Request {
        let host = try params.string("host")
        guard let port = try params.optionalInteger("port", in: 1...65535) else {
            throw BridgeError.invalidParams("port is required and must be a whole number from 1 to 65535")
        }
        let data = try params.base64("data")
        guard data.count <= UDPExchanges.maxDatagramBytes else {
            throw BridgeError.invalidParams("data must be at most \(UDPExchanges.maxDatagramBytes) bytes")
        }
        let timeoutMs = try clampedTimeoutMs(params, range: UDPExchanges.timeoutRange)
        let maxReplies = try params.optionalInteger("maxReplies", in: UDPExchanges.maxRepliesRange) ?? 1
        if let octets = LocalHostPolicy.ipv4Octets(host), octets[0] >= 224 {
            // 224/4 multicast, 240/4 reserved, 255.255.255.255 broadcast.
            throw BridgeError(code: "forbiddenHost", message: "\(host) is not a unicast address")
        }
        return UDPExchanges.Request(
            host: try checkedDeviceHost(host),
            port: port,
            data: data,
            timeoutMs: timeoutMs,
            maxReplies: maxReplies,
            routeTraffic: routeTraffic
        )
    }

    /// A required `timeoutMs`: any positive number, clamped to `range`.
    static func clampedTimeoutMs(_ params: Params, range: ClosedRange<Int>) throws -> Int {
        let value = try params.number("timeoutMs")
        guard value > 0 else {
            throw BridgeError.invalidParams("timeoutMs must be a positive number")
        }
        return Int(min(max(value.rounded(.up), Double(range.lowerBound)), Double(range.upperBound)))
    }

    /// `ble.scan` params (PROTOCOL §11): `services` as the scan filter (absent or
    /// empty: every device), `timeoutMs` clamped to 1 s to 60 s.
    static func bleScanRequest(_ params: Params) throws -> BluetoothService.ScanRequest {
        let services = try params.optionalStringArray("services")?.enumerated().map { index, text in
            try BLEUUID.parse(text, key: "services[\(index)]")
        }
        return BluetoothService.ScanRequest(
            services: (services?.isEmpty ?? true) ? nil : services,
            timeoutMs: try clampedTimeoutMs(params, range: BluetoothService.timeoutRange),
            stopOnName: try params.optionalString("stopOnName").flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// `ble.connect` params (PROTOCOL §11). `mtu` is checked but iOS negotiates the
    /// MTU by itself.
    static func bleConnectRequest(_ params: Params) throws -> (deviceId: String, timeoutMs: Int) {
        let deviceId = try params.string("deviceId")
        let timeoutMs = try clampedTimeoutMs(params, range: BluetoothService.timeoutRange)
        _ = try params.optionalInteger("mtu", in: 23...517)
        return (deviceId, timeoutMs)
    }

    /// `{ deviceId, service, characteristic }` (PROTOCOL §11).
    static func bleCharacteristicRequest(_ params: Params) throws -> BluetoothService.CharacteristicRequest {
        BluetoothService.CharacteristicRequest(
            deviceId: try params.string("deviceId"),
            service: try BLEUUID.parse(try params.string("service"), key: "service"),
            characteristic: try BLEUUID.parse(try params.string("characteristic"), key: "characteristic")
        )
    }

    /// `ble.write` params (PROTOCOL §11): at most 512 bytes; whether a write without
    /// response fits is checked on the connection.
    static func bleWriteRequest(_ params: Params) throws -> (BluetoothService.CharacteristicRequest, Data, Bool) {
        let request = try bleCharacteristicRequest(params)
        let value = try params.base64("value")
        guard value.count <= BluetoothService.maxValueBytes else {
            throw BridgeError.invalidParams("value must be at most \(BluetoothService.maxValueBytes) bytes")
        }
        return (request, value, try params.bool("withResponse"))
    }

    /// `http.session.request` params (PROTOCOL §9.5).
    static func sessionRequest(_ params: Params) throws -> (sessionId: String, request: HTTPSessions.Request) {
        let sessionId = try params.string("sessionId")
        let method = try params.string("method").uppercased()
        guard HTTPSessions.methods.contains(method) else {
            throw BridgeError.invalidParams("method must be one of \(HTTPSessions.methods.sorted().joined(separator: ", "))")
        }
        let path = try params.string("path")
        guard HTTP1.isValidPath(path) else {
            throw BridgeError.invalidParams("path must start with / and hold printable ASCII without spaces or #")
        }
        let headers = try checkedHeaders(params)
        let body = try params.optionalString("body")
        if method == "GET", let body, !body.isEmpty {
            throw BridgeError.invalidParams("a GET request cannot have a body")
        }
        let request = HTTPSessions.Request(
            method: method,
            path: path,
            headers: headers,
            body: method == "GET" ? nil : body,
            timeoutMs: try params.timeoutMs(),
            responseBody: try responseBody(params)
        )
        return (sessionId, request)
    }

    /// `headers` (absent: none): names are tokens, values visible ASCII,
    /// spaces and tabs (PROTOCOL §9.1).
    static func checkedHeaders(_ params: Params) throws -> [String: String] {
        let headers = try params.stringMap("headers")
        for (name, value) in headers {
            guard HTTP1.isValidHeaderName(name), HTTP1.isValidHeaderValue(value) else {
                throw BridgeError.invalidParams("headers.\(name) is not a valid header")
            }
        }
        return headers
    }

    /// Runs an async method and answers with its outcome.
    private func run(_ reply: Reply, _ body: @escaping @MainActor () async throws -> JSONObject) {
        let key = UUID()
        let task = Task { @MainActor [weak self] in
            do {
                reply.succeed(try await body())
            } catch {
                reply.fail(BridgeError.from(error))
            }
            self?.tasks.removeValue(forKey: key)
        }
        tasks[key] = task
    }

    // MARK: - Outgoing

    fileprivate func send(_ message: JSONObject, generation: Int) {
        guard !isShutDown, generation == self.generation, let webView else { return }
        // Only deliver to a page from an allowed origin.
        guard allowList.allows(url: webView.url) else { return }
        do {
            let script = try BridgeScript.receive(message)
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    Self.log("receive() failed: \(error.localizedDescription)")
                }
            }
        } catch {
            log("could not encode a message: \(error)")
        }
    }

    func emit(_ event: String, _ params: JSONObject) {
        send(["type": "event", "event": event, "params": params], generation: generation)
    }

    // MARK: - Lifecycle

    /// The main frame committed a new document: whatever the old page started
    /// is cancelled, and its answers are dropped.
    func pageDidChange() {
        generation += 1
        cancelInFlight()
    }

    /// The Link screen closes: everything stops, every session closes.
    func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true
        cancelInFlight()
        http.invalidate()
        webSockets.invalidate()
        bluetooth.shutDown()
    }

    private func cancelInFlight() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        http.cancelAll()
        webSockets.closeAll()
        discovery.cancel()
        sessions.closeAll()
        tcp.closeAll()
        udp.cancelAll()
        bluetooth.pageDidChange()
    }

    private func log(_ message: String) {
        Self.log(message)
    }

    nonisolated static func log(_ message: String) {
        #if DEBUG
        print("[Plugchoice] \(message)")
        #endif
    }
}

/// One request's answer; sends at most one response.
@MainActor
private final class Reply {
    private weak var bridge: Bridge?
    let id: String
    private let generation: Int
    private var answered = false

    init(bridge: Bridge, id: String, generation: Int) {
        self.bridge = bridge
        self.id = id
        self.generation = generation
    }

    func succeed(_ result: JSONObject) {
        answer(["type": "response", "id": id, "ok": true, "result": result])
    }

    func fail(_ error: BridgeError) {
        answer(["type": "response", "id": id, "ok": false, "error": error.json])
    }

    func finish(_ result: Result<JSONObject, BridgeError>) {
        switch result {
        case .success(let value): succeed(value)
        case .failure(let error): fail(error)
        }
    }

    private func answer(_ message: JSONObject) {
        guard !answered else { return }
        answered = true
        bridge?.send(message, generation: generation)
    }
}
