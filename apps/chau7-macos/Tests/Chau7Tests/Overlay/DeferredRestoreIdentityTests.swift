import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

private func drainDeferredRestoreIdentityQueue() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

@MainActor
final class DeferredRestoreIdentityTests: XCTestCase {

    private func makeSavedTabState(
        tabID: UUID,
        paneID: UUID,
        title: String,
        directory: String,
        aiProvider: String?,
        aiSessionId: String?,
        aiResumeCommand: String?
    ) -> SavedTabState {
        SavedTabState(
            tabID: tabID.uuidString,
            selectedTabID: nil,
            customTitle: title,
            color: TabColor.blue.rawValue,
            directory: directory,
            selectedIndex: nil,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: aiResumeCommand,
            aiProvider: aiProvider,
            aiSessionId: aiSessionId,
            aiSessionIdSource: aiSessionId == nil ? nil : .explicit,
            splitLayout: SavedSplitNode(kind: .terminal, id: paneID.uuidString),
            focusedPaneID: paneID.uuidString,
            paneStates: [
                SavedTerminalPaneState(
                    paneID: paneID.uuidString,
                    directory: directory,
                    scrollbackContent: nil,
                    aiResumeCommand: aiResumeCommand,
                    aiProvider: aiProvider,
                    aiSessionId: aiSessionId,
                    aiSessionIdSource: aiSessionId == nil ? nil : .explicit
                )
            ]
        )
    }

    func testDeferredRestoreStepHydratesIdentityWithoutActivatingBackgroundAI() throws {
        let selectedTabID = UUID()
        let selectedPaneID = UUID()
        let deferredTabID = UUID()
        let deferredPaneID = UUID()
        let states = [
            makeSavedTabState(
                tabID: selectedTabID,
                paneID: selectedPaneID,
                title: "Selected",
                directory: "/tmp/selected",
                aiProvider: "codex",
                aiSessionId: "selected-session",
                aiResumeCommand: "codex resume selected-session"
            ),
            makeSavedTabState(
                tabID: deferredTabID,
                paneID: deferredPaneID,
                title: "Deferred",
                directory: "/tmp/deferred",
                aiProvider: "codex",
                aiSessionId: "deferred-session",
                aiResumeCommand: "codex resume deferred-session"
            )
        ]
        let restoredModel = OverlayTabsModel(appModel: AppModel(), restoreState: false, restoringStates: states)

        XCTAssertTrue(restoredModel.restoreOneDeferredTabIfNeeded(reason: "test"))
        drainDeferredRestoreIdentityQueue()

        let deferredSession = try XCTUnwrap(restoredModel.tabs.first(where: { $0.id == deferredTabID })?.session)
        XCTAssertEqual(deferredSession.lastAIProvider, "codex")
        XCTAssertEqual(deferredSession.lastAISessionId, "deferred-session")
        XCTAssertNil(deferredSession.activeAppName)
        XCTAssertTrue(deferredSession.backgroundLiveRenderReasons().isEmpty)
        XCTAssertNotNil(restoredModel.deferredRestoreStatesByTabID[deferredTabID])

        restoredModel.selectTab(id: deferredTabID)

        XCTAssertNil(restoredModel.deferredRestoreStatesByTabID[deferredTabID])
        XCTAssertEqual(deferredSession.activeAppName, "Codex")
    }
}
#endif
