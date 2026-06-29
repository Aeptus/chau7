import XCTest
@testable import Chau7

/// Direct tests for the RunbookHostAdapter that bridges TextEditorModel +
/// a "send command to terminal" closure into the unified RunbookHost
/// surface MarkdownRunbookView consumes. The integration path is covered
/// by MarkdownRunbookRunAllTests through the model; these tests pin the
/// adapter forwards.
@MainActor
final class RunbookHostAdapterTests: XCTestCase {

    func testRunBlockForwardsCodeWithTrailingNewlineToSendCommand() {
        let editor = TextEditorModel()
        var sentCommands: [(String, Int)] = []
        let adapter = RunbookHostAdapter(editor: editor) { command, line in
            sentCommands.append((command, line))
        }

        adapter.runBlock("echo hi", lineNumber: 12)

        XCTAssertEqual(sentCommands.count, 1)
        XCTAssertEqual(sentCommands[0].0, "echo hi\n")
        XCTAssertEqual(sentCommands[0].1, 12)
    }

    func testCodeBlockStateForwardsToEditorRunbookTracker() {
        let editor = TextEditorModel()
        let adapter = RunbookHostAdapter(editor: editor) { _, _ in }
        let key = RunbookCodeBlockTracker.runbookCodeBlockKey(for: "echo hello", lineNumber: 4)
        editor.runbook.codeBlockRunStates[key] = .succeeded

        XCTAssertEqual(adapter.codeBlockState(for: "echo hello", lineNumber: 4), .succeeded)
        XCTAssertNil(adapter.codeBlockState(for: "echo missing", lineNumber: 99))
    }

    func testUpdateContentForwardsToEditorBuffer() {
        let editor = TextEditorModel()
        let adapter = RunbookHostAdapter(editor: editor) { _, _ in }

        adapter.updateContent("new content\n")
        XCTAssertEqual(editor.content, "new content\n")
        XCTAssertTrue(editor.isDirty)
    }
}
