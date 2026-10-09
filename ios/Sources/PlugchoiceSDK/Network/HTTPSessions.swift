import Foundation
import Network
import Security

/// `http.session.open` / `.request` / `.close` (PROTOCOL §9.5): kept-alive
/// HTTPS connections to devices on the local network whose login lives on
/// the TCP connection rather than in a cookie.
///
/// - One TCP connection per session: `open` does the TCP and TLS handshake,
///   and the connection is never shared, pooled or silently replaced. When
///   the device drops it, the next request answers `network` and the session
///   is gone.
/// - Trust: the page's trust object, or the system's (§9.8).
/// - Requests on a session run one at a time, in the order received.
/// - At most `maxSessions` sessions (opening ones included).
/// - A session opened while `wifi.routeTraffic` is on never uses cellular
///   (the system routes the charger's subnet over Wi-Fi by itself).
///
/// Everything runs on the main queue, like the rest of the bridge.
@MainActor
final class HTTPSessions {
    static let maxSessions = 64
    /// The TCP and TLS handshake of `open`: `timeoutMs`, clamped to this
    /// range, or the default without one.
    nonisolated static let defaultOpenTimeoutMs = 10_000
    nonisolated static let openTimeoutRange = 500...30_000
    static let methods: Set<String> = ["GET", "POST", "PUT"]

