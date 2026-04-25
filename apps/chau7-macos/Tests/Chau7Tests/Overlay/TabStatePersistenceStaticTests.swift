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

    // MARK: - sanitizeRestoredAIResumeOwnership

    /// Two tabs persisted while sharing the same AI session ID — only the first
    /// occurrence keeps it; the second has it cleared. This protects against the
    /// "double-claim" scenario where an old save predates session-ID uniqueness
    /// enforcement.
    func testSanitizeDeduplicatesAISessionIDAcrossTopLevelTabs() throws {
        let shared = "shared-session-abc"
        let states = [
            makeTopLevelState(tabID: UUID(), aiProvider: "codex", aiSessionId: shared,
                              aiResumeCommand: "codex resume \(shared)"),
            makeTopLevelState(tabID: UUID(), aiProvider: "codex", aiSessionId: shared,
                              aiResumeCommand: "codex resume \(shared)")
        ]

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(states: states)

        XCTAssertEqual(sanitized[0].aiSessionId, shared, "First tab keeps the claimed session ID")
        XCTAssertNil(sanitized[1].aiSessionId, "Second tab loses the duplicated session ID")
        XCTAssertNil(sanitized[1].aiResumeCommand, "Second tab's resume command is dropped along with the ID")
    }

    /// Different session IDs must remain untouched even when they look similar.
    func testSanitizePreservesDistinctSessionIDs() {
        let states = [
            makeTopLevelState(tabID: UUID(), aiProvider: "codex", aiSessionId: "session-1",
                              aiResumeCommand: "codex resume session-1"),
            makeTopLevelState(tabID: UUID(), aiProvider: "codex", aiSessionId: "session-2",
                              aiResumeCommand: "codex resume session-2")
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
            [makeTopLevelState(tabID: UUID(), aiProvider: nil, aiSessionId: nil, aiResumeCommand: nil),
             makeTopLevelState(tabID: UUID(), aiProvider: nil, aiSessionId: nil, aiResumeCommand: nil)]
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
}
