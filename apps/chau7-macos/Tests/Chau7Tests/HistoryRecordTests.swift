import XCTest
@testable import Chau7Core

// MARK: - HistoryRecord Tests

final class HistoryRecordTests: XCTestCase {

    func testInitWithDefaults() {
        let record = HistoryRecord(command: "ls -la")

        XCTAssertNil(record.id)
        XCTAssertEqual(record.command, "ls -la")
        XCTAssertNil(record.directory)
        XCTAssertNil(record.exitCode)
        XCTAssertNil(record.shell)
        XCTAssertNil(record.tabID)
        XCTAssertNil(record.sessionID)
        XCTAssertNil(record.duration)
    }

    func testInitWithAllFields() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let record = HistoryRecord(
            id: 42,
            command: "git push",
            directory: "/home/user/project",
            exitCode: 0,
            shell: "zsh",
            tabID: "tab-1",
            sessionID: "session-abc",
            timestamp: date,
            duration: 3.5
        )

        XCTAssertEqual(record.id, 42)
        XCTAssertEqual(record.command, "git push")
        XCTAssertEqual(record.directory, "/home/user/project")
        XCTAssertEqual(record.exitCode, 0)
        XCTAssertEqual(record.shell, "zsh")
        XCTAssertEqual(record.tabID, "tab-1")
        XCTAssertEqual(record.sessionID, "session-abc")
        XCTAssertEqual(record.timestamp, date)
        XCTAssertEqual(record.duration, 3.5)
    }

    func testEquality() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = HistoryRecord(id: 1, command: "ls", timestamp: date)
        let b = HistoryRecord(id: 1, command: "ls", timestamp: date)
        XCTAssertEqual(a, b)
    }

    func testInequality() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = HistoryRecord(id: 1, command: "ls", timestamp: date)
        let b = HistoryRecord(id: 2, command: "ls", timestamp: date)
        XCTAssertNotEqual(a, b)
    }

    func testCodableRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1700000000)
        let original = HistoryRecord(
            id: 7,
            command: "make build",
            directory: "/tmp",
            exitCode: 1,
            shell: "bash",
            tabID: "t1",
            sessionID: "s1",
            timestamp: date,
            duration: 12.3
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HistoryRecord.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testCodableWithNils() throws {
        let original = HistoryRecord(command: "echo hi")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HistoryRecord.self, from: data)

        XCTAssertEqual(decoded.command, "echo hi")
        XCTAssertNil(decoded.id)
        XCTAssertNil(decoded.directory)
        XCTAssertNil(decoded.exitCode)
    }
}

// MARK: - FrequentCommand Tests

final class FrequentCommandTests: XCTestCase {

    func testIdentifiable() {
        let cmd = FrequentCommand(command: "git status", count: 5, lastUsed: Date())
        XCTAssertEqual(cmd.id, "git status")
    }

    func testEquality() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = FrequentCommand(command: "ls", count: 3, lastUsed: date)
        let b = FrequentCommand(command: "ls", count: 3, lastUsed: date)
        XCTAssertEqual(a, b)
    }

    func testFrecencyScorePositive() {
        let cmd = FrequentCommand(command: "ls", count: 10, lastUsed: Date())
        XCTAssertGreaterThan(cmd.frecencyScore, 0)
    }

    func testFrecencyScoreRecentHigherThanOld() {
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)

        let recent = FrequentCommand(command: "ls", count: 5, lastUsed: now)
        let old = FrequentCommand(command: "ls", count: 5, lastUsed: weekAgo)

        XCTAssertGreaterThan(recent.frecencyScore, old.frecencyScore)
    }

    func testFrecencyScoreHighCountHigher() {
        let date = Date()
        let frequent = FrequentCommand(command: "ls", count: 100, lastUsed: date)
        let rare = FrequentCommand(command: "ls", count: 1, lastUsed: date)

        XCTAssertGreaterThan(frequent.frecencyScore, rare.frecencyScore)
    }

    func testCodableRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1700000000)
        let original = FrequentCommand(command: "npm test", count: 42, lastUsed: date)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FrequentCommand.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
