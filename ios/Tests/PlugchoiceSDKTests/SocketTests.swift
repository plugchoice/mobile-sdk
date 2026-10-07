import Network
import XCTest
@testable import PlugchoiceSDK

/// Raw TCP (PROTOCOL §9.6) and unicast UDP (§9.7) against loopback servers,
/// and the socket limit and lifecycle over a scripted connector.
@MainActor
final class SocketTests: XCTestCase {
    private var events: [(event: String, params: JSONObject)] = []
    private var sockets: TCPSockets!
    private var servers: [AnyObject] = []

    override func setUp() async throws {
        try await super.setUp()
        events = []
        sockets = TCPSockets { [unowned self] event, params in
            self.events.append((event, params))
        }
    }

    override func tearDown() async throws {
        sockets.closeAll()
        for server in servers {
            (server as? LocalTCPServer)?.stop()
            (server as? LocalTLSServer)?.stop()
            (server as? SilentTCPServer)?.stop()
            (server as? LocalUDPServer)?.stop()
        }
        servers = []
        try await super.tearDown()
    }

    private func open(_ request: TCPSockets.OpenRequest) async throws -> Result<JSONObject, BridgeError> {
        let answers = Answers()
        try sockets.open(request, completion: answers.add)
        try await waitUntil { !answers.results.isEmpty }
        return answers.results[0]
    }

    private func write(_ socketId: String, _ text: String) async throws -> Result<JSONObject, BridgeError> {
        let answers = Answers()
        try sockets.write(socketId: socketId, data: Data(text.utf8), completion: answers.add)
        try await waitUntil { !answers.results.isEmpty }
        return answers.results[0]
    }

    private func received(_ socketId: String) -> String {
        events.filter { $0.event == "tcp.data" && $0.params["socketId"] as? String == socketId }
            .compactMap { ($0.params["data"] as? String).flatMap { Data(base64Encoded: $0) } }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
    }

    // MARK: - TCP

    func testTCPEcho() async throws {
        let server = try await LocalTCPServer.start()
        servers.append(server)
        _ = try await open(TCPSockets.OpenRequest(socketId: "t1", host: "127.0.0.1", port: server.port)).get()
        _ = try await write("t1", "ping").get()
        try await waitUntil { self.received("t1") == "ping" }

        sockets.close(socketId: "t1")
        XCTAssertEqual(events.last?.event, "tcp.close")
        XCTAssertEqual(events.last?.params as NSDictionary?, ["socketId": "t1"])
        sockets.close(socketId: "t1")
        XCTAssertEqual(events.filter { $0.event == "tcp.close" }.count, 1, "close is idempotent")
        XCTAssertThrowsCode("unknownSocket") {
            try self.sockets.write(socketId: "t1", data: Data("x".utf8)) { _ in }
        }
    }

    func testTheDeviceClosingEndsTheSocket() async throws {
        let server = try await LocalTCPServer.start(greeting: "hello", closeAfterGreeting: true)
        servers.append(server)
        _ = try await open(TCPSockets.OpenRequest(socketId: "t1", host: "127.0.0.1", port: server.port)).get()
        try await waitUntil { self.events.contains { $0.event == "tcp.close" } }
        XCTAssertEqual(received("t1"), "hello")
        XCTAssertEqual(events.last?.params as NSDictionary?, ["socketId": "t1"], "closed by the device, no error")
        XCTAssertEqual(sockets.count, 0)
    }

    func testNothingListeningIsNetwork() async throws {
        let port = try await LocalTCPServer.freePort()
        let result = try await open(TCPSockets.OpenRequest(socketId: "t1", host: "127.0.0.1", port: port))
        XCTAssertEqual(result.errorCode, "network")
        XCTAssertTrue(events.isEmpty, "a socket that never opened gets no events")
    }

