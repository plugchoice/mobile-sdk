import XCTest
@testable import PlugchoiceSDK

/// `http.session.*` (PROTOCOL §9.5) over a scripted connection: the session
/// limit, unknown sessions, per-session ordering, timeouts and a device
/// dropping the connection.
@MainActor
final class HTTPSessionTests: XCTestCase {
    private var connector: FakeConnector!
    private var sessions: HTTPSessions!
    private var nextId = 0

    override func setUp() async throws {
        try await super.setUp()
        connector = FakeConnector()
        nextId = 0
        sessions = HTTPSessions(connector: connector) { [unowned self] in
            self.nextId += 1
            return "s\(self.nextId)"
        }
    }

    private func anchor() throws -> Trust {
        try TrustTests.chargerCATrust()
    }

    private func open() throws -> (id: String, connection: FakeConnection) {
        let answers = Answers()
        try sessions.open(HTTPSessions.OpenRequest(host: "192.168.1.10", port: 443, trust: try anchor()), completion: answers.add)
        let result = try XCTUnwrap(answers.results.first)
        let id = try XCTUnwrap(try result.get()["sessionId"] as? String)
        return (id, try XCTUnwrap(connector.connections.last))
    }

    private func get(_ path: String, timeoutMs: Int = 5_000) -> HTTPSessions.Request {
        HTTPSessions.Request(method: "GET", path: path, headers: [:], body: nil, timeoutMs: timeoutMs)
    }

    // MARK: - Open

    func testOpenAnswersASessionId() throws {
        let (id, _) = try open()
        XCTAssertEqual(id, "s1")
        XCTAssertEqual(connector.connects.first?.host, "192.168.1.10")
        XCTAssertEqual(connector.connects.first?.port, 443)
        XCTAssertEqual(connector.connects.first?.timeoutMs, 10_000, "the default handshake timeout")
        XCTAssertEqual(connector.connects.first?.routeTraffic, false)
        XCTAssertEqual(connector.connects.first?.tls?.trust?.anchors.count, 1, "always TLS, with the session's trust")
        XCTAssertNil(connector.connects.first?.tls?.serverName)
    }

    func testOpenPassesItsTimeoutAndRoute() throws {
        let request = HTTPSessions.OpenRequest(host: "192.168.50.10", port: 443, trust: try anchor(), timeoutMs: 2_500, routeTraffic: true)
        try sessions.open(request) { _ in }
        XCTAssertEqual(connector.connects.first?.timeoutMs, 2_500)
        XCTAssertEqual(connector.connects.first?.routeTraffic, true)
    }

    func testOpenFailuresComeFromTheConnection() throws {
        for code in ["tls", "network", "timeout"] {
            connector.mode = .fail(BridgeError(code: code, message: code))
            let answers = Answers()
            try sessions.open(HTTPSessions.OpenRequest(host: "10.0.0.1", port: 443, trust: try anchor()), completion: answers.add)
            XCTAssertEqual(answers.errorCodes, [code])
        }
        XCTAssertEqual(sessions.count, 0)
    }

    // MARK: - Limit

    func testAtMost64Sessions() throws {
        var ids: [String] = []
        for _ in 0..<HTTPSessions.maxSessions {
            ids.append(try open().id)
        }
        XCTAssertEqual(sessions.count, 64)
        XCTAssertThrowsCode("tooManySessions") {
            try self.sessions.open(HTTPSessions.OpenRequest(host: "10.0.0.1", port: 443, trust: try self.anchor())) { _ in }
        }
        sessions.close(sessionId: ids[0])
        XCTAssertNoThrow(try open())
    }

    func testOpeningSessionsCountTowardsTheLimit() throws {
        connector.mode = .hold
        for _ in 0..<HTTPSessions.maxSessions {
            try sessions.open(HTTPSessions.OpenRequest(host: "10.0.0.1", port: 443, trust: try anchor())) { _ in }
        }
        XCTAssertThrowsCode("tooManySessions") {
            try self.sessions.open(HTTPSessions.OpenRequest(host: "10.0.0.2", port: 443, trust: try self.anchor())) { _ in }
        }
        // One attempt fails: room for another.
        connector.held.removeFirst()(.failure(BridgeError(code: "network", message: "unreachable")))
        XCTAssertNoThrow(try sessions.open(HTTPSessions.OpenRequest(host: "10.0.0.2", port: 443, trust: try anchor())) { _ in })
    }

