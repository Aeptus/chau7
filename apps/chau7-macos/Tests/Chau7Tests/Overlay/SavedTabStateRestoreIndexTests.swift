import XCTest
@testable import Chau7

final class SavedTabStateRestoreIndexTests: XCTestCase {
    func testStripsHeavyPayloadsButKeepsIdentityAndSession() {
        let pane = SavedTerminalPaneState(
            paneID: "pane-1",
            directory: "/Users/x/Downloads/Wikimedia/logo-gen",
            scrollbackContent: "tons of pane scrollback",
            aiResumeCommand: "codex resume 019ead58",
            aiProvider: "codex",
            aiSessionId: "019ead58",
            agentLaunchCommand: "codex"
        )
        let tab = SavedTabState(
            tabID: "tab-1",
            customTitle: "logo-gen",
            color: "blue",
            directory: "/Users/x/Downloads/Wikimedia/logo-gen",
            selectedIndex: 0,
            tokenOptOverride: nil,
            scrollbackContent: "legacy scrollback",
            aiResumeCommand: "codex resume 019ead58",
            aiProvider: "codex",
            aiSessionId: "019ead58",
            splitLayout: nil,
            focusedPaneID: "pane-1",
            paneStates: [pane],
            previewSnapshotPNGData: Data(repeating: 0xFF, count: 4096)
        )

        let stripped = tab.strippedForRestoreIndex

        // Heavy, regenerable payloads are dropped (kept in the file bundle instead).
        XCTAssertNil(stripped.scrollbackContent)
        XCTAssertNil(stripped.previewSnapshotPNGData)
        XCTAssertNil(stripped.commandBlocks)
        XCTAssertNil(stripped.paneStates?.first?.scrollbackContent)

        // Identity, structure, and AI session survive — so a fallback restore brings
        // the tab back (with its codex-resume), not loses it.
        XCTAssertEqual(stripped.tabID, "tab-1")
        XCTAssertEqual(stripped.customTitle, "logo-gen")
        XCTAssertEqual(stripped.directory, "/Users/x/Downloads/Wikimedia/logo-gen")
        XCTAssertEqual(stripped.aiProvider, "codex")
        XCTAssertEqual(stripped.aiSessionId, "019ead58")
        XCTAssertEqual(stripped.aiResumeCommand, "codex resume 019ead58")
        XCTAssertEqual(stripped.focusedPaneID, "pane-1")
        XCTAssertEqual(stripped.paneStates?.first?.paneID, "pane-1")
        XCTAssertEqual(stripped.paneStates?.first?.aiSessionId, "019ead58")
        XCTAssertEqual(stripped.paneStates?.first?.aiResumeCommand, "codex resume 019ead58")
        XCTAssertEqual(stripped.paneStates?.first?.agentLaunchCommand, "codex")
    }
}
