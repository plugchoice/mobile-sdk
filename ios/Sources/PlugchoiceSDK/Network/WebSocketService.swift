import Foundation

/// `ws.open` / `ws.send` / `ws.close` and the `ws.*` events, on
/// `URLSessionWebSocketTask`. Text frames only. `ws.close` is always the
/// last event for a socket.
///
/// A `wss` socket with a page's `trust` (§9.8) gets a URLSession of its own,
/// so its connection is never shared; a refused certificate emits `ws.error`
/// with `code: "tls"` and the presented fingerprint in `details`.
@MainActor
final class WebSocketService {
    typealias Emit = (_ event: String, _ params: JSONObject) -> Void

    /// Handed to URLSession's callbacks, which only read its constants;
    /// `opened` is read and written on the main queue.
    private final class Socket: @unchecked Sendable {
        let id: String
        let task: URLSessionWebSocketTask
        /// The socket's own session (a page's trust).
        let ownSession: URLSession?
        let delegate: WebSocketDelegateProxy
        /// `ws.open` went out.
        var opened = false

        init(id: String, task: URLSessionWebSocketTask, ownSession: URLSession?, delegate: WebSocketDelegateProxy) {
            self.id = id
            self.task = task
            self.ownSession = ownSession
            self.delegate = delegate
        }

        func cancel(with code: URLSessionWebSocketTask.CloseCode) {
            task.cancel(with: code, reason: nil)
            ownSession?.finishTasksAndInvalidate()
        }
    }

    private let session: URLSession
    private let delegate: WebSocketDelegateProxy
    private var sockets: [String: Socket] = [:]
    private let emit: Emit

    init(emit: @escaping Emit) {
        self.emit = emit
        delegate = WebSocketDelegateProxy(trust: nil)
        session = URLSession(configuration: Self.configuration, delegate: delegate, delegateQueue: .main)
        delegate.owner = self
    }

    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        // Straight to the device, never through a proxy.
        configuration.connectionProxyDictionary = [:]
        return configuration
    }

    /// `trust` applies to `wss` only.
    func open(socketId: String, url: URL, headers: [String: String], trust: Trust? = nil) throws {
        guard sockets[socketId] == nil else {
            throw BridgeError.invalidParams("socketId \(socketId) is already open")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        var ownSession: URLSession?
        var socketDelegate = delegate
        if let trust, url.scheme?.lowercased() == "wss" {
            socketDelegate = WebSocketDelegateProxy(trust: trust)
            socketDelegate.owner = self
            ownSession = URLSession(configuration: Self.configuration, delegate: socketDelegate, delegateQueue: .main)
        }
        let task = (ownSession ?? session).webSocketTask(with: request)
        let socket = Socket(id: socketId, task: task, ownSession: ownSession, delegate: socketDelegate)
        sockets[socketId] = socket
        task.resume()
        receive(on: socket)
    }

    func send(socketId: String, data: String, completion: @escaping (Result<JSONObject, BridgeError>) -> Void) throws {
        guard let socket = sockets[socketId] else {
            throw BridgeError.invalidParams("no open socket \(socketId)")
        }
        socket.task.send(.string(data)) { error in
            onMain {
                if let error {
                    completion(.failure(BridgeError(code: "network", message: error.localizedDescription)))
                } else {
                    completion(.success([:]))
                }
            }
        }
    }

    /// Closes the socket and emits its final `ws.close`: 1000, or 1006 for a
    /// socket still connecting (as a browser reports closing one). Unknown
    /// ids are fine.
    func close(socketId: String) {
        guard let socket = sockets.removeValue(forKey: socketId) else { return }
        socket.cancel(with: .normalClosure)
        let code = socket.opened ? URLSessionWebSocketTask.CloseCode.normalClosure.rawValue : Self.abnormalClosure
        emit("ws.close", ["socketId": socketId, "code": code, "reason": ""])
    }

    /// Closed without a close frame.
    static let abnormalClosure = 1006

    /// Drops every socket without events (the page that opened them is gone).
    func closeAll() {
        let all = sockets.values
        sockets.removeAll()
        for socket in all {
            socket.cancel(with: .goingAway)
        }
    }

    func invalidate() {
        closeAll()
        session.invalidateAndCancel()
    }

    // MARK: - Receive loop and delegate callbacks (all on the main queue)

    private func receive(on socket: Socket) {
        socket.task.receive { [weak self] result in
            onMain {
                self?.received(result, on: socket)
            }
        }
    }

    private func received(_ result: Result<URLSessionWebSocketTask.Message, Error>, on socket: Socket) {
        guard sockets[socket.id] === socket else { return }
        switch result {
        case .success(.string(let text)):
            emit("ws.message", ["socketId": socket.id, "data": text])
            receive(on: socket)
        case .success:
            // Binary frames are not part of the protocol; skip them.
            receive(on: socket)
        case .failure:
            // The task's completion (didCompleteWithError) reports the failure
            // and the close; nothing more to read.
            break
        }
    }

    fileprivate func didOpen(_ task: URLSessionWebSocketTask) {
        guard let socket = socket(for: task) else { return }
        socket.opened = true
        emit("ws.open", ["socketId": socket.id])
    }

    fileprivate func didClose(_ task: URLSessionWebSocketTask, code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard let socket = socket(for: task) else { return }
        sockets.removeValue(forKey: socket.id)
        emit("ws.close", [
            "socketId": socket.id,
            "code": code.rawValue,
            "reason": reason.map { String(decoding: $0, as: UTF8.self) } ?? "",
        ])
    }

    fileprivate func didComplete(_ task: URLSessionTask, error: Error?) {
        guard let webSocketTask = task as? URLSessionWebSocketTask, let socket = socket(for: webSocketTask) else { return }
        sockets.removeValue(forKey: socket.id)
        socket.ownSession?.finishTasksAndInvalidate()
        if let rejection = socket.delegate.rejection {
            // A refused certificate (§9.8): the error's code and details too.
            var params: JSONObject = ["socketId": socket.id, "message": rejection.message, "code": rejection.code]
            if let details = rejection.details { params["details"] = details }
            emit("ws.error", params)
        } else if let error {
            var message = error.localizedDescription
            if let status = (task.response as? HTTPURLResponse)?.statusCode {
                message += " (HTTP \(status))"
            }
            emit("ws.error", ["socketId": socket.id, "message": message])
        }
        let closeCode = webSocketTask.closeCode
        emit("ws.close", [
            "socketId": socket.id,
            "code": closeCode == .invalid ? Self.abnormalClosure : closeCode.rawValue,
            "reason": webSocketTask.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "",
        ])
    }

    private func socket(for task: URLSessionWebSocketTask) -> Socket? {
        sockets.values.first { $0.task === task }
    }
}

/// URLSession retains its delegate; this proxy holds the service weakly.
/// With a page's trust it checks the server's certificate (one socket per
/// such session).
private final class WebSocketDelegateProxy: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var owner: WebSocketService?
    let trust: Trust?
    /// Set when the trust refused the certificate.
    private(set) var rejection: BridgeError?

    init(trust: Trust?) {
        self.trust = trust
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let evaluation = trust.evaluate(serverTrust, host: challenge.protectionSpace.host)
        if evaluation.trusted {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            rejection = trust.rejection(evaluation.presentedFingerprint)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        MainActor.assumeIsolated {
            owner?.didOpen(webSocketTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        MainActor.assumeIsolated {
            owner?.didClose(webSocketTask, code: closeCode, reason: reason)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            owner?.didComplete(task, error: error)
        }
    }
}
