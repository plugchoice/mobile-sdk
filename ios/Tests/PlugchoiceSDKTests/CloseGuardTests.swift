import XCTest
@testable import PlugchoiceSDK

@MainActor
final class CloseGuardTests: XCTestCase {
    private let timeout: TimeInterval = 0.1
    private var guardUnderTest: CloseGuard!
    private var asked = 0
    private var closed = 0

    override func setUp() async throws {
        try await super.setUp()
        guardUnderTest = CloseGuard(timeout: timeout)
        asked = 0
        closed = 0
        guardUnderTest.onAskPage = { [unowned self] in self.asked += 1 }
        guardUnderTest.onClose = { [unowned self] in self.closed += 1 }
    }

    func testDefaultTimeoutIsOneSecond() {
        XCTAssertEqual(CloseGuard.defaultTimeout, 1)
        XCTAssertEqual(CloseGuard().timeout, 1)
    }

    func testClosesAtOnceBeforeTheHandshake() {
        guardUnderTest.userWantsToClose()
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(guardUnderTest.isWaitingForPage)
    }

    func testAsksAV1PageAndClosesWhenItDoesNotAnswer() async throws {
        guardUnderTest.pageDecides = true
        guardUnderTest.userWantsToClose()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(closed, 0, "stays open while the page may answer")
        XCTAssertTrue(guardUnderTest.isWaitingForPage)

        try await sleep(timeout / 2)
        XCTAssertEqual(closed, 0)

        try await sleep(timeout * 2)
        XCTAssertEqual(closed, 1, "a hung page is closed after the timeout")
        XCTAssertFalse(guardUnderTest.isWaitingForPage)
    }

    func testCloseHandledStopsTheDeadline() async throws {
        guardUnderTest.pageDecides = true
        guardUnderTest.userWantsToClose()
        try await sleep(timeout / 2)
        guardUnderTest.pageAnswered()
        try await sleep(timeout * 2)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(closed, 0)
    }

    func testRepeatedAttemptsWhileWaitingAskOnceAndKeepTheFirstDeadline() async throws {
        guardUnderTest.pageDecides = true
        guardUnderTest.userWantsToClose()
        try await sleep(timeout * 0.6)
        guardUnderTest.userWantsToClose()
        guardUnderTest.userWantsToClose()
        XCTAssertEqual(asked, 1)
        try await sleep(timeout * 0.8)
        XCTAssertEqual(closed, 1, "the first deadline stands")
    }

    func testAsksAgainAfterThePageHandledTheFirstRequest() async throws {
        guardUnderTest.pageDecides = true
        guardUnderTest.userWantsToClose()
        guardUnderTest.pageAnswered()
        guardUnderTest.userWantsToClose()
        XCTAssertEqual(asked, 2)
        XCTAssertTrue(guardUnderTest.isWaitingForPage)
        try await sleep(timeout * 2)
        XCTAssertEqual(closed, 1)
    }

    func testANewPageClosesAtOnceUntilItsHello() {
        guardUnderTest.pageDecides = true
        guardUnderTest.pageChanged()
        guardUnderTest.userWantsToClose()
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(closed, 1)
    }

    func testAPendingDeadlineSurvivesAPageChange() async throws {
        guardUnderTest.pageDecides = true
        guardUnderTest.userWantsToClose()
        guardUnderTest.pageChanged()
        try await sleep(timeout * 2)
        XCTAssertEqual(closed, 1)
    }

    func testStopCancelsEverything() async throws {
        guardUnderTest.pageDecides = true
        guardUnderTest.userWantsToClose()
        guardUnderTest.stop()
        try await sleep(timeout * 2)
        XCTAssertEqual(closed, 0)
        guardUnderTest.userWantsToClose()
        XCTAssertEqual(asked, 1, "no callbacks after stop")
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