    // MARK: - Unknown sessions and close

    func testRequestOnAnUnknownSession() {
        XCTAssertThrowsCode("unknownSession") {
            try self.sessions.request(sessionId: "nope", self.get("/api/info")) { _ in }
        }
    }

    func testCloseIsIdempotentAndEndsTheSession() throws {
        let (id, connection) = try open()
        sessions.close(sessionId: id)
        sessions.close(sessionId: id)
        sessions.close(sessionId: "never-opened")
        XCTAssertTrue(connection.cancelled)
        XCTAssertThrowsCode("unknownSession") {
            try self.sessions.request(sessionId: id, self.get("/api/info")) { _ in }
        }
    }

    func testCloseAnswersWaitingRequestsWithNetwork() throws {
        let (id, _) = try open()
        let answers = Answers()
        try sessions.request(sessionId: id, get("/a"), completion: answers.add)
        try sessions.request(sessionId: id, get("/b"), completion: answers.add)
        sessions.close(sessionId: id)
        XCTAssertEqual(answers.errorCodes, ["network", "network"])
    }

    func testCloseAllDropsEverythingWithoutAnswers() throws {
        let (id, connection) = try open()
        connector.mode = .hold
        let answers = Answers()
        try sessions.request(sessionId: id, get("/a"), completion: answers.add)
        try sessions.open(HTTPSessions.OpenRequest(host: "10.0.0.2", port: 443, trust: try anchor()), completion: answers.add)
        sessions.closeAll()
        XCTAssertTrue(connection.cancelled)
        XCTAssertEqual(connector.attempts.last?.cancelled, true, "the attempt still connecting is abandoned")
        XCTAssertEqual(sessions.count, 0)
        // A connection that completes after all is dropped, not answered.
        let late = FakeConnection()
        connector.held.removeFirst()(.success(late))
        XCTAssertTrue(late.cancelled)
        XCTAssertTrue(answers.results.isEmpty)
    }

    // MARK: - Requests

    func testARequestAndItsResponse() throws {
        let (id, connection) = try open()
        let answers = Answers()
        try sessions.request(
            sessionId: id,
            HTTPSessions.Request(
                method: "POST",
                path: "/api/login",
                headers: ["Content-Type": "application/json", "Content-Length": "999", "Connection": "close", "Host": "evil"],
                body: "{\"username\":\"admin\"}",
                timeoutMs: 5_000
            ),
            completion: answers.add
        )
        XCTAssertEqual(connection.sentText, [
            "POST /api/login HTTP/1.1\r\nHost: 192.168.1.10\r\nContent-Type: application/json\r\nContent-Length: 20\r\n\r\n{\"username\":\"admin\"}",
        ])
        connection.deliver("HTTP/1.1 200 OK\r\nContent-Type: alfen/json; charset=UTF-8\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 2\r\n\r\nok")
        let result = try XCTUnwrap(answers.results.first).get()
        XCTAssertEqual(result["status"] as? Int, 200)
        XCTAssertEqual(result["body"] as? String, "ok")
        XCTAssertEqual(result["headers"] as? [String: String], [
            "content-type": "alfen/json; charset=UTF-8",
            "set-cookie": "a=1, b=2",
            "content-length": "2",
        ])
    }

    func testAnEmptyPostStillSendsContentLength() throws {
        let (id, connection) = try open()
        try sessions.request(
            sessionId: id,
            HTTPSessions.Request(method: "POST", path: "/api/logout", headers: [:], body: nil, timeoutMs: 5_000)
        ) { _ in }
        XCTAssertEqual(connection.sentText, ["POST /api/logout HTTP/1.1\r\nHost: 192.168.1.10\r\nContent-Length: 0\r\n\r\n"])
    }

    func testRequestsOnASessionRunOneAtATimeInOrder() throws {
        let (id, connection) = try open()
        let answers = Answers()
        for path in ["/1", "/2", "/3"] {
            try sessions.request(sessionId: id, get(path), completion: answers.add)
        }
        XCTAssertEqual(connection.sentText.count, 1, "the next request waits for the response")
        XCTAssertTrue(connection.sentText[0].hasPrefix("GET /1 "))

        // A response split over several reads.
        connection.deliver("HTTP/1.1 200 OK\r\nContent-Le")
        connection.deliver("ngth: 3\r\n\r\none")
        XCTAssertEqual(connection.sentText.count, 2)
        XCTAssertTrue(connection.sentText[1].hasPrefix("GET /2 "))
        connection.deliver("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\ntwo\r\n0\r\n\r\n")
        XCTAssertTrue(connection.sentText[2].hasPrefix("GET /3 "))
        connection.deliver("HTTP/1.1 404 Not Found\r\nContent-Length: 5\r\n\r\nthree")

        XCTAssertEqual(answers.bodies, ["one", "two", "three"])
        XCTAssertEqual(try answers.results[2].get()["status"] as? Int, 404)
    }

