import XCTest
@testable import Chau7Core

final class CommandBlockTests: XCTestCase {

    // MARK: - Block Creation

    func testBlockCreation() {
        let block = CommandBlock(
            command: "ls -la",
            startLine: 10,
            directory: "/tmp"
        )

        XCTAssertEqual(block.command, "ls -la")
        XCTAssertEqual(block.startLine, 10)
        XCTAssertNil(block.endLine)
        XCTAssertNil(block.endTime)
        XCTAssertNil(block.exitCode)
        XCTAssertEqual(block.directory, "/tmp")
        XCTAssertNil(block.turnID)
        XCTAssertEqual(block.changedFilesStatus, .loading)
        XCTAssertTrue(block.isRunning)
        XCTAssertFalse(block.isSuccess)
        XCTAssertFalse(block.isFailed)
    }

    func testBlockWithAllFields() {
        let start = Date()
        let end = start.addingTimeInterval(5.0)
        let id = UUID()

        let block = CommandBlock(
            id: id,
            command: "make build",
            startLine: 100,
            endLine: 150,
            startTime: start,
            endTime: end,
            exitCode: 0,
            directory: "/Users/dev/project",
            turnID: "t_4",
            changedFiles: ["Sources/App.swift"],
            changedFilesUnavailable: false,
            changedFilesStatus: .loaded
        )

        XCTAssertEqual(block.id, id)
        XCTAssertEqual(block.command, "make build")
        XCTAssertEqual(block.startLine, 100)
        XCTAssertEqual(block.endLine, 150)
        XCTAssertEqual(block.exitCode, 0)
        XCTAssertEqual(block.directory, "/Users/dev/project")
        XCTAssertEqual(block.turnID, "t_4")
        XCTAssertEqual(block.changedFiles, ["Sources/App.swift"])
        XCTAssertEqual(block.changedFilesStatus, .loaded)
        XCTAssertFalse(block.isRunning)
        XCTAssertTrue(block.isSuccess)
        XCTAssertFalse(block.isFailed)
    }

    // MARK: - Status Properties

    func testRunningBlock() {
        let block = CommandBlock(command: "sleep 60", startLine: 5)
        XCTAssertTrue(block.isRunning)
        XCTAssertFalse(block.isSuccess)
        XCTAssertFalse(block.isFailed)
    }

    func testSuccessBlock() {
        let block = CommandBlock(
            command: "echo hello",
            startLine: 1,
            endLine: 2,
            exitCode: 0
        )
        XCTAssertFalse(block.isRunning)
        XCTAssertTrue(block.isSuccess)
        XCTAssertFalse(block.isFailed)
    }

    func testFailedBlock() {
        let block = CommandBlock(
            command: "false",
            startLine: 1,
            endLine: 1,
            exitCode: 1
        )
        XCTAssertFalse(block.isRunning)
        XCTAssertFalse(block.isSuccess)
        XCTAssertTrue(block.isFailed)
    }

    func testFailedBlockNonOneExitCode() {
        let block = CommandBlock(
            command: "segfault_program",
            startLine: 1,
            endLine: 5,
            exitCode: 139
        )
        XCTAssertTrue(block.isFailed)
        XCTAssertFalse(block.isSuccess)
    }

    // MARK: - Duration

    func testDurationNilWhenRunning() {
        let block = CommandBlock(command: "running", startLine: 1)
        XCTAssertNil(block.duration)
    }

    func testDurationCalculation() {
        let start = Date()
        let end = start.addingTimeInterval(3.5)
        let block = CommandBlock(
            command: "test",
            startLine: 1,
            endLine: 5,
            startTime: start,
            endTime: end
        )
        XCTAssertEqual(block.duration!, 3.5, accuracy: 0.001)
    }

    func testDurationStringMilliseconds() {
        let start = Date()
        let end = start.addingTimeInterval(0.5)
        let block = CommandBlock(
            command: "fast",
            startLine: 1,
            endLine: 1,
            startTime: start,
            endTime: end
        )
        XCTAssertEqual(block.durationString, "500ms")
    }

    func testDurationStringSeconds() {
        let start = Date()
        let end = start.addingTimeInterval(3.2)
        let block = CommandBlock(
            command: "medium",
            startLine: 1,
            endLine: 1,
            startTime: start,
            endTime: end
        )
        XCTAssertEqual(block.durationString, "3.2s")
    }

    func testDurationStringMinutes() {
        let start = Date()
        let end = start.addingTimeInterval(135.0) // 2m 15s
        let block = CommandBlock(
            command: "long",
            startLine: 1,
            endLine: 1,
            startTime: start,
            endTime: end
        )
        XCTAssertEqual(block.durationString, "2m 15s")
    }

