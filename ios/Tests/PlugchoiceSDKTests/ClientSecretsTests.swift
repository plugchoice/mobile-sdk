import XCTest
@testable import PlugchoiceSDK

/// `auth.clientSecret` (PROTOCOL §7): the secret fetched when the screen
/// opened, a new fetch for every later call, always with the action the
/// screen opened with, and `clientSecretUnavailable` when the host's callback
/// throws, returns nothing or takes too long.
@MainActor
final class ClientSecretsTests: XCTestCase {
    /// Counts calls and answers with `answers` in turn.
    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _actions: [LinkAction] = []
        var answers: [Result<String, Error>]
        var delay: TimeInterval = 0

        init(_ answers: [Result<String, Error>]) {
            self.answers = answers
        }

        var calls: Int {
            lock.withLock { _calls }
        }

        var actions: [LinkAction] {
            lock.withLock { _actions }
        }

        func fetch(_ action: LinkAction) async throws -> String {
            let (answer, delay) = lock.withLock { () -> (Result<String, Error>, TimeInterval) in
                let index = _calls
                _calls += 1
                _actions.append(action)
                return (index < answers.count ? answers[index] : answers.last!, delay)
            }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            return try answer.get()
        }
    }

    private struct Failure: Error {}

    private let opened = LinkAction.network(chargerId: "c-1")

    private func secrets(_ backend: Backend, timeout: TimeInterval = ClientSecrets.defaultTimeout) -> ClientSecrets {
        ClientSecrets(action: opened, fetch: { try await backend.fetch($0) }, timeout: timeout)
    }

    func testTheTimeoutIs30Seconds() {
        XCTAssertEqual(ClientSecrets.defaultTimeout, 30)
    }

    func testTheFirstCallGetsThePrefetchedSecret() async throws {
        let backend = Backend([.success("cs_test_first"), .success("cs_test_second")])
        let secrets = secrets(backend)
        secrets.prefetch()
        secrets.prefetch()
        let first = try await secrets.clientSecret()
        XCTAssertEqual(first, "cs_test_first")
        XCTAssertEqual(backend.calls, 1, "one fetch when the screen opened, used by the first call")
        XCTAssertEqual(backend.actions, [opened], "with the action the screen opened with")
    }

    func testTheFirstCallWaitsForTheFetchStillRunning() async throws {
        let backend = Backend([.success("cs_test_slow")])
        backend.delay = 0.2
        let secrets = secrets(backend)
        secrets.prefetch()
        let secret = try await secrets.clientSecret()
        XCTAssertEqual(secret, "cs_test_slow")
        XCTAssertEqual(backend.calls, 1)
    }

    func testEveryLaterCallFetchesAgain() async throws {
        let backend = Backend([.success("cs_test_1"), .success("cs_test_2"), .success("cs_test_3")])
        let secrets = secrets(backend)
        secrets.prefetch()
        let first = try await secrets.clientSecret()
        let second = try await secrets.clientSecret()
        let third = try await secrets.clientSecret()
        XCTAssertEqual([first, second, third], ["cs_test_1", "cs_test_2", "cs_test_3"])
        XCTAssertEqual(backend.calls, 3)
        XCTAssertEqual(backend.actions, [opened, opened, opened], "refreshes get the same action")
        XCTAssertEqual(backend.actions.first?.action, "network")
        XCTAssertEqual(backend.actions.first?.chargerId, "c-1")
    }

    func testWithoutAPrefetchTheFirstCallFetches() async throws {
        let backend = Backend([.success("cs_test_1")])
        let secret = try await secrets(backend).clientSecret()
        XCTAssertEqual(secret, "cs_test_1")
        XCTAssertEqual(backend.calls, 1)
    }

    func testAThrowingCallbackIsUnavailableAndTheNextCallTriesAgain() async throws {
        let backend = Backend([.failure(Failure()), .success("cs_test_retry")])
        let secrets = secrets(backend)
        secrets.prefetch()
        await assertUnavailable(secrets)
        let retried = try await secrets.clientSecret()
        XCTAssertEqual(retried, "cs_test_retry", "the page's Try again calls again")
    }

    func testAnEmptySecretIsUnavailable() async {
        for empty in ["", "  \n"] {
            await assertUnavailable(secrets(Backend([.success(empty)])))
        }
    }

    func testASlowCallbackRunsOutItsTimeout() async {
        let backend = Backend([.success("cs_test_late")])
        backend.delay = 5
        let secrets = secrets(backend, timeout: 0.1)
        let started = Date()
        await assertUnavailable(secrets)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the deadline doesn't wait for the callback")
    }

    func testTheTimeoutCountsFromThePrefetch() async throws {
        let backend = Backend([.success("cs_test_late")])
        backend.delay = 5
        let secrets = secrets(backend, timeout: 0.2)
        secrets.prefetch()
        try await Task.sleep(nanoseconds: 150_000_000)
        let started = Date()
        await assertUnavailable(secrets)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.15)
    }

    func testDiscardDropsThePrefetchedSecret() async throws {
        let backend = Backend([.success("cs_test_1"), .success("cs_test_2")])
        let secrets = secrets(backend)
        secrets.prefetch()
        // Once the prefetch has called the host (otherwise the next call
        // could be the first to reach it and get its answer).
        while backend.calls == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        secrets.discard()
        let secret = try await secrets.clientSecret()
        XCTAssertEqual(secret, "cs_test_2", "the prefetched one is gone")
    }

    // MARK: - Through the bridge

    func testTheMessageIsNeverTheSecret() async {
        let result = await ClientSecrets.fetch({ _ in throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "cs_test_leak"]) }, action: opened, timeout: 5)
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(error.code, "clientSecretUnavailable")
        XCTAssertFalse(error.message.contains("cs_test_leak"))
    }

    // MARK: - Helpers

    private func assertUnavailable(_ secrets: ClientSecrets, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await secrets.clientSecret()
            XCTFail("expected clientSecretUnavailable", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? BridgeError)?.code, "clientSecretUnavailable", file: file, line: line)
        }
    }
}