    func testSessionsDoNotWaitForEachOther() throws {
        let (first, firstConnection) = try open()
        let (second, secondConnection) = try open()
        try sessions.request(sessionId: first, get("/slow")) { _ in }
        let answers = Answers()
        try sessions.request(sessionId: second, get("/fast"), completion: answers.add)
        secondConnection.deliver("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nfast")
        XCTAssertEqual(answers.bodies, ["fast"])
        XCTAssertEqual(firstConnection.sentText.count, 1)
    }

    // MARK: - The device dropping the connection

    func testADropMidRequestFailsWithNetworkAndEndsTheSession() throws {
        let (id, connection) = try open()
        let answers = Answers()
        try sessions.request(sessionId: id, get("/a"), completion: answers.add)
        try sessions.request(sessionId: id, get("/b"), completion: answers.add)
        connection.deliverEnd()
        XCTAssertEqual(answers.errorCodes, ["network", "network"])
        XCTAssertTrue(connection.cancelled)
        XCTAssertThrowsCode("unknownSession") {
            try self.sessions.request(sessionId: id, self.get("/c")) { _ in }
        }
    }

    func testAfterConnectionCloseTheNextRequestFailsWithNetwork() throws {
        let (id, connection) = try open()
        let answers = Answers()
        try sessions.request(sessionId: id, get("/a"), completion: answers.add)
        connection.deliver("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 1\r\n\r\nx")
        XCTAssertEqual(answers.bodies, ["x"])
        XCTAssertTrue(connection.cancelled)
        XCTAssertThrowsCode("network") {
            try self.sessions.request(sessionId: id, self.get("/b")) { _ in }
        }
        XCTAssertThrowsCode("unknownSession") {
            try self.sessions.request(sessionId: id, self.get("/c")) { _ in }
        }
        // Never reconnected behind the page's back.
        XCTAssertEqual(connector.connects.count, 1)
    }

    func testABodyUntilCloseEndsTheSessionAfterIt() throws {
        let (id, connection) = try open()
        let answers = Answers()
        try sessions.request(sessionId: id, get("/a"), completion: answers.add)
        connection.deliver("HTTP/1.0 200 OK\r\n\r\npart one, ")
        connection.deliver("part two")
        XCTAssertTrue(answers.results.isEmpty)
        connection.deliverEnd()
        XCTAssertEqual(answers.bodies, ["part one, part two"])
        XCTAssertThrowsCode("network") {
            try self.sessions.request(sessionId: id, self.get("/b")) { _ in }
        }
    }

    func testAGarbledResponseFailsWithNetwork() throws {
        let (id, connection) = try open()
        let answers = Answers()
        try sessions.request(sessionId: id, get("/a"), completion: answers.add)
        connection.deliver("SSH-2.0-OpenSSH\r\n\r\n")
        XCTAssertEqual(answers.errorCodes, ["network"])
    }

    func testASendErrorFailsWithIt() throws {
        let (id, connection) = try open()
        connection.sendError = BridgeError(code: "network", message: "broken pipe")
        let answers = Answers()
        try sessions.request(sessionId: id, get("/a"), completion: answers.add)
        XCTAssertEqual(answers.errorCodes, ["network"])
    }

    // MARK: - Timeouts