    func testDurationStringHours() {
        let start = Date()
        let end = start.addingTimeInterval(3900.0) // 1h 5m
        let block = CommandBlock(
            command: "very_long",
            startLine: 1,
            endLine: 1,
            startTime: start,
            endTime: end
        )
        XCTAssertEqual(block.durationString, "1h 5m")
    }

    func testDurationStringEmptyWhenRunning() {
        let block = CommandBlock(command: "running", startLine: 1)
        XCTAssertEqual(block.durationString, "")
    }

    // MARK: - Line Count

    func testLineCountNilWhenRunning() {
        let block = CommandBlock(command: "running", startLine: 10)
        XCTAssertNil(block.lineCount)
    }

    func testLineCountSingleLine() {
        let block = CommandBlock(
            command: "echo hi",
            startLine: 10,
            endLine: 10
        )
        XCTAssertEqual(block.lineCount, 1)
    }

    func testLineCountMultipleLines() {
        let block = CommandBlock(
            command: "ls -la",
            startLine: 10,
            endLine: 25
        )
        XCTAssertEqual(block.lineCount, 16)
    }

    // MARK: - Equatable

    func testEquatable() {
        let id = UUID()
        let time = Date()
        let block1 = CommandBlock(
            id: id,
            command: "test",
            startLine: 1,
            startTime: time
        )
        let block2 = CommandBlock(
            id: id,
            command: "test",
            startLine: 1,
            startTime: time
        )
        XCTAssertEqual(block1, block2)
    }

    func testNotEqual() {
        let block1 = CommandBlock(command: "cmd1", startLine: 1)
        let block2 = CommandBlock(command: "cmd2", startLine: 1)
        XCTAssertNotEqual(block1, block2)
    }

    // MARK: - Codable

    func testCodable() throws {
        let start = Date()
        let end = start.addingTimeInterval(2.0)
        let original = CommandBlock(
            command: "git status",
            startLine: 42,
            endLine: 50,
            startTime: start,
            endTime: end,
            exitCode: 0,
            directory: "/repo",
            turnID: "t_1",
            changedFiles: ["README.md"],
            changedFilesUnavailable: false,
            changedFilesStatus: .loaded
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CommandBlock.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.command, original.command)
        XCTAssertEqual(decoded.startLine, original.startLine)
        XCTAssertEqual(decoded.endLine, original.endLine)
        XCTAssertEqual(decoded.exitCode, original.exitCode)
        XCTAssertEqual(decoded.directory, original.directory)
        XCTAssertEqual(decoded.turnID, original.turnID)
        XCTAssertEqual(decoded.changedFiles, original.changedFiles)
        XCTAssertEqual(decoded.changedFilesStatus, .loaded)
    }

    func testLegacyCodableDefaultsMissingFields() throws {
        let json = """
        {
          "id":"\(UUID().uuidString)",
          "command":"git status",
          "startLine":42,
          "startTime":\(Date().timeIntervalSince1970)
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CommandBlock.self, from: Data(json.utf8))

        XCTAssertNil(decoded.turnID)
        XCTAssertEqual(decoded.changedFiles, [])
        XCTAssertFalse(decoded.changedFilesUnavailable)
        XCTAssertEqual(decoded.changedFilesStatus, .loading)
    }

    // MARK: - Lifecycle Simulation

    func testBlockLifecycle() {
        // Start a command
        var block = CommandBlock(
            command: "make test",
            startLine: 100,
            directory: "/project"
        )

        XCTAssertTrue(block.isRunning)
        XCTAssertNil(block.duration)
        XCTAssertNil(block.lineCount)

        // Command finishes
        block.endLine = 120
        block.endTime = block.startTime.addingTimeInterval(10.0)
        block.exitCode = 0

        XCTAssertFalse(block.isRunning)
        XCTAssertTrue(block.isSuccess)
        XCTAssertFalse(block.isFailed)
        XCTAssertNotNil(block.duration)
        XCTAssertEqual(block.lineCount, 21)
    }

    func testBlockLifecycleFailure() {
        var block = CommandBlock(
            command: "cargo build",
            startLine: 50
        )

        // Command fails
        block.endLine = 80
        block.endTime = block.startTime.addingTimeInterval(30.0)
        block.exitCode = 2

        XCTAssertFalse(block.isRunning)
        XCTAssertFalse(block.isSuccess)
        XCTAssertTrue(block.isFailed)
        XCTAssertEqual(block.exitCode, 2)
    }
}