    func testOpenGivesUpAfterItsTimeout() async throws {
        // TLS to a server that accepts TCP and never answers the handshake.
        let silent = try await SilentTCPServer.start()
        servers.append(silent)
        let started = Date()
        let result = try await open(TCPSockets.OpenRequest(
            socketId: "t1", host: "127.0.0.1", port: silent.port, timeoutMs: 500,
            tls: DeviceTLS(trust: try TrustTests.chargerCATrust(), serverName: nil)
        ))
        XCTAssertEqual(result.errorCode, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testTLSWithATrust() async throws {
        let server = try await LocalTLSServer.start(identity: "test-leaf-localhost")
        servers.append(server)
        server.responses = ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"]
        let tls = DeviceTLS(trust: try TrustTests.trust(["anchors": [try TrustTests.pem("test-device-ca")]]), serverName: nil)
        _ = try await open(TCPSockets.OpenRequest(socketId: "t1", host: "127.0.0.1", port: server.port, tls: tls)).get()
        _ = try await write("t1", "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").get()
        try await waitUntil { self.received("t1").hasSuffix("ok") }
        XCTAssertTrue(received("t1").hasPrefix("HTTP/1.1 200 OK"))
    }

    func testTLSRefusedByTheTrust() async throws {
        let server = try await LocalTLSServer.start(identity: "test-leaf-localhost")
        servers.append(server)
        let tls = DeviceTLS(trust: try TrustTests.trust(["fingerprints": [TrustTests.ecFingerprint]]), serverName: nil)
        let result = try await open(TCPSockets.OpenRequest(socketId: "t1", host: "127.0.0.1", port: server.port, tls: tls))
        guard case .failure(let error) = result else { return XCTFail("expected tls") }
        XCTAssertEqual(error.code, "tls")
        XCTAssertEqual(error.details, ["presentedFingerprint": TrustTests.localhostLeafFingerprint])
    }

    func testTLSWithoutATrustUsesTheSystems() async throws {
        let server = try await LocalTLSServer.start(identity: "test-leaf-localhost")
        servers.append(server)
        let result = try await open(TCPSockets.OpenRequest(
            socketId: "t1", host: "127.0.0.1", port: server.port, tls: DeviceTLS(trust: nil, serverName: nil)
        ))
        XCTAssertEqual(result.errorCode, "tls")
    }

    func testTheServerNameIsCheckedInsteadOfTheHost() async throws {
        let server = try await LocalTLSServer.start(identity: "test-leaf-localhost")
        servers.append(server)
        let trust = try TrustTests.trust(["anchors": [try TrustTests.pem("test-device-ca")]])
        let named = try await open(TCPSockets.OpenRequest(
            socketId: "t1", host: "127.0.0.1", port: server.port, tls: DeviceTLS(trust: trust, serverName: "localhost")
        ))
        XCTAssertNotNil(try? named.get())
        let other = try await open(TCPSockets.OpenRequest(
            socketId: "t2", host: "127.0.0.1", port: server.port, tls: DeviceTLS(trust: trust, serverName: "charger.local")
        ))
        XCTAssertEqual(other.errorCode, "tls")
    }

    // MARK: - TCP limits and lifecycle

    func testAtMost16SocketsAndUniqueIds() throws {
        let connector = FakeConnector()
        connector.mode = .hold
        let sockets = TCPSockets(connector: connector) { _, _ in }
        for index in 0..<TCPSockets.maxSockets {
            try sockets.open(TCPSockets.OpenRequest(socketId: "s\(index)", host: "10.0.0.2", port: 502)) { _ in }
        }
        XCTAssertThrowsCode("invalidParams") {
            try sockets.open(TCPSockets.OpenRequest(socketId: "s0", host: "10.0.0.2", port: 502)) { _ in }
        }
        XCTAssertThrowsCode("tooManySockets") {
            try sockets.open(TCPSockets.OpenRequest(socketId: "s99", host: "10.0.0.2", port: 502)) { _ in }
        }
        connector.held.removeFirst()(.failure(BridgeError(code: "network", message: "refused")))
        XCTAssertNoThrow(try sockets.open(TCPSockets.OpenRequest(socketId: "s99", host: "10.0.0.2", port: 502)) { _ in })
        sockets.closeAll()
    }

    func testClosingAnOpeningSocketAnswersItsOpen() throws {
        let connector = FakeConnector()
        connector.mode = .hold
        var events: [String] = []
        let sockets = TCPSockets(connector: connector) { event, _ in events.append(event) }
        let answers = Answers()
        try sockets.open(TCPSockets.OpenRequest(socketId: "s1", host: "10.0.0.2", port: 502), completion: answers.add)
        sockets.close(socketId: "s1")
        XCTAssertEqual(answers.errorCodes, ["network"])
        XCTAssertEqual(connector.attempts.last?.cancelled, true)
        XCTAssertEqual(events, [], "it never opened")
        // A connection completing late is dropped.
        let late = FakeConnection()
        connector.held.removeFirst()(.success(late))
        XCTAssertTrue(late.cancelled)
        XCTAssertEqual(answers.results.count, 1)
    }

    func testCloseAllEndsEverythingSilently() throws {
        let connector = FakeConnector()
        var events: [String] = []
        let sockets = TCPSockets(connector: connector) { event, _ in events.append(event) }
        try sockets.open(TCPSockets.OpenRequest(socketId: "s1", host: "10.0.0.2", port: 502)) { _ in }
        connector.mode = .hold
        let answers = Answers()
        try sockets.open(TCPSockets.OpenRequest(socketId: "s2", host: "10.0.0.2", port: 502), completion: answers.add)
        sockets.closeAll()
        XCTAssertTrue(connector.connections[0].cancelled)
        XCTAssertEqual(connector.attempts.last?.cancelled, true)
        XCTAssertEqual(events, [])
        XCTAssertTrue(answers.results.isEmpty)
        XCTAssertEqual(sockets.count, 0)
    }

    func testADeviceErrorEndsTheSocketWithIt() throws {
        let connector = FakeConnector()
        var events: [(String, JSONObject)] = []
        let sockets = TCPSockets(connector: connector) { events.append(($0, $1)) }
        try sockets.open(TCPSockets.OpenRequest(socketId: "s1", host: "10.0.0.2", port: 502, tls: DeviceTLS(trust: nil, serverName: "dev")) ) { _ in }
        XCTAssertEqual(connector.connects.last?.tls?.serverName, "dev")
        connector.connections[0].deliver("ab")
        connector.connections[0].deliverError(BridgeError(code: "network", message: "connection reset"))
        XCTAssertEqual(events.map(\.0), ["tcp.data", "tcp.close"])
        XCTAssertEqual(events[0].1["data"] as? String, "YWI=")
        XCTAssertEqual(events[1].1 as NSDictionary, ["socketId": "s1", "error": "connection reset"])
    }

    // MARK: - UDP

    private func exchange(_ request: UDPExchanges.Request) async throws -> Result<JSONObject, BridgeError> {
        let exchanges = UDPExchanges()
        let answers = Answers()
        exchanges.exchange(request, completion: answers.add)
        try await waitUntil { !answers.results.isEmpty }
        return answers.results[0]
    }

    private func replies(_ result: Result<JSONObject, BridgeError>) throws -> [JSONObject] {
        try XCTUnwrap(try result.get()["replies"] as? [JSONObject])
    }

    func testUDPExchange() async throws {
        let server = try await LocalUDPServer.start()
        servers.append(server)
        let result = try await exchange(UDPExchanges.Request(host: "127.0.0.1", port: server.port, data: Data("ping".utf8), timeoutMs: 5_000))
        let replies = try replies(result)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0]["from"] as? String, "127.0.0.1")
        XCTAssertEqual(replies[0]["port"] as? Int, server.port)
        XCTAssertEqual(replies[0]["data"] as? String, Data("ping".utf8).base64EncodedString())
        XCTAssertEqual(server.received, ["ping"])
    }

