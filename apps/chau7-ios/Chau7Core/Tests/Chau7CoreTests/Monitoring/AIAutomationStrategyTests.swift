import XCTest
import Chau7Core

final class AIAutomationStrategyTests: XCTestCase {
    func testCodexInputPlanSplitsTrailingSubmitIntoDelayedEnter() {
        let plan = AIAutomationStrategy.inputPlan(for: "Are you ready\n", provider: "Codex")

        XCTAssertEqual(plan.insertText, "Are you ready")
        XCTAssertEqual(plan.insertMode, .pasteText)
        // Enter key, never raw LF: current Codex TUIs parse 0x0A as Ctrl-J
        // and a rawNewline submit silently does nothing.
        XCTAssertEqual(plan.submitMode, .enterKey)
        XCTAssertEqual(plan.submitDelayMs, 120)
    }

    func testCodexInputPlanKeepsInternalNewlinesButStripsTrailingSubmit() {
        let plan = AIAutomationStrategy.inputPlan(for: "line 1\nline 2\r\n", provider: "codex")

        XCTAssertEqual(plan.insertText, "line 1\nline 2")
        XCTAssertEqual(plan.insertMode, .pasteText)
        XCTAssertEqual(plan.submitMode, .enterKey)
    }

    func testCodexExplicitSubmitUsesDelayOnlyForRecentAutomationInput() {
        let delayed = AIAutomationStrategy.submitPlan(provider: "Codex", recentAutomationInputAgeMs: 42)
        let immediate = AIAutomationStrategy.submitPlan(provider: "Codex", recentAutomationInputAgeMs: 5000)

        XCTAssertEqual(delayed.submitMode, .enterKey)
        XCTAssertEqual(delayed.submitDelayMs, 120)
        XCTAssertEqual(immediate.submitMode, .enterKey)
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

    func testRemoteInputPlanUsesCodexPasteAndDelayedEnter() {
        let plan = AIAutomationStrategy.remoteInputPlan(for: "fix the bug\r", provider: "Codex")

        XCTAssertEqual(plan.insertText, "fix the bug")
        XCTAssertEqual(plan.insertMode, .pasteText)
        XCTAssertEqual(plan.submitMode, .enterKey)
        XCTAssertEqual(plan.submitDelayMs, 120)
    }

    /// A bare Enter (interactive prompt confirmations) submits immediately
    /// with no body write and no delay — and must NOT clear the line, since
    /// confirming a pending resume prefill is exactly a bare Enter.
    func testRemoteInputPlanBareEnterSubmitsImmediately() {
        let plan = AIAutomationStrategy.remoteInputPlan(for: "\r", provider: "Claude")

        XCTAssertEqual(plan.insertText, "")
        XCTAssertEqual(plan.submitMode, .enterKey)
        XCTAssertEqual(plan.submitDelayMs, 0)
        XCTAssertFalse(plan.clearLineFirst)
    }

    /// A submitted body is a complete message: the plan clears the input line
    /// first so it replaces a pending prefill or stale draft instead of
    /// concatenating onto it. Non-terminated sends keep append semantics.
    func testRemoteInputPlanClearsLineOnlyForSubmittedBodies() {
        XCTAssertTrue(AIAutomationStrategy.remoteInputPlan(for: "run tests\r", provider: "Claude").clearLineFirst)
        XCTAssertTrue(AIAutomationStrategy.remoteInputPlan(for: "fix it\r", provider: "Codex").clearLineFirst)
        XCTAssertFalse(
            AIAutomationStrategy.remoteInputPlan(for: "partial draft", provider: "Claude").clearLineFirst,
            "non-terminated sends append deliberately"
        )
        XCTAssertFalse(
            AIAutomationStrategy.remoteInputPlan(for: "\u{1B}[A", provider: "Claude").clearLineFirst,
            "control sequences must pass through untouched"
        )
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

    // MARK: - keyInputSchedule (KEY_INPUT frame)

    func testKeyScheduleDelaysTrailingEnterAfterOtherKeys() {
        let schedule = AIAutomationStrategy.keyInputSchedule(for: [
            .init(key: "down"), .init(key: "down"), .init(key: "enter")
        ])

        XCTAssertEqual(
            schedule.map(\.delayMs),
            [0, 0, 60],
            "the TUI must re-render the moved selection before Enter confirms it"
        )
    }

    func testKeyScheduleLoneEnterIsImmediate() {
        let schedule = AIAutomationStrategy.keyInputSchedule(for: [.init(key: "enter")])
        XCTAssertEqual(schedule.map(\.delayMs), [0])
    }

    func testKeyScheduleNonTrailingAndModifiedEnterNotDelayed() {
        let midEnter = AIAutomationStrategy.keyInputSchedule(for: [
            .init(key: "down"), .init(key: "enter"), .init(key: "down")
        ])
        XCTAssertEqual(midEnter.map(\.delayMs), [0, 0, 0])

        let modified = AIAutomationStrategy.keyInputSchedule(for: [
            .init(key: "down"), .init(key: "enter", modifiers: ["shift"])
        ])
        XCTAssertEqual(modified.map(\.delayMs), [0, 0])
    }

    func testKeyScheduleCapsAtMaxKeys() {
        let keys = Array(repeating: RemoteKeyInputPayload.Key(key: "down"), count: 100)
        let schedule = AIAutomationStrategy.keyInputSchedule(for: keys)
        XCTAssertEqual(schedule.count, RemoteKeyInputPayload.maxKeys)
    }
}
