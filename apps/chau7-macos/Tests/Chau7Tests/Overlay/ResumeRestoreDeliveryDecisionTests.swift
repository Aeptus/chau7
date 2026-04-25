import XCTest
@testable import Chau7

/// SPM-runnable tests for `OverlayTabsModel.decideResumeRestoreDeliveryUpdate`.
///
/// The state machine governing per-pane resume-prefill outcomes has three
/// rules:
///   1. Terminal outcomes (`delivered`, `rejected`) are sticky — a later
///      `superseded` for the same token cannot overwrite them.
///   2. A newer token (different from the existing entry's token) wins;
///      a stale `superseded` for an older token is dropped.
///   3. Any non-`superseded` outcome always writes (latest wins on the
///      same token; tokens are advanced when a new restore cycle begins).
///
/// Before T4 these rules lived inline in `recordResumeRestoreDeliveryState`
/// and were unreachable from `swift test`. Extracting the decision lets us
/// pin the rules with unit tests before W3.28 decomposes the surrounding
/// 400-line `restoreTabState`.
final class ResumeRestoreDeliveryDecisionTests: XCTestCase {

    private typealias Decision = OverlayTabsModel.ResumeRestoreDeliveryDecision
    private typealias State = OverlayTabsModel.ResumeRestoreDeliveryState
    private typealias Outcome = OverlayTabsModel.ResumeRestoreDeliveryState.Outcome

    // MARK: - First-write paths

    /// No existing entry: any incoming outcome writes through, including superseded.
    func testNoExistingEntryAlwaysWrites() {
        for outcome in [Outcome.pending, .queued, .delivered, .rejected, .superseded] {
            let decision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
                existing: nil,
                newToken: "token-A",
                newOutcome: outcome
            )
            XCTAssertEqual(
                decision,
                .write(State(token: "token-A", outcome: outcome)),
                "First write of \(outcome.rawValue) must succeed regardless of value"
            )
        }
    }

    // MARK: - Terminal outcome stickiness

    /// `delivered` is terminal — a `superseded` for the same token must
    /// preserve the delivered state.
    func testSupersededDoesNotOverwriteDelivered() {
        let existing = State(token: "token-A", outcome: .delivered)
        let decision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
            existing: existing,
            newToken: "token-A",
            newOutcome: .superseded
        )
        XCTAssertEqual(decision, .preserveTerminalOutcome)
    }

    /// `rejected` is also terminal.
    func testSupersededDoesNotOverwriteRejected() {
        let existing = State(token: "token-A", outcome: .rejected)
        let decision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
            existing: existing,
            newToken: "token-A",
            newOutcome: .superseded
        )
        XCTAssertEqual(decision, .preserveTerminalOutcome)
    }

    /// Non-superseded outcomes always overwrite — this is the "latest cycle
    /// wins" property. A new pending/queued/delivered/rejected with the same
    /// token must succeed even if a delivered/rejected exists.
    func testNonSupersededOverwritesEvenTerminalState() {
        let existing = State(token: "token-A", outcome: .delivered)

        let pendingDecision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
            existing: existing,
            newToken: "token-A",
            newOutcome: .pending
        )
        XCTAssertEqual(
            pendingDecision,
            .write(State(token: "token-A", outcome: .pending)),
            "Same-token pending must overwrite delivered (next restore cycle, latest state wins)"
        )

        let rejectedDecision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
            existing: existing,
            newToken: "token-A",
            newOutcome: .rejected
        )
        XCTAssertEqual(
            rejectedDecision,
            .write(State(token: "token-A", outcome: .rejected)),
            "Rejected must overwrite delivered for the same token"
        )
    }

    // MARK: - Newer token wins

    /// A `superseded` for an older token must be dropped — the newer token's
    /// state is fresher.
    func testSupersededWithOlderTokenIsDropped() {
        let existing = State(token: "token-newer", outcome: .pending)
        let decision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
            existing: existing,
            newToken: "token-stale",
            newOutcome: .superseded
        )
        XCTAssertEqual(decision, .preserveNewerToken)
    }

    /// A non-`superseded` for a different token writes through — that's
    /// how new restore cycles bring their own token in.
    func testNonSupersededWithDifferentTokenWrites() {
        let existing = State(token: "token-A", outcome: .delivered)
        let decision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
            existing: existing,
            newToken: "token-B",
            newOutcome: .pending
        )
        XCTAssertEqual(
            decision,
            .write(State(token: "token-B", outcome: .pending)),
            "A different token's pending starts a fresh delivery cycle and overwrites"
        )
    }

    // MARK: - Same-token, non-terminal supersession

    /// Same token, existing is `pending` (non-terminal): superseded writes through.
    /// Pending → superseded is a valid transition (e.g. a new restore cycle for
    /// the same token, where the old delivery was queued but a fresher one took over).
    func testSupersededOverwritesPendingSameToken() {
        let existing = State(token: "token-A", outcome: .pending)
        let decision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
            existing: existing,
            newToken: "token-A",
            newOutcome: .superseded
        )
        XCTAssertEqual(
            decision,
            .write(State(token: "token-A", outcome: .superseded))
        )
    }

    /// Same as above for queued (also non-terminal).
    func testSupersededOverwritesQueuedSameToken() {
        let existing = State(token: "token-A", outcome: .queued)
        let decision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
            existing: existing,
            newToken: "token-A",
            newOutcome: .superseded
        )
        XCTAssertEqual(
            decision,
            .write(State(token: "token-A", outcome: .superseded))
        )
    }

    /// Same-token superseded → superseded: still writes (the rule is
    /// "preserve TERMINAL outcomes from supersession", not "preserve
    /// supersession from supersession"). Latest write wins for non-terminal.
    func testSupersededOverwritesSupersededSameToken() {
        let existing = State(token: "token-A", outcome: .superseded)
        let decision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
            existing: existing,
            newToken: "token-A",
            newOutcome: .superseded
        )
        XCTAssertEqual(
            decision,
            .write(State(token: "token-A", outcome: .superseded))
        )
    }

    // MARK: - Token prefix invariant

    /// Token comparisons are full-string, not prefix. A truncated token must
    /// be treated as different from the full token.
    func testTokenComparisonIsFullStringNotPrefix() {
        let existing = State(token: "token-FULL-VALUE-12345", outcome: .pending)
        let decision = OverlayTabsModel.decideResumeRestoreDeliveryUpdate(
            existing: existing,
            newToken: "token-FULL",
            newOutcome: .superseded
        )
        XCTAssertEqual(
            decision,
            .preserveNewerToken,
            "Token prefix is not a token match — the existing full token wins"
        )
    }
}
