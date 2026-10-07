import Foundation

/// Runs one device's GATT requests one at a time, in the order sent
/// (PROTOCOL §11), each with the shell's operation timeout.
///
/// An operation starts its GATT call and says which delegate callback ends
/// it (`expectation`); the device hands callbacks to `finish(_:_:)`, which
/// ends the current operation only when it expects that callback. A late
/// callback (after a timeout) is ignored. After a timeout `onTimeout` runs:
/// the device then disconnects, since the peripheral may still answer, out
/// of step.
@MainActor
final class BLEOperationQueue {
    typealias Completion = (Result<JSONObject, BridgeError>) -> Void

    /// The callback an operation waits for, keyed by the characteristic's
    /// identity.
    enum Expectation: Equatable {
        case none
        case read(ObjectIdentifier)
        case write(ObjectIdentifier)
        case notificationState(ObjectIdentifier)
        /// `peripheralIsReady(toSendWriteWithoutResponse:)`.
        case readyToWriteWithoutResponse
    }

    final class Operation {
        fileprivate let start: (Operation) -> Void
        fileprivate let completion: Completion
        /// Set by `start` before its GATT call.
        var expectation = Expectation.none
        /// Runs when `readyToWriteWithoutResponse` arrives.
        var onReady: (() -> Void)?
        fileprivate var timer: BLECancellable?

        fileprivate init(start: @escaping (Operation) -> Void, completion: @escaping Completion) {
            self.start = start
            self.completion = completion
        }
    }

    let timeoutMs: Int
    private let scheduler: BLEScheduler
    /// After an operation timed out (and answered `timeout`).
    var onTimeout: (() -> Void)?
    private(set) var current: Operation?
    private var waiting: [Operation] = []

    init(timeoutMs: Int = 10_000, scheduler: BLEScheduler = DispatchScheduler()) {
        self.timeoutMs = timeoutMs
        self.scheduler = scheduler
    }

    /// Operations started or waiting.
    var count: Int { waiting.count + (current == nil ? 0 : 1) }

    /// Queues an operation. `start` runs when it's its turn; it sets the
    /// expectation and makes the GATT call, or ends at once with `finish`.
    func enqueue(start: @escaping (Operation) -> Void, completion: @escaping Completion) {
        waiting.append(Operation(start: start, completion: completion))
        startNext()
    }

    /// Ends `operation` when it is the current one (start ending at once).
    func finish(_ operation: Operation, _ result: Result<JSONObject, BridgeError>) {
        guard current === operation else { return }
        end(operation, result)
    }

    /// Ends the current operation when it waits for `expectation`. Returns
    /// whether it did (otherwise the callback is something else, such as a
    /// notification).
    @discardableResult
    func finish(_ expectation: Expectation, _ result: Result<JSONObject, BridgeError>) -> Bool {
        guard let current, current.expectation == expectation, expectation != .none else { return false }
        end(current, result)
        return true
    }

    /// The peripheral can take another write without response.
    func readyToWriteWithoutResponse() {
        guard let current, current.expectation == .readyToWriteWithoutResponse else { return }
        let onReady = current.onReady
        current.onReady = nil
        onReady?()
    }

    /// Answers every operation, started or waiting, with `error`.
    func failAll(_ error: BridgeError) {
        let all = (current.map { [$0] } ?? []) + waiting
        current = nil
        waiting.removeAll()
        for operation in all {
            operation.timer?.cancel()
            operation.completion(.failure(error))
        }
    }

    private func end(_ operation: Operation, _ result: Result<JSONObject, BridgeError>) {
        operation.timer?.cancel()
        operation.timer = nil
        current = nil
        operation.completion(result)
        startNext()
    }

    private func startNext() {
        guard current == nil, !waiting.isEmpty else { return }
        let operation = waiting.removeFirst()
        current = operation
        operation.timer = scheduler.schedule(afterMs: timeoutMs) { [weak self, weak operation] in
            guard let self, let operation else { return }
            self.timedOut(operation)
        }
        operation.start(operation)
    }

    private func timedOut(_ operation: Operation) {
        guard current === operation else { return }
        current = nil
        operation.timer = nil
        operation.completion(.failure(BridgeError(code: "timeout", message: "the device didn't answer within \(timeoutMs) ms")))
        onTimeout?()
        startNext()
    }
}

/// Runs a block later; a seam for tests.
@MainActor
protocol BLEScheduler {
    func schedule(afterMs: Int, _ body: @escaping @MainActor () -> Void) -> BLECancellable
}

@MainActor
protocol BLECancellable {
    func cancel()
}

/// The main queue.
struct DispatchScheduler: BLEScheduler {
    nonisolated init() {}

    final class Item: BLECancellable {
        let work: DispatchWorkItem

        init(_ work: DispatchWorkItem) {
            self.work = work
        }

        func cancel() {
            work.cancel()
        }
    }

    func schedule(afterMs: Int, _ body: @escaping @MainActor () -> Void) -> BLECancellable {
        let work = DispatchWorkItem {
            MainActor.assumeIsolated(body)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(afterMs), execute: work)
        return Item(work)
    }
}
