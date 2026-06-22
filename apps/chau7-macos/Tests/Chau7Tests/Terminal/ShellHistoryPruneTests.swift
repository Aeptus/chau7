import Foundation
import XCTest
@testable import Chau7

/// Covers `TerminalSessionModel.pruneOrphanShellHistory(in:protectedTabIDs:maxLines:minLinesPerTab:)`.
/// It rewrites and deletes files, so the invariants matter: protected (restorable)
/// tabs are never touched, the bound is total input lines (not age), the OLDEST
/// commands go first (closed tabs trim to a per-tab floor before any whole file is
/// removed), and trimming keeps a tab's MOST RECENT commands.
final class ShellHistoryPruneTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        dir = fm.temporaryDirectory.appendingPathComponent("chau7-histprune-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: dir)
        super.tearDown()
    }

    private func url(_ tabID: String, _ suffix: String = "zsh_history") -> URL {
        dir.appendingPathComponent("\(tabID).\(suffix)")
    }

    /// Write `<tabID>.<suffix>` with the given newline-terminated lines and an mtime.
    private func write(_ tabID: String, suffix: String = "zsh_history", lines: [String], mtimeOffset: TimeInterval) {
        let content = lines.map { $0 + "\n" }.joined()
        try? content.write(to: url(tabID, suffix), atomically: true, encoding: .utf8)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000 + mtimeOffset)
        try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url(tabID, suffix).path)
    }

    private func write(_ tabID: String, suffix: String = "zsh_history", count: Int, mtimeOffset: TimeInterval) {
        write(tabID, suffix: suffix, lines: (1...max(1, count)).map { "echo \(tabID)-\($0)" }, mtimeOffset: mtimeOffset)
    }

    private func exists(_ tabID: String, _ suffix: String = "zsh_history") -> Bool {
        fm.fileExists(atPath: url(tabID, suffix).path)
    }

    private func lineCount(_ tabID: String, _ suffix: String = "zsh_history") -> Int {
        guard let s = try? String(contentsOf: url(tabID, suffix), encoding: .utf8) else { return 0 }
        return s.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }.count
    }

    private func contentLines(_ tabID: String, _ suffix: String = "zsh_history") -> [String] {
        guard let s = try? String(contentsOf: url(tabID, suffix), encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init)
    }

    func testTrimsOldestTabsToFloorUntilUnderCap() {
        write("P", count: 500, mtimeOffset: 0)    // protected
        write("A", count: 30, mtimeOffset: 10)    // oldest orphan
        write("B", count: 30, mtimeOffset: 20)
        write("C", count: 30, mtimeOffset: 30)    // newest orphan

        // Orphans = 90, cap 50, floor 5 → trim A (→5, total 65) then B (→5, total 40 ≤ 50).
        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: ["P"], maxLines: 50)

        XCTAssertEqual(lineCount("P"), 500, "protected tab is never trimmed")
        XCTAssertEqual(lineCount("A"), 5, "oldest orphan trimmed to the floor first")
        XCTAssertEqual(lineCount("B"), 5, "next-oldest trimmed until under cap")
        XCTAssertEqual(lineCount("C"), 30, "newest orphan untouched once under cap")
    }

    func testTrimKeepsMostRecentCommands() {
        write("A", count: 30, mtimeOffset: 10)    // lines echo A-1 ... echo A-30

        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: [], maxLines: 5, minLinesPerTab: 5)

        XCTAssertEqual(contentLines("A"), (26...30).map { "echo A-\($0)" },
                       "trimming drops the OLDEST commands and keeps the most recent floor")
    }

    func testProtectedTabNeverTrimmedOrCounted() {
        write("P", count: 10_000, mtimeOffset: 0) // protected, far over any cap
        write("A", count: 200, mtimeOffset: 10)

        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: ["P"], maxLines: 50)

        XCTAssertEqual(lineCount("P"), 10_000, "protected lines don't count and are never trimmed")
        XCTAssertEqual(lineCount("A"), 5, "only the orphan is trimmed to fit the budget")
    }

    func testDeletesWholeOldestTabsWhenFloorsStillExceedCap() {
        for i in 0..<5 { write("T\(i)", count: 10, mtimeOffset: Double((i + 1) * 10)) } // T0 oldest

        // total 50; floor-trim all to 5 → 25 still > 12; delete oldest whole tabs
        // until ≤ 12: remove T0,T1,T2 (→10), keep T3,T4.
        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: [], maxLines: 12, minLinesPerTab: 5)

        XCTAssertFalse(exists("T0"))
        XCTAssertFalse(exists("T1"))
        XCTAssertFalse(exists("T2"))
        XCTAssertEqual(lineCount("T3"), 5, "surviving newest tabs keep the floor")
        XCTAssertEqual(lineCount("T4"), 5)
    }

    func testKeepsEverythingWhenUnderCap() {
        write("A", count: 10, mtimeOffset: 10)
        write("B", count: 10, mtimeOffset: 20)

        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: [], maxLines: 1000)

        XCTAssertEqual(lineCount("A"), 10)
        XCTAssertEqual(lineCount("B"), 10)
    }

    func testPrunesBashHistoryToo() {
        write("A", suffix: "bash_history", count: 80, mtimeOffset: 10)
        write("B", suffix: "bash_history", count: 80, mtimeOffset: 20)

        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: [], maxLines: 100, minLinesPerTab: 5)

        XCTAssertEqual(lineCount("A", "bash_history"), 5, "oldest bash orphan trimmed")
        XCTAssertEqual(lineCount("B", "bash_history"), 80, "newest retained under the cap")
    }

    func testIgnoresUnrelatedFiles() {
        write("A", count: 200, mtimeOffset: 10)
        try? "scratch".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: [], maxLines: 50, minLinesPerTab: 5)

        XCTAssertEqual(lineCount("A"), 5, "the over-cap history file is trimmed")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("notes.txt").path),
                      "non-history files are left alone")
    }
}