    func testUDPCollectsUpToMaxReplies() async throws {
        let server = try await LocalUDPServer.start(repliesPerDatagram: 3)
        servers.append(server)
        let started = Date()
        let three = try replies(try await exchange(UDPExchanges.Request(host: "127.0.0.1", port: server.port, data: Data("a".utf8), timeoutMs: 5_000, maxReplies: 3)))
        XCTAssertEqual(three.count, 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "done once maxReplies arrived")
        let two = try replies(try await exchange(UDPExchanges.Request(host: "127.0.0.1", port: server.port, data: Data("a".utf8), timeoutMs: 5_000, maxReplies: 2)))
        XCTAssertEqual(two.count, 2)
    }

    func testUDPAnswersWhatArrivedAtItsTimeout() async throws {
        let silent = try await LocalUDPServer.start(repliesPerDatagram: 0)
        servers.append(silent)
        let started = Date()
        let none = try replies(try await exchange(UDPExchanges.Request(host: "127.0.0.1", port: silent.port, data: Data("a".utf8), timeoutMs: 300)))
        XCTAssertEqual(none.count, 0)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.28)
        XCTAssertLessThan(elapsed, 2)

        let server = try await LocalUDPServer.start(repliesPerDatagram: 2)
        servers.append(server)
        // Long enough for a busy CI runner's loopback; the exchange still ends at
        // its deadline with fewer than maxReplies.
        let some = try replies(try await exchange(UDPExchanges.Request(host: "127.0.0.1", port: server.port, data: Data("a".utf8), timeoutMs: 2_000, maxReplies: 5)))
        XCTAssertEqual(some.count, 2, "fewer than maxReplies by the deadline")
    }

    func testUDPToAPortNobodyListensOn() async throws {
        let port = try await LocalUDPServer.freePort()
        let result = try await exchange(UDPExchanges.Request(host: "127.0.0.1", port: port, data: Data("a".utf8), timeoutMs: 300))
        // No reply is no error: the port being unreachable doesn't surface.
        XCTAssertEqual(try replies(result).count, 0)
    }

    func testCancelAllDropsExchangesSilently() async throws {
        let silent = try await LocalUDPServer.start(repliesPerDatagram: 0)
        servers.append(silent)
        let exchanges = UDPExchanges()
        let answers = Answers()
        exchanges.exchange(UDPExchanges.Request(host: "127.0.0.1", port: silent.port, data: Data("a".utf8), timeoutMs: 200), completion: answers.add)
        XCTAssertEqual(exchanges.count, 1)
        exchanges.cancelAll()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(answers.results.isEmpty)
        XCTAssertEqual(exchanges.count, 0)
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
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

extension FakeConnection {
    func deliverError(_ error: BridgeError) {
        deliverResult(.failure(error))
    }
}

/// A TCP server on 127.0.0.1 that echoes what it gets, optionally after a
/// greeting (and then closing).
@MainActor
final class LocalTCPServer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var started = false
    private let greeting: String?
    private let closeAfterGreeting: Bool
    private(set) var port = 0

    static func start(greeting: String? = nil, closeAfterGreeting: Bool = false) async throws -> LocalTCPServer {
        let server = try LocalTCPServer(greeting: greeting, closeAfterGreeting: closeAfterGreeting)
        try await server.run()
        return server
    }

    /// A port nothing listens on (a server's, after it stopped).
    static func freePort() async throws -> Int {
        let probe = try await start()
        let port = probe.port
        probe.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        return port
    }

    private init(greeting: String?, closeAfterGreeting: Bool) throws {
        self.greeting = greeting
        self.closeAfterGreeting = closeAfterGreeting
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    private func run() async throws {
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
        connections.append(connection)
        connection.start(queue: .main)
        if let greeting {
            if closeAfterGreeting {
                // The greeting, then the end of the stream.
                connection.send(content: Data(greeting.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                return
            }
            connection.send(content: Data(greeting.utf8), completion: .contentProcessed { _ in })
        }
        echo(connection)
    }

    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                if let data, !data.isEmpty {
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
                if isComplete || error != nil { return }
                self?.echo(connection)
            }
        }
    }
}

/// A UDP server on 127.0.0.1 that answers each datagram with
/// `repliesPerDatagram` copies of it (none: silent).
@MainActor
final class LocalUDPServer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var started = false
    private let repliesPerDatagram: Int
    private(set) var port = 0
    private(set) var received: [String] = []

    static func start(repliesPerDatagram: Int = 1) async throws -> LocalUDPServer {
        let server = try LocalUDPServer(repliesPerDatagram: repliesPerDatagram)
        try await server.run()
        return server
    }

    static func freePort() async throws -> Int {
        let probe = try await start()
        let port = probe.port
        probe.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        return port
    }

    private init(repliesPerDatagram: Int) throws {
        self.repliesPerDatagram = repliesPerDatagram
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    private func run() async throws {
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
        connections.append(connection)
        connection.start(queue: .main)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data {
                    self.received.append(String(decoding: data, as: UTF8.self))
                    for _ in 0..<self.repliesPerDatagram {
                        connection.send(content: data, completion: .contentProcessed { _ in })
                    }
                }
                if error == nil { self.receive(connection) }
            }
        }
    }
}
