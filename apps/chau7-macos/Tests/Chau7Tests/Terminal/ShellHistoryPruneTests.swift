import Foundation
import XCTest
@testable import Chau7

/// Covers `TerminalSessionModel.pruneOrphanShellHistory(in:protectedTabIDs:maxLines:)`,
/// the per-tab shell-history cleanup. It deletes files, so the invariants matter:
/// protected (restorable) tabs are never touched, the bound is total input lines
/// (not age), and eviction is oldest-first.
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

    /// Write `<tabID>.<suffix>` with `lines` newline-terminated entries and an mtime.
    private func writeHistory(_ tabID: String, suffix: String = "zsh_history", lines: Int, mtimeOffset: TimeInterval) {
        let url = dir.appendingPathComponent("\(tabID).\(suffix)")
        let content = String(repeating: "echo \(tabID)\n", count: lines)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000 + mtimeOffset)
        try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private func exists(_ tabID: String, suffix: String = "zsh_history") -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent("\(tabID).\(suffix)").path)
    }

    func testEvictsOldestOrphansUntilUnderLineCap() {
        writeHistory("P", lines: 500, mtimeOffset: 0)   // protected — huge + oldest
        writeHistory("A", lines: 30, mtimeOffset: 10)   // orphan, oldest
        writeHistory("B", lines: 30, mtimeOffset: 20)   // orphan, middle
        writeHistory("C", lines: 30, mtimeOffset: 30)   // orphan, newest

        // Orphan corpus = 90 lines, cap 50 → evict A (→60), then B (→30 ≤ 50), keep C.
        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: ["P"], maxLines: 50)

        XCTAssertTrue(exists("P"), "protected tab history must never be pruned, even when large/old")
        XCTAssertFalse(exists("A"), "oldest orphan should be evicted first")
        XCTAssertFalse(exists("B"), "second-oldest orphan evicted until under the cap")
        XCTAssertTrue(exists("C"), "newest orphan retained once corpus is under the cap")
    }

    func testKeepsEverythingWhenUnderCap() {
        writeHistory("A", lines: 10, mtimeOffset: 10)
        writeHistory("B", lines: 10, mtimeOffset: 20)

        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: [], maxLines: 1000)

        XCTAssertTrue(exists("A"))
        XCTAssertTrue(exists("B"))
    }

    func testProtectedTabIsNeverCountedTowardTheBudget() {
        // One protected tab far over the cap, plus a single small orphan under it.
        writeHistory("P", lines: 10_000, mtimeOffset: 0)
        writeHistory("A", lines: 5, mtimeOffset: 10)

        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: ["P"], maxLines: 100)

        XCTAssertTrue(exists("P"), "protected lines don't count toward the orphan budget")
        XCTAssertTrue(exists("A"), "orphan stays because the orphan-only total (5) is under the cap")
    }

    func testPrunesBashHistoryFilesToo() {
        writeHistory("A", suffix: "bash_history", lines: 80, mtimeOffset: 10)
        writeHistory("B", suffix: "bash_history", lines: 80, mtimeOffset: 20)

        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: [], maxLines: 100)

        XCTAssertFalse(exists("A", suffix: "bash_history"), "oldest bash orphan evicted")
        XCTAssertTrue(exists("B", suffix: "bash_history"), "newest retained under the cap")
    }

    func testIgnoresUnrelatedFiles() {
        writeHistory("A", lines: 200, mtimeOffset: 10)
        try? "noise".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        TerminalSessionModel.pruneOrphanShellHistory(in: dir, protectedTabIDs: [], maxLines: 50)

        XCTAssertFalse(exists("A"), "the over-cap orphan history file is pruned")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("notes.txt").path),
                      "non-history files are left alone")
    }
}
