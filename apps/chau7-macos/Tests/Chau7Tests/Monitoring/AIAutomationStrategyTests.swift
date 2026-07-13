import XCTest
import Chau7Core

final class AIAutomationStrategyTests: XCTestCase {
    func testCodexInputPlanSplitsTrailingSubmitIntoDelayedNewline() {
        let plan = AIAutomationStrategy.inputPlan(for: "Are you ready\n", provider: "Codex")

        XCTAssertEqual(plan.insertText, "Are you ready")
        XCTAssertEqual(plan.insertMode, .pasteText)
        XCTAssertEqual(plan.submitMode, .rawNewline)
        XCTAssertEqual(plan.submitDelayMs, 120)
    }

    func testCodexInputPlanKeepsInternalNewlinesButStripsTrailingSubmit() {
        let plan = AIAutomationStrategy.inputPlan(for: "line 1\nline 2\r\n", provider: "codex")

        XCTAssertEqual(plan.insertText, "line 1\nline 2")
        XCTAssertEqual(plan.insertMode, .pasteText)
        XCTAssertEqual(plan.submitMode, .rawNewline)
    }

    func testCodexExplicitSubmitUsesDelayOnlyForRecentAutomationInput() {
        let delayed = AIAutomationStrategy.submitPlan(provider: "Codex", recentAutomationInputAgeMs: 42)
        let immediate = AIAutomationStrategy.submitPlan(provider: "Codex", recentAutomationInputAgeMs: 5000)

        XCTAssertEqual(delayed.submitMode, .rawNewline)
        XCTAssertEqual(delayed.submitDelayMs, 120)
        XCTAssertEqual(immediate.submitMode, .rawNewline)
        XCTAssertEqual(immediate.submitDelayMs, 0)
    }

    // MARK: - remoteInputPlan (iOS keyboard sends)

    /// A remote send's trailing CR must become a separate delayed Enter — a
    /// single "text\r" PTY chunk reads as a paste to TUI composers and never
    /// submits.
    func testRemoteInputPlanSplitsTrailingCRIntoDelayedEnterKey() {
        let plan = AIAutomationStrategy.remoteInputPlan(for: "hello claude\r", provider: "Claude")

        XCTAssertEqual(plan.insertText, "hello claude")
        XCTAssertEqual(plan.insertMode, .rawText)
        XCTAssertEqual(plan.submitMode, .enterKey)
        XCTAssertEqual(plan.submitDelayMs, 60)
    }

    /// Legacy iOS builds terminate with LF; the plan must treat it as the
    /// same submit intent.
    func testRemoteInputPlanTreatsTrailingLFAsSubmit() {
        let plan = AIAutomationStrategy.remoteInputPlan(for: "echo hi\n", provider: nil)

        XCTAssertEqual(plan.insertText, "echo hi")
        XCTAssertEqual(plan.submitMode, .enterKey)
        XCTAssertEqual(plan.submitDelayMs, 60)
    }

    func testRemoteInputPlanUsesCodexPasteAndDelayedNewline() {
        let plan = AIAutomationStrategy.remoteInputPlan(for: "fix the bug\r", provider: "Codex")

        XCTAssertEqual(plan.insertText, "fix the bug")
        XCTAssertEqual(plan.insertMode, .pasteText)
        XCTAssertEqual(plan.submitMode, .rawNewline)
        XCTAssertEqual(plan.submitDelayMs, 120)
    }

    /// A bare Enter (interactive prompt confirmations) submits immediately
    /// with no body write and no delay.
    func testRemoteInputPlanBareEnterSubmitsImmediately() {
        let plan = AIAutomationStrategy.remoteInputPlan(for: "\r", provider: "Claude")

        XCTAssertEqual(plan.insertText, "")
        XCTAssertEqual(plan.submitMode, .enterKey)
        XCTAssertEqual(plan.submitDelayMs, 0)
    }

    /// Keyboard-bar control sequences (ESC, ^C, arrows) carry no terminator
    /// and must pass through raw and untouched — never paste-wrapped.
    func testRemoteInputPlanPassesControlSequencesThroughRaw() {
        for sequence in ["\u{1B}", "\u{03}", "\u{1B}[A"] {
            let plan = AIAutomationStrategy.remoteInputPlan(for: sequence, provider: "Codex")

            XCTAssertEqual(plan.insertText, sequence)
            XCTAssertEqual(plan.insertMode, .rawText)
            XCTAssertEqual(plan.submitMode, .none)
        }
    }

    func testNonCodexAutomationStaysRaw() {
        let inputPlan = AIAutomationStrategy.inputPlan(for: "echo hi\n", provider: "Claude")
        let submitPlan = AIAutomationStrategy.submitPlan(provider: "Claude", recentAutomationInputAgeMs: 10)

        XCTAssertEqual(inputPlan.insertText, "echo hi\n")
        XCTAssertEqual(inputPlan.insertMode, .rawText)
        XCTAssertEqual(inputPlan.submitMode, .none)
        XCTAssertEqual(submitPlan.submitMode, .enterKey)
        XCTAssertEqual(submitPlan.submitDelayMs, 0)
    }
}
