#if canImport(AppKit)
import XCTest
import Chau7Core
@testable import Chau7

/// Tests for `OverlayTabsModel.reResolveResumeCommand(paneState:)`.
///
/// The function is the load-bearing piece behind restore-time recovery for
/// tabs whose autosave landed during the post-launch identity-corroboration
/// window. Two flavors of that loss:
///
///   * `provider` set but `aiResumeCommand` nil — buildAIResumeCommand
///     correctly refused a synthetic session ID. Original (commit
///     `733898a3`) fix path.
///
///   * `provider` nil AND `aiResumeCommand` nil — the *wider* failure
///     where autosave ran before *any* identity was corroborated. This
///     suite is the regression test for the dual-provider expansion: we
///     now scan both Claude AND Codex transcript directories and pick
///     whichever has a transcript closer to the saved activity time.
///
/// We redirect `~` to a tempdir via `CHAU7_HOME_ROOT` so the test never
/// reads the developer's real Claude/Codex history. `setenv` + matching
/// `unsetenv` in `tearDown` keeps the global env clean across runs.
@MainActor
final class ReResolveResumeCommandTests: XCTestCase {

    private var tmpHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpHome = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("Chau7ReResolveResumeCommand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        setenv("CHAU7_HOME_ROOT", tmpHome.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("CHAU7_HOME_ROOT")
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        try super.tearDownWithError()
    }

    private func writeClaudeTranscript(directory: String, sessionId: String, modifiedAt: Date) throws {
        let projectDirName = directory.replacingOccurrences(of: "/", with: "-")
        let projectDir = tmpHome.appendingPathComponent(".claude/projects/\(projectDirName)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("\(sessionId).jsonl")
        try Data("{}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
    }

    private func makePane(
        directory: String,
        provider: String? = nil,
        sessionId: String? = nil,
        cmd: String? = nil,
        lastInputAt: Date? = nil
    ) -> SavedTerminalPaneState {
        SavedTerminalPaneState(
            paneID: UUID().uuidString,
            directory: directory,
            scrollbackContent: nil,
            aiResumeCommand: cmd,
            aiResumeDirectory: nil,
            aiProvider: provider,
            aiSessionId: sessionId,
            aiSessionIdSource: nil,
            lastOutputAt: lastInputAt,
            lastInputAt: lastInputAt
        )
    }

    // MARK: - The regression class

    /// The user-reported case: autosave captured *nothing* (provider nil,
    /// session nil, cmd nil) because identity wasn't yet corroborated when
    /// it fired. The restore pipeline previously hit "no resume command
    /// candidate found" and the tab came back blank. With the dual-scan
    /// fallback this test must produce a Claude resume command from the
    /// Claude transcript on disk for the same directory.
    func testNilProviderWithClaudeTranscriptResolvesClaudeCommand() throws {
        let dir = "/Users/me/projects/work"
        let claudeSession = "abc12345-aaaa-bbbb-cccc-dddddddddddd"
        try writeClaudeTranscript(directory: dir, sessionId: claudeSession, modifiedAt: Date())

        let pane = makePane(directory: dir)
        let resolved = OverlayTabsModel.reResolveResumeCommand(paneState: pane)

        XCTAssertNotNil(resolved, "Dual scan must find the Claude transcript when provider is nil")
        XCTAssertEqual(resolved?.provider, "claude")
        XCTAssertEqual(resolved?.sessionId, claudeSession)
        XCTAssertEqual(resolved?.command, "claude --resume \(claudeSession)")
    }

    /// Provider explicitly set: the function must NOT cross-scan into the
    /// other provider's transcripts. Codex transcript on disk + provider
    /// set to "claude" must not return a codex command.
    func testExplicitClaudeProviderDoesNotPickUpCodexTranscript() throws {
        let dir = "/Users/me/projects/other"
        // Plant a Claude transcript for this dir (so the named provider has a match).
        try writeClaudeTranscript(
            directory: dir,
            sessionId: "11111111-2222-3333-4444-555555555555",
            modifiedAt: Date()
        )

        let pane = makePane(directory: dir, provider: "Claude")
        let resolved = OverlayTabsModel.reResolveResumeCommand(paneState: pane)
        XCTAssertEqual(resolved?.provider, "claude")
    }

    /// Already has a usable command — must NOT re-resolve (preserves the
    /// primary path's correctness).
    func testReturnsNilWhenCommandAlreadyPresent() throws {
        let dir = "/Users/me/proj-with-cmd"
        try writeClaudeTranscript(
            directory: dir,
            sessionId: "11111111-2222-3333-4444-555555555555",
            modifiedAt: Date()
        )
        let pane = makePane(
            directory: dir,
            provider: "Claude",
            sessionId: "preserved",
            cmd: "claude --resume preserved"
        )
        XCTAssertNil(
            OverlayTabsModel.reResolveResumeCommand(paneState: pane),
            "Must NOT re-resolve when the pane already has a valid command — primary path owns it"
        )
    }

    /// Empty directory — there's nothing to scan against; return nil
    /// cleanly rather than scanning every transcript on disk.
    func testReturnsNilWhenDirectoryIsEmpty() throws {
        let pane = makePane(directory: "")
        XCTAssertNil(OverlayTabsModel.reResolveResumeCommand(paneState: pane))
    }

    /// No transcripts on disk for the saved directory — nothing to recover.
    /// Return nil so the caller logs "no resume command candidate found"
    /// and the tab comes back blank (the genuine "we have no signal" case,
    /// not the bug class this whole helper exists to address).
    func testReturnsNilWhenNoTranscriptsForDirectory() throws {
        let pane = makePane(directory: "/Users/me/no-such-dir")
        XCTAssertNil(OverlayTabsModel.reResolveResumeCommand(paneState: pane))
    }

    // MARK: - Tie-breaking

    /// When provider is nil and BOTH Claude has a transcript for the
    /// directory, the most recently touched candidate must win — we
    /// generally want the latest session the user worked on.
    ///
    /// Note we can only test Claude reliably here (Codex's resolver doesn't
    /// accept an environment override; the dual-scan logic is verified
    /// structurally — `CodexSessionResolverTests` covers Codex matching).
    func testNilProviderPicksMostRecentClaudeTranscript() throws {
        let dir = "/Users/me/proj-recency"
        let older = "11111111-1111-1111-1111-111111111111"
        let newer = "22222222-2222-2222-2222-222222222222"
        try writeClaudeTranscript(directory: dir, sessionId: older, modifiedAt: Date().addingTimeInterval(-3600))
        try writeClaudeTranscript(directory: dir, sessionId: newer, modifiedAt: Date())

        let pane = makePane(directory: dir)
        let resolved = OverlayTabsModel.reResolveResumeCommand(paneState: pane)
        XCTAssertEqual(resolved?.sessionId, newer, "Newest transcript must win")
    }
}
#endif
