import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7
@testable import Chau7Core

@MainActor
final class CommandBlockOverlayTests: XCTestCase {
    private var manager: CommandBlockManager!

    override func setUp() {
        super.setUp()
        manager = CommandBlockManager.shared
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

    private func startBlock(
        tabID: String = "test-tab",
        command: String,
        line: Int,
        directory: String? = nil,
        turnID: String? = nil
    ) -> UUID {
        manager.commandStarted(tabID: tabID, command: command, line: line, directory: directory, turnID: turnID)
    }

    func testCommandStartedAddsBlock() {
        let blockID = startBlock(command: "ls -la", line: 10, directory: "/tmp", turnID: "t_1")

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].id, blockID)
        XCTAssertEqual(blocks[0].command, "ls -la")
        XCTAssertEqual(blocks[0].startLine, 10)
        XCTAssertEqual(blocks[0].directory, "/tmp")
        XCTAssertEqual(blocks[0].turnID, "t_1")
        XCTAssertEqual(blocks[0].changedFilesStatus, .loading)
        XCTAssertTrue(blocks[0].isRunning)
    }

    func testCommandFinishedUpdatesBlock() {
        let blockID = startBlock(command: "make build", line: 5)
        manager.commandFinished(tabID: "test-tab", blockID: blockID, line: 30, exitCode: 0)

        let block = manager.blocksForTab("test-tab")[0]
        XCTAssertFalse(block.isRunning)
        XCTAssertTrue(block.isSuccess)
        XCTAssertEqual(block.endLine, 30)
        XCTAssertEqual(block.exitCode, 0)
        XCTAssertNotNil(block.endTime)
    }

    func testCommandFinishedSupportsUnknownExitCode() {
        let blockID = startBlock(command: "continue", line: 4)
        manager.commandFinished(tabID: "test-tab", blockID: blockID, line: 12, exitCode: nil)

        let block = manager.blocksForTab("test-tab")[0]
        XCTAssertFalse(block.isRunning)
        XCTAssertNil(block.exitCode)
        XCTAssertFalse(block.isSuccess)
        XCTAssertFalse(block.isFailed)
    }

    func testFinishUsesExplicitBlockID() {
        let firstID = startBlock(command: "first", line: 1)
        let secondID = startBlock(command: "second", line: 10)

        manager.commandFinished(tabID: "test-tab", blockID: firstID, line: 5, exitCode: 0)

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertEqual(blocks[0].id, firstID)
        XCTAssertEqual(blocks[0].endLine, 5)
        XCTAssertTrue(blocks[1].isRunning)
        XCTAssertEqual(blocks[1].id, secondID)
    }

    func testRapidSequentialFinishEventsPreserveBlockAssociation() {
        let firstID = startBlock(command: "first", line: 1)
        let secondID = startBlock(command: "second", line: 10)

        manager.commandFinished(tabID: "test-tab", blockID: secondID, line: 20, exitCode: 2)
        manager.commandFinished(tabID: "test-tab", blockID: firstID, line: 5, exitCode: 0)

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertEqual(blocks[0].endLine, 5)
        XCTAssertEqual(blocks[0].exitCode, 0)
        XCTAssertEqual(blocks[1].endLine, 20)
        XCTAssertEqual(blocks[1].exitCode, 2)
    }

    func testSetChangedFilesTargetsExplicitBlockID() {
        let firstID = startBlock(command: "first", line: 1)
        let secondID = startBlock(command: "second", line: 10)
        manager.commandFinished(tabID: "test-tab", blockID: firstID, line: 5, exitCode: 0)
        manager.commandFinished(tabID: "test-tab", blockID: secondID, line: 20, exitCode: 0)

        manager.setChangedFiles(["Sources/App.swift"], unavailable: false, status: .loaded, for: secondID, in: "test-tab")

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertTrue(blocks[0].changedFiles.isEmpty)
        XCTAssertEqual(blocks[1].changedFiles, ["Sources/App.swift"])
        XCTAssertEqual(blocks[1].changedFilesStatus, .loaded)
    }

    func testBlockContainingLineFindsCorrectBlock() {
        let firstID = startBlock(command: "cmd1", line: 10)
        manager.commandFinished(tabID: "test-tab", blockID: firstID, line: 20, exitCode: 0)
        let secondID = startBlock(command: "cmd2", line: 25)
        manager.commandFinished(tabID: "test-tab", blockID: secondID, line: 40, exitCode: 0)

        XCTAssertEqual(manager.blockContaining(line: 15, tabID: "test-tab")?.command, "cmd1")
        XCTAssertEqual(manager.blockContaining(line: 30, tabID: "test-tab")?.command, "cmd2")
        XCTAssertNil(manager.blockContaining(line: 22, tabID: "test-tab"))
    }

    func testRunningBlockContainsLaterLines() {
        _ = startBlock(command: "running", line: 50)
        XCTAssertEqual(manager.blockContaining(line: 100, tabID: "test-tab")?.command, "running")
    }

    func testBlocksAreIsolatedPerTab() {
        _ = startBlock(tabID: "tab-A", command: "cmdA", line: 1)
        _ = startBlock(tabID: "tab-B", command: "cmdB", line: 1)

        XCTAssertEqual(manager.blocksForTab("tab-A").first?.command, "cmdA")
        XCTAssertEqual(manager.blocksForTab("tab-B").first?.command, "cmdB")
    }

    func testClearBlocksRemovesOnlyTargetTab() {
        _ = startBlock(tabID: "tab-A", command: "cmdA", line: 1)
        _ = startBlock(tabID: "tab-B", command: "cmdB", line: 1)

        manager.clearBlocks(tabID: "tab-A")

        XCTAssertTrue(manager.blocksForTab("tab-A").isEmpty)
        XCTAssertEqual(manager.blocksForTab("tab-B").count, 1)
    }

    func testTrimBlocksWhenOverCapacity() {
        for i in 0 ..< (CommandBlockManager.maxBlocksPerTab + 10) {
            _ = startBlock(command: "cmd-\(i)", line: i * 10)
        }

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertLessThanOrEqual(blocks.count, CommandBlockManager.maxBlocksPerTab)
        XCTAssertEqual(blocks.first?.command, "cmd-10")
    }

    func testRestoreBlocksRehydratesPersistedState() {
        let restored = [
            CommandBlock(
                command: "git status",
                startLine: 3,
                endLine: 9,
                exitCode: 0,
                directory: "/repo",
                turnID: "t_2",
                changedFiles: ["README.md"],
                changedFilesStatus: .loaded
            )
        ]

        manager.restoreBlocks(restored, for: "test-tab")

        let blocks = manager.blocksForTab("test-tab")
        XCTAssertEqual(blocks, restored)
    }

    func testTooltipContainsCommandContext() {
        let block = CommandBlock(
            command: "git status",
            startLine: 1,
            endLine: 10,
            exitCode: 0,
            directory: "/repo"
        )

        var parts: [String] = [block.command]
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
}
#endif
