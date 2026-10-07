import Foundation

/// `auth.clientSecret` (PROTOCOL §7): the client secret, from the host
/// app's `fetchClientSecret` callback, always called with the action the
/// screen opened with (the host's server scopes the secret to it).
///
/// - The screen calls `prefetch()` when it opens, in parallel with loading
///   the page. The page's first `auth.clientSecret` answers with that fetch's
///   result (waiting for it if needed); every later call runs the callback
///   again (the page asks when its secret has expired).
/// - `clientSecretUnavailable` when the callback threw, returned an empty
///   string or took longer than `timeout` (30 s), counted from when the fetch
///   started.
/// - The secret is never logged, and no copy is kept after answering.
@MainActor
final class ClientSecrets {
    nonisolated static let unavailableCode = "clientSecretUnavailable"
    nonisolated static let defaultTimeout: TimeInterval = 30

    let action: LinkAction
    private let fetch: Plugchoice.FetchClientSecret
    private let timeout: TimeInterval
    /// The fetch started when the screen opened, until the first call takes it.
    private var prefetched: Task<Result<String, BridgeError>, Never>?
    private var firstCallMade = false

    init(action: LinkAction, fetch: @escaping Plugchoice.FetchClientSecret, timeout: TimeInterval = ClientSecrets.defaultTimeout) {
        self.action = action
        self.fetch = fetch
        self.timeout = timeout
    }

    /// Starts the first fetch. Calling it again does nothing.
    func prefetch() {
        guard prefetched == nil, !firstCallMade else { return }
        prefetched = Task { await self.run() }
    }

    /// The secret for the page, or `clientSecretUnavailable`.
    func clientSecret() async throws -> String {
        let task: Task<Result<String, BridgeError>, Never>
        if !firstCallMade, let prefetched {
            task = prefetched
        } else {
            task = Task { await self.run() }
        }
        firstCallMade = true
        prefetched = nil
        return try await task.value.get()
    }

    /// The screen is closing: drops the prefetched secret, if nobody took it.
    func discard() {
        firstCallMade = true
        prefetched = nil
    }

    private func run() async -> Result<String, BridgeError> {
        await Self.fetch(fetch, action: action, timeout: timeout)
    }

    /// Runs `fetch` for `action` with a deadline. The callback isn't required
    /// to honour cancellation, so the deadline doesn't wait for it to return.
    nonisolated static func fetch(_ fetch: @escaping Plugchoice.FetchClientSecret, action: LinkAction, timeout: TimeInterval) async -> Result<String, BridgeError> {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            let work = Task.detached {
                do {
                    let secret = try await fetch(action)
                    if secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        gate.resume(.failure(unavailable("the host app's fetchClientSecret returned an empty string")))
                    } else {
                        gate.resume(.success(secret))
                    }
                } catch {
                    Bridge.log("fetchClientSecret threw: \(error)")
                    gate.resume(.failure(unavailable("the host app's fetchClientSecret threw")))
                }
            }
            let deadline = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                gate.resume(.failure(unavailable("the host app's fetchClientSecret took longer than \(Int(timeout)) s")))
                work.cancel()
            }
            gate.onResume = { deadline.cancel() }
        }
    }

    nonisolated static func unavailable(_ message: String) -> BridgeError {
        BridgeError(code: unavailableCode, message: message)
    }
}

/// Resumes a continuation once, from whichever task gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<String, BridgeError>, Never>?
    private var pendingOnResume: (@Sendable () -> Void)?
    private var resumed = false

    init(_ continuation: CheckedContinuation<Result<String, BridgeError>, Never>) {
        self.continuation = continuation
    }

    /// Runs once it resumed (at once when it already did).
    var onResume: (@Sendable () -> Void)? {
        get { nil }
        set {
            lock.lock()
            if resumed {
                lock.unlock()
                newValue?()
                return
            }
            pendingOnResume = newValue
            lock.unlock()
        }
    }

    func resume(_ result: Result<String, BridgeError>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        resumed = true
        let onResume = pendingOnResume
        pendingOnResume = nil
        lock.unlock()
        continuation.resume(returning: result)
        onResume?()
    }
}
