import XCTest
@testable import Chau7Core

final class TurnStatsTests: XCTestCase {

    // MARK: - Tool Recording

    func testRecordToolUse_incrementsCount() {
        var stats = TurnStats()
        stats.recordToolUse(name: "Write", file: "/tmp/a.swift")
        stats.recordToolUse(name: "Write", file: "/tmp/b.swift")
        stats.recordToolUse(name: "Read", file: nil)

        XCTAssertEqual(stats.toolTallies["Write"]?.count, 2)
        XCTAssertEqual(stats.toolTallies["Read"]?.count, 1)
    }

    func testRecordToolUse_deduplicatesFiles() {
        var stats = TurnStats()
        stats.recordToolUse(name: "Edit", file: "/tmp/x.swift")
        stats.recordToolUse(name: "Edit", file: "/tmp/x.swift")
        stats.recordToolUse(name: "Edit", file: "/tmp/y.swift")

        let tally = stats.toolTallies["Edit"]!
        XCTAssertEqual(tally.count, 3)
        XCTAssertEqual(tally.files, ["/tmp/x.swift", "/tmp/y.swift"])
    }

    func testRecordToolUse_ignoresEmptyFile() {
        var stats = TurnStats()
        stats.recordToolUse(name: "Bash", file: "")
        stats.recordToolUse(name: "Bash", file: nil)

        XCTAssertEqual(stats.toolTallies["Bash"]?.count, 2)
        XCTAssertTrue(stats.toolTallies["Bash"]?.files.isEmpty ?? false)
    }

    // MARK: - Token Accumulation

    func testAddTokens_cumulativeAccumulation() {
        var stats = TurnStats()
        stats.addTokens(input: 100, output: 50, cacheCreation: 10, cacheRead: 20)
        stats.addTokens(input: 200, output: 100, cacheCreation: 5, cacheRead: 15)

        XCTAssertEqual(stats.inputTokens, 300)
        XCTAssertEqual(stats.outputTokens, 150)
        XCTAssertEqual(stats.cacheCreationTokens, 15)
        XCTAssertEqual(stats.cacheReadTokens, 35)
        XCTAssertEqual(stats.totalTokens, 450) // input + output
    }

    // MARK: - Summary

    func testSummary_containsAllExpectedKeys() {
        var stats = TurnStats()
        stats.recordToolUse(name: "Write", file: "/a.swift")
        stats.recordToolUse(name: "Read", file: nil)
        stats.addTokens(input: 1000, output: 500, cacheCreation: 100, cacheRead: 200)

        let summary = stats.summary()

        XCTAssertEqual(summary["tool_count"], "2")
        XCTAssertEqual(summary["input_tokens"], "1000")
        XCTAssertEqual(summary["output_tokens"], "500")
        XCTAssertEqual(summary["cache_creation_tokens"], "100")
        XCTAssertEqual(summary["cache_read_tokens"], "200")
        XCTAssertEqual(summary["total_tokens"], "1500")
        XCTAssertEqual(summary["files_touched"], "1")

        // tools_used is sorted, comma-separated
        let tools = summary["tools_used"]!
        XCTAssertTrue(tools.contains("Read"))
        XCTAssertTrue(tools.contains("Write"))
    }

    func testSummary_emptyStats() {
        let stats = TurnStats()
        let summary = stats.summary()

        XCTAssertEqual(summary["tool_count"], "0")
        XCTAssertEqual(summary["tools_used"], "")
        XCTAssertEqual(summary["total_tokens"], "0")
        XCTAssertEqual(summary["files_touched"], "0")
    }

    // MARK: - Fresh State

    func testFreshStats_allZero() {
        let stats = TurnStats()
        XCTAssertTrue(stats.toolTallies.isEmpty)
        XCTAssertEqual(stats.inputTokens, 0)
        XCTAssertEqual(stats.outputTokens, 0)
        XCTAssertEqual(stats.cacheCreationTokens, 0)
        XCTAssertEqual(stats.cacheReadTokens, 0)
        XCTAssertEqual(stats.totalTokens, 0)
    }
}
