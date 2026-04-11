import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class GitDiffTrackerTests: XCTestCase {
    func testChangedPathReturnsDestinationForRename() {
        XCTAssertEqual(
            GitDiffTracker.changedPath(fromStatusPorcelainLine: "R  old/name.swift -> new/name.swift"),
            "new/name.swift"
        )
    }

    func testChangedPathReturnsDestinationForCopy() {
        XCTAssertEqual(
            GitDiffTracker.changedPath(fromStatusPorcelainLine: "C  src/template.swift -> src/template_copy.swift"),
            "src/template_copy.swift"
        )
    }

    func testFirstChangedPathUsesParsedDestination() {
        let porcelain = """
        R  old/name.swift -> new/name.swift
         M README.md
        """

        XCTAssertEqual(GitDiffTracker.firstChangedPath(inStatusPorcelain: porcelain), "new/name.swift")
    }

    func testChangedFilesResultFallsBackToFilesystemOutsideGit() throws {
        let tracker = GitDiffTracker()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("git-diff-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        tracker.snapshot(directory: directory.path)
        let file = directory.appendingPathComponent("example.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let result = tracker.changedFilesResult(directory: directory.path)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.files, ["example.txt"])
        XCTAssertFalse(result.diffUnavailable)
    }
}
#endif
