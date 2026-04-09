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
