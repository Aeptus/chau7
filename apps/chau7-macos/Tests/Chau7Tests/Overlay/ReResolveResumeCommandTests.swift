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

    /// Tightened contract: when autosave captured nothing — no provider,
    /// no session id, no command — the re-resolver must REFUSE to guess.
    /// The original "scan both providers and pick newest in cwd" behavior
    /// caused N tabs that shared a directory to all collapse onto the same
    /// most-recent transcript, turning every nil-identity tab into a
    /// duplicate of the one tab whose autosave correctly captured the
    /// active session. The recovery is only safe when at least the
    /// provider tag survived — that's evidence an AI process really did
    /// run in the pane.
    func testReturnsNilWhenAllIdentityFieldsAreNil() throws {
        let dir = "/Users/me/projects/work"
        let claudeSession = "abc12345-aaaa-bbbb-cccc-dddddddddddd"
        try writeClaudeTranscript(directory: dir, sessionId: claudeSession, modifiedAt: Date())

        let pane = makePane(directory: dir)
        XCTAssertNil(
            OverlayTabsModel.reResolveResumeCommand(paneState: pane),
            "All-nil identity must NOT fabricate a command from cwd alone"
        )
    }

    /// Provider tag survived but session id and command were dropped — the
    /// synthetic-identity autosave window we built this helper for. Still
    /// recoverable because the provider tag proves an AI process was
    /// actually running.
    func testNilSessionWithProviderTagResolvesProvidersTranscript() throws {
        let dir = "/Users/me/projects/with-provider"
        let claudeSession = "11111111-aaaa-bbbb-cccc-222222222222"
        try writeClaudeTranscript(directory: dir, sessionId: claudeSession, modifiedAt: Date())

        let pane = makePane(directory: dir, provider: "claude")
        let resolved = OverlayTabsModel.reResolveResumeCommand(paneState: pane)
        XCTAssertEqual(resolved?.provider, "claude")
        XCTAssertEqual(resolved?.sessionId, claudeSession)
    }

    /// Dedup: a tab whose only candidate session is claimed by another tab
    /// in the restore set must NOT inherit it. Restores blank instead.
    func testDoesNotPickSessionAlreadyClaimedByAnotherTab() throws {
        let dir = "/Users/me/shared-cwd"
        let onlySession = "33333333-aaaa-bbbb-cccc-444444444444"
        try writeClaudeTranscript(directory: dir, sessionId: onlySession, modifiedAt: Date())

        // Pane has provider tag so the helper is willing to recover, but
        // the only candidate on disk is already owned by another tab.
        let pane = makePane(directory: dir, provider: "claude")
        let resolved = OverlayTabsModel.reResolveResumeCommand(
            paneState: pane,
            claimedSessionIds: [onlySession]
        )
        XCTAssertNil(
            resolved,
            "Must refuse to duplicate a session ID already claimed by another tab"
        )
    }

    /// Dedup leaves later candidates alone. If the newest matches a claim
    /// but an older same-cwd session exists and is not claimed, fall back
    /// to the older one.
    func testFallsBackToNextCandidateWhenNewestIsClaimed() throws {
        let dir = "/Users/me/falls-back"
        let claimedNewer = "55555555-aaaa-bbbb-cccc-666666666666"
        let availableOlder = "77777777-aaaa-bbbb-cccc-888888888888"
        try writeClaudeTranscript(directory: dir, sessionId: availableOlder, modifiedAt: Date().addingTimeInterval(-3600))
        try writeClaudeTranscript(directory: dir, sessionId: claimedNewer, modifiedAt: Date())

        let pane = makePane(directory: dir, provider: "claude")
        let resolved = OverlayTabsModel.reResolveResumeCommand(
            paneState: pane,
            claimedSessionIds: [claimedNewer]
        )
        XCTAssertEqual(
            resolved?.sessionId,
            availableOlder,
            "Dedup must skip the newest claimed candidate and pick the next eligible one"
        )
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
    func testReturnsNilWhenDirectoryIsEmpty() {
        let pane = makePane(directory: "")
        XCTAssertNil(OverlayTabsModel.reResolveResumeCommand(paneState: pane))
    }

    /// No transcripts on disk for the saved directory — nothing to recover.
    /// Return nil so the caller logs "no resume command candidate found"
    /// and the tab comes back blank (the genuine "we have no signal" case,
    /// not the bug class this whole helper exists to address).
    func testReturnsNilWhenNoTranscriptsForDirectory() {
        let pane = makePane(directory: "/Users/me/no-such-dir")
        XCTAssertNil(OverlayTabsModel.reResolveResumeCommand(paneState: pane))
    }

    // MARK: - Tie-breaking

    /// Within a provider, the most recently touched matching transcript
    /// wins. Provider tag is required to reach this branch (see the
    /// all-nil guard test) so the test plants it explicitly.
    func testPicksMostRecentTranscriptForKnownProvider() throws {
        let dir = "/Users/me/proj-recency"
        let older = "11111111-1111-1111-1111-111111111111"
        let newer = "22222222-2222-2222-2222-222222222222"
        try writeClaudeTranscript(directory: dir, sessionId: older, modifiedAt: Date().addingTimeInterval(-3600))
        try writeClaudeTranscript(directory: dir, sessionId: newer, modifiedAt: Date())

        let pane = makePane(directory: dir, provider: "claude")
        let resolved = OverlayTabsModel.reResolveResumeCommand(paneState: pane)
        XCTAssertEqual(resolved?.sessionId, newer, "Newest transcript must win")
    }
}
#endif
