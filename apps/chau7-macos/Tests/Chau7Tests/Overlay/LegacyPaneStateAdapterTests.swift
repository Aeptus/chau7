import XCTest
@testable import Chau7

/// SPM-runnable tests for `OverlayTabsModel.applyLegacyPaneStateAdapters`.
///
/// The adapters bring older `SavedTabState` payloads up to the pane-native
/// shape `restoreTabState` expects:
///   - Legacy single-pane: synthesize a pane-state from top-level
///     SavedTabState fields when paneStates is missing.
///   - Legacy top-level AI metadata: backfill missing pane-level AI
///     provider/session from the top-level fields for single-pane tabs.
///
/// Pre-W3.28.2 these adapters lived inline in restoreTabState (50 lines
/// of struct copies). Extracting them lets us pin the rules with unit
/// tests; W3.28.1 already extracted the executeRestore body.
final class LegacyPaneStateAdapterTests: XCTestCase {

    // MARK: - Single-pane adapter (paneStates missing)

    /// When paneStatesByID is empty and there's exactly one terminal session,
    /// the adapter synthesizes a SavedTerminalPaneState from the top-level
    /// SavedTabState fields and keys it by the live session's pane ID.
    func testSinglePaneAdapterSynthesizesFromTopLevelFields() {
        let livePaneID = UUID()
        let session = TerminalSessionModel(appModel: AppModel())
        let state = makeTopLevelSavedTabState(
            directory: "/test/dir",
            aiProvider: "codex",
            aiSessionId: "abc-123",
            aiResumeCommand: "codex resume abc-123"
        )

        let result = OverlayTabsModel.applyLegacyPaneStateAdapters(
            paneStatesByID: [:],
            terminalSessions: [(livePaneID, session)],
            state: state
        )

        XCTAssertEqual(result.count, 1)
        let pane = try? XCTUnwrap(result[livePaneID])
        XCTAssertEqual(pane?.paneID, livePaneID.uuidString)
        XCTAssertEqual(pane?.directory, "/test/dir")
        XCTAssertEqual(pane?.aiProvider, "codex")
        XCTAssertEqual(pane?.aiSessionId, "abc-123")
        XCTAssertEqual(pane?.aiResumeCommand, "codex resume abc-123")
    }

    /// Empty paneStates + zero live sessions = no synthesis. The adapter
    /// should not fabricate paneIDs from nothing.
    func testSinglePaneAdapterSkipsWhenNoLiveSessions() {
        let result = OverlayTabsModel.applyLegacyPaneStateAdapters(
            paneStatesByID: [:],
            terminalSessions: [],
            state: makeTopLevelSavedTabState()
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// Non-empty paneStatesByID = the saved state is already pane-native;
    /// no single-pane adaptation needed even if there's one live session.
    func testSinglePaneAdapterSkipsWhenPaneStatesPresent() {
        let savedPaneID = UUID()
        let livePaneID = UUID()
        let savedPane = SavedTerminalPaneState(
            paneID: savedPaneID.uuidString,
            directory: "/saved",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: "codex",
            aiSessionId: "saved-session"
        )
        let session = TerminalSessionModel(appModel: AppModel())

        let result = OverlayTabsModel.applyLegacyPaneStateAdapters(
            paneStatesByID: [savedPaneID: savedPane],
            terminalSessions: [(livePaneID, session)],
            state: makeTopLevelSavedTabState(directory: "/top-level")
        )

        // The saved pane survives unchanged — no live-pane synthesis.
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[savedPaneID]?.directory, "/saved")
        XCTAssertNil(result[livePaneID])
    }

    // MARK: - Top-level AI metadata adapter

    /// Single pane with no AI metadata + top-level metadata present:
    /// adapter backfills from top-level. Without this, restored tabs
    /// would lose their resume command in the persisted pane-native shape.
    func testTopLevelAdapterBackfillsMissingPaneAIMetadata() {
        let paneID = UUID()
        let paneWithoutAI = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: "/dir",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: nil,
            aiSessionId: nil
        )
        let session = TerminalSessionModel(appModel: AppModel())
        let state = makeTopLevelSavedTabState(
            aiProvider: "claude",
            aiSessionId: "claude-xyz",
            aiResumeCommand: "claude --resume claude-xyz"
        )

        let result = OverlayTabsModel.applyLegacyPaneStateAdapters(
            paneStatesByID: [paneID: paneWithoutAI],
            terminalSessions: [(paneID, session)],
            state: state
        )

        let pane = result[paneID]
        XCTAssertEqual(pane?.aiProvider, "claude", "Backfilled from top-level")
        XCTAssertEqual(pane?.aiSessionId, "claude-xyz", "Backfilled from top-level")
        XCTAssertEqual(pane?.aiResumeCommand, "claude --resume claude-xyz")
    }

    /// Multi-pane (count > 1): top-level adapter does NOT fire. The rule
    /// is single-pane-only because top-level metadata in a multi-pane save
    /// would be ambiguous (which pane does it belong to?).
    func testTopLevelAdapterSkipsForMultiPane() {
        let paneA = UUID()
        let paneB = UUID()
        let session = TerminalSessionModel(appModel: AppModel())
        let result = OverlayTabsModel.applyLegacyPaneStateAdapters(
            paneStatesByID: [
                paneA: SavedTerminalPaneState(paneID: paneA.uuidString, directory: "/a", scrollbackContent: nil, aiResumeCommand: nil),
                paneB: SavedTerminalPaneState(paneID: paneB.uuidString, directory: "/b", scrollbackContent: nil, aiResumeCommand: nil)
            ],
            terminalSessions: [(paneA, session), (paneB, session)],
            state: makeTopLevelSavedTabState(
                aiProvider: "codex",
                aiSessionId: "ambiguous",
                aiResumeCommand: "codex resume ambiguous"
            )
        )

        // Neither pane gets the top-level AI metadata.
        XCTAssertNil(result[paneA]?.aiProvider)
        XCTAssertNil(result[paneB]?.aiProvider)
    }

    /// Single pane WITH AI metadata: adapter does NOT overwrite existing
    /// pane metadata with top-level values. Pane-level wins.
    func testTopLevelAdapterDoesNotOverwriteExistingPaneAIMetadata() {
        let paneID = UUID()
        let paneWithAI = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: "/dir",
            scrollbackContent: nil,
            aiResumeCommand: "codex resume pane-level",
            aiProvider: "codex",
            aiSessionId: "pane-level-session"
        )
        let session = TerminalSessionModel(appModel: AppModel())
        let result = OverlayTabsModel.applyLegacyPaneStateAdapters(
            paneStatesByID: [paneID: paneWithAI],
            terminalSessions: [(paneID, session)],
            state: makeTopLevelSavedTabState(
                aiProvider: "claude",
                aiSessionId: "top-level-session",
                aiResumeCommand: "claude --resume top-level-session"
            )
        )

        XCTAssertEqual(result[paneID]?.aiProvider, "codex", "Pane-level wins")
        XCTAssertEqual(result[paneID]?.aiSessionId, "pane-level-session")
    }

    // MARK: - Helpers

    private func makeTopLevelSavedTabState(
        directory: String = "/tmp",
        aiProvider: String? = nil,
        aiSessionId: String? = nil,
        aiResumeCommand: String? = nil
    ) -> SavedTabState {
        SavedTabState(
            tabID: UUID().uuidString,
            selectedTabID: nil,
            customTitle: "Test",
            color: TabColor.blue.rawValue,
            directory: directory,
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
