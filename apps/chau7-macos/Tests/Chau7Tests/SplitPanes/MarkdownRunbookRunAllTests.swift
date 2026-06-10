import XCTest
@testable import Chau7
@testable import Chau7Core

/// Covers `TextEditorModel.runMarkdownBlocksSequentially`, which replaced the
/// old fixed-stagger Run All loop. The new runner waits for each block's run
/// state to leave `.running` before sending the next, so a long first command
/// can't paste-bomb the shell with the second.
@MainActor
final class MarkdownRunbookRunAllTests: XCTestCase {

    func testRunAllSendsBlocksOnlyAfterEachSettles() {
        let model = TextEditorModel()
        let blocks: [(line: Int, code: String)] = [
            (line: 10, code: "echo one"),
            (line: 20, code: "echo two"),
            (line: 30, code: "echo three")
        ]

        var sent: [(String, Int)] = []
        model.runMarkdownBlocksSequentially(blocks) { command, lineNumber in
            sent.append((command, lineNumber))
            // Mirror what `markCodeBlockQueued` does inline — flip the
            // block to `.running` so the runner knows it's in flight.
            let key = TextEditorModel.RunbookCodeBlockKey(
                lineNumber: lineNumber,
                normalizedCommand: command.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            model.codeBlockRunStates[key] = .running
        }

        // First block fires synchronously; the next two are gated.
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0, "echo one\n")
        XCTAssertEqual(sent[0].1, 10)

        // Still in `.running` after spinning the loop — runner waits.
        spin(0.6)
        XCTAssertEqual(sent.count, 1, "runner must not advance while block is still running")

        // Mark block 1 succeeded; runner should send block 2 within ~250ms.
        settle(at: 10, command: "echo one", to: .succeeded, model: model)
        waitForSent(count: 2, sent: { sent }, timeout: 2.0)
        XCTAssertEqual(sent[1].0, "echo two\n")

        // Failure also counts as settled; runner advances anyway.
        settle(at: 20, command: "echo two", to: .failed, model: model)
        waitForSent(count: 3, sent: { sent }, timeout: 2.0)
        XCTAssertEqual(sent[2].0, "echo three\n")
    }

    func testRunAllStopsWhenBlockNeverSettles() {
        // No state ever transitions; the runner should keep polling but
        // never advance past the first block.
        let model = TextEditorModel()
        let blocks: [(line: Int, code: String)] = [
            (line: 1, code: "hang"),
            (line: 2, code: "never sent")
        ]

        var sent: [(String, Int)] = []
        model.runMarkdownBlocksSequentially(blocks) { command, lineNumber in
            sent.append((command, lineNumber))
            // Intentionally don't set `.running` — simulates "no terminal
            // attached" path where markCodeBlockQueued never gets called.
        }

        XCTAssertEqual(sent.count, 1)
        spin(1.5)
        XCTAssertEqual(sent.count, 1, "runner must not advance without a settled state")
    }

    // MARK: - Helpers

    private func settle(
        at line: Int,
        command: String,
        to state: RunbookCodeBlockState,
        model: TextEditorModel
    ) {
        let key = TextEditorModel.RunbookCodeBlockKey(
            lineNumber: line,
            normalizedCommand: command
        )
        model.codeBlockRunStates[key] = state
    }

    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func waitForSent(
        count target: Int,
        sent: () -> [(String, Int)],
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sent().count >= target { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(sent().count, target, "did not reach \(target) sent blocks in time")
    }
}
