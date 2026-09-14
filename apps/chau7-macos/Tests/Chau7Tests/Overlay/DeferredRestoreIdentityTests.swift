import XCTest
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
        aiResumeCommand: String?,
        selectedTabIDMarker: UUID? = nil
    ) -> SavedTabState {
        SavedTabState(
            tabID: tabID.uuidString,
            selectedTabID: selectedTabIDMarker?.uuidString,
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
            splitLayout: SavedSplitNode(
                kind: .terminal,
                id: paneID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil
            ),
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

    func testDeferredRestorePrefillsBackgroundAgentBeforeSelectionWithoutDuplicateOnPromotion() throws {
        let originalAutoSubmit = FeatureSettings.shared.autoSubmitRestorePrefill
        FeatureSettings.shared.autoSubmitRestorePrefill = true
        defer { FeatureSettings.shared.autoSubmitRestorePrefill = originalAutoSubmit }
        let directory = FileManager.default.temporaryDirectory.standardized.path
        let selectedTabID = UUID()
        let selectedPaneID = UUID()
        let deferredTabID = UUID()
        let deferredPaneID = UUID()
        let resumeCommand = "codex resume deferred-session"
        let states = [
            makeSavedTabState(
                tabID: selectedTabID,
                paneID: selectedPaneID,
                title: "Selected shell",
                directory: directory,
                aiProvider: nil,
                aiSessionId: nil,
                aiResumeCommand: nil,
                selectedTabIDMarker: selectedTabID
            ),
            makeSavedTabState(
                tabID: deferredTabID,
                paneID: deferredPaneID,
                title: "Deferred agent",
                directory: directory,
                aiProvider: "codex",
                aiSessionId: "deferred-session",
                aiResumeCommand: resumeCommand
            )
        ]
        let restoredModel = OverlayTabsModel(appModel: AppModel(), restoreState: false, restoringStates: states)
        let deferredSession = try XCTUnwrap(
            restoredModel.tabs.first(where: { $0.id == deferredTabID })?.session
        )
        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { capturedInputs.append($0) }
        deferredSession.attachRustTerminal(terminalView)
        deferredSession.isShellLoading = false
        deferredSession.isAtPrompt = true
        deferredSession.status = .idle

        XCTAssertTrue(restoredModel.restoreOneDeferredTabIfNeeded(reason: "test_background_prefill"))
        drainDeferredRestoreIdentityQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(capturedInputs, [resumeCommand], "Background restore must prefill without launching the agent")
        XCTAssertEqual(restoredModel.selectedTabID, selectedTabID)
        XCTAssertNil(deferredSession.activeAppName)
        XCTAssertNotNil(restoredModel.deferredRestoreStatesByTabID[deferredTabID])

        FeatureSettings.shared.autoSubmitRestorePrefill = false
        restoredModel.selectTab(id: deferredTabID)
        drainDeferredRestoreIdentityQueue()

        XCTAssertEqual(capturedInputs, [resumeCommand], "Interactive promotion must not insert the prefilled command twice")
        XCTAssertNil(restoredModel.deferredRestoreStatesByTabID[deferredTabID])
        XCTAssertEqual(deferredSession.activeAppName, "Codex")
    }

    func testDeferredRestoreSchedulerWaitsAfterRecentSelection() {
        let tabIDs = (0 ..< 3).map { _ in UUID() }
        let paneIDs = (0 ..< 3).map { _ in UUID() }
        let states = (0 ..< 3).map { index in
            makeSavedTabState(
                tabID: tabIDs[index],
                paneID: paneIDs[index],
                title: "Tab \(index)",
                directory: "/tmp/tab-\(index)",
                aiProvider: "codex",
                aiSessionId: "session-\(index)",
                aiResumeCommand: "codex resume session-\(index)",
                selectedTabIDMarker: index == 0 ? tabIDs[0] : nil
            )
        }
        let restoredModel = OverlayTabsModel(appModel: AppModel(), restoreState: false, restoringStates: states)
        restoredModel.lastSelectionChangedAt = 10

        let result = restoredModel.restoreOneDeferredTabIfAllowed(reason: "test", now: 10.2)

        if case .deferred(let delay) = result {
            XCTAssertEqual(delay, 0.25, accuracy: 0.0001)
        } else {
            XCTFail("Expected background identity restore to wait after a recent selection")
        }
        XCTAssertEqual(restoredModel.deferredRestoreTabOrder, [tabIDs[1], tabIDs[2]])
    }

    func testSelectedDeferredRestoreDoesNotConsumeStateForMissingTab() {
        let model = OverlayTabsModel(appModel: AppModel(), restoreState: false)
        let missingTabID = UUID()
        let state = makeSavedTabState(
            tabID: missingTabID,
            paneID: UUID(),
            title: "Recovery",
            directory: "/tmp/recovery",
            aiProvider: "codex",
            aiSessionId: "recovery-session",
            aiResumeCommand: "codex resume recovery-session"
        )
        model.selectedTabID = missingTabID
        model.deferredRestoreStatesByTabID[missingTabID] = state
        model.deferredRestoreTabOrder = [missingTabID]

        model.restoreSelectedDeferredTabIfNeeded(reason: "test_missing_tab")

        XCTAssertEqual(model.deferredRestoreStatesByTabID[missingTabID]?.customTitle, "Recovery")
        XCTAssertEqual(model.deferredRestoreTabOrder, [missingTabID])
    }

    func testDeferredRestoreSchedulerPrioritizesNearestTabToSelection() {
        let tabIDs = (0 ..< 4).map { _ in UUID() }
        let paneIDs = (0 ..< 4).map { _ in UUID() }
        let states = (0 ..< 4).map { index in
            makeSavedTabState(
                tabID: tabIDs[index],
                paneID: paneIDs[index],
                title: "Tab \(index)",
                directory: "/tmp/tab-\(index)",
                aiProvider: "codex",
                aiSessionId: "session-\(index)",
                aiResumeCommand: "codex resume session-\(index)",
                selectedTabIDMarker: index == 1 ? tabIDs[1] : nil
            )
        }
        let restoredModel = OverlayTabsModel(appModel: AppModel(), restoreState: false, restoringStates: states)

        XCTAssertEqual(restoredModel.restoreOneDeferredTabIfAllowed(reason: "test", now: 20), .restored)

        XCTAssertFalse(restoredModel.deferredRestoreTabOrder.contains(tabIDs[2]))
        XCTAssertTrue(restoredModel.deferredRestoreTabOrder.contains(tabIDs[0]))
        XCTAssertTrue(restoredModel.deferredRestoreTabOrder.contains(tabIDs[3]))
    }
}
