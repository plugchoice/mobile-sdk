import Network
import Security
import XCTest
@testable import PlugchoiceSDK

/// `http.session`, and `http.request` and `ws.open` with a trust, end to end
/// over real TLS, against a local server that presents the test
/// certificates (see TrustTests).
@MainActor
final class TLSSessionTests: XCTestCase {
    private var server: LocalTLSServer!
    private var sessions: HTTPSessions!

    override func setUp() async throws {
        try await super.setUp()
        sessions = HTTPSessions()
    }

    override func tearDown() async throws {
        sessions.closeAll()
        server?.stop()
        server = nil
        try await super.tearDown()
    }

    private func open(trust: Trust?, port: Int? = nil) async throws -> Result<JSONObject, BridgeError> {
        let answers = Answers()
        try sessions.open(
            HTTPSessions.OpenRequest(host: "127.0.0.1", port: port ?? server.port, trust: trust),
            completion: answers.add
        )
        try await waitUntil { !answers.results.isEmpty }
        return answers.results[0]
    }

    private func request(_ sessionId: String, _ request: HTTPSessions.Request) async throws -> Result<JSONObject, BridgeError> {
        let answers = Answers()
        try sessions.request(sessionId: sessionId, request, completion: answers.add)
        try await waitUntil { !answers.results.isEmpty }
        return answers.results[0]
    }

    func testAnExpiredLeafForAnotherHostVerifiesAgainstItsAnchor() async throws {
        server = try await LocalTLSServer.start(identity: "test-leaf-expired")
        server.responses = [
            "HTTP/1.1 200 OK\r\nContent-Type: alfen/json\r\nContent-Length: 17\r\n\r\n{\"Model\":\"NG910\"}",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        ]
        let opened = try await open(trust: TrustTests.chargerCATrust()).get()
        let sessionId = try XCTUnwrap(opened["sessionId"] as? String)

        let info = try await request(sessionId, HTTPSessions.Request(method: "GET", path: "/api/info", headers: ["Accept": "application/json"], body: nil, timeoutMs: 5_000)).get()
        XCTAssertEqual(info["status"] as? Int, 200)
        XCTAssertEqual(info["body"] as? String, "{\"Model\":\"NG910\"}")
        XCTAssertEqual((info["headers"] as? [String: String])?["content-type"], "alfen/json")

        let login = try await request(sessionId, HTTPSessions.Request(method: "POST", path: "/api/login", headers: ["Content-Type": "application/json"], body: "{\"username\":\"admin\"}", timeoutMs: 5_000)).get()
        XCTAssertEqual(login["status"] as? Int, 200)

        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(server.requests[0].hasPrefix("GET /api/info HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n"))
        XCTAssertTrue(server.requests[1].contains("\r\nContent-Length: 20\r\n\r\n{\"username\":\"admin\"}"))
        XCTAssertEqual(server.connectionCount, 1, "both requests on the one connection open made")
    }

    func testASelfSignedDeviceFailsWithTLS() async throws {
        server = try await LocalTLSServer.start(identity: "test-self-signed")
        let result = try await open(trust: TrustTests.chargerCATrust())
        XCTAssertEqual(result.errorCode, "tls")
        XCTAssertEqual(sessions.count, 0)
    }

    func testAnotherCAsAnchorRefusesTheDevice() async throws {
        server = try await LocalTLSServer.start(identity: "test-leaf-expired")
        let otherCA = try TrustTests.trust(["anchors": [try TrustTests.pem("test-device-ca")], "ignoreExpiry": true, "ignoreHostname": true])
        let result = try await open(trust: otherCA)
        XCTAssertEqual(result.errorCode, "tls")
    }

    func testNothingListeningFailsWithNetwork() async throws {
        // Find a free port, then close it again.
        let probe = try await LocalTLSServer.start(identity: "test-self-signed")
        let port = probe.port
        probe.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let result = try await open(trust: TrustTests.chargerCATrust(), port: port)
        XCTAssertEqual(result.errorCode, "network")
    }

