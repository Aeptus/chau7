import XCTest
@testable import Chau7

/// Pins the wiring that lets a restored tab render its saved screen instantly:
/// `resolveAndApplyPaneMetadata` must hand the persisted, already-styled
/// scrollback tail to the live `TerminalSessionModel` via
/// `pendingRestoreScrollback`, which `launchTerminal` later injects once and
/// clears. Both the interactive (selected) and background/deferred restore
/// profiles reach this single metadata-apply site, so covering it here covers
/// both paths.
final class PendingRestoreScrollbackTests: XCTestCase {

    /// A restored pane carrying non-empty scrollback content leaves it on the
    /// session so the launch path can replay the saved screen.
    func testMetadataApplyCarriesSavedScrollbackOntoSession() {
        let paneID = UUID()
        let session = TerminalSessionModel(appModel: AppModel())
        let styled = "\u{1B}[32m$ ls\u{1B}[0m\nfile.txt\n"
        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: "/repo",
            scrollbackContent: styled,
            aiResumeCommand: nil
        )
        var toRestore: [UUID: SavedTerminalPaneState] = [paneID: paneState]

        _ = OverlayTabsModel.resolveAndApplyPaneMetadata(
            currentSessions: [(paneID, session)],
            paneStatesByID: [paneID: paneState],
            paneStatesToRestore: &toRestore,
            state: makeSavedTabState(),
            targetTabID: UUID()
        )

        XCTAssertEqual(session.pendingRestoreScrollback, styled)
    }

    /// A restored pane with no saved scrollback must not arm the carrier — the
    /// launch path keeps its normal tip banner for such panes.
    func testMetadataApplyLeavesCarrierNilWhenNoScrollback() {
        let paneID = UUID()
        let session = TerminalSessionModel(appModel: AppModel())
        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: "/repo",
            scrollbackContent: nil,
            aiResumeCommand: nil
        )
        var toRestore: [UUID: SavedTerminalPaneState] = [paneID: paneState]

        _ = OverlayTabsModel.resolveAndApplyPaneMetadata(
            currentSessions: [(paneID, session)],
            paneStatesByID: [paneID: paneState],
            paneStatesToRestore: &toRestore,
            state: makeSavedTabState(),
            targetTabID: UUID()
        )

        XCTAssertNil(session.pendingRestoreScrollback)
    }

    /// Whitespace-only scrollback is treated as none: nothing worth replaying,
    /// so the carrier stays nil.
    func testMetadataApplyIgnoresWhitespaceOnlyScrollback() {
        let paneID = UUID()
        let session = TerminalSessionModel(appModel: AppModel())
        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: "/repo",
            scrollbackContent: "   \n\t\n",
            aiResumeCommand: nil
        )
        var toRestore: [UUID: SavedTerminalPaneState] = [paneID: paneState]

        _ = OverlayTabsModel.resolveAndApplyPaneMetadata(
            currentSessions: [(paneID, session)],
            paneStatesByID: [paneID: paneState],
            paneStatesToRestore: &toRestore,
            state: makeSavedTabState(),
            targetTabID: UUID()
        )

        XCTAssertNil(session.pendingRestoreScrollback)
    }

    // MARK: - Helpers

    private func makeSavedTabState() -> SavedTabState {
        SavedTabState(
            tabID: UUID().uuidString,
            selectedTabID: nil,
            customTitle: "Test",
            color: TabColor.blue.rawValue,
            directory: "/repo",
            selectedIndex: nil,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: nil,
            aiSessionId: nil,
            aiSessionIdSource: nil,
            splitLayout: nil,
            focusedPaneID: nil,
            paneStates: nil
        )
    }
}
