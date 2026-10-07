import Foundation

/// What a native close (the close button, a swipe down on the sheet) does
/// (PROTOCOL §6.2).
///
/// Until the page has answered `hello` (while loading, after a load error)
/// it closes at once. After that the page decides: it gets
/// `ui.closeRequested` and has `timeout` to call `session.close` or
/// `ui.closeHandled`. A page that does neither (hung) is closed with
/// `cancelled`.
@MainActor
final class CloseGuard {
    nonisolated static let defaultTimeout: TimeInterval = 1

    /// The page answered `hello` and handles close requests.
    var pageDecides = false
    /// Send `ui.closeRequested` to the page.
    var onAskPage: (() -> Void)?
    /// Close the screen with `cancelled`.
    var onClose: (() -> Void)?

    let timeout: TimeInterval
    private var deadline: Task<Void, Never>?

    init(timeout: TimeInterval = CloseGuard.defaultTimeout) {
        self.timeout = timeout
    }

    /// The page was asked and hasn't answered yet.
    var isWaitingForPage: Bool { deadline != nil }

    /// The user tried to leave natively.
    func userWantsToClose() {
        guard pageDecides else {
            onClose?()
            return
        }
        // Asked already: the first deadline stands.
        guard deadline == nil else { return }
        let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.deadline = nil
            self.onClose?()
        }
        onAskPage?()
    }

    /// `ui.closeHandled`: the page is alive and asking the user. The next
    /// native close asks it again.
    func pageAnswered() {
        deadline?.cancel()
        deadline = nil
    }

    /// A new document in the main frame: native closes close at once until it
    /// says `hello`. A pending deadline keeps running (the user still wants
    /// out).
    func pageChanged() {
        pageDecides = false
    }

    /// The screen is closing anyway.
    func stop() {
        pageAnswered()
        onAskPage = nil
        onClose = nil
    }
}
