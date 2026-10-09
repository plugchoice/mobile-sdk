import Foundation

/// `http.request` / `http.cancel`: one HTTP request at a time per `requestId`
/// to a device on the local network.
///
/// - ephemeral session, no cookie storage, cookies never stored or attached
///   (a `Cookie` header from the page goes out verbatim)
/// - no URL cache
/// - redirects are not followed: the 3xx comes back as is
/// - no proxy
/// - `timeoutMs` is a total deadline for the request, enforced with a timer
///   (URLSession's own `timeoutInterval` only measures idle time)
/// - `https` with a page's `trust` (§9.8): the request gets a URLSession of
///   its own, so a connection trusted one way is never reused by a request
///   that trusts another; a refused certificate answers `tls`
@MainActor
final class HTTPService {
    struct Request {
        let requestId: String
        let url: URL
        let method: String
        let headers: [String: String]
        let body: String?
        let timeoutMs: Int
        /// Only for `https`; nil: the system's trust.
        var trust: Trust?
        var responseBody: HTTP1.ResponseBody = .text
    }

    private enum StopReason {
        case cancelled
        case timeout
    }

    private final class Pending {
        let task: URLSessionDataTask
        /// The request's own session (a page's trust), invalidated after it.
        let ownSession: URLSession?
        let delegate: HTTPTaskDelegate
        let responseBody: HTTP1.ResponseBody
        var stopReason: StopReason?
        var timer: DispatchWorkItem?

        init(task: URLSessionDataTask, ownSession: URLSession?, delegate: HTTPTaskDelegate, responseBody: HTTP1.ResponseBody) {
            self.task = task
            self.ownSession = ownSession
            self.delegate = delegate
            self.responseBody = responseBody
        }
    }

    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    private let sharedDelegate = HTTPTaskDelegate(trust: nil)
    private let session: URLSession
    private var pending: [String: Pending] = [:]

    init() {
        // Callbacks arrive on the main queue, where the rest of the bridge lives.
        session = URLSession(configuration: Self.configuration, delegate: sharedDelegate, delegateQueue: .main)
    }

    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        // Straight to the device, never through a proxy.
        configuration.connectionProxyDictionary = [:]
        return configuration
    }

    func start(_ request: Request, completion: @escaping (Result<JSONObject, BridgeError>) -> Void) throws {
        guard pending[request.requestId] == nil else {
            throw BridgeError.invalidParams("requestId \(request.requestId) is already in flight")
        }

        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: TimeInterval(request.timeoutMs) / 1000
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        // URLSession refuses a GET with a body; the protocol never needs one.
        if let body = request.body, request.method != "GET" {
            urlRequest.httpBody = Data(body.utf8)
        }

        let requestId = request.requestId
        var ownSession: URLSession?
        var delegate = sharedDelegate
        if let trust = request.trust, request.url.scheme?.lowercased() == "https" {
            delegate = HTTPTaskDelegate(trust: trust)
            ownSession = URLSession(configuration: Self.configuration, delegate: delegate, delegateQueue: .main)
        }
        let task = (ownSession ?? session).dataTask(with: urlRequest) { [weak self] data, response, error in
            // The session's delegate queue is the main queue.
            MainActor.assumeIsolated {
                self?.finish(requestId: requestId, data: data, response: response, error: error, completion: completion)
            }
        }
        let entry = Pending(task: task, ownSession: ownSession, delegate: delegate, responseBody: request.responseBody)
        let timer = DispatchWorkItem { [weak self, weak entry] in
            MainActor.assumeIsolated {
                guard let self, let entry, self.pending[requestId] === entry else { return }
                entry.stopReason = .timeout
                entry.task.cancel()
            }
        }
        entry.timer = timer
        pending[requestId] = entry
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(request.timeoutMs), execute: timer)
        task.resume()
    }

    /// The pending request then fails with `cancelled`. Unknown ids are fine.
    func cancel(requestId: String) {
        guard let entry = pending[requestId] else { return }
        entry.stopReason = .cancelled
        entry.task.cancel()
    }

    /// Drops every request without answering (the page that asked is gone).
    func cancelAll() {
        let entries = pending.values
        pending.removeAll()
        for entry in entries {
            entry.timer?.cancel()
            entry.task.cancel()
            entry.ownSession?.invalidateAndCancel()
        }
    }

    func invalidate() {
        cancelAll()
        session.invalidateAndCancel()
    }

    private func finish(
        requestId: String,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        completion: (Result<JSONObject, BridgeError>) -> Void
    ) {
        // Already dropped by cancelAll(): nobody is waiting for the answer.
        guard let entry = pending.removeValue(forKey: requestId) else { return }
        entry.timer?.cancel()
        entry.ownSession?.finishTasksAndInvalidate()

        if let error {
            if let rejection = entry.delegate.rejection(for: entry.task) {
                completion(.failure(rejection))
                return
            }
            completion(.failure(Self.map(error, stopReason: entry.stopReason)))
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completion(.failure(BridgeError(code: "network", message: "no HTTP response")))
            return
        }
        completion(.success([
            "status": http.statusCode,
            "headers": Self.lowerCasedHeaders(http),
            "body": entry.responseBody.encode(data ?? Data()),
        ]))
    }

    /// Header names lower-cased. Foundation already joins repeated headers
    /// (several `Set-Cookie`s included) with ", "; names that only differ in
    /// case are joined the same way.
    private static func lowerCasedHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let name = ((key.base as? String) ?? String(describing: key)).lowercased()
            let text = (value as? String) ?? String(describing: value)
            if let existing = headers[name] {
                headers[name] = existing + ", " + text
            } else {
                headers[name] = text
            }
        }
        return headers
    }

    private static func map(_ error: Error, stopReason: StopReason?) -> BridgeError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                if stopReason == .timeout {
                    return BridgeError(code: "timeout", message: "request timed out")
                }
                return BridgeError(code: "cancelled", message: "request cancelled")
            case NSURLErrorTimedOut:
                return BridgeError(code: "timeout", message: nsError.localizedDescription)
            default:
                break
            }
        }
        return BridgeError(code: "network", message: "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
    }
}

/// Answers every redirect with "don't follow", so the 3xx response itself
/// completes the task, and checks a page's trust for `https` (the system's
/// trust otherwise). Its callbacks run on the main queue.
final class HTTPTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let trust: Trust?
    /// Tasks whose certificate the trust refused, with the presented leaf's
    /// fingerprint.
    private var rejected: [Int: String?] = [:]

    init(trust: Trust?) {
        self.trust = trust
    }

    /// The `tls` error for a task whose certificate was refused, or nil.
    func rejection(for task: URLSessionTask) -> BridgeError? {
        guard let trust, let fingerprint = rejected[task.taskIdentifier] else { return nil }
        return trust.rejection(fingerprint)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    /// Server trust reaches this task-level method because the delegate has
    /// no session-level one.
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
            rejected[task.taskIdentifier] = .some(evaluation.presentedFingerprint)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
