import XCTest
@testable import Chau7Core

final class TerminalPromptNotificationAdapterTests: XCTestCase {
    func testDoesNotEmitForClaudeFallback() {
        let context = TerminalPromptNotificationContext(
            previousStatus: "running",
            hasOwnerTab: true,
            runtimeOwnsTab: false,
            providerID: "claude",
            providerIsRestored: false,
            hasPendingPrefillInput: false,
            commandLooksLikeResume: false,
            observedAIRoundTrip: true,
            sessionID: "session-1"
        )

        XCTAssertFalse(TerminalPromptNotificationAdapter.shouldEmitWaitingInput(from: context))
    }

    func testDoesNotEmitForResumeLikePrompt() {
        let context = TerminalPromptNotificationContext(
            previousStatus: "running",
            hasOwnerTab: true,
            runtimeOwnsTab: false,
            providerID: "codex",
            providerIsRestored: true,
            hasPendingPrefillInput: false,
            commandLooksLikeResume: true,
            observedAIRoundTrip: true,
            sessionID: "session-1"
        )

        XCTAssertFalse(TerminalPromptNotificationAdapter.shouldEmitWaitingInput(from: context))
    }

    func testEmitsForNonClaudePromptFallbackAfterObservedRoundTrip() {
        let context = TerminalPromptNotificationContext(
            previousStatus: "running",
            hasOwnerTab: true,
            runtimeOwnsTab: false,
            providerID: "codex",
            providerIsRestored: false,
            hasPendingPrefillInput: false,
            commandLooksLikeResume: false,
            observedAIRoundTrip: true,
            sessionID: "session-1"
        )

        XCTAssertTrue(TerminalPromptNotificationAdapter.shouldEmitWaitingInput(from: context))
    }
}