    func testOpenGivesUpAfterItsTimeout() async throws {
        // A device that accepts TCP but never answers the TLS handshake.
        let silent = try await SilentTCPServer.start()
        defer { silent.stop() }
        let answers = Answers()
        let started = Date()
        try sessions.open(
            HTTPSessions.OpenRequest(host: "127.0.0.1", port: silent.port, trust: TrustTests.chargerCATrust(), timeoutMs: 500),
            completion: answers.add
        )
        try await waitUntil { !answers.results.isEmpty }
        XCTAssertEqual(answers.errorCodes, ["timeout"])
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.45)
        XCTAssertLessThan(elapsed, 3, "the page's timeoutMs, not the default 10 s")
    }

    func testRouteTrafficKeepsSessionsOffCellular() throws {
        let tls = DeviceTLS(trust: try TrustTests.chargerCATrust(), serverName: nil)
        XCTAssertEqual(DeviceConnection.parameters(host: "10.0.0.2", tls: tls, routeTraffic: true).prohibitedInterfaceTypes, [.cellular])
        XCTAssertEqual(DeviceConnection.parameters(host: "10.0.0.2", tls: tls, routeTraffic: false).prohibitedInterfaceTypes ?? [], [])
        XCTAssertTrue(DeviceConnection.parameters(host: "10.0.0.2", tls: tls, routeTraffic: true).preferNoProxies)
    }

    func testAMissingLocalNetworkPermissionIsLocalNetworkDenied() {
        func code(_ error: NWError, _ reason: NWPath.UnsatisfiedReason? = nil, trustRejected: Bool = false) -> String {
            let verification = TLSVerification(pageTrust: true)
            if trustRejected { verification.reject(presentedFingerprint: nil) }
            return DeviceConnection.openFailure(error, unsatisfiedReason: reason, verification: verification).code
        }
        XCTAssertEqual(code(.dns(-65570)), "localNetworkDenied", "kDNSServiceErr_PolicyDenied")
        XCTAssertEqual(code(.posix(.ENETUNREACH), .localNetworkDenied), "localNetworkDenied")
        XCTAssertEqual(code(.posix(.ECONNREFUSED)), "network")
        XCTAssertEqual(code(.posix(.EHOSTUNREACH), .notAvailable), "network")
        XCTAssertEqual(code(.posix(.ETIMEDOUT)), "timeout")
        XCTAssertEqual(code(.tls(-9808), trustRejected: true), "tls")
        XCTAssertEqual(code(.tls(-9836)), "network", "a handshake failure that isn't the certificate")
    }

    // MARK: - Trust objects (§9.8)

    func testATLSErrorCarriesThePresentedFingerprint() async throws {
        server = try await LocalTLSServer.start(identity: "test-self-signed")
        let result = try await open(trust: TrustTests.chargerCATrust())
        guard case .failure(let error) = result else { return XCTFail("expected tls") }
        XCTAssertEqual(error.code, "tls")
        XCTAssertEqual(error.details, ["presentedFingerprint": TrustTests.expiredLeafFingerprint])
        XCTAssertEqual(error.json["details"] as? [String: String], ["presentedFingerprint": TrustTests.expiredLeafFingerprint])
    }

    func testAPinnedSelfSignedDevice() async throws {
        server = try await LocalTLSServer.start(identity: "test-self-signed")
        server.responses = ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"]
        // test-self-signed names no host: the page says not to check it.
        let pinned = try TrustTests.trust(["fingerprints": [TrustTests.expiredLeafFingerprint], "ignoreHostname": true])
        let opened = try await open(trust: pinned).get()
        let sessionId = try XCTUnwrap(opened["sessionId"] as? String)
        let answer = try await request(sessionId, HTTPSessions.Request(method: "GET", path: "/", headers: [:], body: nil, timeoutMs: 5_000)).get()
        XCTAssertEqual(answer["body"] as? String, "ok")
    }

    func testAPinnedDeviceForAnotherHostFailsWithTLS() async throws {
        server = try await LocalTLSServer.start(identity: "test-self-signed")
        let pinned = try TrustTests.trust(["fingerprints": [TrustTests.expiredLeafFingerprint]])
        let result = try await open(trust: pinned)
        guard case .failure(let error) = result else { return XCTFail("expected tls") }
        XCTAssertEqual(error.code, "tls", "the pin doesn't skip the host-name check")
        XCTAssertEqual(error.details, ["presentedFingerprint": TrustTests.expiredLeafFingerprint])
    }

    func testAValidLeafForItsHostVerifiesAgainstItsCA() async throws {
        server = try await LocalTLSServer.start(identity: "test-leaf-localhost")
        let anchored = try TrustTests.trust(["anchors": [try TrustTests.pem("test-device-ca")]])
        let opened = try await open(trust: anchored).get()
        XCTAssertNotNil(opened["sessionId"] as? String, "127.0.0.1 is in the leaf")
    }

    func testWithoutATrustTheSystemsTrustRefusesADevice() async throws {
        server = try await LocalTLSServer.start(identity: "test-leaf-localhost")
        let result = try await open(trust: nil)
        guard case .failure(let error) = result else { return XCTFail("expected tls") }
        XCTAssertEqual(error.code, "tls")
        XCTAssertEqual(error.details?["presentedFingerprint"], TrustTests.localhostLeafFingerprint)
    }

    func testHTTPRequestWithATrust() async throws {
        server = try await LocalTLSServer.start(identity: "test-leaf-localhost")
        server.responses = ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"]
        let http = HTTPService()
        defer { http.invalidate() }
        let answers = Answers()
        try http.start(HTTPService.Request(
            requestId: "r1",
            url: URL(string: "https://127.0.0.1:\(server.port)/api")!,
            method: "GET",
            headers: [:],
            body: nil,
            timeoutMs: 10_000,
            trust: try TrustTests.trust(["anchors": [try TrustTests.pem("test-device-ca")]])
        ), completion: answers.add)
        try await waitUntil { !answers.results.isEmpty }
        let answer = try answers.results[0].get()
        XCTAssertEqual(answer["status"] as? Int, 200)
        XCTAssertEqual(answer["body"] as? String, "hello")
    }

    func testHTTPRequestRefusedByItsTrust() async throws {
        server = try await LocalTLSServer.start(identity: "test-leaf-localhost")
        let http = HTTPService()
        defer { http.invalidate() }
        let answers = Answers()
        try http.start(HTTPService.Request(
            requestId: "r1",
            url: URL(string: "https://127.0.0.1:\(server.port)/api")!,
            method: "GET",
            headers: [:],
            body: nil,
            timeoutMs: 10_000,
            trust: try TrustTests.trust(["fingerprints": [TrustTests.ecFingerprint]])
        ), completion: answers.add)
        try await waitUntil { !answers.results.isEmpty }
        guard case .failure(let error) = answers.results[0] else { return XCTFail("expected tls") }
        XCTAssertEqual(error.code, "tls")
        XCTAssertEqual(error.details, ["presentedFingerprint": TrustTests.localhostLeafFingerprint])
    }

    func testWebSocketRefusedByItsTrust() async throws {
        server = try await LocalTLSServer.start(identity: "test-leaf-localhost")
        var events: [(String, JSONObject)] = []
        let webSockets = WebSocketService { events.append(($0, $1)) }
        defer { webSockets.invalidate() }
        try webSockets.open(
            socketId: "s1",
            url: URL(string: "wss://127.0.0.1:\(server.port)/ws")!,
            headers: [:],
            trust: try TrustTests.trust(["fingerprints": [TrustTests.ecFingerprint]])
        )
        try await waitUntil { events.contains { $0.0 == "ws.close" } }
        XCTAssertEqual(events.map(\.0), ["ws.error", "ws.close"])
        XCTAssertEqual(events[0].1["code"] as? String, "tls")
        XCTAssertEqual(events[0].1["details"] as? [String: String], ["presentedFingerprint": TrustTests.localhostLeafFingerprint])
        XCTAssertEqual(events[1].1["code"] as? Int, 1006)
    }

    func testClosingAWebSocketStillConnectingIs1006() async throws {
        // A device that accepts TCP but never answers the upgrade.
        let silent = try await SilentTCPServer.start()
        defer { silent.stop() }
        var events: [(String, JSONObject)] = []
        let webSockets = WebSocketService { events.append(($0, $1)) }
        defer { webSockets.invalidate() }
        try webSockets.open(socketId: "w1", url: URL(string: "ws://127.0.0.1:\(silent.port)/ws")!, headers: [:])
        try await Task.sleep(nanoseconds: 100_000_000)
        webSockets.close(socketId: "w1")
        XCTAssertEqual(events.map(\.0), ["ws.close"], "no ws.open, and nothing after the close")
        XCTAssertEqual(events.first?.1["code"] as? Int, 1006, "as a browser reports closing a connecting socket")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(events.count, 1)
    }

    func testADeviceDroppingTheConnectionEndsTheSession() async throws {
        server = try await LocalTLSServer.start(identity: "test-leaf-expired")
        server.responses = ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"]
        server.dropAfterResponse = true
        let opened = try await open(trust: TrustTests.chargerCATrust()).get()
        let sessionId = try XCTUnwrap(opened["sessionId"] as? String)
        let get = HTTPSessions.Request(method: "GET", path: "/api/info", headers: [:], body: nil, timeoutMs: 5_000)
        let first = try await request(sessionId, get).get()
        XCTAssertEqual(first["body"] as? String, "ok")
        try await Task.sleep(nanoseconds: 200_000_000)

        let second = try await request(sessionId, get)
        XCTAssertEqual(second.errorCode, "network")
        XCTAssertThrowsCode("unknownSession") {
            try self.sessions.request(sessionId: sessionId, get) { _ in }
        }
        XCTAssertEqual(server.connectionCount, 1, "no new connection behind the page's back")
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

extension Result where Failure == BridgeError {
    var errorCode: String? {
        if case .failure(let error) = self { return error.code }
        return nil
    }
}

/// Accepts TCP connections on 127.0.0.1 and never says anything.
@MainActor
final class SilentTCPServer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var started = false
    private(set) var port = 0

    static func start() async throws -> SilentTCPServer {
        let server = try SilentTCPServer()
        try await server.run()
        return server
    }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    private func run() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.connections.append(connection)
                connection.start(queue: .main)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, !self.started else { return }
                    switch state {
                    case .ready:
                        self.started = true
                        continuation.resume()
                    case .failed(let error):
                        self.started = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
        }
        port = Int(listener.port?.rawValue ?? 0)
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}

