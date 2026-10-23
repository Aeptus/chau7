import XCTest
@testable import Chau7Core

final class TerminalRenderRetryPolicyTests: XCTestCase {
    func testRetryBackoffKeepsTransientFailuresResponsive() {
        XCTAssertEqual(
            TerminalRenderRetryPolicy.decision(
                reason: .noDrawable,
                consecutiveFailureCount: 1
            ).delay,
            0.05
        )
        XCTAssertEqual(
            TerminalRenderRetryPolicy.decision(
                reason: .noDrawable,
                consecutiveFailureCount: 3
            ).delay,
            0.05
        )
        XCTAssertEqual(
            TerminalRenderRetryPolicy.decision(
                reason: .noDrawable,
                consecutiveFailureCount: 4
            ).delay,
            0.10
        )
        XCTAssertEqual(
            TerminalRenderRetryPolicy.decision(
                reason: .noDrawable,
                consecutiveFailureCount: 11
            ).delay,
            0.25
        )
    }

    func testRetryLoggingIsSampled() {
        XCTAssertTrue(
            TerminalRenderRetryPolicy.decision(
                reason: .gridUnavailable,
                consecutiveFailureCount: 1
            ).shouldLog
        )
        XCTAssertTrue(
            TerminalRenderRetryPolicy.decision(
                reason: .gridUnavailable,
                consecutiveFailureCount: 3
            ).shouldLog
        )
        XCTAssertFalse(
            TerminalRenderRetryPolicy.decision(
                reason: .gridUnavailable,
                consecutiveFailureCount: 4
            ).shouldLog
        )
        XCTAssertTrue(
            TerminalRenderRetryPolicy.decision(
                reason: .gridUnavailable,
                consecutiveFailureCount: 10
            ).shouldLog
        )
    }

    func testRetryStateTracksConsecutiveReasonAndResetsOnSuccess() {
        var state = TerminalRenderRetryState()

        let first = state.recordFailure(reason: .zeroBounds)
        let second = state.recordFailure(reason: .zeroBounds)
        let changedReason = state.recordFailure(reason: .renderCommitFailed)

        XCTAssertEqual(first.consecutiveFailureCount, 1)
        XCTAssertEqual(second.consecutiveFailureCount, 2)
        XCTAssertEqual(changedReason.consecutiveFailureCount, 1)
        XCTAssertEqual(state.snapshot.lastReason, .renderCommitFailed)
        XCTAssertEqual(state.snapshot.consecutiveFailureCount, 1)

        state.recordSuccess()

        XCTAssertNil(state.snapshot.lastReason)
        XCTAssertEqual(state.snapshot.consecutiveFailureCount, 0)
    }
}
