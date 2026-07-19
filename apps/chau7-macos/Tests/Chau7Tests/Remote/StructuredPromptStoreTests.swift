import XCTest
@testable import Chau7Core

final class StructuredPromptStoreTests: XCTestCase {
    private let tabA = UUID()
    private let tabB = UUID()

    private func singleSelectInput(
        question: String = "Which auth method should we use?",
        header: String? = "Auth",
        labels: [String] = ["OAuth (Recommended)", "JWT", "Cancel setup"],
        multiSelect: Bool = false
    ) -> String {
        var q: [String: Any] = [
            "question": question,
            "options": labels.map { ["label": $0, "description": "d"] },
            "multiSelect": multiSelect
        ]
        if let header { q["header"] = header }
        let root: [String: Any] = ["questions": [q]]
        let data = try! JSONSerialization.data(withJSONObject: root)
        return String(data: data, encoding: .utf8)!
    }

    private func makeStore(ttl: TimeInterval = 3600, now: @escaping () -> Date = Date.init) -> StructuredPromptStore {
        StructuredPromptStore(ttl: ttl, now: now)
    }

    // MARK: - Intake

    func testSingleSelectIntakeSynthesizesDigitOnlyResponses() throws {
        let store = makeStore()
        XCTAssertTrue(store.applyToolStart(
            toolName: "AskUserQuestion",
            toolInputJSON: singleSelectInput(),
            toolUseID: "toolu_1",
            runtimeTabID: tabA,
            sessionID: "s1"
        ))

        let entry = try XCTUnwrap(store.entry(forRuntimeTabID: tabA))
        XCTAssertEqual(entry.prompt, "Which auth method should we use?")
        XCTAssertEqual(entry.detail, "Auth")
        XCTAssertEqual(entry.options.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(entry.options.map(\.label), ["OAuth (Recommended)", "JWT", "Cancel setup"])
        // Digit only — no trailing CR: digits activate directly in Claude
        // Code, and a delayed Enter would land on the next screen.
        XCTAssertEqual(entry.options.map(\.response), ["1", "2", "3"])
        XCTAssertFalse(entry.options[0].isDestructive)
        XCTAssertTrue(entry.options[2].isDestructive, "'Cancel setup' matches the destructive vocabulary")
    }

    func testMultiSelectResponsesToggleThenSubmit() throws {
        let store = makeStore()
        store.applyToolStart(
            toolName: "AskUserQuestion",
            toolInputJSON: singleSelectInput(multiSelect: true),
            toolUseID: "toolu_1",
            runtimeTabID: tabA,
            sessionID: "s1"
        )

        let entry = try XCTUnwrap(store.entry(forRuntimeTabID: tabA))
        XCTAssertEqual(entry.options.map(\.response), ["1\r", "2\r", "3\r"])
        XCTAssertTrue(entry.detail?.contains("Multi-select") == true)
    }

    func testMultiQuestionPayloadIsNotSurfaced() throws {
        let store = makeStore()
        let root: [String: Any] = ["questions": [
            ["question": "Q1", "options": [["label": "A"], ["label": "B"]]],
            ["question": "Q2", "options": [["label": "C"], ["label": "D"]]]
        ]]
        let json = try String(data: JSONSerialization.data(withJSONObject: root), encoding: .utf8)!

        XCTAssertFalse(store.applyToolStart(
            toolName: "AskUserQuestion", toolInputJSON: json,
            toolUseID: "t", runtimeTabID: tabA, sessionID: "s1"
        ))
        XCTAssertNil(store.entry(forRuntimeTabID: tabA))
    }

    func testMalformedOrMissingInputIsIgnored() {
        let store = makeStore()
        for bad in [
            nil,
            "",
            "not json",
            "{\"questions\":[]}",
            "{\"questions\":[{\"question\":\"Q\",\"options\":[{\"label\":\"only one\"}]}]}"
        ] {
            XCTAssertFalse(store.applyToolStart(
                toolName: "AskUserQuestion", toolInputJSON: bad,
                toolUseID: "t", runtimeTabID: tabA, sessionID: "s1"
            ), "input \(bad ?? "nil") must not create an entry")
        }
        XCTAssertTrue(store.isEmpty)
    }

    func testOtherToolsAreIgnored() {
        let store = makeStore()
        XCTAssertFalse(store.applyToolStart(
            toolName: "Bash", toolInputJSON: singleSelectInput(),
            toolUseID: "t", runtimeTabID: tabA, sessionID: "s1"
        ))
        XCTAssertTrue(store.isEmpty)
    }

    // MARK: - Lifecycle

    func testToolEndClearsMatchingSessionOnly() {
        let store = makeStore()
        store.applyToolStart(
            toolName: "AskUserQuestion", toolInputJSON: singleSelectInput(),
            toolUseID: "t1", runtimeTabID: tabA, sessionID: "s1"
        )
        store.applyToolStart(
            toolName: "AskUserQuestion", toolInputJSON: singleSelectInput(question: "Other?"),
            toolUseID: "t2", runtimeTabID: tabB, sessionID: "s2"
        )

        // Unrelated tool completing must not clear anything.
        XCTAssertFalse(store.applyToolEnd(toolName: "Bash", sessionID: "s1"))
        XCTAssertNotNil(store.entry(forRuntimeTabID: tabA))

        // AskUserQuestion completing clears only its session.
        XCTAssertTrue(store.applyToolEnd(toolName: "AskUserQuestion", sessionID: "s1"))
        XCTAssertNil(store.entry(forRuntimeTabID: tabA))
        XCTAssertNotNil(store.entry(forRuntimeTabID: tabB))
    }

    func testSessionTerminalClearsRegardlessOfTool() {
        let store = makeStore()
        store.applyToolStart(
            toolName: "AskUserQuestion", toolInputJSON: singleSelectInput(),
            toolUseID: "t1", runtimeTabID: tabA, sessionID: "s1"
        )
        XCTAssertTrue(store.applySessionTerminal(sessionID: "s1"))
        XCTAssertTrue(store.isEmpty)
        XCTAssertFalse(store.applySessionTerminal(sessionID: "s1"), "second clear is a no-op")
    }

    func testEntriesExpireAfterTTL() {
        var current = Date(timeIntervalSince1970: 1000)
        let store = makeStore(ttl: 60) { current }
        store.applyToolStart(
            toolName: "AskUserQuestion", toolInputJSON: singleSelectInput(),
            toolUseID: "t1", runtimeTabID: tabA, sessionID: "s1"
        )
        XCTAssertNotNil(store.entry(forRuntimeTabID: tabA))

        current = current.addingTimeInterval(61)
        XCTAssertNil(store.entry(forRuntimeTabID: tabA))
        XCTAssertTrue(store.isEmpty)
    }

    // MARK: - ExitPlanMode

    private func exitPlanInput(plan: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["plan": plan])
        return String(data: data, encoding: .utf8)!
    }

