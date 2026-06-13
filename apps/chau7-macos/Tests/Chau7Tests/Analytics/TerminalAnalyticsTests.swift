import XCTest
@testable import Chau7
@testable import Chau7Core

/// Tests for the analytics value types backing TerminalAnalytics.
///
/// NOTE: The old `DailyStat` and `ShellUsage` types no longer exist in production
/// (TerminalAnalytics was rewritten around `FrequentCommand` + aggregate counters),
/// so the original tests for them were removed. `TerminalAnalytics` itself is a
/// singleton wired to `PersistentHistoryStore.shared` and is not unit-testable here.
final class TerminalAnalyticsTests: XCTestCase {

    // MARK: - FrequentCommand Frecency

    func testFrecencyScoreRecentHighCount() {
        let cmd = FrequentCommand(
            command: "git status",
            count: 100,
            lastUsed: Date() // just now
        )
        XCTAssertGreaterThan(cmd.frecencyScore, 0)
    }

    func testFrecencyScoreOldCommand() {
        let oldDate = Date().addingTimeInterval(-7 * 24 * 3600) // 7 days ago
        let cmd = FrequentCommand(
            command: "old command",
            count: 10,
            lastUsed: oldDate
        )
        XCTAssertGreaterThan(cmd.frecencyScore, 0)
    }

    func testFrecencyScoreRecentBeatsOld() {
        let recentCmd = FrequentCommand(
            command: "git status",
            count: 10,
            lastUsed: Date()
        )
        let oldCmd = FrequentCommand(
            command: "git status",
            count: 10,
            lastUsed: Date().addingTimeInterval(-30 * 24 * 3600) // 30 days ago
        )
        XCTAssertGreaterThan(recentCmd.frecencyScore, oldCmd.frecencyScore)
    }

    func testFrecencyScoreHighCountBeatsLow() {
        let now = Date()
        let highCount = FrequentCommand(
            command: "ls",
            count: 100,
            lastUsed: now
        )
        let lowCount = FrequentCommand(
            command: "ls",
            count: 5,
            lastUsed: now
        )
        XCTAssertGreaterThan(highCount.frecencyScore, lowCount.frecencyScore)
    }

    func testFrecencyScoreNeverNegative() {
        let veryOld = Date().addingTimeInterval(-365 * 24 * 3600) // 1 year ago
        let cmd = FrequentCommand(
            command: "ancient",
            count: 1,
            lastUsed: veryOld
        )
        XCTAssertGreaterThanOrEqual(cmd.frecencyScore, 0)
    }

    // MARK: - FrequentCommand Identifiable

    func testFrequentCommandIdentifiable() {
        let cmd = FrequentCommand(command: "npm install", count: 5, lastUsed: Date())
        XCTAssertEqual(cmd.id, "npm install")
    }

    // MARK: - FrequentCommand Codable

    func testFrequentCommandCodable() throws {
        let original = FrequentCommand(command: "docker ps", count: 42, lastUsed: Date())

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FrequentCommand.self, from: data)

        XCTAssertEqual(decoded.command, original.command)
        XCTAssertEqual(decoded.count, original.count)
    }
}