/// A TLS server on 127.0.0.1 that answers each request with the next of
/// `responses` (then 404s).
@MainActor
final class LocalTLSServer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var started = false
    private(set) var port = 0
    private(set) var connectionCount = 0
    private(set) var requests: [String] = []
    var responses: [String] = []
    /// Close the connection after each response, without saying so.
    var dropAfterResponse = false

    static func start(identity name: String) async throws -> LocalTLSServer {
        let server = try LocalTLSServer(identity: try identity(name))
        try await server.start()
        return server
    }

    private init(identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    private static func identity(_ name: String) throws -> SecIdentity {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "p12", subdirectory: "Certificates"))
        var items: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: url) as CFData, [kSecImportExportPassphrase as String: "test"] as CFDictionary, &items)
        XCTAssertEqual(status, errSecSuccess, "SecPKCS12Import")
        let first = try XCTUnwrap((items as? [[String: Any]])?.first)
        return first[kSecImportItemIdentity as String] as! SecIdentity
    }

    private func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.accept(connection)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, !self.started else { return }
                    switch state {
                    case .ready:
                        self.started = true
                        continuation.resume()
                    case .failed(let error):
                        self.started = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
        }
        port = Int(listener.port?.rawValue ?? 0)
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        connectionCount += 1
        connections.append(connection)
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer + (data ?? Data())
                while let (request, rest) = Self.splitRequest(buffer) {
                    buffer = rest
                    self.requests.append(request)
                    let response = self.responses.isEmpty ? "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" : self.responses.removeFirst()
                    let drop = self.dropAfterResponse
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        if drop { connection.cancel() }
                    })
                }
                if isComplete || error != nil { return }
                self.read(connection, buffer: buffer)
            }
        }
    }

    /// One complete request (head and Content-Length body) and the rest.
    private static func splitRequest(_ buffer: Data) -> (String, Data)? {
        let bytes = [UInt8](buffer)
        guard let end = (0..<max(0, bytes.count - 3)).first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10 }) else {
            return nil
        }
        let head = String(decoding: bytes[0..<end], as: UTF8.self)
        let length = head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let total = end + 4 + length
        guard bytes.count >= total else { return nil }
        return (String(decoding: bytes[0..<total], as: UTF8.self), Data(bytes[total...]))
    }
}