    func testExitPlanModeCarriesPlanExcerptWithoutOptions() throws {
        let store = makeStore()
        XCTAssertTrue(store.applyToolStart(
            toolName: "ExitPlanMode",
            toolInputJSON: exitPlanInput(plan: String(repeating: "step ", count: 200)),
            toolUseID: "t1", runtimeTabID: tabA, sessionID: "s1"
        ))

        let entry = try XCTUnwrap(store.entry(forRuntimeTabID: tabA))
        XCTAssertEqual(entry.toolName, "ExitPlanMode")
        // No options: the on-screen approval menu labels aren't in
        // tool_input — the entry drives status only, the scrape supplies
        // the card.
        XCTAssertTrue(entry.options.isEmpty)
        XCTAssertEqual(entry.detail?.count, 501, "plan excerpt capped at 500 + ellipsis")
    }

    func testExitPlanModeWithoutPlanIsIgnored() {
        let store = makeStore()
        XCTAssertFalse(store.applyToolStart(
            toolName: "ExitPlanMode", toolInputJSON: "{}",
            toolUseID: "t1", runtimeTabID: tabA, sessionID: "s1"
        ))
        XCTAssertTrue(store.isEmpty)
    }

    func testToolEndClearIsScopedToTheEntryTool() {
        let store = makeStore()
        store.applyToolStart(
            toolName: "ExitPlanMode", toolInputJSON: exitPlanInput(plan: "the plan"),
            toolUseID: "t1", runtimeTabID: tabA, sessionID: "s1"
        )

        // A different interactive tool completing in the same session must
        // not clear a plan review still on screen.
        XCTAssertFalse(store.applyToolEnd(toolName: "AskUserQuestion", sessionID: "s1"))
        XCTAssertNotNil(store.entry(forRuntimeTabID: tabA))

        XCTAssertTrue(store.applyToolEnd(toolName: "ExitPlanMode", sessionID: "s1"))
        XCTAssertNil(store.entry(forRuntimeTabID: tabA))
    }

    // MARK: - Identity

    func testDuplicateApplyReportsNoChangeAndKeepsSignature() throws {
        let store = makeStore(now: { Date(timeIntervalSince1970: 5) })
        XCTAssertTrue(store.applyToolStart(
            toolName: "AskUserQuestion", toolInputJSON: singleSelectInput(),
            toolUseID: "t1", runtimeTabID: tabA, sessionID: "s1"
        ))
        let first = try XCTUnwrap(store.entry(forRuntimeTabID: tabA))

        XCTAssertFalse(store.applyToolStart(
            toolName: "AskUserQuestion", toolInputJSON: singleSelectInput(),
            toolUseID: "t1", runtimeTabID: tabA, sessionID: "s1"
        ), "identical re-apply (hook re-fire) must not report a change")
        XCTAssertEqual(store.entry(forRuntimeTabID: tabA)?.signature, first.signature)
    }

    func testSignatureDiffersPerToolUse() throws {
        let store = makeStore()
        store.applyToolStart(
            toolName: "AskUserQuestion", toolInputJSON: singleSelectInput(),
            toolUseID: "toolu_1", runtimeTabID: tabA, sessionID: "s1"
        )
        let first = try XCTUnwrap(store.entry(forRuntimeTabID: tabA))
        store.applyToolEnd(toolName: "AskUserQuestion", sessionID: "s1")

        store.applyToolStart(
            toolName: "AskUserQuestion", toolInputJSON: singleSelectInput(),
            toolUseID: "toolu_2", runtimeTabID: tabA, sessionID: "s1"
        )
        let second = try XCTUnwrap(store.entry(forRuntimeTabID: tabA))
        XCTAssertNotEqual(
            first.signature, second.signature,
            "asking the same question twice is two distinct prompts (two pushes)"
        )
    }
}
