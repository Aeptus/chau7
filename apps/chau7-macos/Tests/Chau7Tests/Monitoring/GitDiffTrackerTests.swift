import XCTest
@testable import Chau7

/// Creates a scratch directory and guarantees it is genuinely outside any git
/// work tree, which is the precondition both fallback tests depend on.
///
/// `NSTemporaryDirectory()` is inherited from the environment, and some runners
/// relocate `TMPDIR` inside the repository. There, `git status` exits 0 and
/// reports an empty change list, so these tests were silently asserting the
/// wrong thing — a *git* result rather than a filesystem fallback. Asserting the
/// precondition turns that into an honest skip instead of an intermittent red.
private func makeScratchDirectoryOutsideGit() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("git-diff-fallback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    probe.arguments = ["-C", directory.path, "rev-parse", "--is-inside-work-tree"]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    try probe.run()
    probe.waitUntilExit()

    try XCTSkipIf(
        probe.terminationStatus == 0,
        "TMPDIR resolved to \(NSTemporaryDirectory()), which is inside a git work tree; "
            + "the filesystem-fallback precondition cannot hold here"
    )
    return directory
}

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

    func testSignalledGitIsNotTreatedAsSuccess() {
        // The git probe runs under a timeout and is killed when it overruns.
        // A signalled process has no meaningful exit status, so it must not be
        // read as "exit 0 / inside a repository" — that silently turned the
        // probe into an empty git answer instead of a filesystem fallback.
        let killed = GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0, terminationReason: .uncaughtSignal)
        XCTAssertFalse(killed.succeeded)

        let exitedCleanly = GitDiffTracker.GitResult(stdout: "", stderr: "", exitCode: 0, terminationReason: .exit)
        XCTAssertTrue(exitedCleanly.succeeded)

        let failed = GitDiffTracker.GitResult(stdout: "", stderr: "fatal: not a git repository", exitCode: 128)
        XCTAssertFalse(failed.succeeded)
    }

    func testNonGitDirectoryReturnsNoFileList() throws {
        let tracker = GitDiffTracker()
        // NSTemporaryDirectory() goes through the /var → /private/var symlink on
        // macOS; this deliberately exercises the canonical-path handling in the
        // filesystem fallback.
        let directory = try makeScratchDirectoryOutsideGit()
        defer { try? FileManager.default.removeItem(at: directory) }

        tracker.snapshot(directory: directory.path)
        let file = directory.appendingPathComponent("example.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let result = tracker.changedFilesResult(directory: directory.path)
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.status, .notGitRepo)
        // Git failure is explicit; it must not trigger a home-directory crawl.
        XCTAssertTrue(result.diffUnavailable)
        XCTAssertNotNil(result.unavailableReason)
    }

    func testNonGitDirectoryDoesNotExposeHiddenFiles() throws {
        let tracker = GitDiffTracker()
        let directory = try makeScratchDirectoryOutsideGit()
        defer { try? FileManager.default.removeItem(at: directory) }

        tracker.snapshot(directory: directory.path)
        let file = directory.appendingPathComponent(".env")
        try "SECRET=1".write(to: file, atomically: true, encoding: .utf8)

        let result = tracker.changedFilesResult(directory: directory.path)
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.status, .notGitRepo)
    }
}
