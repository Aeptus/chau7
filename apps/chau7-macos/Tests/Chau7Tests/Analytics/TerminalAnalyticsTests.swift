import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7
@testable import Chau7Core

final class TerminalAnalyticsTests: XCTestCase {

    // MARK: - DailyStat Error Rate

    func testErrorRateZeroCommands() {
        let stat = DailyStat(date: Date(), commandCount: 0, errorCount: 0)
        XCTAssertEqual(stat.errorRate, 0)
    }

    func testErrorRateNoErrors() {
        let stat = DailyStat(date: Date(), commandCount: 50, errorCount: 0)
        XCTAssertEqual(stat.errorRate, 0)
    }

    func testErrorRateAllErrors() {
        let stat = DailyStat(date: Date(), commandCount: 10, errorCount: 10)
        XCTAssertEqual(stat.errorRate, 1.0, accuracy: 0.001)
    }

    func testErrorRatePartial() {
        let stat = DailyStat(date: Date(), commandCount: 100, errorCount: 25)
        XCTAssertEqual(stat.errorRate, 0.25, accuracy: 0.001)
    }

    func testErrorRateSingleCommand() {
        let stat = DailyStat(date: Date(), commandCount: 1, errorCount: 1)
        XCTAssertEqual(stat.errorRate, 1.0, accuracy: 0.001)
    }

    // MARK: - DailyStat Day Label

    func testDayLabelFormat() {
        // Create a known date (Monday)
        var components = DateComponents()
        components.year = 2025
        components.month = 1
        components.day = 6 // Monday
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: components)!

        let stat = DailyStat(date: monday, commandCount: 10, errorCount: 1)
        let label = stat.dayLabel
        // The label should be a short day name
        XCTAssertFalse(label.isEmpty)
        XCTAssertTrue(label.count <= 5, "Day label should be a short abbreviation")
    }

    // MARK: - DailyStat Identifiable

    func testDailyStatIdentifiable() {
        let date = Date()
        let stat = DailyStat(date: date, commandCount: 5, errorCount: 1)
        XCTAssertEqual(stat.id, date)
    }

    // MARK: - ShellUsage Properties

    func testShellUsageIdentifiable() {
        let usage = ShellUsage(shell: "zsh", count: 100, percentage: 60)
        XCTAssertEqual(usage.id, "zsh")
    }

    func testShellUsageProperties() {
        let usage = ShellUsage(shell: "bash", count: 50, percentage: 30)
        XCTAssertEqual(usage.shell, "bash")
        XCTAssertEqual(usage.count, 50)
        XCTAssertEqual(usage.percentage, 30)
    }

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
#endif
