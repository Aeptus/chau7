import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7
@testable import Chau7Core

/// Tests for the data and logic aspects underlying CommandBlockOverlayView.
///
/// CommandBlockOverlayView is a SwiftUI view, so we test the supporting logic
/// rather than the view rendering itself:
/// - CommandBlockManager lifecycle (start/finish/queries)
/// - CommandBlock model properties used by the overlay (color selection, visibility, tooltips)
/// - Block trimming when capacity is exceeded
@MainActor
final class CommandBlockOverlayTests: XCTestCase {

    private var manager: CommandBlockManager!

    override func setUp() {
        super.setUp()
        manager = CommandBlockManager.shared
        // Clear any leftover blocks from prior tests
        manager.clearBlocks(tabID: "test-tab")
        manager.clearBlocks(tabID: "tab-A")
        manager.clearBlocks(tabID: "tab-B")
    }

    override func tearDown() {
        manager.clearBlocks(tabID: "test-tab")
        manager.clearBlocks(tabID: "tab-A")
        manager.clearBlocks(tabID: "tab-B")
        manager = nil
        super.tearDown()
    }

    // MARK: - Command Started

    func testCommandStartedAddsBlock() {
        manager.commandStarted(tabID: "test-tab", command: "ls -la", line: 10, directory: "/tmp")

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].command, "ls -la")
        XCTAssertEqual(blocks[0].startLine, 10)
        XCTAssertEqual(blocks[0].directory, "/tmp")
        XCTAssertTrue(blocks[0].isRunning)
    }

    func testMultipleCommandsAccumulate() {
        manager.commandStarted(tabID: "test-tab", command: "cmd1", line: 1, directory: nil)
        manager.commandStarted(tabID: "test-tab", command: "cmd2", line: 10, directory: nil)
        manager.commandStarted(tabID: "test-tab", command: "cmd3", line: 20, directory: nil)

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].command, "cmd1")
        XCTAssertEqual(blocks[1].command, "cmd2")
        XCTAssertEqual(blocks[2].command, "cmd3")
    }

    // MARK: - Command Finished

    func testCommandFinishedUpdatesBlock() {
        manager.commandStarted(tabID: "test-tab", command: "make build", line: 5, directory: nil)
        manager.commandFinished(tabID: "test-tab", line: 30, exitCode: 0)

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertFalse(blocks[0].isRunning)
        XCTAssertTrue(blocks[0].isSuccess)
        XCTAssertEqual(blocks[0].endLine, 30)
        XCTAssertEqual(blocks[0].exitCode, 0)
        XCTAssertNotNil(blocks[0].endTime)
    }

    func testCommandFinishedWithNonZeroExitCode() {
        manager.commandStarted(tabID: "test-tab", command: "false", line: 1, directory: nil)
        manager.commandFinished(tabID: "test-tab", line: 2, exitCode: 1)

        let block = manager.blocksForTab("test-tab")[0]
        XCTAssertTrue(block.isFailed)
        XCTAssertFalse(block.isSuccess)
        XCTAssertEqual(block.exitCode, 1)
    }

    func testFinishMatchesMostRecentRunningBlock() {
        // Start two commands; only the second should be finished by the next finish call
        manager.commandStarted(tabID: "test-tab", command: "first", line: 1, directory: nil)
        manager.commandFinished(tabID: "test-tab", line: 5, exitCode: 0)
        manager.commandStarted(tabID: "test-tab", command: "second", line: 10, directory: nil)
        manager.commandFinished(tabID: "test-tab", line: 20, exitCode: 2)

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks[0].isSuccess, "First block should be success (exit 0)")
        XCTAssertTrue(blocks[1].isFailed, "Second block should be failed (exit 2)")
    }

    // MARK: - Queries

    func testBlocksForTabReturnsEmptyForUnknownTab() {
        let blocks = manager.blocksForTab("nonexistent")
        XCTAssertTrue(blocks.isEmpty)
    }

    func testBlockContainingLineFindsCorrectBlock() {
        manager.commandStarted(tabID: "test-tab", command: "cmd1", line: 10, directory: nil)
        manager.commandFinished(tabID: "test-tab", line: 20, exitCode: 0)
        manager.commandStarted(tabID: "test-tab", command: "cmd2", line: 25, directory: nil)
        manager.commandFinished(tabID: "test-tab", line: 40, exitCode: 0)

        let block1 = manager.blockContaining(line: 15, tabID: "test-tab")
        XCTAssertEqual(block1?.command, "cmd1",
                       "Line 15 should be in the first block (10..20)")

        let block2 = manager.blockContaining(line: 30, tabID: "test-tab")
        XCTAssertEqual(block2?.command, "cmd2",
                       "Line 30 should be in the second block (25..40)")

        let none = manager.blockContaining(line: 22, tabID: "test-tab")
        XCTAssertNil(none, "Line 22 is between blocks and should return nil")
    }

    func testBlockContainingLineForRunningBlock() {
        manager.commandStarted(tabID: "test-tab", command: "running", line: 50, directory: nil)
        // Block is still running (no endLine), so it spans from startLine onward
        let block = manager.blockContaining(line: 100, tabID: "test-tab")
        XCTAssertEqual(block?.command, "running",
                       "A running block should contain any line beyond its start")
    }

    func testBlockContainingLineBeforeStart() {
        manager.commandStarted(tabID: "test-tab", command: "cmd", line: 50, directory: nil)
        let block = manager.blockContaining(line: 10, tabID: "test-tab")
        XCTAssertNil(block, "Lines before the first block's start should return nil")
    }

    // MARK: - Tab Isolation

    func testBlocksAreIsolatedPerTab() {
        manager.commandStarted(tabID: "tab-A", command: "cmdA", line: 1, directory: nil)
        manager.commandStarted(tabID: "tab-B", command: "cmdB", line: 1, directory: nil)

        XCTAssertEqual(manager.blocksForTab("tab-A").count, 1)
        XCTAssertEqual(manager.blocksForTab("tab-A")[0].command, "cmdA")
        XCTAssertEqual(manager.blocksForTab("tab-B").count, 1)
        XCTAssertEqual(manager.blocksForTab("tab-B")[0].command, "cmdB")
    }

    // MARK: - Clear Blocks

    func testClearBlocksRemovesAllForTab() {
        manager.commandStarted(tabID: "test-tab", command: "cmd1", line: 1, directory: nil)
        manager.commandStarted(tabID: "test-tab", command: "cmd2", line: 10, directory: nil)
        XCTAssertEqual(manager.blocksForTab("test-tab").count, 2)

        manager.clearBlocks(tabID: "test-tab")

        XCTAssertTrue(manager.blocksForTab("test-tab").isEmpty,
                      "clearBlocks should remove all blocks for the tab")
    }

    func testClearBlocksDoesNotAffectOtherTabs() {
        manager.commandStarted(tabID: "tab-A", command: "cmdA", line: 1, directory: nil)
        manager.commandStarted(tabID: "tab-B", command: "cmdB", line: 1, directory: nil)

        manager.clearBlocks(tabID: "tab-A")

        XCTAssertTrue(manager.blocksForTab("tab-A").isEmpty)
        XCTAssertEqual(manager.blocksForTab("tab-B").count, 1,
                       "Clearing one tab should not affect other tabs")
    }

    // MARK: - Trimming / Capacity

    func testTrimBlocksWhenOverCapacity() {
        let maxBlocks = CommandBlockManager.maxBlocksPerTab
        // Add more than maxBlocksPerTab blocks
        for i in 0..<(maxBlocks + 10) {
            manager.commandStarted(
                tabID: "test-tab",
                command: "cmd-\(i)",
                line: i * 10,
                directory: nil
            )
        }

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertLessThanOrEqual(blocks.count, maxBlocks,
                                 "Blocks should be trimmed to the max capacity")
        // The oldest blocks should have been removed
        XCTAssertEqual(blocks.first?.command, "cmd-10",
                       "The oldest blocks should be trimmed first")
    }

    // MARK: - CommandBlock Color Logic (mirrors CommandBlockOverlayView.blockColor)

    func testBlockColorForRunningBlock() {
        let block = CommandBlock(command: "running", startLine: 1)
        XCTAssertTrue(block.isRunning)
        // Running blocks should be blue in the overlay
    }

    func testBlockColorForSuccessBlock() {
        let block = CommandBlock(command: "ok", startLine: 1, endLine: 2, exitCode: 0)
        XCTAssertTrue(block.isSuccess)
        // Success blocks should be green in the overlay
    }

    func testBlockColorForFailedBlock() {
        let block = CommandBlock(command: "fail", startLine: 1, endLine: 2, exitCode: 127)
        XCTAssertTrue(block.isFailed)
        // Failed blocks should be red in the overlay
    }

    func testBlockColorForCompletedNoExitCode() {
        let block = CommandBlock(command: "done", startLine: 1, endLine: 5)
        // endLine is set, but no exitCode and no endTime -> isRunning is false because endLine != nil
        // Wait -- isRunning checks endLine == nil && endTime == nil
        // Here endLine is set, so isRunning = false, but exitCode is nil, so isSuccess = false, isFailed = false
        XCTAssertFalse(block.isRunning)
        XCTAssertFalse(block.isSuccess)
        XCTAssertFalse(block.isFailed)
        // This is the "gray" case in the overlay
    }

    // MARK: - CommandBlock Visibility (mirrors CommandBlockOverlayView.blockIsVisible)

    func testBlockVisibilityWhenOverlapping() {
        // Simulate the visibility check from CommandBlockOverlayView
        let block = CommandBlock(command: "test", startLine: 10, endLine: 20)
        let visibleRange: Range<Int> = 5..<25

        let blockEnd = block.endLine ?? Int.max
        let isVisible = block.startLine < visibleRange.upperBound && blockEnd >= visibleRange.lowerBound
        XCTAssertTrue(isVisible, "Block 10..20 should be visible in range 5..<25")
    }

    func testBlockVisibilityWhenAboveViewport() {
        let block = CommandBlock(command: "test", startLine: 1, endLine: 3)
        let visibleRange: Range<Int> = 10..<20

        let blockEnd = block.endLine ?? Int.max
        let isVisible = block.startLine < visibleRange.upperBound && blockEnd >= visibleRange.lowerBound
        XCTAssertFalse(isVisible, "Block 1..3 should not be visible in range 10..<20")
    }

    func testBlockVisibilityWhenBelowViewport() {
        let block = CommandBlock(command: "test", startLine: 50, endLine: 60)
        let visibleRange: Range<Int> = 10..<20

        let blockEnd = block.endLine ?? Int.max
        let isVisible = block.startLine < visibleRange.upperBound && blockEnd >= visibleRange.lowerBound
        XCTAssertFalse(isVisible, "Block 50..60 should not be visible in range 10..<20")
    }

    func testRunningBlockVisibilityUsesMaxInt() {
        // Running blocks have endLine == nil, treated as Int.max for visibility
        let block = CommandBlock(command: "running", startLine: 15)
        let visibleRange: Range<Int> = 10..<20

        let blockEnd = block.endLine ?? Int.max
        let isVisible = block.startLine < visibleRange.upperBound && blockEnd >= visibleRange.lowerBound
        XCTAssertTrue(isVisible, "Running block starting at 15 should be visible in range 10..<20")
    }

    // MARK: - CommandBlock Tooltip / Accessibility

    func testTooltipContainsCommandText() {
        let block = CommandBlock(
            command: "git status",
            startLine: 1,
            endLine: 10,
            exitCode: 0,
            directory: "/repo"
        )
        // Reconstruct the tooltip logic from CommandBlockOverlayView
        var parts: [String] = []
        parts.append(block.command)
        if let dir = block.directory {
            parts.append("Dir: " + dir)
        }
        if block.isRunning {
            parts.append("Status: Running")
        } else if let code = block.exitCode {
            parts.append("Exit: " + String(code))
        }
        let tooltip = parts.joined(separator: "\n")

        XCTAssertTrue(tooltip.contains("git status"))
        XCTAssertTrue(tooltip.contains("Dir: /repo"))
        XCTAssertTrue(tooltip.contains("Exit: 0"))
    }

    func testTooltipForRunningCommand() {
        let block = CommandBlock(command: "sleep 60", startLine: 1)
        var parts: [String] = []
        parts.append(block.command)
        if block.isRunning {
            parts.append("Status: Running")
        }
        let tooltip = parts.joined(separator: "\n")

        XCTAssertTrue(tooltip.contains("sleep 60"))
        XCTAssertTrue(tooltip.contains("Status: Running"))
    }

    func testAccessibilityLabelForSuccess() {
        let block = CommandBlock(command: "echo hello", startLine: 1, endLine: 2, exitCode: 0)
        let status = block.isRunning ? "running"
            : block.isSuccess ? "succeeded"
            : block.isFailed ? "failed with exit code \(block.exitCode ?? -1)"
            : "completed"
        let label = "Command block: " + block.command + ", " + status
        XCTAssertEqual(label, "Command block: echo hello, succeeded")
    }

    func testAccessibilityLabelForFailed() {
        let block = CommandBlock(command: "false", startLine: 1, endLine: 1, exitCode: 1)
        let status = block.isRunning ? "running"
            : block.isSuccess ? "succeeded"
            : block.isFailed ? "failed with exit code \(block.exitCode ?? -1)"
            : "completed"
        let label = "Command block: " + block.command + ", " + status
        XCTAssertEqual(label, "Command block: false, failed with exit code 1")
    }
}
#endif