    func testATimeoutWhileWaitingForTheDeviceEndsTheSession() async throws {
        let (id, connection) = try open()
        let answers = Answers()
        try sessions.request(sessionId: id, get("/slow", timeoutMs: 50), completion: answers.add)
        try sessions.request(sessionId: id, get("/next", timeoutMs: 5_000), completion: answers.add)
        try await waitUntil { answers.results.count == 2 }
        XCTAssertEqual(answers.errorCodes, ["timeout", "network"])
        XCTAssertTrue(connection.cancelled)
        // A late answer goes nowhere.
        connection.deliver("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        XCTAssertEqual(answers.results.count, 2)
        XCTAssertThrowsCode("unknownSession") {
            try self.sessions.request(sessionId: id, self.get("/c")) { _ in }
        }
    }

    func testATimeoutWhileQueuedLeavesTheSessionAlone() async throws {
        let (id, connection) = try open()
        let answers = Answers()
        try sessions.request(sessionId: id, get("/first", timeoutMs: 5_000), completion: answers.add)
        try sessions.request(sessionId: id, get("/queued", timeoutMs: 50), completion: answers.add)
        try await waitUntil { answers.results.count == 1 }
        XCTAssertEqual(answers.errorCodes, ["timeout"], "timeoutMs counts from when the request arrived")
        connection.deliver("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfirst")
        XCTAssertEqual(answers.bodies, ["first"])
        XCTAssertEqual(connection.sentText.count, 1, "the timed-out request was never sent")
        try sessions.request(sessionId: id, get("/after"), completion: answers.add)
        XCTAssertEqual(connection.sentText.count, 2)
        XCTAssertFalse(connection.cancelled)
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
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

// MARK: - Test doubles

@MainActor
final class Answers {
    private(set) var results: [Result<JSONObject, BridgeError>] = []

    func add(_ result: Result<JSONObject, BridgeError>) {
        results.append(result)
    }

    var errorCodes: [String] {
        results.compactMap { result in
            if case .failure(let error) = result { return error.code }
            return nil
        }
    }

    var bodies: [String] {
        results.compactMap { (try? $0.get())?["body"] as? String }
    }
}

@MainActor
final class FakeConnection: SessionConnection {
    private(set) var sent: [Data] = []
    private(set) var cancelled = false
    var sendError: BridgeError?
    private var waiting: [(Result<(data: Data, isComplete: Bool), BridgeError>) -> Void] = []
    private var buffered: [Result<(data: Data, isComplete: Bool), BridgeError>] = []

    var sentText: [String] { sent.map { String(decoding: $0, as: UTF8.self) } }

    func send(_ data: Data, completion: @escaping (BridgeError?) -> Void) {
        sent.append(data)
        completion(sendError)
    }

    func receive(completion: @escaping (Result<(data: Data, isComplete: Bool), BridgeError>) -> Void) {
        if buffered.isEmpty {
            waiting.append(completion)
        } else {
            completion(buffered.removeFirst())
        }
    }

    func deliver(_ text: String) {
        deliverResult(.success((Data(text.utf8), false)))
    }

    /// The device closed the connection.
    func deliverEnd() {
        deliverResult(.success((Data(), true)))
    }

    func deliverResult(_ chunk: Result<(data: Data, isComplete: Bool), BridgeError>) {
        if waiting.isEmpty {
            buffered.append(chunk)
        } else {
            waiting.removeFirst()(chunk)
        }
    }

    func cancel() {
        cancelled = true
    }
}

@MainActor
final class FakeConnector: SessionConnector {
    enum Mode {
        case succeed
        case fail(BridgeError)
        /// Keeps the attempt open; complete it through `held`.
        case hold
    }

    final class Attempt: SessionConnectAttempt {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    var mode = Mode.succeed
    private(set) var connects: [(host: String, port: Int, timeoutMs: Int, routeTraffic: Bool, tls: DeviceTLS?)] = []
    private(set) var connections: [FakeConnection] = []
    private(set) var attempts: [Attempt] = []
    var held: [(Result<SessionConnection, BridgeError>) -> Void] = []

    func connect(
        host: String,
        port: Int,
        tls: DeviceTLS?,
        timeoutMs: Int,
        routeTraffic: Bool,
        completion: @escaping (Result<SessionConnection, BridgeError>) -> Void
    ) -> SessionConnectAttempt {
        connects.append((host, port, timeoutMs, routeTraffic, tls))
        let attempt = Attempt()
        attempts.append(attempt)
        switch mode {
        case .succeed:
            let connection = FakeConnection()
            connections.append(connection)
            completion(.success(connection))
        case .fail(let error):
            completion(.failure(error))
        case .hold:
            held.append(completion)
        }
        return attempt
    }
}

@MainActor
func XCTAssertThrowsCode(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        XCTFail("expected \(code)", file: file, line: line)
    } catch {
        XCTAssertEqual((error as? BridgeError)?.code, code, file: file, line: line)
    }
}
