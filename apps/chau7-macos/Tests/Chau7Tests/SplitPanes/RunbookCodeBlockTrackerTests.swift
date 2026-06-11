import XCTest
@testable import Chau7

/// Direct tests for the extracted RunbookCodeBlockTracker. The integration
/// path is covered by MarkdownRunbookRunAllTests via the editor; these
/// tests pin the tracker's own contract (state lookup, sequential runner
/// settles on .succeeded / .failed, normalization).
@MainActor
final class RunbookCodeBlockTrackerTests: XCTestCase {

    func testCodeBlockStateReturnsNilForUntrackedKey() {
        let tracker = RunbookCodeBlockTracker()
        XCTAssertNil(tracker.codeBlockState(for: "echo hi", lineNumber: 7))
    }

    func testManualStateSetIsObservableViaCodeBlockState() {
        let tracker = RunbookCodeBlockTracker()
        let key = RunbookCodeBlockTracker.runbookCodeBlockKey(for: "echo hi", lineNumber: 7)
        tracker.codeBlockRunStates[key] = .succeeded
        XCTAssertEqual(tracker.codeBlockState(for: "echo hi", lineNumber: 7), .succeeded)
    }

    func testNormalizationStripsLeadingAndTrailingWhitespace() {
        let key1 = RunbookCodeBlockTracker.runbookCodeBlockKey(for: "  echo hi  ", lineNumber: 1)
        let key2 = RunbookCodeBlockTracker.runbookCodeBlockKey(for: "echo hi", lineNumber: 1)
        XCTAssertEqual(key1, key2, "Leading/trailing whitespace must normalize equal")
    }

    func testRunMarkdownBlocksSequentiallyOnlyAdvancesAfterSettle() {
        let tracker = RunbookCodeBlockTracker()
        let blocks: [(line: Int, code: String)] = [
            (line: 1, code: "first"),
            (line: 2, code: "second")
        ]
        var sent: [(String, Int)] = []
        tracker.runMarkdownBlocksSequentially(blocks) { command, line in
            sent.append((command, line))
            let key = RunbookCodeBlockTracker.runbookCodeBlockKey(
                for: command.trimmingCharacters(in: .whitespacesAndNewlines),
                lineNumber: line
            )
            tracker.codeBlockRunStates[key] = .running
        }

        XCTAssertEqual(sent.count, 1, "First block fires synchronously, next gated on settle")

        // Settle block 1.
        let key1 = RunbookCodeBlockTracker.runbookCodeBlockKey(for: "first", lineNumber: 1)
        tracker.codeBlockRunStates[key1] = .succeeded

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, sent.count < 2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].0, "second\n")
    }
}
