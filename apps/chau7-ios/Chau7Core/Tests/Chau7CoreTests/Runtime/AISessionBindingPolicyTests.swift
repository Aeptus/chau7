import XCTest
@testable import Chau7Core

final class AISessionBindingPolicyTests: XCTestCase {
    private let tabID = UUID()

    func testRejectsStaleClaudeTargetWhenCodexIsCurrentlyActive() {
        let state = AISessionBindingPolicy.classify(
            incomingProvider: "Claude",
            incomingSessionID: "claude-stale",
            records: [record(activeApp: "Codex", sessionID: "codex-live")]
        )

        XCTAssertEqual(state, .conflicting(activeProvider: "codex"))
    }

    func testAllowsNewClaudeSessionWhenTabHasReturnedToShell() {
        let state = AISessionBindingPolicy.classify(
            incomingProvider: "Claude",
            incomingSessionID: "claude-new",
            records: [record(activeApp: "shell", sessionID: "claude-old")]
        )

        XCTAssertEqual(state, .available)
    }

    func testAllowsClaudeSessionReplacementWhileClaudeRemainsActive() {
        let state = AISessionBindingPolicy.classify(
            incomingProvider: "Claude",
            incomingSessionID: "claude-new",
            records: [record(activeApp: "Claude", sessionID: "claude-old")]
        )

        XCTAssertEqual(state, .available)
    }

    func testReportsExactLiveSessionMatch() {
        let state = AISessionBindingPolicy.classify(
            incomingProvider: "Claude",
            incomingSessionID: "claude-live",
            records: [record(activeApp: "Claude", sessionID: "claude-live")]
        )

        XCTAssertEqual(state, .matching)
    }

    func testIgnoresPersistedNonDisplayRecords() {
        let state = AISessionBindingPolicy.classify(
            incomingProvider: "Claude",
            incomingSessionID: "claude-new",
            records: [record(activeApp: "Codex", sessionID: "codex-old", isDisplaySession: false)]
        )

        XCTAssertEqual(state, .available)
    }

    private func record(
        activeApp: String,
        sessionID: String,
        isDisplaySession: Bool = true
    ) -> TabRouteRecord {
        TabRouteRecord(
            tabID: tabID,
            provider: AIResumeParser.normalizeProviderName(activeApp),
            activeAppName: activeApp,
            sessionID: sessionID,
            isDisplaySession: isDisplaySession
        )
    }
}
