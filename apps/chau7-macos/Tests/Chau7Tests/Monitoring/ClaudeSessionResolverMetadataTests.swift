#if canImport(AppKit)
import XCTest
@testable import Chau7

/// Verifies that Claude history lookups are cached per store generation while
/// still noticing newly-appended history entries. Autosave asks about many
/// sessions in one pass, so a miss must not rescan the complete history file
/// for every tab.
final class ClaudeSessionResolverMetadataTests: XCTestCase {

    private var tmpHome: URL!
    private var env: [String: String]!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ClaudeSessionResolver.clearCache()
        tmpHome = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("Chau7ClaudeResolverMetadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        env = ["CHAU7_HOME_ROOT": tmpHome.path]
    }

    override func tearDownWithError() throws {
        ClaudeSessionResolver.clearCache()
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        try super.tearDownWithError()
    }

    private func historyURL() -> URL {
        tmpHome.appendingPathComponent(".claude/history.jsonl")
    }

    private func transcriptURL(directory: String, sessionId: String) -> URL {
        let projectDirectory = directory.replacingOccurrences(of: "/", with: "-")
        return tmpHome
            .appendingPathComponent(".claude/projects/\(projectDirectory)/\(sessionId).jsonl")
    }

    private func appendHistory(
        sessionId: String,
        project: String,
        timestamp: TimeInterval
    ) throws {
        let url = historyURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let line = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionId,
            "project": project,
            "timestamp": timestamp
        ])
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data([0x0A]))
            try handle.close()
        } else {
            try (line + Data([0x0A])).write(to: url)
        }
    }

    private func writeTranscript(directory: String, sessionId: String) throws {
        let url = transcriptURL(directory: directory, sessionId: sessionId)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: url)
    }

    func testNegativeMetadataCacheRefreshesWhenHistoryChanges() throws {
        let directory = "/Users/me/repo"
        let firstSession = "11112222-3333-4444-5555-666666666666"
        let secondSession = "aaaabbbb-cccc-dddd-eeee-ffffffffffff"
        try appendHistory(sessionId: firstSession, project: directory, timestamp: 1)
        try writeTranscript(directory: directory, sessionId: firstSession)

        XCTAssertNil(
            ClaudeSessionResolver.metadata(
                forSessionID: secondSession,
                fileManager: .default,
                environment: env
            )
        )

        // The second lookup must invalidate the cached miss because both the
        // history file and its newly-created transcript now have a new
        // fingerprint.
        try appendHistory(sessionId: secondSession, project: directory, timestamp: 2)
        try writeTranscript(directory: directory, sessionId: secondSession)

        let candidate = ClaudeSessionResolver.metadata(
            forSessionID: secondSession,
            fileManager: .default,
            environment: env
        )
        XCTAssertEqual(candidate?.sessionId, secondSession)
        XCTAssertEqual(candidate?.projectDirectory, directory)
        XCTAssertEqual(candidate?.transcriptPath, transcriptURL(directory: directory, sessionId: secondSession).path)
    }

    func testHistoryIndexReturnsLatestProjectForEachSession() throws {
        let firstSession = "11112222-3333-4444-5555-666666666666"
        let secondSession = "aaaabbbb-cccc-dddd-eeee-ffffffffffff"
        try appendHistory(sessionId: firstSession, project: "/Users/me/old", timestamp: 1)
        try appendHistory(sessionId: firstSession, project: "/Users/me/new", timestamp: 3)
        try appendHistory(sessionId: secondSession, project: "/Users/me/other", timestamp: 2)
        try writeTranscript(directory: "/Users/me/new", sessionId: firstSession)
        try writeTranscript(directory: "/Users/me/other", sessionId: secondSession)

        let first = ClaudeSessionResolver.metadata(
            forSessionID: firstSession,
            fileManager: .default,
            environment: env
        )
        let second = ClaudeSessionResolver.metadata(
            forSessionID: secondSession,
            fileManager: .default,
            environment: env
        )

        XCTAssertEqual(first?.projectDirectory, "/Users/me/new")
        XCTAssertEqual(second?.projectDirectory, "/Users/me/other")
    }
}
#endif
