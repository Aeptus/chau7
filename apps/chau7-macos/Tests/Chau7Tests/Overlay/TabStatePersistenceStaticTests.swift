import XCTest
@testable import Chau7

/// SPM-runnable tests for the static persistence helpers on `OverlayTabsModel`.
/// These helpers are pure (no instance state, no main-actor dependency), so they
/// can run via `swift test` and form a regression safety net before the W3.25
/// extraction passes touch any of the surrounding code.
///
/// The instance-level tests live in `OverlayTabsModelTests.swift` (Xcode-only
/// because they exercise tab/session construction that depends on AppKit-bound
/// types not visible across the SPM test boundary).
final class TabStatePersistenceStaticTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClaudeSessionResolver.clearCache()
    }

    override func tearDown() {
        ClaudeSessionResolver.clearCache()
        super.tearDown()
    }

    // MARK: - sanitizeRestoredAIResumeOwnership

    /// Two tabs persisted while sharing the same AI session ID — only the first
    /// occurrence keeps it; the second has it cleared. This protects against the
    /// "double-claim" scenario where an old save predates session-ID uniqueness
    /// enforcement.
    func testSanitizeDeduplicatesAISessionIDAcrossTopLevelTabs() {
        let shared = "shared-session-abc"
        let firstID = UUID()
        let secondID = UUID()
        let states = [
            makeTopLevelState(
                tabID: firstID,
                aiProvider: "codex",
                aiSessionId: shared,
                aiResumeCommand: "codex resume \(shared)"
            ),
            makeTopLevelState(
                tabID: secondID,
                aiProvider: "codex",
                aiSessionId: shared,
                aiResumeCommand: "codex resume \(shared)"
            )
        ]

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(states: states)

        XCTAssertEqual(sanitized[0].aiSessionId, shared, "First tab keeps the claimed session ID")
        XCTAssertNil(sanitized[1].aiSessionId, "Second tab loses the duplicated session ID")
        XCTAssertNil(sanitized[1].aiResumeCommand, "Second tab's resume command is dropped along with the ID")

        // Non-AI fields must survive the dedup pass on BOTH tabs — a regression
        // that nukes too much state during sanitization would still pass the
        // assertions above, so anchor on identity + presentation fields too.
        XCTAssertEqual(sanitized[0].tabID, firstID.uuidString)
        XCTAssertEqual(sanitized[1].tabID, secondID.uuidString)
        XCTAssertEqual(sanitized[1].customTitle, "Tab", "customTitle preserved on dedup-loser tab")
        XCTAssertEqual(sanitized[1].directory, "/tmp", "directory preserved on dedup-loser tab")
        XCTAssertEqual(sanitized[1].color, TabColor.blue.rawValue, "color preserved on dedup-loser tab")
    }

    /// Different session IDs must remain untouched even when they look similar.
    func testSanitizePreservesDistinctSessionIDs() {
        let states = [
            makeTopLevelState(
                tabID: UUID(),
                aiProvider: "codex",
                aiSessionId: "session-1",
                aiResumeCommand: "codex resume session-1"
            ),
            makeTopLevelState(
                tabID: UUID(),
                aiProvider: "codex",
                aiSessionId: "session-2",
                aiResumeCommand: "codex resume session-2"
            )
        ]

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(states: states)

        XCTAssertEqual(sanitized[0].aiSessionId, "session-1")
        XCTAssertEqual(sanitized[1].aiSessionId, "session-2")
    }

    /// Empty / nil session IDs are not subject to dedup — every tab can have nil.
    func testSanitizePassesThroughNilSessionIDs() {
        let states = [
            makeTopLevelState(tabID: UUID(), aiProvider: nil, aiSessionId: nil, aiResumeCommand: nil),
            makeTopLevelState(tabID: UUID(), aiProvider: nil, aiSessionId: nil, aiResumeCommand: nil)
        ]

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(states: states)

        XCTAssertNil(sanitized[0].aiSessionId)
        XCTAssertNil(sanitized[1].aiSessionId)
    }

    func testSanitizeDropsClaudeSessionWithoutTranscript() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let deadSessionID = "fc48a626-5528-403f-b7da-6e9386493643"
        let states = [
            makeTopLevelState(
                tabID: UUID(),
                aiProvider: "claude",
                aiSessionId: deadSessionID,
                aiResumeCommand: "claude --resume \(deadSessionID)"
            )
        ]

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(
            states: states,
            environment: ["CHAU7_HOME_ROOT": home.path]
        )

        XCTAssertNil(sanitized[0].aiProvider)
        XCTAssertNil(sanitized[0].aiSessionId)
        XCTAssertNil(sanitized[0].aiResumeCommand)
    }

    func testSanitizeFallsBackToClaudeAgentLaunchCommandWhenSavedSessionIsDead() throws {
        let home = try temporaryDirectory()
        let repoRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: repoRoot)
        }
        let packageDirectory = repoRoot.appendingPathComponent("packages/aethyme", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let deadSessionID = "fc48a626-5528-403f-b7da-6e9386493643"
        let restoredSessionID = "d3da599e-f985-4eaf-a834-f9eb069d6802"
        try createClaudeTranscript(home: home, projectDirectory: repoRoot, sessionID: restoredSessionID)
        let paneID = UUID().uuidString
        let state = SavedTabState(
            tabID: UUID().uuidString,
            selectedTabID: nil,
            customTitle: "Redb",
            color: TabColor.blue.rawValue,
            directory: packageDirectory.path,
            selectedIndex: nil,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: nil,
            aiSessionId: nil,
            splitLayout: nil,
            focusedPaneID: paneID,
            paneStates: [
                SavedTerminalPaneState(
                    paneID: paneID,
                    directory: packageDirectory.path,
                    scrollbackContent: nil,
                    aiResumeCommand: "claude --resume \(deadSessionID)",
                    aiProvider: "claude",
                    aiSessionId: deadSessionID,
                    aiSessionIdSource: .explicit,
                    agentLaunchCommand: "claude --resume \(restoredSessionID)"
                )
            ]
        )

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(
            states: [state],
            environment: ["CHAU7_HOME_ROOT": home.path]
        )
        let pane = sanitized.first?.paneStates?.first

        XCTAssertEqual(pane?.aiProvider, "claude")
        XCTAssertEqual(pane?.aiSessionId, restoredSessionID)
        XCTAssertEqual(pane?.aiResumeCommand, "claude --resume \(restoredSessionID)")
        XCTAssertEqual(pane?.aiResumeDirectory, repoRoot.path)
    }

    func testResolveSavedClaudeMetadataUsesCommandOnlyAgentLaunchInRelatedProject() throws {
        let home = try temporaryDirectory()
        let repoRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: repoRoot)
        }
        let packageDirectory = repoRoot.appendingPathComponent("packages/aethyme", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let sessionID = "d3da599e-f985-4eaf-a834-f9eb069d6802"
        try createClaudeTranscript(home: home, projectDirectory: repoRoot, sessionID: sessionID)
        let paneState = SavedTerminalPaneState(
            paneID: UUID().uuidString,
            directory: packageDirectory.path,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: nil,
            aiSessionId: nil,
            agentLaunchCommand: "claude --resume \(sessionID)"
        )

        let resolved = OverlayTabsModel.resolveAIResumeMetadataFromSavedState(
            paneState: paneState,
            fallbackAIProvider: nil,
            fallbackAISessionId: nil,
            environment: ["CHAU7_HOME_ROOT": home.path]
        )

        XCTAssertEqual(resolved?.provider, "claude")
        XCTAssertEqual(resolved?.sessionId, sessionID)
        XCTAssertEqual(resolved?.sessionIdSource, .explicit)
    }

    func testPreferredRestoreDirectoryUsesCommandOnlyAgentLaunchProjectRoot() throws {
        let home = try temporaryDirectory()
        let repoRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: repoRoot)
        }
        let packageDirectory = repoRoot.appendingPathComponent("packages/aethyme", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let sessionID = "d3da599e-f985-4eaf-a834-f9eb069d6802"
        try createClaudeTranscript(home: home, projectDirectory: repoRoot, sessionID: sessionID)
        let paneState = SavedTerminalPaneState(
            paneID: UUID().uuidString,
            directory: packageDirectory.path,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: nil,
            aiSessionId: nil,
            agentLaunchCommand: "claude --resume \(sessionID)"
        )

        let directory = paneState.resolvedPreferredRestoreDirectory(
            environment: ["CHAU7_HOME_ROOT": home.path]
        )

        XCTAssertEqual(directory, repoRoot.path)
    }

    func testSanitizeDropsClaudeSessionFromForeignProject() throws {
        let home = try temporaryDirectory()
        let aethymeRoot = try temporaryDirectory()
        let chau7Root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: aethymeRoot)
            try? FileManager.default.removeItem(at: chau7Root)
        }
        let packageDirectory = aethymeRoot.appendingPathComponent("packages/aethyme", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let foreignSessionID = "b074c722-cca4-4a08-a40d-b05df8622490d"
        try createClaudeTranscript(home: home, projectDirectory: chau7Root, sessionID: foreignSessionID)
        let paneID = UUID().uuidString
        let state = SavedTabState(
            tabID: UUID().uuidString,
            selectedTabID: nil,
            customTitle: "Eval",
            color: TabColor.green.rawValue,
            directory: packageDirectory.path,
            selectedIndex: nil,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: nil,
            aiSessionId: nil,
            splitLayout: nil,
            focusedPaneID: paneID,
            paneStates: [
                SavedTerminalPaneState(
                    paneID: paneID,
                    directory: packageDirectory.path,
                    scrollbackContent: nil,
                    aiResumeCommand: "claude --resume \(foreignSessionID)",
                    aiProvider: "claude",
                    aiSessionId: foreignSessionID,
                    aiSessionIdSource: .explicit
                )
            ]
        )

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(
            states: [state],
            environment: ["CHAU7_HOME_ROOT": home.path]
        )
        let pane = sanitized.first?.paneStates?.first

        XCTAssertNil(pane?.aiProvider)
        XCTAssertNil(pane?.aiSessionId)
        XCTAssertNil(pane?.aiResumeCommand)
        XCTAssertNil(pane?.aiResumeDirectory)
    }

    // MARK: - normalizedResumeCommand / isSafeResumeCommand

    /// Whitespace-trimming and the safe-command guard are the two responsibilities
    /// of `normalizedResumeCommand`. Both must be exercised so a refactor that
    /// reorders them gets caught.
    func testNormalizedResumeCommandTrimsWhitespaceAndAcceptsClaude() {
        XCTAssertEqual(
            OverlayTabsModel.normalizedResumeCommand("  claude --resume abc-123  "),
            "claude --resume abc-123"
        )
    }

    func testNormalizedResumeCommandRejectsEmpty() {
        XCTAssertNil(OverlayTabsModel.normalizedResumeCommand(""))
        XCTAssertNil(OverlayTabsModel.normalizedResumeCommand("   "))
        XCTAssertNil(OverlayTabsModel.normalizedResumeCommand(nil))
    }

    func testNormalizedResumeCommandRejectsUnsafeShellInjectionAttempts() {
        XCTAssertNil(
            OverlayTabsModel.normalizedResumeCommand("claude --resume abc; rm -rf /"),
            "Shell metacharacter injection in session ID must be rejected"
        )
        XCTAssertNil(
            OverlayTabsModel.normalizedResumeCommand("rm -rf /"),
            "Non-resume commands must be rejected even if syntactically harmless"
        )
    }

    func testIsSafeResumeCommandAcceptsCodexResume() {
        XCTAssertTrue(OverlayTabsModel.isSafeResumeCommand("codex resume valid-session-id-1234"))
    }

    func testIsSafeResumeCommandRejectsArbitraryCommand() {
        XCTAssertFalse(OverlayTabsModel.isSafeResumeCommand("echo hello"))
    }

    // MARK: - decodeBackupWindowStates

    /// Single-window legacy payload (a bare `[SavedTabState]` array) must decode
    /// into a `[[SavedTabState]]` with a single window.
    func testDecodeBackupWindowStatesAcceptsLegacySingleWindowArray() throws {
        let single = [makeTopLevelState(tabID: UUID(), aiProvider: nil, aiSessionId: nil, aiResumeCommand: nil)]
        let data = try XCTUnwrap(try? JSONEncoder().encode(single))

        let decoded = OverlayTabsModel.decodeBackupWindowStates(from: data)

        XCTAssertEqual(decoded?.count, 1, "Single-window legacy payload becomes a one-window list")
        XCTAssertEqual(decoded?[0].count, 1)
    }

    /// Multi-window payload (`SavedMultiWindowState`) must decode into the same
    /// `[[SavedTabState]]` shape with the recorded window count.
    func testDecodeBackupWindowStatesAcceptsMultiWindowEnvelope() throws {
        let windows = [
            [makeTopLevelState(tabID: UUID(), aiProvider: nil, aiSessionId: nil, aiResumeCommand: nil)],
            [
                makeTopLevelState(tabID: UUID(), aiProvider: nil, aiSessionId: nil, aiResumeCommand: nil),
                makeTopLevelState(tabID: UUID(), aiProvider: nil, aiSessionId: nil, aiResumeCommand: nil)
            ]
        ]
        let envelope = SavedMultiWindowState(windows: windows)
        let data = try XCTUnwrap(try? JSONEncoder().encode(envelope))

        let decoded = OverlayTabsModel.decodeBackupWindowStates(from: data)

        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?[0].count, 1)
        XCTAssertEqual(decoded?[1].count, 2)
    }

    /// Garbage input must return nil rather than crash or produce a misleading
    /// non-nil value. This is the silent-data-loss boundary that Persist.encodeLogged
    /// can't catch on the read side.
    func testDecodeBackupWindowStatesReturnsNilForCorruptData() {
        XCTAssertNil(OverlayTabsModel.decodeBackupWindowStates(from: Data("not json".utf8)))
        XCTAssertNil(OverlayTabsModel.decodeBackupWindowStates(from: Data()))
    }

    // MARK: - Helpers

    private func makeTopLevelState(
        tabID: UUID,
        aiProvider: String?,
        aiSessionId: String?,
        aiResumeCommand: String?
    ) -> SavedTabState {
        SavedTabState(
            tabID: tabID.uuidString,
            selectedTabID: nil,
            customTitle: "Tab",
            color: TabColor.blue.rawValue,
            directory: "/tmp",
            selectedIndex: nil,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: aiResumeCommand,
            aiProvider: aiProvider,
            aiSessionId: aiSessionId,
            aiSessionIdSource: aiSessionId == nil ? nil : .explicit,
            splitLayout: nil,
            focusedPaneID: nil,
            paneStates: nil
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Chau7StaticTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func createClaudeTranscript(home: URL, projectDirectory: URL, sessionID: String) throws {
        let normalizedProject = projectDirectory.standardizedFileURL.path
        let projectDirName = normalizedProject.replacingOccurrences(of: "/", with: "-")
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let projectDir = claudeDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: projectDir.appendingPathComponent("\(sessionID).jsonl"))

        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let historyURL = claudeDir.appendingPathComponent("history.jsonl")
        let payload: [String: Any] = [
            "display": "test",
            "timestamp": 1,
            "project": normalizedProject,
            "sessionId": sessionID
        ]
        let line = try JSONSerialization.data(withJSONObject: payload)
        var historyData = (try? Data(contentsOf: historyURL)) ?? Data()
        historyData.append(line)
        historyData.append(Data("\n".utf8))
        try historyData.write(to: historyURL)
    }
}
