import Foundation

/// `tcp.open` / `tcp.write` / `tcp.close` and the `tcp.data` / `tcp.close`
/// events (PROTOCOL §9.6): raw TCP to a device on the local network,
/// optionally with TLS and a trust, for protocols such as Modbus TCP.
///
/// - `open` answers once connected (and the TLS handshake done), within
///   `timeoutMs`; a socket that never opened gets no events.
/// - Bytes travel as base64. `tcp.close` is always the last event for a
///   socket that opened: after `tcp.close`, when the device closes, or with
///   `error` when the connection fails.
/// - At most `maxSockets` sockets, opening ones included. All close with the
///   page, without events.
@MainActor
final class TCPSockets {
    static let maxSockets = 16
    typealias Emit = (_ event: String, _ params: JSONObject) -> Void
    typealias Completion = (Result<JSONObject, BridgeError>) -> Void

    struct OpenRequest {
        let socketId: String
        let host: String
        let port: Int
        var timeoutMs = HTTPSessions.defaultOpenTimeoutMs
        /// nil: plain TCP.
        var tls: DeviceTLS?
        var routeTraffic = false
    }

    private final class Opening {
        let completion: Completion
        var attempt: SessionConnectAttempt?

        init(completion: @escaping Completion) {
            self.completion = completion
        }
    }

    private let connector: SessionConnector
    private let emit: Emit
    private var sockets: [String: SessionConnection] = [:]
    private var opening: [String: Opening] = [:]

    /// `connector` is for tests.
    init(connector: SessionConnector? = nil, emit: @escaping Emit) {
        self.connector = connector ?? NetworkConnector()
        self.emit = emit
    }

    /// Open sockets, opening ones included.
    var count: Int { sockets.count + opening.count }

    func open(_ request: OpenRequest, completion: @escaping Completion) throws {
        guard sockets[request.socketId] == nil, opening[request.socketId] == nil else {
            throw BridgeError.invalidParams("socketId \(request.socketId) is already in use")
        }
        guard count < Self.maxSockets else {
            throw BridgeError(code: "tooManySockets", message: "at most \(Self.maxSockets) sockets can be open")
        }
        let socketId = request.socketId
        let entry = Opening(completion: completion)
        opening[socketId] = entry
        let attempt = connector.connect(
            host: request.host,
            port: request.port,
            tls: request.tls,
            timeoutMs: request.timeoutMs,
            routeTraffic: request.routeTraffic
        ) { [weak self] result in
            guard let self, self.opening[socketId] === entry else {
                // Closed meanwhile: nobody is waiting.
                if case .success(let connection) = result { connection.cancel() }
                return
            }
            self.opening.removeValue(forKey: socketId)
            switch result {
            case .success(let connection):
                self.sockets[socketId] = connection
                entry.completion(.success([:]))
                self.receive(socketId, connection)
            case .failure(let error):
                entry.completion(.failure(error))
            }
        }
        if opening[socketId] === entry {
            entry.attempt = attempt
        }
    }

    /// Answers once the bytes are handed to the OS.
    func write(socketId: String, data: Data, completion: @escaping Completion) throws {
        guard let connection = sockets[socketId] else {
            throw BridgeError(code: "unknownSocket", message: "no open socket \(socketId)")
        }
        connection.send(data) { error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success([:]))
            }
        }
    }

    /// Idempotent. An open socket emits its final `tcp.close`; one still
    /// opening answers its `open` with `network`.
    func close(socketId: String) {
        if let entry = opening.removeValue(forKey: socketId) {
            entry.attempt?.cancel()
            entry.completion(.failure(BridgeError(code: "network", message: "closed before it opened")))
            return
        }
        guard let connection = sockets.removeValue(forKey: socketId) else { return }
        connection.cancel()
        emit("tcp.close", ["socketId": socketId])
    }

    /// The page is gone: drops every socket and attempt without events or
    /// answers.
    func closeAll() {
        let attempts = opening.values.compactMap(\.attempt)
        opening.removeAll()
        attempts.forEach { $0.cancel() }
        let connections = sockets.values
        sockets.removeAll()
        connections.forEach { $0.cancel() }
    }

    private func receive(_ socketId: String, _ connection: SessionConnection) {
        connection.receive { [weak self] result in
            guard let self, self.sockets[socketId] === connection else { return }
            switch result {
            case .success(let chunk):
                if !chunk.data.isEmpty {
                    self.emit("tcp.data", ["socketId": socketId, "data": chunk.data.base64EncodedString()])
                }
                if chunk.isComplete {
                    self.ended(socketId, connection, error: nil)
                } else {
                    self.receive(socketId, connection)
                }
            case .failure(let error):
                self.ended(socketId, connection, error: error)
            }
        }
    }

    /// The device closed the connection, or it failed.
    private func ended(_ socketId: String, _ connection: SessionConnection, error: BridgeError?) {
        guard sockets[socketId] === connection else { return }
        sockets.removeValue(forKey: socketId)
        connection.cancel()
        var params: JSONObject = ["socketId": socketId]
        if let error { params["error"] = error.message }
        emit("tcp.close", params)
    }
}