    struct OpenRequest {
        let host: String
        let port: Int
        /// nil: the system's trust.
        let trust: Trust?
        var timeoutMs = HTTPSessions.defaultOpenTimeoutMs
        /// `wifi.routeTraffic` was on: the session stays off cellular.
        var routeTraffic = false
    }

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String?
        let timeoutMs: Int
        var responseBody: HTTP1.ResponseBody = .text
    }

    typealias Completion = (Result<JSONObject, BridgeError>) -> Void

    private let connector: SessionConnector
    private let makeSessionId: () -> String
    private var sessions: [String: HTTPSession] = [:]
    /// Connection attempts of `open` calls not answered yet.
    private var opening: Set<UUID> = []
    private var attempts: [UUID: SessionConnectAttempt] = [:]

    /// `connector` and `makeSessionId` are for tests.
    init(
        connector: SessionConnector? = nil,
        makeSessionId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.connector = connector ?? NetworkConnector()
        self.makeSessionId = makeSessionId
    }

    /// Open sessions, opening ones included (they count against the limit).
    var count: Int { sessions.count + opening.count }

    func open(_ request: OpenRequest, completion: @escaping Completion) throws {
        guard count < Self.maxSessions else {
            throw BridgeError(code: "tooManySessions", message: "at most \(Self.maxSessions) sessions can be open")
        }
        let key = UUID()
        opening.insert(key)
        let attempt = connector.connect(
            host: request.host,
            port: request.port,
            tls: DeviceTLS(trust: request.trust, serverName: nil),
            timeoutMs: request.timeoutMs,
            routeTraffic: request.routeTraffic
        ) { [weak self] result in
            guard let self, self.opening.remove(key) != nil else {
                // Closed meanwhile (the page went away): nobody is waiting.
                if case .success(let connection) = result { connection.cancel() }
                return
            }
            self.attempts.removeValue(forKey: key)
            switch result {
            case .success(let connection):
                let id = self.makeSessionId()
                self.sessions[id] = HTTPSession(host: request.host, port: request.port, connection: connection)
                completion(.success(["sessionId": id]))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        if opening.contains(key) {
            attempts[key] = attempt
        }
    }

    func request(sessionId: String, _ request: Request, completion: @escaping Completion) throws {
        guard let session = sessions[sessionId] else {
            throw BridgeError(code: "unknownSession", message: "no open session \(sessionId)")
        }
        guard !session.isEnded else {
            // The device dropped the connection after the last answer.
            sessions.removeValue(forKey: sessionId)
            throw HTTPSession.connectionGone
        }
        session.enqueue(request) { [weak self, weak session] result in
            // A failed request ends the session: the next call is unknownSession.
            if case .failure = result, let self, let session, session.isEnded, self.sessions[sessionId] === session {
                self.sessions.removeValue(forKey: sessionId)
            }
            completion(result)
        }
    }

    /// Idempotent. Requests still waiting on the session answer `network`.
    func close(sessionId: String) {
        sessions.removeValue(forKey: sessionId)?.end(BridgeError(code: "network", message: "the session was closed"))
    }

    /// The page is gone: drops every session and connection attempt without
    /// answering.
    func closeAll() {
        let all = sessions.values
        sessions.removeAll()
        let pending = attempts.values
        opening.removeAll()
        attempts.removeAll()
        pending.forEach { $0.cancel() }
        all.forEach { $0.end(nil) }
    }
}

/// One session: a connection and the requests queued on it.
@MainActor
final class HTTPSession {
    static let connectionGone = BridgeError(code: "network", message: "the device closed the connection; open a new session")

    private final class Pending {
        let request: HTTPSessions.Request
        let completion: HTTPSessions.Completion
        var timer: DispatchWorkItem?

        init(request: HTTPSessions.Request, completion: @escaping HTTPSessions.Completion) {
            self.request = request
            self.completion = completion
        }
    }

    private let host: String
    private let port: Int
    private var connection: SessionConnection?
    private var queue: [Pending] = []
    private var current: Pending?
    private var parser = HTTP1.ResponseParser()

    /// The connection is gone (dropped, failed, timed out or closed).
    private(set) var isEnded = false

    init(host: String, port: Int, connection: SessionConnection) {
        self.host = host
        self.port = port
        self.connection = connection
    }

    func enqueue(_ request: HTTPSessions.Request, completion: @escaping HTTPSessions.Completion) {
        let pending = Pending(request: request, completion: completion)
        // timeoutMs counts from now, so time spent waiting for earlier
        // requests counts too.
        let timer = DispatchWorkItem { [weak self, weak pending] in
            MainActor.assumeIsolated {
                guard let self, let pending else { return }
                self.timedOut(pending)
            }
        }
        pending.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(request.timeoutMs), execute: timer)
        queue.append(pending)
        startNext()
    }

    /// Ends the connection. Everything waiting answers `error`, or nothing
    /// when it's nil (the page is gone).
    func end(_ error: BridgeError?) {
        closeConnection()
        let waiting = (current.map { [$0] } ?? []) + queue
        current = nil
        queue.removeAll()
        for pending in waiting {
            pending.timer?.cancel()
            if let error { pending.completion(.failure(error)) }
        }
    }

    private func closeConnection() {
        isEnded = true
        connection?.cancel()
        connection = nil
    }

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        guard !isEnded, let connection else {
            finish(next, .failure(Self.connectionGone))
            startNext()
            return
        }
        current = next
        let request = next.request
        let bytes = HTTP1.encodeRequest(
            method: request.method,
            path: request.path,
            host: host,
            port: port,
            headers: request.headers,
            body: request.body.map { Data($0.utf8) }
        )
        connection.send(bytes) { [weak self] error in
            guard let self, self.current === next else { return }
            if let error {
                self.fail(error)
            } else {
                self.receive()
            }
        }
    }

    private func receive() {
        guard let connection, let pending = current else { return }
        connection.receive { [weak self] result in
            guard let self, self.current === pending else { return }
            do {
                switch result {
                case .success(let chunk):
                    if !chunk.data.isEmpty, let response = try self.parser.feed(chunk.data) {
                        self.received(response)
                    } else if chunk.isComplete {
                        self.received(try self.parser.finish())
                    } else {
                        self.receive()
                    }
                case .failure(let error):
                    self.fail(error)
                }
            } catch let error as HTTP1.ParseError {
                self.fail(BridgeError(code: "network", message: error.message))
            } catch {
                self.fail(BridgeError.from(error))
            }
        }
    }

    private func received(_ response: HTTP1.Response) {
        guard let pending = current else { return }
        current = nil
        if response.closesConnection {
            // The device ends the connection after this answer: the next
            // request finds the session gone.
            closeConnection()
        }
        finish(pending, .success(response.json(pending.request.responseBody)))
        startNext()
    }

    /// The connection failed mid-request: this request answers `error`, the
    /// rest `network`, and the session is gone.
    private func fail(_ error: BridgeError) {
        guard let pending = current else { return }
        current = nil
        closeConnection()
        finish(pending, .failure(error))
        end(Self.connectionGone)
    }

    private func timedOut(_ pending: Pending) {
        if let index = queue.firstIndex(where: { $0 === pending }) {
            // Never sent: the session carries on.
            queue.remove(at: index)
            finish(pending, .failure(Self.timeout(pending.request)))
        } else if current === pending {
            // The device may still answer on this connection, which would then
            // be out of step: a timeout ends the session.
            current = nil
            closeConnection()
            finish(pending, .failure(Self.timeout(pending.request)))
            end(Self.connectionGone)
        }
    }

    private func finish(_ pending: Pending, _ result: Result<JSONObject, BridgeError>) {
        pending.timer?.cancel()
        pending.timer = nil
        pending.completion(result)
    }

    private static func timeout(_ request: HTTPSessions.Request) -> BridgeError {
        BridgeError(code: "timeout", message: "\(request.method) \(request.path): no response within \(request.timeoutMs) ms")
    }
}
