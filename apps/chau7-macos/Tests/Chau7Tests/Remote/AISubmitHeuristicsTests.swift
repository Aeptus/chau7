import XCTest
@testable import Chau7Core

final class AISubmitHeuristicsTests: XCTestCase {
    func testShouldObserveAfterFirstEnterForCodexDraft() {
        let snapshot = AISubmitSnapshot(
            toolName: "Codex",
            status: "running",
            isAtPrompt: true,
            transcript: "› Audit Chau7 MCP"
        )

        XCTAssertTrue(AISubmitHeuristics.shouldObserveAfterFirstEnter(snapshot))
    }

    func testDoesNotObserveUnsupportedTool() {
        let snapshot = AISubmitSnapshot(
            toolName: "zsh",
            status: "running",
            isAtPrompt: true,
            transcript: "› echo hello"
        )

        XCTAssertFalse(AISubmitHeuristics.shouldObserveAfterFirstEnter(snapshot))
    }

    func testDetectsWorkStartedWhenPromptLeavesAndWorkingAppears() {
        let initial = AISubmitSnapshot(
            toolName: "Codex",
            status: "running",
            isAtPrompt: true,
            transcript: "› Audit Chau7 MCP"
        )
        let current = AISubmitSnapshot(
            toolName: "Codex",
            status: "running",
            isAtPrompt: false,
            transcript: "• Working (3s • esc to interrupt)"
        )

        XCTAssertTrue(AISubmitHeuristics.workStarted(initial: initial, current: current))
        XCTAssertFalse(AISubmitHeuristics.shouldSendSecondEnter(initial: initial, current: current))
    }

    func testRequestsSecondEnterWhenDraftPersistsAtPrompt() {
        let initial = AISubmitSnapshot(
            toolName: "Codex",
            status: "running",
            isAtPrompt: true,
            transcript: "› Audit Chau7 MCP and report back"
        )
        let current = AISubmitSnapshot(
            toolName: "Codex",
            status: "running",
            isAtPrompt: true,
            transcript: "› Audit Chau7 MCP and report back"
        )

        XCTAssertTrue(AISubmitHeuristics.shouldSendSecondEnter(initial: initial, current: current))
    }

    func testRequestsSecondEnterAfterInteractivePromptClearsButDraftRemains() {
        let initial = AISubmitSnapshot(
            toolName: "Codex",
            status: "waitingForInput",
            isAtPrompt: true,
            transcript: """
            Do you want to continue?
            1. Continue
            2. Cancel

            › Audit Chau7 MCP and report back
            """
        )
        let current = AISubmitSnapshot(
            toolName: "Codex",
            status: "running",
            isAtPrompt: true,
            transcript: "› Audit Chau7 MCP and report back"
        )

        XCTAssertTrue(AISubmitHeuristics.shouldSendSecondEnter(initial: initial, current: current))
    }

    func testDoesNotRequestSecondEnterWithoutDraftOrPrompt() {
        let initial = AISubmitSnapshot(
            toolName: "Codex",
            status: "running",
            isAtPrompt: true,
            transcript: ""
        )
        let current = AISubmitSnapshot(
            toolName: "Codex",
            status: "running",
            isAtPrompt: true,
            transcript: ""
        )

        XCTAssertFalse(AISubmitHeuristics.shouldSendSecondEnter(initial: initial, current: current))
    }
}
