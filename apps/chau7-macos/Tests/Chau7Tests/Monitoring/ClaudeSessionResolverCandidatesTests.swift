#if canImport(AppKit)
import XCTest
@testable import Chau7

/// Tests for `ClaudeSessionResolver.sessionCandidates(forDirectory:…)`.
///
/// This is the load-bearing helper for the restore-time recovery path:
/// when autosave persisted a synthetic session ID and the pane state has
/// `aiResumeCommand == nil`, the restore pipeline calls this to scan
/// `~/.claude/projects/<dir-as-dashes>/*.jsonl` and recover a real
/// session ID. Without it, every restart that lands during the synthetic-
/// identity window strands tabs with no resume command prefilled.
///
/// All tests redirect `~` to a tempdir via `CHAU7_HOME_ROOT` so they
/// don't see the developer's real Claude transcripts.
final class ClaudeSessionResolverCandidatesTests: XCTestCase {

    private var tmpHome: URL!
    private var env: [String: String]!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpHome = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("Chau7ClaudeResolverCandidates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        env = ["CHAU7_HOME_ROOT": tmpHome.path]
    }

    override func tearDownWithError() throws {
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        try super.tearDownWithError()
    }

    private func writeTranscript(
        directory: String,
        sessionId: String,
        modifiedAt: Date
    ) throws {
        let projectDirName = directory.replacingOccurrences(of: "/", with: "-")
        let projectDir = tmpHome.appendingPathComponent(".claude/projects/\(projectDirName)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("\(sessionId).jsonl")
        try Data("{}\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: file.path
        )
    }

    // MARK: - Empty / missing cases

    func testReturnsEmptyForEmptyDirectory() {
        let result = ClaudeSessionResolver.sessionCandidates(
            forDirectory: "",
            fileManager: .default,
            environment: env
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testReturnsEmptyWhenProjectDirectoryAbsent() {
        let result = ClaudeSessionResolver.sessionCandidates(
            forDirectory: "/Users/me/nonexistent",
            fileManager: .default,
            environment: env
        )
        XCTAssertTrue(result.isEmpty, "Absent project dir must not crash and must return no candidates")
    }

    // MARK: - Happy path

    func testReturnsRecognizedSessionsForDirectory() throws {
        let dir = "/Users/me/projects/myrepo"
        let now = Date()
        try writeTranscript(directory: dir, sessionId: "abc12345-aaaa-bbbb-cccc-dddddddddddd", modifiedAt: now.addingTimeInterval(-60))
        try writeTranscript(directory: dir, sessionId: "fffeeeed-1111-2222-3333-444444444444", modifiedAt: now)
        try writeTranscript(directory: dir, sessionId: "11112222-3333-4444-5555-666666666666", modifiedAt: now.addingTimeInterval(-3600))

        let result = ClaudeSessionResolver.sessionCandidates(
            forDirectory: dir,
            fileManager: .default,
            environment: env
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(
            result.map(\.sessionId),
            ["fffeeeed-1111-2222-3333-444444444444",
             "abc12345-aaaa-bbbb-cccc-dddddddddddd",
             "11112222-3333-4444-5555-666666666666"],
            "Candidates must be returned newest-first by transcript mtime"
        )
    }

    // MARK: - Safety / filtering

    /// Files whose name doesn't end in .jsonl are ignored — Claude only
    /// ever writes .jsonl per-session transcripts; anything else is noise.
    func testNonJsonlFilesIgnored() throws {
        let dir = "/Users/me/proj"
        try writeTranscript(directory: dir, sessionId: "11112222-3333-4444-5555-666666666666", modifiedAt: Date())
        // Drop a noise file next to the transcripts:
        let projectDirName = dir.replacingOccurrences(of: "/", with: "-")
        let stray = tmpHome.appendingPathComponent(".claude/projects/\(projectDirName)/notes.md")
        try Data("noise".utf8).write(to: stray)

        let result = ClaudeSessionResolver.sessionCandidates(
            forDirectory: dir,
            fileManager: .default,
            environment: env
        )
        XCTAssertEqual(result.map(\.sessionId), ["11112222-3333-4444-5555-666666666666"])
    }

    /// Filenames whose stem fails `AIResumeParser.isValidSessionId` are
    /// dropped so the downstream `isSafeResumeCommand` gate never sees a
    /// dangerous session ID. Without this, a colluding/typo'd transcript
    /// file (e.g. `bad;rm -rf.jsonl`) could end up in a built command.
    func testInvalidSessionIdFilenamesFilteredOut() throws {
        let dir = "/Users/me/proj2"
        try writeTranscript(directory: dir, sessionId: "11112222-3333-4444-5555-666666666666", modifiedAt: Date())
        // Hostile filename — should be filtered:
        let projectDirName = dir.replacingOccurrences(of: "/", with: "-")
        let hostileDir = tmpHome.appendingPathComponent(".claude/projects/\(projectDirName)")
        try FileManager.default.createDirectory(at: hostileDir, withIntermediateDirectories: true)
        let hostile = hostileDir.appendingPathComponent("bad;rm -rf .jsonl")
        try Data("{}\n".utf8).write(to: hostile)

        let result = ClaudeSessionResolver.sessionCandidates(
            forDirectory: dir,
            fileManager: .default,
            environment: env
        )
        XCTAssertEqual(
            result.map(\.sessionId),
            ["11112222-3333-4444-5555-666666666666"],
            "Hostile filename containing shell metacharacters must be filtered out before it reaches the prefill state machine"
        )
    }

    // MARK: - Encoding

    /// Directory paths encode forward slashes as dashes (`/Users/me/proj`
    /// → `-Users-me-proj`) to match Claude's on-disk layout.
    func testDirectoryToProjectDirEncoding() throws {
        let dir = "/A/B/C"
        try writeTranscript(directory: dir, sessionId: "aaaabbbb-cccc-dddd-eeee-ffffffffffff", modifiedAt: Date())

        // The transcript should land under the dash-encoded project directory:
        let projectsRoot = tmpHome.appendingPathComponent(".claude/projects")
        let expected = projectsRoot.appendingPathComponent("-A-B-C", isDirectory: true)
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expected.path, isDirectory: &isDir) && isDir.boolValue,
            "Setup writes to /-A-B-C, matching Claude's slash→dash encoding"
        )

        XCTAssertEqual(
            ClaudeSessionResolver.sessionCandidates(
                forDirectory: dir,
                fileManager: .default,
                environment: env
            ).map(\.sessionId),
            ["aaaabbbb-cccc-dddd-eeee-ffffffffffff"]
        )
    }
}
#endif
