import XCTest
import AppKit
import Chau7Core
@testable import Chau7

// swiftlint:disable type_body_length

private func drainMainQueue() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

private func storeSavedTabStates(_ states: [SavedTabState]) {
    guard let data = try? JSONEncoder().encode(states) else {
        XCTFail("Failed to encode saved tab states")
        return
    }
    UserDefaults.standard.set(data, forKey: SavedTabState.userDefaultsKey)
}

@MainActor
final class OverlayTabsModelTests: XCTestCase {

    private var model: OverlayTabsModel!
    private var appModel: AppModel!
    private var originalLastTabCloseBehavior: LastTabCloseBehavior = .keepWindow
    private var originalWarnOnCloseWithRunningProcess = true
    private var originalAlwaysWarnOnTabClose = false
    private var originalRepoGroupingMode: RepoGroupingMode = .off
    private var originalRecentRepoRoots: [String] = []
    private var originalAutoSubmitRestorePrefill = false
    private var originalKnownRepoIdentities: [KnownRepoIdentity] = []

    private func tabStateBackupRootURL() -> URL {
        OverlayTabsModel.tabStateBackupRootURL()
            ?? RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("TabStateBackups", isDirectory: true)
    }

    private func removePersistedWindowStateArtifacts() {
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        // Restore is freshest-wins arbitrated between the file bundle and the
        // UserDefaults index (`bundleIsCurrentRestoreSource`). A bundle or
        // save token leaked from another suite would hijack restoreSavedTabs,
        // so clear all three sources, not just the UserDefaults states.
        UserDefaults.standard.removeObject(forKey: SavedTabState.restoreIndexSaveTokenKey)
        try? TabRestoreBundleStore.clearCurrentBundle()
        TabRestoreBundleStore.resetCacheForTesting()
        try? FileManager.default.removeItem(at: tabStateBackupRootURL())
    }

    private func temporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Chau7Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Repo-group inheritance (`RepoGroupInheritance.inheritedGroupID`) and
    /// `inheritedStartDirectory` both require an on-disk directory inside the
    /// group root — a new tab only inherits the selected tab's group when its
    /// resolved start directory actually lives under that root. Tests that
    /// exercise inheritance therefore need real directories, not synthetic
    /// `/tmp/...` paths. Returns the created root; tracks it for cleanup.
    private var temporaryRepoDirs: [URL] = []
    /// Polls `condition` on the main run loop until it is true or the timeout
    /// elapses. Uses an XCTestExpectation-driven timer so DispatchQueue.main
    /// async work (e.g. the deferred executeRestoreBody phase) is reliably
    /// pumped — a bare `RunLoop.run(until:)` loop does not always drain it
    /// under swift test.
    private func waitForCondition(
        timeout: TimeInterval = 8.0,
        _ condition: @escaping () -> Bool
    ) {
        if condition() { return }
        let exp = expectation(description: "condition")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { t in
            if condition() {
                t.invalidate()
                exp.fulfill()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wait(for: [exp], timeout: timeout)
        timer.invalidate()
    }

    @discardableResult
    private func makeTemporaryRepoRoot(subpath: String? = nil) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Chau7RepoTests-\(UUID().uuidString)", isDirectory: true)
        let target = subpath.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        temporaryRepoDirs.append(root)
        return root
    }

    private func createClaudeTranscript(home: URL, directory: String, sessionID: String) throws {
        let normalizedDirectory = URL(fileURLWithPath: directory).standardized.path
        let projectDirName = normalizedDirectory.replacingOccurrences(of: "/", with: "-")
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let projectDir = claudeDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(
            atPath: projectDir.appendingPathComponent("\(sessionID).jsonl").path,
            contents: Data("[]\n".utf8)
        )
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let historyURL = claudeDir.appendingPathComponent("history.jsonl")
        let payload: [String: Any] = [
            "display": "test",
            "timestamp": 1,
            "project": normalizedDirectory,
            "sessionId": sessionID
        ]
        let line = try JSONSerialization.data(withJSONObject: payload)
        var historyData = (try? Data(contentsOf: historyURL)) ?? Data()
        historyData.append(line)
        historyData.append(Data("\n".utf8))
        try historyData.write(to: historyURL)
    }

    private func makeSavedTabState(title: String, directory: String) -> SavedTabState {
        SavedTabState(
            customTitle: title,
            color: TabColor.blue.rawValue,
            directory: directory,
            selectedIndex: nil,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            splitLayout: nil,
            focusedPaneID: nil,
            paneStates: nil
        )
    }

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

    override func setUp() {
        super.setUp()
        // Clear any saved tab state so restoreSavedTabs returns nil
        // and the model starts with a single fresh tab.
        removePersistedWindowStateArtifacts()
        OverlayTabsModel.sessionFinders = [:]
        ClaudeSessionResolver.clearCache()
        originalLastTabCloseBehavior = FeatureSettings.shared.lastTabCloseBehavior
        originalWarnOnCloseWithRunningProcess = FeatureSettings.shared.warnOnCloseWithRunningProcess
        originalAlwaysWarnOnTabClose = FeatureSettings.shared.alwaysWarnOnTabClose
        originalRepoGroupingMode = FeatureSettings.shared.repoGroupingMode
        originalRecentRepoRoots = FeatureSettings.shared.recentRepoRoots
        // Resume-prefill tests assert exactly the prefilled command with no
        // trailing newline. Auto-submit (a feature flag, default false) would
        // append a "\n"/Enter; pin it off so a leaked value from another
        // suite can't perturb these assertions.
        originalAutoSubmitRestorePrefill = FeatureSettings.shared.autoSubmitRestorePrefill
        FeatureSettings.shared.autoSubmitRestorePrefill = false
        // Repo-grouping resolution consults KnownRepoIdentityStore; a stale
        // identity leaked from another test perturbs gitRoot/group resolution.
        // Snapshot and start from a clean store.
        originalKnownRepoIdentities = KnownRepoIdentityStore.shared.allIdentities()
        KnownRepoIdentityStore.shared.reset()
        appModel = AppModel()
        model = OverlayTabsModel(appModel: appModel, restoreState: false)
        FeatureSettings.shared.recentRepoRoots = []
    }

    override func tearDown() {
        MemoryPressureResponder.shared.memoryPressureOverrideForTesting = nil
        for dir in temporaryRepoDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        temporaryRepoDirs = []
        model = nil
        appModel = nil
        OverlayTabsModel.sessionFinders = [:]
        ClaudeSessionResolver.clearCache()
        removePersistedWindowStateArtifacts()
        FeatureSettings.shared.lastTabCloseBehavior = originalLastTabCloseBehavior
        FeatureSettings.shared.warnOnCloseWithRunningProcess = originalWarnOnCloseWithRunningProcess
        FeatureSettings.shared.alwaysWarnOnTabClose = originalAlwaysWarnOnTabClose
        FeatureSettings.shared.repoGroupingMode = originalRepoGroupingMode
        FeatureSettings.shared.recentRepoRoots = originalRecentRepoRoots
        FeatureSettings.shared.autoSubmitRestorePrefill = originalAutoSubmitRestorePrefill
        KnownRepoIdentityStore.shared.reset()
        KnownRepoIdentityStore.shared.restore(originalKnownRepoIdentities)
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(model.tabs.count, 1, "Model should start with exactly one tab")
        XCTAssertEqual(
            model.selectedTabID,
            model.tabs.first?.id,
            "The single initial tab should be selected"
        )
        XCTAssertFalse(model.isSearchVisible)
        XCTAssertFalse(model.isBroadcastMode)
    }

    func testDecodeBackupWindowStatesSupportsLegacySingleWindowPayload() throws {
        let state = makeSavedTabState(title: "Primary", directory: "/tmp/primary")
        let data = try JSONEncoder().encode([state])

        let windows = try XCTUnwrap(OverlayTabsModel.decodeBackupWindowStates(from: data))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].first?.customTitle, "Primary")
    }

    func testDecodeBackupWindowStatesSupportsMultiWindowPayload() throws {
        let data = try JSONEncoder().encode(
            SavedMultiWindowState(
                windows: [
                    [makeSavedTabState(title: "Window 1", directory: "/tmp/one")],
                    [makeSavedTabState(title: "Window 2", directory: "/tmp/two")]
                ]
            )
        )

        let windows = try XCTUnwrap(OverlayTabsModel.decodeBackupWindowStates(from: data))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[1].first?.customTitle, "Window 2")
    }

    func testRestoreSavedTabsUsesPrimaryWindowFromMultiWindowState() throws {
        let data = try JSONEncoder().encode(
            SavedMultiWindowState(
                windows: [
                    [makeSavedTabState(title: "Window 1", directory: "/tmp/one")],
                    [makeSavedTabState(title: "Window 2", directory: "/tmp/two")]
                ]
            )
        )
        UserDefaults.standard.set(data, forKey: SavedMultiWindowState.userDefaultsKey)

        let restored = try XCTUnwrap(OverlayTabsModel.restoreSavedTabs(appModel: appModel))

        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs.first?.customTitle, "Window 1")
        XCTAssertEqual(restored.rawStates.first?.directory, "/tmp/one")
    }

    func testRestoreSavedTabsBackfillsMissingAIResumeMetadataFromOlderArchive() throws {
        let tabID = UUID()
        let paneID = UUID()
        let latestState = makeSavedTabState(
            tabID: tabID,
            paneID: paneID,
            title: "Latest",
            directory: "/tmp/aetower",
            aiProvider: nil,
            aiSessionId: nil,
            aiResumeCommand: nil
        )
        let archivedState = makeSavedTabState(
            tabID: tabID,
            paneID: paneID,
            title: "Archived",
            directory: "/tmp/aetower",
            aiProvider: "codex",
            aiSessionId: "session-123",
            aiResumeCommand: "codex resume session-123"
        )

        let backupRoot = tabStateBackupRootURL()
        try FileManager.default.createDirectory(
            at: backupRoot.appendingPathComponent("archive", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(SavedMultiWindowState(windows: [[latestState]])).write(
            to: backupRoot.appendingPathComponent("latest.json")
        )
        try JSONEncoder().encode(SavedMultiWindowState(windows: [[archivedState]])).write(
            to: backupRoot.appendingPathComponent("archive/0000000000001-autosave.json")
        )

        let restored = try XCTUnwrap(OverlayTabsModel.restoreSavedTabs(appModel: appModel))
        let restoredPane = try XCTUnwrap(restored.rawStates.first?.paneStates?.first)

        XCTAssertEqual(restoredPane.aiProvider, "codex")
        XCTAssertEqual(restoredPane.aiSessionId, "session-123")
        XCTAssertEqual(restoredPane.aiResumeCommand, "codex resume session-123")
    }

    func testRestoreSavedTabsRepairsLatestBackupWhenArchiveHasRicherMetadata() throws {
        let tabID = UUID()
        let paneID = UUID()
        let latestState = makeSavedTabState(
            tabID: tabID,
            paneID: paneID,
            title: "Latest",
            directory: "/tmp/aetower",
            aiProvider: nil,
            aiSessionId: nil,
            aiResumeCommand: nil
        )
        let archivedState = makeSavedTabState(
            tabID: tabID,
            paneID: paneID,
            title: "Archived",
            directory: "/tmp/aetower",
            aiProvider: "codex",
            aiSessionId: "session-123",
            aiResumeCommand: "codex resume session-123"
        )

        let backupRoot = tabStateBackupRootURL()
        try FileManager.default.createDirectory(
            at: backupRoot.appendingPathComponent("archive", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(SavedMultiWindowState(windows: [[latestState]])).write(
            to: backupRoot.appendingPathComponent("latest.json")
        )
        try JSONEncoder().encode(SavedMultiWindowState(windows: [[archivedState]])).write(
            to: backupRoot.appendingPathComponent("archive/0000000000001-autosave.json")
        )

        _ = try XCTUnwrap(OverlayTabsModel.restoreSavedTabs(appModel: appModel))

        let repairedData = try Data(contentsOf: backupRoot.appendingPathComponent("latest.json"))
        let repaired = try XCTUnwrap(OverlayTabsModel.decodeBackupWindowStates(from: repairedData))
        let repairedPane = try XCTUnwrap(repaired.first?.first?.paneStates?.first)

        XCTAssertEqual(repairedPane.aiProvider, "codex")
        XCTAssertEqual(repairedPane.aiSessionId, "session-123")
        XCTAssertEqual(repairedPane.aiResumeCommand, "codex resume session-123")
    }

    func testRestoreSavedTabsRepairsLatestBackupWhenOnlyResumeCommandIsMissing() throws {
        let tabID = UUID()
        let paneID = UUID()
        let latestState = makeSavedTabState(
            tabID: tabID,
            paneID: paneID,
            title: "Latest",
            directory: "/tmp/aetower",
            aiProvider: "codex",
            aiSessionId: "session-123",
            aiResumeCommand: nil
        )
        let archivedState = makeSavedTabState(
            tabID: tabID,
            paneID: paneID,
            title: "Archived",
            directory: "/tmp/aetower",
            aiProvider: "codex",
            aiSessionId: "session-123",
            aiResumeCommand: "codex resume session-123"
        )

        let backupRoot = tabStateBackupRootURL()
        try FileManager.default.createDirectory(
            at: backupRoot.appendingPathComponent("archive", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(SavedMultiWindowState(windows: [[latestState]])).write(
            to: backupRoot.appendingPathComponent("latest.json")
        )
        try JSONEncoder().encode(SavedMultiWindowState(windows: [[archivedState]])).write(
            to: backupRoot.appendingPathComponent("archive/0000000000001-autosave.json")
        )

        _ = try XCTUnwrap(OverlayTabsModel.restoreSavedTabs(appModel: appModel))

        let repairedData = try Data(contentsOf: backupRoot.appendingPathComponent("latest.json"))
        let repaired = try XCTUnwrap(OverlayTabsModel.decodeBackupWindowStates(from: repairedData))
        let repairedPane = try XCTUnwrap(repaired.first?.first?.paneStates?.first)

        XCTAssertEqual(repairedPane.aiProvider, "codex")
        XCTAssertEqual(repairedPane.aiSessionId, "session-123")
        XCTAssertEqual(repairedPane.aiResumeCommand, "codex resume session-123")
    }

    func testRestoreSavedTabsBackfillsUserDefaultsAIResumeCommandFromArchive() throws {
        let tabID = UUID()
        let paneID = UUID()
        let userDefaultsState = makeSavedTabState(
            tabID: tabID,
            paneID: paneID,
            title: "User Defaults",
            directory: "/tmp/aetower",
            aiProvider: "codex",
            aiSessionId: "session-123",
            aiResumeCommand: nil
        )
        let archivedState = makeSavedTabState(
            tabID: tabID,
            paneID: paneID,
            title: "Archived",
            directory: "/tmp/aetower",
            aiProvider: "codex",
            aiSessionId: "session-123",
            aiResumeCommand: "codex resume session-123"
        )

        let userDefaultsPayload = try JSONEncoder().encode(
            SavedMultiWindowState(windows: [[userDefaultsState]])
        )
        UserDefaults.standard.set(userDefaultsPayload, forKey: SavedMultiWindowState.userDefaultsKey)

        let backupRoot = tabStateBackupRootURL()
        try FileManager.default.createDirectory(
            at: backupRoot.appendingPathComponent("archive", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(SavedMultiWindowState(windows: [[archivedState]])).write(
            to: backupRoot.appendingPathComponent("archive/0000000000001-autosave.json")
        )

        let restored = try XCTUnwrap(OverlayTabsModel.restoreSavedTabs(appModel: appModel))
        let restoredPane = try XCTUnwrap(restored.rawStates.first?.paneStates?.first)

        XCTAssertEqual(restoredPane.aiProvider, "codex")
        XCTAssertEqual(restoredPane.aiSessionId, "session-123")
        XCTAssertEqual(restoredPane.aiResumeCommand, "codex resume session-123")

        let repairedData = try XCTUnwrap(
            UserDefaults.standard.data(forKey: SavedMultiWindowState.userDefaultsKey)
        )
        let repaired = try JSONDecoder().decode(SavedMultiWindowState.self, from: repairedData)
        let repairedPane = try XCTUnwrap(repaired.windows.first?.first?.paneStates?.first)
        XCTAssertEqual(repairedPane.aiResumeCommand, "codex resume session-123")
    }

    func testMergedAIResumePayloadUsesFallbackCommandIdentityWhenCurrentIsSynthetic() {
        let paneID = UUID().uuidString
        let current = SavedTerminalPaneState(
            paneID: paneID,
            directory: "/tmp/aetower",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: "codex",
            aiSessionId: "synth:codex:abc123",
            aiSessionIdSource: .synthetic
        )
        let fallback = SavedTerminalPaneState(
            paneID: paneID,
            directory: "/tmp/aetower",
            scrollbackContent: nil,
            aiResumeCommand: "codex resume real-session-123",
            aiProvider: "codex",
            aiSessionId: "synth:codex:fallback",
            aiSessionIdSource: .synthetic
        )

        let merged = current.mergedAIResumePayload(with: fallback)

        XCTAssertEqual(merged.aiProvider, "codex")
        XCTAssertEqual(merged.aiSessionId, "real-session-123")
        XCTAssertEqual(merged.aiSessionIdSource, .explicit)
        XCTAssertEqual(merged.aiResumeCommand, "codex resume real-session-123")
    }

    func testMergedAIResumePayloadDoesNotUseFallbackCommandForDifferentProvider() {
        let paneID = UUID().uuidString
        let current = SavedTerminalPaneState(
            paneID: paneID,
            directory: "/tmp/aetower",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: "codex",
            aiSessionId: nil,
            aiSessionIdSource: nil
        )
        let fallback = SavedTerminalPaneState(
            paneID: paneID,
            directory: "/tmp/aetower",
            scrollbackContent: nil,
            aiResumeCommand: "claude --resume claude-session-123",
            aiProvider: "claude",
            aiSessionId: "claude-session-123",
            aiSessionIdSource: .explicit
        )

        let merged = current.mergedAIResumePayload(with: fallback)

        XCTAssertEqual(merged.aiProvider, "codex")
        XCTAssertNil(merged.aiSessionId)
        XCTAssertNil(merged.aiSessionIdSource)
        XCTAssertNil(merged.aiResumeCommand)
    }

    func testExportTabStatesPreservesDeferredRestoreAIResumeMetadata() throws {
        let selectedState = makeSavedTabState(
            tabID: UUID(),
            paneID: UUID(),
            title: "Selected",
            directory: "/tmp/selected",
            aiProvider: "codex",
            aiSessionId: "selected-session",
            aiResumeCommand: "codex resume selected-session"
        )
        let deferredTabID = UUID()
        let deferredPaneID = UUID()
        let deferredState = makeSavedTabState(
            tabID: deferredTabID,
            paneID: deferredPaneID,
            title: "Deferred",
            directory: "/tmp/deferred",
            aiProvider: "codex",
            aiSessionId: "deferred-session",
            aiResumeCommand: "codex resume deferred-session"
        )

        let restoredModel = OverlayTabsModel(
            appModel: AppModel(),
            restoringStates: [selectedState, deferredState]
        )
        let exported = restoredModel.exportTabStates()
        let exportedDeferred = try XCTUnwrap(exported.first(where: { $0.tabID == deferredTabID.uuidString }))
        let exportedDeferredPane = try XCTUnwrap(exportedDeferred.paneStates?.first)

        XCTAssertEqual(exportedDeferredPane.aiProvider, "codex")
        XCTAssertEqual(exportedDeferredPane.aiSessionId, "deferred-session")
        XCTAssertEqual(exportedDeferredPane.aiResumeCommand, "codex resume deferred-session")
    }

    func testDeferredRestoreDoesNotCountAsStartupRestoreWork() {
        let deferredTabID = UUID()
        model.deferredRestoreTabOrder = [deferredTabID]
        model.deferredRestoreStatesByTabID[deferredTabID] = makeSavedTabState(
            title: "Deferred",
            directory: "/tmp/deferred"
        )

        XCTAssertFalse(model.hasPendingStartupRestoreWork)
    }

    func testSelectingDeferredTabConsumesOnlySelectedDeferredState() throws {
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
        XCTAssertEqual(restoredModel.deferredRestoreTabOrder, [deferredTabID])

        restoredModel.selectTab(id: deferredTabID)

        XCTAssertEqual(restoredModel.selectedTabID, deferredTabID)
        XCTAssertTrue(restoredModel.deferredRestoreTabOrder.isEmpty)
        XCTAssertTrue(restoredModel.deferredRestoreStatesByTabID.isEmpty)

        let deferredSession = try XCTUnwrap(restoredModel.tabs.first(where: { $0.id == deferredTabID })?.session)
        XCTAssertEqual(deferredSession.activeAppName, "Codex")
        XCTAssertEqual(deferredSession.lastAISessionId, "deferred-session")
    }

    func testSelectingDeferredTabDoesNotArmVisibleFrameHandoffBeforeRendererAttaches() throws {
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

        restoredModel.selectTab(id: deferredTabID)

        let deferredSession = try XCTUnwrap(restoredModel.tabs.first(where: { $0.id == deferredTabID })?.session)
        XCTAssertEqual(restoredModel.selectedTabID, deferredTabID)
        XCTAssertFalse(deferredSession.awaitingVisibleFrameReady)
        XCTAssertEqual(restoredModel.selectedSurfacePresentation.phase, .live)
    }

    func testSelectingDeferredTabRevalidatesQueuedResumePrefillBeforeDelivery() throws {
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
                directory: "/tmp/owned-pane",
                aiProvider: "codex",
                aiSessionId: "deferred-session",
                aiResumeCommand: "codex resume deferred-session"
            )
        ]

        let restoredModel = OverlayTabsModel(appModel: AppModel(), restoreState: false, restoringStates: states)
        restoredModel.selectTab(id: deferredTabID)
        drainMainQueue()

        let deferredSession = try XCTUnwrap(restoredModel.tabs.first(where: { $0.id == deferredTabID })?.session)
        deferredSession.updateCurrentDirectory("/tmp/drifted-pane")
        deferredSession.isShellLoading = false
        deferredSession.isAtPrompt = true
        deferredSession.status = .idle

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { text in
            capturedInputs.append(text)
        }
        deferredSession.attachRustTerminal(terminalView)

        let expectationDone = expectation(description: "selected deferred prefill is rejected after ownership drift")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(capturedInputs.isEmpty)
            XCTAssertEqual(
                restoredModel.resumeRestoreDeliveryStateByPaneID[deferredPaneID]?.outcome,
                .rejected
            )
            XCTAssertNil(restoredModel.latestRestoreResumeTokenByPaneID[deferredPaneID])
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 1.0)
    }

    func testResolveAIResumeMetadataAllowsLiveProviderHintToOverrideStaleCodexRestore() {
        OverlayTabsModel.registerSessionFinder(forProviderKey: "claude") { directory, _, _ in
            directory == "/tmp/aetower" ? "claude-session-1" : nil
        }
        OverlayTabsModel.registerSessionFinder(forProviderKey: "codex") { _, _, _ in nil }

        let resolved = OverlayTabsModel.resolveAIResumeMetadata(
            appName: "Claude",
            directory: "/tmp/aetower",
            outputHint: "claude code",
            explicitAIProvider: "codex",
            explicitAISessionId: nil
        )

        XCTAssertEqual(resolved?.provider, "claude")
        XCTAssertEqual(resolved?.sessionId, "claude-session-1")
    }

    func testResolveResumeMetadataReusesClaimedCodexFallbackAcrossHistoryGrowth() throws {
        let session = try XCTUnwrap(model.tabs.first?.session)
        session.currentDirectory = "/tmp/chau7-runtime"
        session.restoreAIMetadata(provider: "codex", sessionId: "codex-claimed")

        let firstHistory = [
            HistoryEntry(
                sessionId: "candidate-1",
                timestamp: 1,
                summary: "prompt",
                isExit: false
            )
        ]
        let secondHistory = firstHistory + [
            HistoryEntry(
                sessionId: "candidate-2",
                timestamp: 2,
                summary: "prompt",
                isExit: false
            )
        ]

        appModel.toolHistoryEntries["codex"] = firstHistory
        let firstResolved = model.resolveResumeMetadata(
            for: session,
            directory: session.currentDirectory,
            outputHint: nil,
            claimedSessionIds: ["codex-claimed"]
        )
        let cacheKey = ObjectIdentifier(session)
        let firstCache = try XCTUnwrap(model.codexResumeFallbackCache[cacheKey])

        appModel.toolHistoryEntries["codex"] = secondHistory
        let secondResolved = model.resolveResumeMetadata(
            for: session,
            directory: session.currentDirectory,
            outputHint: nil,
            claimedSessionIds: ["codex-claimed"]
        )
        let secondCache = try XCTUnwrap(model.codexResumeFallbackCache[cacheKey])

        XCTAssertEqual(firstResolved?.provider, "codex")
        XCTAssertEqual(firstResolved?.sessionId, "codex-claimed")
        XCTAssertEqual(secondResolved?.provider, "codex")
        XCTAssertEqual(secondResolved?.sessionId, "codex-claimed")
        XCTAssertNotEqual(
            OverlayTabsModel.codexHistoryFingerprint(firstHistory),
            OverlayTabsModel.codexHistoryFingerprint(secondHistory)
        )
        XCTAssertEqual(firstCache.signature.historyFingerprint, secondCache.signature.historyFingerprint)
    }

    func testClearPersistedWindowStateRemovesSavedStateAndBackups() {
        let state = makeSavedTabState(title: "Primary", directory: "/tmp/primary")
        storeSavedTabStates([state])
        OverlayTabsModel.persistWindowStateBackups(windowStates: [[state]], reason: .termination)

        let backupRoot = tabStateBackupRootURL()
        let latest = backupRoot.appendingPathComponent("latest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: latest.path))
        XCTAssertNotNil(UserDefaults.standard.data(forKey: SavedTabState.userDefaultsKey))

        OverlayTabsModel.clearPersistedWindowState()

        XCTAssertNil(UserDefaults.standard.data(forKey: SavedTabState.userDefaultsKey))
        XCTAssertNil(UserDefaults.standard.data(forKey: SavedMultiWindowState.userDefaultsKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: latest.path))

        let restoredModel = OverlayTabsModel(appModel: AppModel())
        XCTAssertEqual(restoredModel.tabs.count, 1)
        XCTAssertNotEqual(restoredModel.tabs.first?.customTitle, "Primary")
    }

    // MARK: - Tab Creation (addTab / newTab)

    func testNewTabIncreasesCount() {
        let initialCount = model.tabs.count
        model.newTab()
        XCTAssertEqual(
            model.tabs.count,
            initialCount + 1,
            "newTab should add exactly one tab"
        )
    }

    func testNewTabBecomesSelected() {
        model.newTab()
        let lastTab = model.tabs.last!
        XCTAssertEqual(
            model.selectedTabID,
            lastTab.id,
            "Newly created tab should become the selected tab"
        )
    }

    func testNewTabGetsUniqueID() {
        model.newTab()
        model.newTab()
        let ids = model.tabs.map(\.id)
        XCTAssertEqual(
            Set(ids).count,
            ids.count,
            "Every tab should have a unique ID"
        )
    }

    func testNewTabCyclesColors() {
        // Start with 1 tab, add enough to cycle through all colors
        let colorCount = TabColor.allCases.count
        for _ in 0 ..< colorCount {
            model.newTab()
        }
        // The (colorCount + 1)th tab should wrap around to the first color
        let wrappedTab = model.tabs[colorCount]
        let firstColor = TabColor.allCases[colorCount % colorCount]
        XCTAssertEqual(
            wrappedTab.color,
            firstColor,
            "Tab colors should cycle through TabColor.allCases"
        )
    }

    func testNewTabAtDirectorySetsCwd() {
        let directory = "/tmp/test-dir"
        model.newTab(at: directory)
        // The new tab was created; just verify it exists and is selected.
        // The actual directory change is deferred to the shell process.
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.selectedTabID, model.tabs.last?.id)
    }

    func testNewTabFromGroupedSelectionInheritsGroupAndStaysAdjacent() {
        // Inheritance requires the selected tab's current directory to live
        // on disk inside the group root (RepoGroupInheritance + the
        // existence check in inheritedStartDirectory).
        let groupID = makeTemporaryRepoRoot().standardized.path
        model.newTab()
        model.newTab()
        model.tabs[0].repoGroupID = groupID
        model.tabs[1].repoGroupID = groupID
        model.tabs[0].session?.currentDirectory = groupID
        model.selectTab(id: model.tabs[0].id)

        model.newTab()

        XCTAssertEqual(model.tabs[1].id, model.selectedTabID, "Grouped Cmd+T should insert immediately after the selected grouped tab")
        XCTAssertEqual(model.tabs[1].repoGroupID, groupID, "Grouped Cmd+T should inherit the current repo group")
    }

    func testNewTabAtDirectoryFromGroupedSelectionInheritsGroupAndStaysAdjacent() {
        model.newTab()
        let groupID = "/tmp/chau7-grouped-dir"
        model.tabs[0].repoGroupID = groupID
        model.selectTab(id: model.tabs[0].id)

        model.newTab(at: "/tmp/chau7-grouped-dir/worktree")

        XCTAssertEqual(model.tabs[1].id, model.selectedTabID)
        XCTAssertEqual(model.tabs[1].repoGroupID, groupID)
    }

    func testNewTabAtDirectoryFromGroupedSelectionDoesNotInheritDifferentRepoGroup() throws {
        let groupID = makeTemporaryRepoRoot().standardized.path
        let unrelatedDir = makeTemporaryRepoRoot().standardized.path
        model.newTab()
        model.tabs[0].repoGroupID = groupID
        model.tabs[0].session?.currentDirectory = groupID
        model.selectTab(id: model.tabs[0].id)

        model.newTab(at: unrelatedDir)

        // A non-inheriting new tab is appended at the end (newTabPosition
        // default is "end"), so it's the selected/last tab, not tabs[1].
        let newTab = try XCTUnwrap(model.tabs.last)
        XCTAssertEqual(newTab.id, model.selectedTabID)
        XCTAssertNil(newTab.repoGroupID)
        XCTAssertFalse(newTab.hasInheritedRepoGroup)
    }

    func testDisplaySessionTracksFocusedTerminalPane() {
        model.splitCurrentTabHorizontally()

        let sessions = model.tabs[0].splitController.terminalSessions
        XCTAssertEqual(sessions.count, 2)

        let secondaryPaneID = sessions[1].0
        let secondarySession = sessions[1].1
        model.tabs[0].splitController.setFocusedPane(secondaryPaneID)

        XCTAssertTrue(model.tabs[0].displaySession === secondarySession)
    }

    func testDisplaySessionKeepsLastTerminalWhenEditorPaneIsFocused() {
        model.splitCurrentTabHorizontally()

        let sessions = model.tabs[0].splitController.terminalSessions
        XCTAssertEqual(sessions.count, 2)

        let secondaryPaneID = sessions[1].0
        let secondarySession = sessions[1].1
        model.tabs[0].splitController.setFocusedPane(secondaryPaneID)

        model.tabs[0].splitController.splitWithTextEditor(direction: .horizontal)

        XCTAssertNil(model.tabs[0].splitController.focusedSession)
        XCTAssertNotNil(model.tabs[0].splitController.focusedEditor)
        XCTAssertTrue(model.tabs[0].displaySession === secondarySession)
    }

    func testHandleTabBarSelectionDismissesDashboardForCurrentTab() {
        let selectedTabID = model.selectedTabID
        model.activeDashboardGroupID = "/tmp/chau7-dashboard"

        model.handleTabBarSelection(id: selectedTabID)

        XCTAssertNil(model.activeDashboardGroupID)
        XCTAssertEqual(model.selectedTabID, selectedTabID)
    }

    func testHandleTabBarSelectionDismissesDashboardAndSelectsDifferentTab() {
        model.newTab()
        let targetTabID = model.tabs[1].id
        model.activeDashboardGroupID = "/tmp/chau7-dashboard"

        model.handleTabBarSelection(id: targetTabID)

        XCTAssertNil(model.activeDashboardGroupID)
        XCTAssertEqual(model.selectedTabID, targetTabID)
    }

    func testInheritedRepoGroupDetachesWhenTabMovesToDifferentRepoInManualMode() throws {
        let originalMode = FeatureSettings.shared.repoGroupingMode
        FeatureSettings.shared.repoGroupingMode = .manual
        defer { FeatureSettings.shared.repoGroupingMode = originalMode }

        // Inheritance needs the selected tab's cwd to live on disk inside the
        // group root, so use a real temp directory.
        let originalGroupID = makeTemporaryRepoRoot().standardized.path
        model.tabs[0].repoGroupID = originalGroupID
        model.tabs[0].session?.currentDirectory = originalGroupID
        model.selectTab(id: model.tabs[0].id)

        model.newTab()

        let newTab = try XCTUnwrap(model.tabs.first(where: { $0.id == model.selectedTabID }))
        XCTAssertEqual(newTab.repoGroupID, originalGroupID)
        XCTAssertTrue(newTab.hasInheritedRepoGroup)

        newTab.session?.gitRootPath = "/tmp/chau7-group-b"
        drainMainQueue()

        let movedTab = try XCTUnwrap(model.tabs.first(where: { $0.id == newTab.id }))
        XCTAssertNil(movedTab.repoGroupID)
        XCTAssertFalse(movedTab.hasInheritedRepoGroup)
    }

    func testExplicitRepoGroupPersistsWhenTabMovesToDifferentRepoInManualMode() {
        let originalMode = FeatureSettings.shared.repoGroupingMode
        FeatureSettings.shared.repoGroupingMode = .manual
        defer { FeatureSettings.shared.repoGroupingMode = originalMode }

        // addTabToRepoGroup reads the session's gitRootPath. Setting it then
        // draining lets the async refreshGitStatus (which resolves the real
        // git status of the cwd) clobber a synthetic /tmp path back to nil, so
        // capture the explicit group immediately, before any drain.
        let originalGroupID = "/tmp/chau7-group-a"
        model.tabs[0].session?.gitRootPath = originalGroupID
        model.addTabToRepoGroup(tabID: model.tabs[0].id)
        XCTAssertEqual(model.tabs[0].repoGroupID, originalGroupID)
        XCTAssertFalse(model.tabs[0].hasInheritedRepoGroup)

        // Moving to a different repo must NOT detach an explicit (user-set)
        // group — only inherited groups detach in manual mode.
        model.tabs[0].session?.gitRootPath = "/tmp/chau7-group-b"
        drainMainQueue()

        XCTAssertEqual(model.tabs[0].repoGroupID, originalGroupID)
        XCTAssertFalse(model.tabs[0].hasInheritedRepoGroup)
    }

    func testAutoGroupingFallsBackToKnownRecentRepoWhenGitRootIsUnavailable() {
        let originalMode = FeatureSettings.shared.repoGroupingMode
        FeatureSettings.shared.repoGroupingMode = .auto
        defer { FeatureSettings.shared.repoGroupingMode = originalMode }

        // The known-recent-repo fallback now sources its candidate roots from
        // KnownRepoIdentityStore (not FeatureSettings.recentRepoRoots), so seed
        // the store and restore it afterwards.
        let previousIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer { KnownRepoIdentityStore.shared.restore(previousIdentities) }

        let repoRoot = "/tmp/Downloads/Repositories/Chau7"
        KnownRepoIdentityStore.shared.reset()
        KnownRepoIdentityStore.shared.record(rootPath: repoRoot)
        model.tabs[0].session?.currentDirectory = "\(repoRoot)/apps/chau7-macos"
        model.tabs[0].session?.gitRootPath = nil

        model.applyAutoGroupingToAllTabs()

        XCTAssertEqual(model.tabs[0].repoGroupID, URL(fileURLWithPath: repoRoot).standardized.path)
    }

    func testReconcileStaleRepoGroupsMigratesVanishedPathToLiveRoot() {
        // Repro of the "two Mockup groups" report: both tabs were tagged with
        // the OLD path before the folder move; their live session root already
        // resolves to the NEW path. The vanished old tag must migrate onto it.
        let oldRoot = "/Users/me/Downloads/Repositories/Mockup"
        let newRoot = "/Users/me/Repositories/Mockup"
        model.newTab()
        model.tabs[0].repoGroupID = oldRoot
        model.tabs[1].repoGroupID = oldRoot
        model.tabs[0].session?.gitRootPath = newRoot
        model.tabs[1].session?.gitRootPath = newRoot

        // Only the new root exists on disk after the move.
        model.reconcileStaleRepoGroups(directoryExists: { $0 == newRoot })

        XCTAssertEqual(model.tabs[0].repoGroupID, newRoot)
        XCTAssertEqual(model.tabs[1].repoGroupID, newRoot)
        XCTAssertEqual(Set(model.tabs.compactMap(\.repoGroupID)), [newRoot], "Both tabs should collapse into one group")
    }

    func testReconcileStaleRepoGroupsLeavesDistinctSameNamedReposUnmerged() {
        // Two different repos that merely share a basename ("Mockup") and both
        // still exist on disk must never be merged.
        let rootA = "/Users/me/work/alpha/Mockup"
        let rootB = "/Users/me/work/beta/Mockup"
        model.newTab()
        model.tabs[0].repoGroupID = rootA
        model.tabs[1].repoGroupID = rootB
        model.tabs[0].session?.gitRootPath = rootA
        model.tabs[1].session?.gitRootPath = rootB

        // Both paths exist — nothing is stale.
        model.reconcileStaleRepoGroups(directoryExists: { _ in true })

        XCTAssertEqual(model.tabs[0].repoGroupID, rootA)
        XCTAssertEqual(model.tabs[1].repoGroupID, rootB)
    }

    func testReconcileStaleRepoGroupsLeavesTagWhenLiveRootAlsoMissing() {
        // If the live git root is unavailable (or also gone), there is no safe
        // target — keep the existing tag rather than dropping the grouping.
        let oldRoot = "/Users/me/Downloads/Repositories/Mockup"
        model.newTab()
        model.tabs[0].repoGroupID = oldRoot
        model.tabs[0].session?.gitRootPath = nil

        model.reconcileStaleRepoGroups(directoryExists: { _ in false })

        XCTAssertEqual(model.tabs[0].repoGroupID, oldRoot)
    }

    func testInheritedRepoGroupDetachesForNewTabAtDirectoryWhenTabMovesToDifferentRepoInManualMode() throws {
        let originalMode = FeatureSettings.shared.repoGroupingMode
        FeatureSettings.shared.repoGroupingMode = .manual
        defer { FeatureSettings.shared.repoGroupingMode = originalMode }

        // The new tab inherits the group only when its explicit directory is
        // inside the group root, so open it at a real subdirectory of the
        // group root.
        let originalGroupRoot = makeTemporaryRepoRoot(subpath: "worktree")
        let originalGroupID = originalGroupRoot.standardized.path
        let childDir = originalGroupRoot.appendingPathComponent("worktree", isDirectory: true).standardized.path
        model.tabs[0].repoGroupID = originalGroupID
        model.tabs[0].session?.currentDirectory = originalGroupID
        model.selectTab(id: model.tabs[0].id)

        model.newTab(at: childDir)

        let newTab = try XCTUnwrap(model.tabs.first(where: { $0.id == model.selectedTabID }))
        XCTAssertEqual(newTab.repoGroupID, originalGroupID)
        XCTAssertTrue(newTab.hasInheritedRepoGroup)

        newTab.session?.gitRootPath = "/tmp/chau7-group-b"
        drainMainQueue()

        let movedTab = try XCTUnwrap(model.tabs.first(where: { $0.id == newTab.id }))
        XCTAssertNil(movedTab.repoGroupID)
        XCTAssertFalse(movedTab.hasInheritedRepoGroup)
    }

    // MARK: - Notification Styling

    func testApplyNotificationStyleAppliesToSelectedTab() {
        let selectedTab = model.tabs[0]

        let resolved = model.applyNotificationStyle(
            to: selectedTab.id,
            stylePreset: "attention",
            config: [:]
        )

        XCTAssertTrue(resolved)
        XCTAssertEqual(model.tabs[0].notificationStyle, .attention)
    }

    func testSetNotificationStyleForSessionFindsSecondarySplitSession() {
        let targetTabID = model.tabs[0].id
        model.splitCurrentTabHorizontally()
        let terminalSessions = model.tabs[0].splitController.terminalSessions
        XCTAssertEqual(terminalSessions.count, 2)
        let secondarySession = terminalSessions[1].1

        model.newTab()
        XCTAssertNotEqual(model.selectedTabID, targetTabID, "Target tab must be backgrounded for styling")

        model.setNotificationStyle(.attention, forSession: secondarySession)

        guard let tab = model.tabs.first(where: { $0.id == targetTabID }) else {
            XCTFail("Target tab missing after split")
            return
        }
        XCTAssertEqual(tab.notificationStyle, .attention)
    }

    func testSplitCreatedTerminalInheritsOwnerTabAndPermissionCallback() {
        let tabID = model.tabs[0].id

        model.splitCurrentTabHorizontally()

        let terminalSessions = model.tabs[0].splitController.terminalSessions
        XCTAssertEqual(terminalSessions.count, 2)
        let secondarySession = terminalSessions[1].1
        XCTAssertEqual(secondarySession.ownerTabID, tabID)
        XCTAssertNotNil(secondarySession.onPermissionResolved)
    }

    func testSetNotificationStyleUpdatesTabState() {
        let targetTabID = model.tabs[0].id
        model.newTab()
        XCTAssertNotEqual(model.selectedTabID, targetTabID, "Target tab must be backgrounded for styling")

        _ = model.setNotificationStyle(.waiting, for: targetTabID)

        guard let tab = model.tabs.first(where: { $0.id == targetTabID }) else {
            XCTFail("Target tab missing after style update")
            return
        }
        XCTAssertEqual(tab.notificationStyle, .waiting)
    }

    func testSelectingTabClearsNonPersistentNotificationStyle() {
        let targetTabID = model.tabs[0].id
        model.newTab()
        XCTAssertNotEqual(model.selectedTabID, targetTabID, "Target tab must be backgrounded for selection clear")

        _ = model.setNotificationStyle(.waiting, for: targetTabID)
        model.selectTab(id: targetTabID)

        XCTAssertNil(model.tabs[0].notificationStyle)
    }

    func testSelectingTabPreservesPersistentNotificationStyle() {
        let targetTabID = model.tabs[0].id
        model.newTab()
        XCTAssertNotEqual(model.selectedTabID, targetTabID, "Target tab must be backgrounded for selection clear")

        var style = TabNotificationStyle.attention
        style.persistent = true
        _ = model.setNotificationStyle(style, for: targetTabID)
        model.selectTab(id: targetTabID)

        XCTAssertEqual(model.tabs[0].notificationStyle, style)
    }

    // MARK: - Render Suspension

    /// Render-lifecycle policy change (TabRenderLifecyclePolicy.phase): a
    /// non-selected tab is held `.warm` (never `.hidden`/suspended) regardless
    /// of whether it hosts an AI session — the old "keep background AI tabs
    /// live, suspend the rest" gate was removed. Suspension of background tabs
    /// is now driven solely by memory pressure, which demotes *every*
    /// non-selected tab to `.hidden`.
    func testRenderSuspensionSuspendsBackgroundTabsOnlyUnderMemoryPressure() {
        let selectedTab = model.tabs[0]
        model.newTab()
        model.newTab()

        let aiTab = model.tabs[1]
        let shellTab = model.tabs[2]
        aiTab.session?.activeAppName = "Codex"

        model.selectTab(id: selectedTab.id)

        // Without memory pressure, both background tabs stay live (.warm).
        MemoryPressureResponder.shared.memoryPressureOverrideForTesting = false
        model.configureRenderSuspension(enabled: true, delay: 0)
        drainMainQueue()

        XCTAssertFalse(
            model.suspendedTabIDs.contains(aiTab.id),
            "Background AI tabs stay live without memory pressure"
        )
        XCTAssertFalse(
            model.suspendedTabIDs.contains(shellTab.id),
            "Background shell tabs stay live without memory pressure"
        )

        // Under memory pressure, all non-selected tabs demote to .hidden and
        // suspend — AI status no longer exempts a tab.
        MemoryPressureResponder.shared.memoryPressureOverrideForTesting = true
        model.invalidateRenderLifecycle(reason: "test_memory_pressure")
        drainMainQueue()

        XCTAssertTrue(
            model.suspendedTabIDs.contains(aiTab.id),
            "Background AI tabs suspend under memory pressure"
        )
        XCTAssertTrue(
            model.suspendedTabIDs.contains(shellTab.id),
            "Background shell tabs suspend under memory pressure"
        )
    }

    /// Lifting memory pressure re-activates a previously suspended background
    /// tab on the next lifecycle re-evaluation (the realistic unsuspend trigger
    /// now that AI detection no longer drives suspension).
    func testRenderSuspensionReactivatesBackgroundTabWhenMemoryPressureClears() {
        let selectedTab = model.tabs[0]
        model.newTab()

        let backgroundTab = model.tabs[1]
        model.selectTab(id: selectedTab.id)

        MemoryPressureResponder.shared.memoryPressureOverrideForTesting = true
        model.configureRenderSuspension(enabled: true, delay: 0)
        drainMainQueue()

        XCTAssertTrue(
            model.suspendedTabIDs.contains(backgroundTab.id),
            "Background tabs suspend while under memory pressure"
        )

        MemoryPressureResponder.shared.memoryPressureOverrideForTesting = false
        model.invalidateRenderLifecycle(reason: "test_memory_pressure_cleared")
        drainMainQueue()

        XCTAssertFalse(
            model.suspendedTabIDs.contains(backgroundTab.id),
            "Clearing memory pressure should reactivate the background tab"
        )
    }

    func testDeferredRestoreDefersConsumptionUntilExplicitStep() {
        let tabIDs = (0 ..< 3).map { _ in UUID() }
        let states = (0 ..< 3).map { index in
            SavedTabState(
                tabID: tabIDs[index].uuidString,
                selectedTabID: index == 0 ? tabIDs[0].uuidString : nil,
                customTitle: "Restored \(index)",
                color: TabColor.allCases[index % TabColor.allCases.count].rawValue,
                directory: "/tmp/startup-restored-\(index)",
                selectedIndex: index == 0 ? 0 : nil,
                tokenOptOverride: nil,
                scrollbackContent: "echo restored \(index)",
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            )
        }

        let restoredModel = OverlayTabsModel(appModel: AppModel(), restoreState: false, restoringStates: states)

        XCTAssertEqual(restoredModel.deferredRestoreTabOrder.count, 2)

        restoredModel.beginDeferredRestoreIfNeeded(reason: "test")

        XCTAssertTrue(restoredModel.hasStartedDeferredRestore)
        XCTAssertEqual(restoredModel.deferredRestoreTabOrder.count, 2)
        XCTAssertEqual(restoredModel.deferredRestoreStatesByTabID.count, 2)
    }

    func testDeferredRestoreConsumesOneBackgroundTabPerStep() {
        let tabIDs = (0 ..< 3).map { _ in UUID() }
        let states = (0 ..< 3).map { index in
            SavedTabState(
                tabID: tabIDs[index].uuidString,
                selectedTabID: index == 0 ? tabIDs[0].uuidString : nil,
                customTitle: "Restored \(index)",
                color: TabColor.allCases[index % TabColor.allCases.count].rawValue,
                directory: "/tmp/startup-restored-\(index)",
                selectedIndex: index == 0 ? 0 : nil,
                tokenOptOverride: nil,
                scrollbackContent: "echo restored \(index)",
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            )
        }

        let restoredModel = OverlayTabsModel(appModel: AppModel(), restoreState: false, restoringStates: states)

        XCTAssertTrue(restoredModel.restoreOneDeferredTabIfNeeded(reason: "test"))
        XCTAssertEqual(restoredModel.deferredRestoreTabOrder.count, 1)
        XCTAssertEqual(restoredModel.deferredRestoreStatesByTabID.count, 2)

        XCTAssertTrue(restoredModel.restoreOneDeferredTabIfNeeded(reason: "test"))
        XCTAssertEqual(restoredModel.deferredRestoreTabOrder.count, 0)
        XCTAssertEqual(restoredModel.deferredRestoreStatesByTabID.count, 2)

        XCTAssertFalse(restoredModel.restoreOneDeferredTabIfNeeded(reason: "test"))
    }

    func testRestoreDoesNotQueueShellReplayByDefault() {
        guard let tab = model.tabs.first,
              let session = tab.session else {
            XCTFail("Expected initial tab session")
            return
        }

        let state = SavedTabState(
            customTitle: "Restored",
            color: TabColor.blue.rawValue,
            directory: "/tmp/chau7-stable-restore",
            selectedIndex: 0,
            tokenOptOverride: nil,
            scrollbackContent: "echo restored output",
            aiResumeCommand: nil,
            splitLayout: nil,
            focusedPaneID: nil,
            paneStates: nil
        )

        model.restoreTabState(for: tab, state: state, scheduledDelayOverride: 0)
        drainMainQueue()
        drainMainQueue()

        XCTAssertNil(session.pendingSystemRestoreInputLine)
    }

    // MARK: - Tab Close (closeTab)

    func testCloseTabRemovesTab() {
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 3)

        let tabToClose = model.tabs[1]
        model.closeTab(id: tabToClose.id)

        XCTAssertEqual(
            model.tabs.count,
            2,
            "Closing a tab should reduce the count by one"
        )
        XCTAssertNil(
            model.tabs.first(where: { $0.id == tabToClose.id }),
            "Closed tab should no longer be in the array"
        )
    }

    func testCloseSelectedTabSelectsNeighbor() {
        model.newTab()
        model.newTab()
        // Select the middle tab
        let middleTab = model.tabs[1]
        model.selectTab(id: middleTab.id)

        model.closeTab(id: middleTab.id)

        // After closing the middle tab, the tab to its left should be selected
        XCTAssertEqual(
            model.selectedTabID,
            model.tabs[0].id,
            "Closing the selected tab should select the tab to its left"
        )
    }

    func testCloseNonSelectedTabKeepsSelection() {
        model.newTab()
        model.newTab()
        let firstTab = model.tabs[0]
        let lastTab = model.tabs[2]
        model.selectTab(id: firstTab.id)

        model.closeTab(id: lastTab.id)

        XCTAssertEqual(
            model.selectedTabID,
            firstTab.id,
            "Closing a non-selected tab should not change the selection"
        )
    }

    // MARK: - Close Last Tab Behavior

    func testCloseLastTabReplacesWithNewTab() {
        // Ensure the behavior is set to keep the window open
        FeatureSettings.shared.lastTabCloseBehavior = .keepWindow
        // Disable warnings so the modal dialog doesn't block
        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        XCTAssertEqual(model.tabs.count, 1)
        let originalID = model.tabs[0].id

        model.closeCurrentTab()

        XCTAssertEqual(
            model.tabs.count,
            1,
            "Closing the last tab with keepWindow should create a replacement"
        )
        XCTAssertNotEqual(
            model.tabs[0].id,
            originalID,
            "The replacement tab should have a different ID"
        )
        XCTAssertEqual(
            model.selectedTabID,
            model.tabs[0].id,
            "The replacement tab should be selected"
        )
    }

    // MARK: - Close Other Tabs

    func testCloseOtherTabsKeepsOnlySelected() {
        model.newTab()
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 4)

        let keepID = model.tabs[1].id
        model.selectTab(id: keepID)

        // Disable warnings so the modal dialog doesn't block
        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        model.closeOtherTabs()

        XCTAssertEqual(model.tabs.count, 1, "Only the selected tab should remain")
        XCTAssertEqual(model.tabs[0].id, keepID)
    }

    // MARK: - Tab Reorder

    func testMoveTabToIndex() {
        model.newTab()
        model.newTab()
        // tabs: [A, B, C]
        let tabA = model.tabs[0]
        let tabC = model.tabs[2]

        model.moveTab(id: tabA.id, toIndex: 2)
        // After moving A to position 2: [B, A, C] (adjusted to index 1 since remove shifts)
        // Actually: remove at 0, clampedIndex=2, adjusted=2-1=1 -> insert at 1: [B, A, C]
        XCTAssertEqual(
            model.tabs[1].id,
            tabA.id,
            "Tab A should move from index 0 to index 1 (adjusted)"
        )
        XCTAssertEqual(model.tabs[2].id, tabC.id)
    }

    func testMoveTabClampsIndex() {
        model.newTab()
        let firstTab = model.tabs[0]
        // Try to move to an index beyond bounds
        model.moveTab(id: firstTab.id, toIndex: 999)
        // Should clamp and not crash
        XCTAssertEqual(
            model.tabs.last?.id,
            firstTab.id,
            "Moving to a very large index should clamp to end"
        )
    }

    func testMoveTabSameIndexIsNoop() {
        model.newTab()
        model.newTab()
        let originalOrder = model.tabs.map(\.id)
        let middleTab = model.tabs[1]

        model.moveTab(id: middleTab.id, toIndex: 1)

        XCTAssertEqual(
            model.tabs.map(\.id),
            originalOrder,
            "Moving a tab to its current index should be a no-op"
        )
    }

    func testMoveTabFromIndexRight() {
        model.newTab()
        model.newTab()
        let tabA = model.tabs[0]
        let tabB = model.tabs[1]

        model.moveTab(fromIndex: 0, toIndex: 1)

        XCTAssertEqual(model.tabs[0].id, tabB.id)
        XCTAssertEqual(
            model.tabs[1].id,
            tabA.id,
            "Moving index 0 to 1 should swap adjacent tabs"
        )
    }

    func testMoveTabFromIndexLeft() {
        model.newTab()
        model.newTab()
        let tabB = model.tabs[1]
        let tabC = model.tabs[2]

        model.moveTab(fromIndex: 2, toIndex: 1)

        XCTAssertEqual(model.tabs[1].id, tabC.id)
        XCTAssertEqual(
            model.tabs[2].id,
            tabB.id,
            "Moving index 2 to 1 should swap adjacent tabs"
        )
    }

    func testMoveTabFromIndexSameIsNoop() {
        model.newTab()
        let originalOrder = model.tabs.map(\.id)

        model.moveTab(fromIndex: 0, toIndex: 0)
        XCTAssertEqual(
            model.tabs.map(\.id),
            originalOrder,
            "Moving to same index should be a no-op"
        )
    }

    func testMoveTabFromIndexOutOfBoundsIsNoop() {
        model.newTab()
        let originalOrder = model.tabs.map(\.id)

        model.moveTab(fromIndex: -1, toIndex: 0)
        XCTAssertEqual(
            model.tabs.map(\.id),
            originalOrder,
            "Negative source index should be a no-op"
        )

        model.moveTab(fromIndex: 0, toIndex: model.tabs.count)
        XCTAssertEqual(
            model.tabs.map(\.id),
            originalOrder,
            "Destination beyond bounds should be a no-op"
        )
    }

    func testExtractTabForWindowTransferAllowsLastTab() {
        let onlyTab = model.tabs[0]

        let extracted = model.extractTabForWindowTransfer(id: onlyTab.id)

        XCTAssertEqual(extracted?.id, onlyTab.id)
        XCTAssertTrue(model.tabs.isEmpty, "Moving the last tab out should leave the source window empty")
    }

    func testFocusSelectedRecreatesFreshTabAfterLastTabTransfer() {
        let onlyTab = model.tabs[0]
        _ = model.extractTabForWindowTransfer(id: onlyTab.id)
        // Bind the window to a local — `model.overlayWindow` is weak, so an
        // inline `NSWindow(...)` deallocates before focusSelected() runs and
        // the compiler treats the assignment as `weak ... = nil`.
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        model.overlayWindow = window

        model.focusSelected()

        XCTAssertEqual(model.tabs.count, 1, "Showing an emptied window should lazily recreate a fresh tab")
        XCTAssertEqual(model.selectedTabID, model.tabs[0].id)
    }

    func testExtractGroupForWindowTransferAllowsMovingEntireWindowContents() {
        model.newTab()
        let repoGroupID = "/tmp/chau7-group"
        model.tabs[0].repoGroupID = repoGroupID
        model.tabs[1].repoGroupID = repoGroupID

        let extracted = model.extractGroupForWindowTransfer(repoGroupID: repoGroupID)

        XCTAssertEqual(extracted.count, 2)
        XCTAssertTrue(model.tabs.isEmpty, "Moving the only repo group out should leave the source window empty")
    }

    func testMoveCurrentTabRight() {
        model.newTab()
        model.newTab()
        let tabA = model.tabs[0]
        model.selectTab(id: tabA.id)

        model.moveCurrentTabRight()

        XCTAssertEqual(
            model.tabs[1].id,
            tabA.id,
            "moveCurrentTabRight should move the selected tab one position right"
        )
    }

    func testMoveCurrentTabLeft() {
        model.newTab()
        model.newTab()
        let tabC = model.tabs[2]
        model.selectTab(id: tabC.id)

        model.moveCurrentTabLeft()

        XCTAssertEqual(
            model.tabs[1].id,
            tabC.id,
            "moveCurrentTabLeft should move the selected tab one position left"
        )
    }

    // MARK: - Active Tab Management

    func testSelectTabByID() {
        model.newTab()
        model.newTab()
        let targetTab = model.tabs[1]

        model.selectTab(id: targetTab.id)

        XCTAssertEqual(
            model.selectedTabID,
            targetTab.id,
            "selectTab should update selectedTabID"
        )
    }

    func testSelectTabByNumber() {
        model.newTab()
        model.newTab()
        let secondTab = model.tabs[1]

        // selectTab(number:) is 1-indexed
        model.selectTab(number: 2)

        XCTAssertEqual(
            model.selectedTabID,
            secondTab.id,
            "selectTab(number: 2) should select the second tab"
        )
    }

    func testSelectTabByNumberOutOfRange() {
        let originalSelected = model.selectedTabID
        model.selectTab(number: 999)
        XCTAssertEqual(
            model.selectedTabID,
            originalSelected,
            "Selecting an out-of-range tab number should be a no-op"
        )
    }

    func testSelectNextTabWrapsAround() {
        model.newTab()
        // tabs: [A, B], select B (last)
        let tabB = model.tabs[1]
        model.selectTab(id: tabB.id)

        model.selectNextTab()

        XCTAssertEqual(
            model.selectedTabID,
            model.tabs[0].id,
            "selectNextTab from the last tab should wrap to the first"
        )
    }

    func testSelectPreviousTabWrapsAround() {
        model.newTab()
        // tabs: [A, B], select A (first)
        let tabA = model.tabs[0]
        model.selectTab(id: tabA.id)

        model.selectPreviousTab()

        XCTAssertEqual(
            model.selectedTabID,
            model.tabs[1].id,
            "selectPreviousTab from the first tab should wrap to the last"
        )
    }

    func testSelectNextTabWithSingleTabIsNoop() {
        let originalSelected = model.selectedTabID
        model.selectNextTab()
        XCTAssertEqual(
            model.selectedTabID,
            originalSelected,
            "selectNextTab with one tab should be a no-op"
        )
    }

    func testSelectedTabProperty() {
        XCTAssertNotNil(model.selectedTab, "selectedTab should return the current tab")
        XCTAssertEqual(model.selectedTab?.id, model.selectedTabID)
    }

    // MARK: - Search / Filter State

    func testToggleSearchVisibility() {
        XCTAssertFalse(model.isSearchVisible)

        model.toggleSearch()
        XCTAssertTrue(model.isSearchVisible, "First toggle should show search")

        model.toggleSearch()
        XCTAssertFalse(model.isSearchVisible, "Second toggle should hide search")
    }

    func testToggleSearchClearsQueryOnClose() {
        model.toggleSearch() // Open
        model.searchQuery = "test"
        model.toggleSearch() // Close

        XCTAssertEqual(
            model.searchQuery,
            "",
            "Closing search should clear the search query"
        )
        XCTAssertEqual(
            model.searchResults.count,
            0,
            "Closing search should clear the results"
        )
        XCTAssertEqual(
            model.searchMatchCount,
            0,
            "Closing search should reset match count"
        )
    }

    func testToggleSearchClosesRename() {
        model.isRenameVisible = true
        model.toggleSearch() // Open search

        XCTAssertTrue(model.isSearchVisible)
        XCTAssertFalse(
            model.isRenameVisible,
            "Opening search should close the rename overlay"
        )
    }

    // MARK: - Reopen Closed Tab

    func testCanReopenClosedTabInitiallyFalse() {
        XCTAssertFalse(
            model.canReopenClosedTab,
            "No tabs have been closed yet, so canReopenClosedTab should be false"
        )
    }

    func testClosingTabPopulatesClosedTabStack() {
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 3)

        // Disable warnings
        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        model.closeTab(id: model.tabs[1].id)

        XCTAssertTrue(
            model.canReopenClosedTab,
            "After closing a tab, canReopenClosedTab should be true"
        )
    }

    // MARK: - captureClosedTabSnapshot

    /// Regression guard for the deferred-state fast path. When a tab is closed
    /// before its deferred restore state has been replayed, captureClosedTabSnapshot
    /// must pull the full saved state out of deferredRestoreStatesByTabID (not the
    /// eager-seeded live session) so Cmd+Shift+T restores the AI identity + scrollback,
    /// and it must drain both the dict and the ordering queue.
    func testCaptureClosedTabSnapshotConsumesDeferredStateAndRestoresAIIdentity() throws {
        let deferredTabID = UUID()
        let deferredPaneID = UUID()
        let selectedTabID = UUID()
        let selectedPaneID = UUID()
        let selectedState = makeSavedTabState(
            tabID: selectedTabID,
            paneID: selectedPaneID,
            title: "Selected",
            directory: "/tmp/selected",
            aiProvider: "codex",
            aiSessionId: "selected-session",
            aiResumeCommand: "codex resume selected-session"
        )
        let deferredState = makeSavedTabState(
            tabID: deferredTabID,
            paneID: deferredPaneID,
            title: "Deferred",
            directory: "/tmp/deferred",
            aiProvider: "codex",
            aiSessionId: "deferred-session",
            aiResumeCommand: "codex resume deferred-session"
        )
        let restored = OverlayTabsModel(
            appModel: AppModel(),
            restoreState: false,
            restoringStates: [selectedState, deferredState]
        )
        let deferredTab = try XCTUnwrap(restored.tabs.first(where: { $0.id == deferredTabID }))
        let deferredIndex = try XCTUnwrap(restored.tabs.firstIndex(where: { $0.id == deferredTabID }))
        XCTAssertTrue(
            restored.deferredRestoreStatesByTabID[deferredTabID] != nil,
            "Precondition: deferred state is queued"
        )

        restored.captureClosedTabSnapshot(tab: deferredTab, at: deferredIndex)

        XCTAssertNil(
            restored.deferredRestoreStatesByTabID[deferredTabID],
            "Deferred state dict must be drained after capture"
        )
        XCTAssertFalse(
            restored.deferredRestoreTabOrder.contains(deferredTabID),
            "Deferred order queue must not contain the closed tab"
        )

        let entry = try XCTUnwrap(restored.closedTabStack.last)
        XCTAssertEqual(entry.originalIndex, deferredIndex)
        XCTAssertEqual(entry.state.customTitle, "Deferred")
        // makeSavedTabState mirrors the AI identity into both the top-level
        // state and the single pane. sanitizeRestoredAIResumeOwnership
        // sanitizes the pane first, which claims (codex, deferred-session);
        // the duplicate top-level copy is then deduped to nil. The pane is
        // the authoritative carrier of the restored identity.
        let pane = try XCTUnwrap(entry.state.paneStates?.first)
        XCTAssertEqual(pane.aiProvider, "codex")
        XCTAssertEqual(pane.aiSessionId, "deferred-session")
        XCTAssertEqual(pane.aiResumeCommand, "codex resume deferred-session")
        XCTAssertNil(entry.state.aiSessionId, "Duplicate top-level identity is deduped to the claiming pane")
    }

    /// Regression guard for the live-session branch. With no deferred state queued,
    /// capture must build a ClosedTabEntry from the live tab's session + splitController
    /// and leave the deferred maps empty.
    func testCaptureClosedTabSnapshotLiveBranchPopulatesClosedStack() throws {
        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        model.newTab()
        XCTAssertEqual(model.tabs.count, 2)
        let tab = model.tabs[1]
        XCTAssertNil(model.deferredRestoreStatesByTabID[tab.id])

        model.captureClosedTabSnapshot(tab: tab, at: 1)

        XCTAssertTrue(model.deferredRestoreStatesByTabID.isEmpty)
        XCTAssertTrue(model.deferredRestoreTabOrder.isEmpty)
        let entry = try XCTUnwrap(model.closedTabStack.last)
        XCTAssertEqual(entry.originalIndex, 1)
    }

    /// T2 — Live-session branch must capture the tab's live session state in
    /// the resulting `SavedTabState`. Specifically: the tab's directory and
    /// the per-pane state (paneStates) must be populated. We can't easily
    /// inject scrollback into the Rust terminal under SPM, but verifying the
    /// other live-session fields confirms the buildPaneStates helper (Pass F)
    /// is wired into the live branch correctly. Pre-existing gap flagged in
    /// the Pass F reviewer report.
    func testCaptureClosedTabSnapshotLiveBranchPreservesPaneAndDirectory() throws {
        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        // newTab(at:) only adopts a directory that exists on disk (the
        // session's updateCurrentDirectory validates it), so use a real temp
        // directory rather than a synthetic /tmp path that would fall back to
        // $HOME.
        let directory = makeTemporaryRepoRoot().standardized.path
        model.newTab(at: directory)
        XCTAssertEqual(model.tabs.count, 2)
        let tab = model.tabs[1]
        // Sanity: a fresh live tab should have at least one terminal session
        // attached via splitController (the live-session branch only kicks in
        // when there's something to capture).
        XCTAssertFalse(tab.splitController.terminalSessions.isEmpty)

        model.captureClosedTabSnapshot(tab: tab, at: 1)

        let entry = try XCTUnwrap(model.closedTabStack.last)
        XCTAssertEqual(entry.originalIndex, 1)
        XCTAssertEqual(
            entry.state.directory,
            directory,
            "Live-branch capture must preserve the tab's working directory"
        )
        // paneStates is the per-pane snapshot — exists even when scrollback
        // is empty/nil because the entry is constructed from
        // splitController.terminalSessions.
        let paneStates = try XCTUnwrap(
            entry.state.paneStates,
            "Live-branch capture must populate paneStates from splitController"
        )
        XCTAssertEqual(paneStates.count, tab.splitController.terminalSessions.count)
        XCTAssertEqual(paneStates.first?.directory, directory)
    }

    // MARK: - validateResumeRestoreIntent

    /// Directory mismatch must reject the intent — previously `isEmpty ||` let an
    /// unknown expected directory match anything, silently delivering resume commands
    /// to the wrong pane.
    func testValidateResumeRestoreIntentRejectsDirectoryMismatch() {
        let session = TerminalSessionModel(appModel: appModel)
        session.currentDirectory = "/actual/dir"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        session.lastAISessionId = "abc-123"
        session.lastAISessionIdentitySource = .explicit

        let intent = OverlayTabsModel.ResumeRestoreIntent(
            paneID: UUID(),
            command: "codex resume abc-123",
            expectedDirectory: "/expected/elsewhere",
            expectedProvider: "codex",
            expectedSessionID: "abc-123",
            expectedSessionIDSource: .explicit,
            isFocusedPane: true
        )
        XCTAssertFalse(model.validateResumeRestoreIntent(intent, against: session, tabID: UUID()))
    }

    /// Provider mismatch must reject (e.g. saved as claude, live session is codex).
    func testValidateResumeRestoreIntentRejectsProviderMismatch() {
        let session = TerminalSessionModel(appModel: appModel)
        session.currentDirectory = "/shared/dir"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        session.lastAISessionId = "abc-123"
        session.lastAISessionIdentitySource = .explicit

        let intent = OverlayTabsModel.ResumeRestoreIntent(
            paneID: UUID(),
            command: "claude --resume abc-123",
            expectedDirectory: "/shared/dir",
            expectedProvider: "claude",
            expectedSessionID: "abc-123",
            expectedSessionIDSource: .explicit,
            isFocusedPane: true
        )
        XCTAssertFalse(model.validateResumeRestoreIntent(intent, against: session, tabID: UUID()))
    }

    /// Session-ID mismatch must reject even when directory + provider agree —
    /// the live pane has been reassigned to a different session.
    func testValidateResumeRestoreIntentRejectsSessionIDMismatch() {
        let session = TerminalSessionModel(appModel: appModel)
        session.currentDirectory = "/shared/dir"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        session.lastAISessionId = "live-xyz"
        session.lastAISessionIdentitySource = .explicit

        let intent = OverlayTabsModel.ResumeRestoreIntent(
            paneID: UUID(),
            command: "codex resume saved-abc",
            expectedDirectory: "/shared/dir",
            expectedProvider: "codex",
            expectedSessionID: "saved-abc",
            expectedSessionIDSource: .explicit,
            isFocusedPane: true
        )
        XCTAssertFalse(model.validateResumeRestoreIntent(intent, against: session, tabID: UUID()))
    }

    /// All three dimensions match → accept.
    func testValidateResumeRestoreIntentAcceptsFullMatch() {
        let session = TerminalSessionModel(appModel: appModel)
        session.currentDirectory = "/shared/dir"
        session.lastDetectedAppName = "Codex"
        session.lastAIProvider = "codex"
        session.lastAISessionId = "abc-123"
        session.lastAISessionIdentitySource = .explicit

        let intent = OverlayTabsModel.ResumeRestoreIntent(
            paneID: UUID(),
            command: "codex resume abc-123",
            expectedDirectory: "/shared/dir",
            expectedProvider: "codex",
            expectedSessionID: "abc-123",
            expectedSessionIDSource: .explicit,
            isFocusedPane: true
        )
        XCTAssertTrue(model.validateResumeRestoreIntent(intent, against: session, tabID: UUID()))
    }

    // MARK: - Broadcast Mode

    func testBroadcastModeToggle() {
        XCTAssertFalse(model.isBroadcastMode)
        model.isBroadcastMode = true
        XCTAssertTrue(model.isBroadcastMode)
    }

    // MARK: - Has Active Overlay

    func testHasActiveOverlay() {
        XCTAssertFalse(
            model.hasActiveOverlay,
            "No overlay should be active initially"
        )

        model.isSearchVisible = true
        XCTAssertTrue(model.hasActiveOverlay)
        model.isSearchVisible = false

        model.isRenameVisible = true
        XCTAssertTrue(model.hasActiveOverlay)
        model.isRenameVisible = false

        model.isClipboardHistoryVisible = true
        XCTAssertTrue(model.hasActiveOverlay)
        model.isClipboardHistoryVisible = false

        model.isBookmarkListVisible = true
        XCTAssertTrue(model.hasActiveOverlay)
        model.isBookmarkListVisible = false

        model.isSnippetManagerVisible = true
        XCTAssertTrue(model.hasActiveOverlay)
    }

    // MARK: - Advanced Restore Metadata

    func testRestoreFromSavedStatePreservesTabOrderAndSelectionIndex() {
        let terminalID = UUID()
        let editorID = UUID()
        let split = SavedSplitNode(
            kind: .split,
            id: UUID().uuidString,
            direction: .horizontal,
            ratio: 0.5,
            first: SavedSplitNode(
                kind: .terminal,
                id: terminalID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil
            ),
            second: SavedSplitNode(
                kind: .textEditor,
                id: editorID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: "/tmp/example.swift"
            ),
            textEditorPath: nil
        )

        // The session only adopts an on-disk directory; use a real temp dir
        // so the restored terminal pane's currentDirectory matches.
        let advancedRestoreDir = makeTemporaryRepoRoot().standardized.path
        let primaryPaneState = SavedTerminalPaneState(
            paneID: terminalID.uuidString,
            directory: advancedRestoreDir,
            scrollbackContent: "previous output",
            aiResumeCommand: "claude --resume abc123"
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Left",
                color: TabColor.green.rawValue,
                directory: "/tmp/fallback-1",
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            ),
            SavedTabState(
                customTitle: "Right",
                color: TabColor.purple.rawValue,
                directory: advancedRestoreDir,
                selectedIndex: 1,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: terminalID.uuidString,
                paneStates: [primaryPaneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)

        XCTAssertEqual(restoredModel.tabs.count, 2)
        XCTAssertEqual(restoredModel.tabs[0].customTitle, "Left")
        XCTAssertEqual(restoredModel.tabs[1].customTitle, "Right")
        XCTAssertEqual(restoredModel.selectedTabID, restoredModel.tabs[1].id)

        let rightTab = restoredModel.tabs[1]
        guard let terminalPair = rightTab.splitController.terminalSessions.first(where: { $0.0 == terminalID }) else {
            XCTFail("Expected restored terminal pane ID \(terminalID)")
            return
        }
        XCTAssertEqual(terminalPair.1.currentDirectory, advancedRestoreDir)
        XCTAssertEqual(rightTab.splitController.focusedTerminalSessionID(), terminalID)
    }

    func testRestoreUsesPersistedSelectedTabID() {
        let firstTabID = UUID()
        let secondTabID = UUID()

        storeSavedTabStates([
            SavedTabState(
                tabID: firstTabID.uuidString,
                selectedTabID: nil,
                customTitle: "First",
                color: TabColor.green.rawValue,
                directory: "/tmp/restore-1",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            ),
            SavedTabState(
                tabID: secondTabID.uuidString,
                selectedTabID: secondTabID.uuidString,
                customTitle: "Second",
                color: TabColor.blue.rawValue,
                directory: "/tmp/restore-2",
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)

        XCTAssertEqual(restoredModel.tabs.count, 2, "restore should rebuild all saved tabs")
        XCTAssertEqual(restoredModel.tabs[0].id, firstTabID)
        XCTAssertEqual(restoredModel.tabs[1].id, secondTabID)
        XCTAssertEqual(restoredModel.selectedTabID, secondTabID, "explicit selected tab marker should override legacy selectedIndex")
    }

    func testResolveResumeMetadataDropsClaimedExplicitSessionIDButKeepsProvider() {
        guard let session = model.tabs[0].session else {
            XCTFail("Expected initial session")
            return
        }

        let claimedSessionID = "019d25d0-d0bd-7501-99ba-1f937c17b29b"
        session.restoreAIMetadata(provider: "claude", sessionId: claimedSessionID)

        let resolved = model.resolveResumeMetadata(
            for: session,
            directory: "/tmp/claimed-claude-session",
            outputHint: nil,
            claimedSessionIds: [claimedSessionID]
        )

        let persisted = model.persistedAIResumeMetadata(
            from: session,
            resolvedResumeMetadata: resolved,
            claimedSessions: [
                AIResumeOwnership.ClaimedSession(provider: "claude", sessionId: claimedSessionID)
            ]
        )

        XCTAssertNil(resolved)
        XCTAssertEqual(persisted.provider, "claude")
        XCTAssertNil(persisted.sessionId)
        XCTAssertEqual(session.effectiveAIProvider, "claude")
        XCTAssertNil(session.effectiveAISessionId)
    }

    func testResolveResumeMetadataCacheInvalidatesWhenExplicitCodexSessionChanges() {
        guard let session = model.tabs[0].session else {
            XCTFail("Expected initial session")
            return
        }

        session.restoreAIMetadata(provider: "codex", sessionId: "codex-explicit-1")
        let firstResolved = model.resolveResumeMetadata(
            for: session,
            directory: "/tmp/cached-codex-session",
            outputHint: nil,
            claimedSessionIds: ["codex-explicit-1"]
        )

        session.restoreAIMetadata(provider: "codex", sessionId: "codex-explicit-2")
        let secondResolved = model.resolveResumeMetadata(
            for: session,
            directory: "/tmp/cached-codex-session",
            outputHint: nil,
            claimedSessionIds: ["codex-explicit-2"]
        )

        XCTAssertEqual(firstResolved?.sessionId, "codex-explicit-1")
        XCTAssertEqual(secondResolved?.sessionId, "codex-explicit-2")
        XCTAssertEqual(session.effectiveAIProvider, "codex")
        XCTAssertEqual(session.effectiveAISessionId, "codex-explicit-2")
    }

    func testSanitizeRestoredAIResumeOwnershipDropsDuplicateSessionIDs() {
        let duplicateSessionID = "019d25d0-d0bd-7501-99ba-1f937c17b29b"
        let states = [
            SavedTabState(
                tabID: UUID().uuidString,
                selectedTabID: nil,
                customTitle: "First",
                color: TabColor.blue.rawValue,
                directory: "/tmp/a",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: "codex resume \(duplicateSessionID)",
                aiProvider: "codex",
                aiSessionId: duplicateSessionID,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil,
                createdAt: nil,
                repoGroupID: nil
            ),
            SavedTabState(
                tabID: UUID().uuidString,
                selectedTabID: nil,
                customTitle: "Second",
                color: TabColor.green.rawValue,
                directory: "/tmp/b",
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: "claude --resume \(duplicateSessionID)",
                aiProvider: "claude",
                aiSessionId: duplicateSessionID,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil,
                createdAt: nil,
                repoGroupID: nil
            )
        ]

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(states: states)

        XCTAssertEqual(sanitized[0].aiProvider, "codex")
        XCTAssertEqual(sanitized[0].aiSessionId, duplicateSessionID)
        XCTAssertEqual(sanitized[0].aiResumeCommand, "codex resume \(duplicateSessionID)")
        XCTAssertNil(sanitized[1].aiProvider)
        XCTAssertNil(sanitized[1].aiSessionId)
        XCTAssertNil(sanitized[1].aiResumeCommand)
    }

    func testSanitizeRestoredAIResumeOwnershipPreservesLegacyCommandOnlyPaneMetadata() {
        let legacySessionID = "legacy-pane-001"
        let states = [
            SavedTabState(
                tabID: UUID().uuidString,
                selectedTabID: nil,
                customTitle: "Legacy Pane",
                color: TabColor.blue.rawValue,
                directory: "/tmp/legacy-pane",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                aiProvider: nil,
                aiSessionId: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: [
                    SavedTerminalPaneState(
                        paneID: UUID().uuidString,
                        directory: "/tmp/legacy-pane",
                        scrollbackContent: nil,
                        aiResumeCommand: "codex resume \(legacySessionID)",
                        aiProvider: nil,
                        aiSessionId: nil
                    )
                ],
                createdAt: nil,
                repoGroupID: nil
            )
        ]

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(states: states)
        XCTAssertEqual(sanitized.first?.paneStates?.first?.aiProvider, "codex")
        XCTAssertEqual(sanitized.first?.paneStates?.first?.aiSessionId, legacySessionID)
        XCTAssertEqual(sanitized.first?.paneStates?.first?.aiResumeCommand, "codex resume \(legacySessionID)")
    }

    func testSanitizeRestoredAIResumeOwnershipPreservesLegacyTopLevelFallbackMetadata() {
        let legacySessionID = "legacy-top-level-001"
        let paneID = UUID().uuidString
        let states = [
            SavedTabState(
                tabID: UUID().uuidString,
                selectedTabID: nil,
                customTitle: "Legacy Top Level",
                color: TabColor.green.rawValue,
                directory: "/tmp/legacy-top-level",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: "codex resume \(legacySessionID)",
                aiProvider: nil,
                aiSessionId: nil,
                splitLayout: nil,
                focusedPaneID: paneID,
                paneStates: [
                    SavedTerminalPaneState(
                        paneID: paneID,
                        directory: "/tmp/legacy-top-level",
                        scrollbackContent: nil,
                        aiResumeCommand: nil,
                        aiProvider: nil,
                        aiSessionId: nil
                    )
                ],
                createdAt: nil,
                repoGroupID: nil
            )
        ]

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(states: states)
        XCTAssertEqual(sanitized.first?.aiProvider, "codex")
        XCTAssertEqual(sanitized.first?.aiSessionId, legacySessionID)
        XCTAssertEqual(sanitized.first?.aiResumeCommand, "codex resume \(legacySessionID)")
    }

    func testSanitizeRestoredAIResumeOwnershipUsesAgentLaunchResumeCommandWhenResumeCommandMissing() {
        let sessionID = "019e0bd8-1367-7e53-97a5-3977e8d37c8a"
        let paneID = UUID().uuidString
        let states = [
            SavedTabState(
                tabID: UUID().uuidString,
                selectedTabID: nil,
                customTitle: "Debug",
                color: TabColor.blue.rawValue,
                directory: "/tmp/debug",
                selectedIndex: 0,
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
                        directory: "/tmp/debug",
                        scrollbackContent: nil,
                        aiResumeCommand: nil,
                        aiProvider: nil,
                        aiSessionId: nil,
                        agentLaunchCommand: "codex resume \(sessionID)"
                    )
                ],
                createdAt: nil,
                repoGroupID: nil
            )
        ]

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(states: states)
        let pane = sanitized.first?.paneStates?.first

        XCTAssertEqual(pane?.aiProvider, "codex")
        XCTAssertEqual(pane?.aiSessionId, sessionID)
        XCTAssertEqual(pane?.aiSessionIdSource, .explicit)
        XCTAssertEqual(pane?.aiResumeCommand, "codex resume \(sessionID)")
    }

    func testSanitizeRestoredAIResumeOwnershipDropsClaudeUUIDWithoutTranscript() throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "019e0bd8-1367-7e53-97a5-3977e8d37c8a"
        let paneID = UUID().uuidString
        let state = SavedTabState(
            tabID: UUID().uuidString,
            selectedTabID: nil,
            customTitle: "Legacy Cleaning",
            color: TabColor.blue.rawValue,
            directory: "/tmp/mockup",
            selectedIndex: 0,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: "claude --resume \(sessionID)",
            aiProvider: "claude",
            aiSessionId: sessionID,
            aiSessionIdSource: .explicit,
            splitLayout: nil,
            focusedPaneID: paneID,
            paneStates: [
                SavedTerminalPaneState(
                    paneID: paneID,
                    directory: "/tmp/mockup",
                    scrollbackContent: nil,
                    aiResumeCommand: "claude --resume \(sessionID)",
                    aiProvider: "claude",
                    aiSessionId: sessionID,
                    aiSessionIdSource: .explicit
                )
            ]
        )

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(
            states: [state],
            environment: ["CHAU7_HOME_ROOT": home.path]
        )

        XCTAssertNil(sanitized.first?.aiProvider)
        XCTAssertNil(sanitized.first?.aiSessionId)
        XCTAssertNil(sanitized.first?.aiResumeCommand)
        XCTAssertNil(sanitized.first?.aiSessionIdSource)
        XCTAssertNil(sanitized.first?.paneStates?.first?.aiProvider)
        XCTAssertNil(sanitized.first?.paneStates?.first?.aiSessionId)
        XCTAssertNil(sanitized.first?.paneStates?.first?.aiResumeCommand)
        XCTAssertNil(sanitized.first?.paneStates?.first?.aiSessionIdSource)
    }

    func testSanitizeRestoredAIResumeOwnershipKeepsClaudeUUIDWithTranscript() throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = "/tmp/mockup"
        let sessionID = "2de5f491-618a-4b57-a4d0-66e4586674c9"
        try createClaudeTranscript(home: home, directory: directory, sessionID: sessionID)
        let paneID = UUID().uuidString
        let state = SavedTabState(
            tabID: UUID().uuidString,
            selectedTabID: nil,
            customTitle: "Claude",
            color: TabColor.blue.rawValue,
            directory: directory,
            selectedIndex: 0,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: "claude --resume \(sessionID)",
            aiProvider: "claude",
            aiSessionId: sessionID,
            aiSessionIdSource: .explicit,
            splitLayout: nil,
            focusedPaneID: paneID,
            paneStates: [
                SavedTerminalPaneState(
                    paneID: paneID,
                    directory: directory,
                    scrollbackContent: nil,
                    aiResumeCommand: "claude --resume \(sessionID)",
                    aiProvider: "claude",
                    aiSessionId: sessionID,
                    aiSessionIdSource: .explicit
                )
            ]
        )

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(
            states: [state],
            environment: ["CHAU7_HOME_ROOT": home.path]
        )

        // The pane is sanitized before the top-level fallback and claims the
        // (claude, sessionID) pair, so the verified transcript identity is
        // retained on the pane. The duplicate top-level copy is deduped to
        // nil to avoid a double resume of the same session — the pane is the
        // authoritative carrier.
        XCTAssertEqual(sanitized.first?.paneStates?.first?.aiProvider, "claude")
        XCTAssertEqual(sanitized.first?.paneStates?.first?.aiSessionId, sessionID)
        XCTAssertEqual(sanitized.first?.paneStates?.first?.aiResumeCommand, "claude --resume \(sessionID)")
        XCTAssertNil(sanitized.first?.aiSessionId, "Duplicate top-level identity is deduped to the claiming pane")
    }

    func testBuildAIResumeCommandRejectsSyntheticSessionIdentity() {
        let command = OverlayTabsModel.buildAIResumeCommand(
            provider: "claude",
            sessionId: "synth:claude:abc123",
            sessionIdSource: .synthetic
        )

        XCTAssertNil(command)
    }

    func testResolveAIResumeMetadataFromSavedStatePreservesSyntheticSessionIdentity() {
        let paneState = SavedTerminalPaneState(
            paneID: UUID().uuidString,
            directory: "/tmp/synthetic-pane",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: "claude",
            aiSessionId: "synth:claude:abc123",
            aiSessionIdSource: .synthetic
        )

        let resolved = OverlayTabsModel.resolveAIResumeMetadataFromSavedState(
            paneState: paneState,
            fallbackAIProvider: nil,
            fallbackAISessionId: nil
        )

        XCTAssertEqual(resolved?.provider, "claude")
        XCTAssertEqual(resolved?.sessionId, "synth:claude:abc123")
        XCTAssertEqual(resolved?.sessionIdSource, .synthetic)
    }

    func testResolveAIResumeMetadataFromSavedStateDropsClaudeUUIDWithoutTranscript() throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "019e0bd8-1367-7e53-97a5-3977e8d37c8a"
        let paneState = SavedTerminalPaneState(
            paneID: UUID().uuidString,
            directory: "/tmp/mockup",
            scrollbackContent: nil,
            aiResumeCommand: "claude --resume \(sessionID)",
            aiProvider: "claude",
            aiSessionId: sessionID,
            aiSessionIdSource: .explicit
        )

        let resolved = OverlayTabsModel.resolveAIResumeMetadataFromSavedState(
            paneState: paneState,
            fallbackAIProvider: nil,
            fallbackAISessionId: nil,
            environment: ["CHAU7_HOME_ROOT": home.path]
        )

        XCTAssertNil(resolved)
    }

    func testSanitizeRestoredAIResumeOwnershipPreservesPaneMetadataFields() {
        let startedAt = Date(timeIntervalSince1970: 1234.0)
        let lastInputAt = Date(timeIntervalSince1970: 1235.0)
        let lastExitAt = Date(timeIntervalSince1970: 1236.0)
        let pane = SavedTerminalPaneState(
            paneID: UUID().uuidString,
            directory: "/tmp/persisted-pane",
            scrollbackContent: nil,
            aiResumeCommand: "codex resume persisted-001",
            aiProvider: "codex",
            aiSessionId: "persisted-001",
            aiSessionIdSource: .observed,
            lastOutputAt: startedAt,
            lastInputAt: lastInputAt,
            knownRepoRoot: "/tmp",
            knownGitBranch: "main",
            lastStatus: .done,
            agentLaunchCommand: "codex resume persisted-001",
            agentStartedAt: startedAt,
            lastExitCode: 0,
            lastExitAt: lastExitAt
        )

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(states: [
            SavedTabState(
                tabID: UUID().uuidString,
                selectedTabID: nil,
                customTitle: "Persisted Pane",
                color: TabColor.blue.rawValue,
                directory: "/tmp/persisted-pane",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: pane.paneID,
                paneStates: [pane]
            )
        ])

        guard let sanitizedPane = sanitized.first?.paneStates?.first else {
            XCTFail("Expected sanitized pane state")
            return
        }

        // A parseable resume/agent-launch command is the highest-priority
        // restore candidate and is treated as explicit ownership, so the
        // sanitized source is `.explicit` even though the pane persisted
        // `.observed` — the command supersedes the bare field source.
        XCTAssertEqual(sanitizedPane.aiSessionIdSource, .explicit)
        XCTAssertEqual(sanitizedPane.lastInputAt, lastInputAt)
        XCTAssertEqual(sanitizedPane.lastStatus, .done)
        XCTAssertEqual(sanitizedPane.agentLaunchCommand, "codex resume persisted-001")
        XCTAssertEqual(sanitizedPane.agentStartedAt, startedAt)
        XCTAssertEqual(sanitizedPane.lastExitCode, 0)
        XCTAssertEqual(sanitizedPane.lastExitAt, lastExitAt)
    }

    func testResolveResumeMetadataIgnoresTelemetryOnlyCodexProvider() {
        guard let session = model.tabs[0].session else {
            XCTFail("Expected initial session")
            return
        }

        TelemetryRecorder.shared.runStarted(
            tabID: session.tabIdentifier,
            provider: "codex",
            cwd: "/tmp/aetower"
        )
        defer {
            TelemetryRecorder.shared.runEnded(tabID: session.tabIdentifier, exitStatus: 0)
        }

        XCTAssertEqual(session.effectiveAIProvider, "codex")
        XCTAssertNil(session.lastAIProvider)
        XCTAssertNil(session.lastAISessionId)

        let resolved = model.resolveResumeMetadata(
            for: session,
            directory: "/tmp/aetower",
            outputHint: nil
        )

        XCTAssertNil(resolved)
        XCTAssertNil(session.lastAIProvider)
        XCTAssertNil(session.lastAISessionId)
    }

    func testRestoreFallsBackToLegacySelectedIndexWhenTabIDIsMissing() {
        storeSavedTabStates([
            SavedTabState(
                customTitle: "First",
                color: TabColor.green.rawValue,
                directory: "/tmp/fallback-1",
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            ),
            SavedTabState(
                customTitle: "Second",
                color: TabColor.blue.rawValue,
                directory: "/tmp/fallback-2",
                selectedIndex: 1,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        let selectedIndex = restoredModel.tabs.firstIndex(where: { $0.id == restoredModel.selectedTabID })
        XCTAssertEqual(selectedIndex, 1, "legacy selectedIndex should be honored when tab IDs are missing")
        XCTAssertEqual(restoredModel.tabs[1].customTitle, "Second")
    }

    func testReopenClosedTabReturnsToOriginalIndex() {
        model.newTab()
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 4)

        let originalIDs = model.tabs.map(\.id)
        let middleID = originalIDs[1]

        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        model.closeTab(id: middleID)
        XCTAssertEqual(model.tabs.map(\.id), [originalIDs[0], originalIDs[2], originalIDs[3]])

        model.reopenClosedTab()
        XCTAssertEqual(model.tabs.map(\.id), [originalIDs[0], middleID, originalIDs[2], originalIDs[3]])
    }

    func testReopenClosedTabPreservesIdentityMetadata() {
        let originalRepoGroupingMode = FeatureSettings.shared.repoGroupingMode
        let originalWarnOnCloseWithRunningProcess = FeatureSettings.shared.warnOnCloseWithRunningProcess
        let originalAlwaysWarnOnTabClose = FeatureSettings.shared.alwaysWarnOnTabClose
        FeatureSettings.shared.repoGroupingMode = .off
        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false
        defer {
            FeatureSettings.shared.repoGroupingMode = originalRepoGroupingMode
            FeatureSettings.shared.warnOnCloseWithRunningProcess = originalWarnOnCloseWithRunningProcess
            FeatureSettings.shared.alwaysWarnOnTabClose = originalAlwaysWarnOnTabClose
        }

        model.newTab()
        guard model.tabs.count >= 2 else {
            XCTFail("expected a second tab")
            return
        }

        let originalTab = model.tabs[1]
        let originalID = originalTab.id
        let originalCreatedAt = originalTab.createdAt
        let originalRepoGroupID = "/tmp/repo"

        model.tabs[1].customTitle = "Closed Tab"
        model.tabs[1].repoGroupID = originalRepoGroupID

        model.closeTab(id: originalID)
        model.reopenClosedTab()

        guard let reopenedTab = model.tabs.first(where: { $0.id == originalID }) else {
            XCTFail("expected reopened tab with original identity")
            return
        }

        XCTAssertEqual(reopenedTab.id, originalID)
        // createdAt round-trips through an ISO8601 string (second precision),
        // so compare at second granularity rather than exact sub-second.
        XCTAssertEqual(
            reopenedTab.createdAt.timeIntervalSince1970,
            originalCreatedAt.timeIntervalSince1970,
            accuracy: 1.0
        )
        XCTAssertEqual(reopenedTab.repoGroupID, originalRepoGroupID)
        XCTAssertEqual(reopenedTab.customTitle, "Closed Tab")
    }

    func testRestorePrefillsResumeCommandAfterTerminalBecomesReady() {
        let paneID = UUID()
        let split = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let resumeCommand = "codex resume abc123"

        // The resume-prefill delivery gate now requires the saved directory to
        // match the restored session's cwd (empty-expected no longer matches
        // any directory), and the session only adopts a directory that exists
        // on disk — so use a real temp directory for both.
        let directory = makeTemporaryRepoRoot().standardized.path
        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: directory,
            scrollbackContent: nil,
            aiResumeCommand: resumeCommand
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "AI Session",
                color: TabColor.purple.rawValue,
                directory: directory,
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: paneID.uuidString,
                paneStates: [paneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let session = restoredModel.tabs.first?.splitController.terminalSessions
            .first(where: { $0.0 == paneID })?.1 else {
            XCTFail("Expected restored session for pane \(paneID)")
            return
        }

        session.isShellLoading = true
        session.isAtPrompt = false
        session.status = .running

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { text in
            capturedInputs.append(text)
        }
        session.attachRustTerminal(terminalView)

        let notReadyExpectation = expectation(description: "resume command not sent before terminal becomes ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            XCTAssertTrue(capturedInputs.isEmpty)
            session.isShellLoading = false
            session.isAtPrompt = true
            session.status = .idle
            notReadyExpectation.fulfill()
        }
        wait(for: [notReadyExpectation], timeout: 2.0)

        let readyExpectation = expectation(description: "resume command sent after terminal is ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            XCTAssertEqual(capturedInputs, [resumeCommand])
            readyExpectation.fulfill()
        }
        wait(for: [readyExpectation], timeout: 2.0)
    }

    func testRestorePrefillsUsingPersistedAiMetadata() {
        let paneID = UUID()
        let split = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )

        // The prefill delivery gate requires the saved directory to match the
        // restored session's cwd, which only adopts an on-disk directory.
        let directory = makeTemporaryRepoRoot().standardized.path
        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: directory,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: "codex",
            aiSessionId: "meta-restore-001"
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Meta Restore",
                color: TabColor.orange.rawValue,
                directory: directory,
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: paneID.uuidString,
                paneStates: [paneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let session = restoredModel.tabs.first?.splitController.terminalSessions
            .first(where: { $0.0 == paneID })?.1 else {
            XCTFail("Expected restored session for pane \(paneID)")
            return
        }

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { capturedInputs.append($0) }
        session.attachRustTerminal(terminalView)
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let readyExpectation = expectation(description: "restore from persisted AI metadata")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            XCTAssertEqual(capturedInputs, ["codex resume meta-restore-001"])
            readyExpectation.fulfill()
        }
        wait(for: [readyExpectation], timeout: 2.0)
    }

    func testExportTabStatesPersistsKnownRepoIdentity() {
        let repoRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads/Repositories/Chau7")
            .path
        let session = model.tabs[0].session!
        session.currentDirectory = repoRoot + "/apps/chau7-macos"
        session.isGitRepo = true
        session.gitRootPath = repoRoot
        session.gitBranch = "main"

        let states = model.exportTabStates()
        let paneState = try? XCTUnwrap(states.first?.paneStates?.first)
        XCTAssertEqual(paneState?.knownRepoRoot, repoRoot)
        XCTAssertEqual(paneState?.knownGitBranch, "main")
        XCTAssertEqual(states.first?.knownRepoRoot, repoRoot)
        XCTAssertEqual(states.first?.knownGitBranch, "main")
    }

    func testRestoreProtectedRepoUsesPersistedKnownRepoIdentity() {
        let settings = FeatureSettings.shared
        let previousAllowProtectedFolderAccess = settings.allowProtectedFolderAccess
        let previousRecentRepoRoots = settings.recentRepoRoots
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer {
            settings.allowProtectedFolderAccess = previousAllowProtectedFolderAccess
            settings.recentRepoRoots = previousRecentRepoRoots
            KnownRepoIdentityStore.shared.restore(previousKnownIdentities)
            ProtectedPathPolicy.resetAccessChecks()
            RepositoryCache.shared.resetNegativeCache()
        }

        let repoRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads/Repositories/Chau7")
            .path
        let paneID = UUID()
        let split = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: repoRoot + "/apps/chau7-macos",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            knownRepoRoot: repoRoot,
            knownGitBranch: "feature/protected"
        )

        settings.allowProtectedFolderAccess = false
        settings.recentRepoRoots = []
        KnownRepoIdentityStore.shared.reset()
        ProtectedPathPolicy.resetAccessChecks()
        RepositoryCache.shared.resetNegativeCache()

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Protected Repo",
                color: TabColor.blue.rawValue,
                directory: repoRoot + "/apps/chau7-macos",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: paneID.uuidString,
                paneStates: [paneState],
                knownRepoRoot: repoRoot,
                knownGitBranch: "feature/protected"
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        drainMainQueue()
        drainMainQueue()

        guard let session = restoredModel.tabs.first?.splitController.terminalSessions
            .first(where: { $0.0 == paneID })?.1 else {
            XCTFail("Expected restored session for pane \(paneID)")
            return
        }

        XCTAssertTrue(session.isGitRepo)
        XCTAssertEqual(session.gitRootPath, repoRoot)
        XCTAssertEqual(session.gitBranch, "feature/protected")
        XCTAssertFalse(session.repositoryAccessSnapshot.canProbeLive)
        XCTAssertTrue(session.repositoryAccessSnapshot.canUseKnownIdentity)
    }

    func testRestorePrefillsLegacyTopLevelMetadataForSinglePaneStates() {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let firstSplit = SavedSplitNode(
            kind: .terminal,
            id: firstPaneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let secondSplit = SavedSplitNode(
            kind: .terminal,
            id: secondPaneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        // Shared on-disk directory so the prefill delivery directory gate
        // passes for each restored pane.
        let sharedDir = makeTemporaryRepoRoot().standardized.path
        let firstPaneState = SavedTerminalPaneState(
            paneID: firstPaneID.uuidString,
            directory: sharedDir,
            scrollbackContent: nil,
            aiResumeCommand: nil
        )
        let secondPaneState = SavedTerminalPaneState(
            paneID: secondPaneID.uuidString,
            directory: sharedDir,
            scrollbackContent: nil,
            aiResumeCommand: nil
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "First",
                color: TabColor.purple.rawValue,
                directory: sharedDir,
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                aiProvider: "codex",
                aiSessionId: "legacy-111",
                splitLayout: firstSplit,
                focusedPaneID: firstPaneID.uuidString,
                paneStates: [firstPaneState]
            ),
            SavedTabState(
                customTitle: "Second",
                color: TabColor.orange.rawValue,
                directory: sharedDir,
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                aiProvider: "codex",
                aiSessionId: "legacy-222",
                splitLayout: secondSplit,
                focusedPaneID: secondPaneID.uuidString,
                paneStates: [secondPaneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let firstSession = restoredModel.tabs.first(where: { $0.customTitle == "First" })?
            .splitController.terminalSessions.first(where: { $0.0 == firstPaneID })?.1,
            let secondSession = restoredModel.tabs.first(where: { $0.customTitle == "Second" })?
            .splitController.terminalSessions.first(where: { $0.0 == secondPaneID })?.1 else {
            XCTFail("Expected restored sessions for both tabs")
            return
        }

        let firstView = RustTerminalView(frame: .zero)
        let secondView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        firstView.onInput = { capturedInputs.append($0) }
        secondView.onInput = { capturedInputs.append($0) }
        firstSession.attachRustTerminal(firstView)
        secondSession.attachRustTerminal(secondView)
        firstSession.isShellLoading = false
        firstSession.isAtPrompt = true
        firstSession.status = .idle
        secondSession.isShellLoading = false
        secondSession.isAtPrompt = true
        secondSession.status = .idle

        // The second tab is deferred (background-identity-only restore does
        // not prefill); selecting it promotes it to the interactive restore
        // path that delivers its resume command.
        if let secondTabID = restoredModel.tabs.first(where: { $0.customTitle == "Second" })?.id {
            restoredModel.selectTab(id: secondTabID)
        }

        let expectationDone = expectation(description: "restore from legacy top-level metadata")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            let expected: Set = [
                "codex resume legacy-111",
                "codex resume legacy-222"
            ]
            XCTAssertEqual(Set(capturedInputs), expected)
            XCTAssertEqual(capturedInputs.count, 2)
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 2.0)
    }

    func testRestoreLegacyTopLevelMetadataRestoresLifecycleFields() {
        let paneID = UUID()
        let split = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let startedAt = Date(timeIntervalSince1970: 4000.0)
        let lastInputAt = Date(timeIntervalSince1970: 4005.0)
        let lastExitAt = Date(timeIntervalSince1970: 4010.0)
        let directory = makeTemporaryRepoRoot().standardized.path

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Legacy Lifecycle",
                color: TabColor.purple.rawValue,
                directory: directory,
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                aiProvider: "codex",
                aiSessionId: "legacy-lifecycle-001",
                aiSessionIdSource: .explicit,
                splitLayout: split,
                focusedPaneID: paneID.uuidString,
                paneStates: [
                    SavedTerminalPaneState(
                        paneID: paneID.uuidString,
                        directory: directory,
                        scrollbackContent: nil,
                        aiResumeCommand: nil,
                        lastOutputAt: startedAt
                    )
                ],
                lastInputAt: lastInputAt,
                lastStatus: .done,
                agentLaunchCommand: "codex --model gpt-5.3-codex",
                agentStartedAt: startedAt,
                lastExitCode: 0,
                lastExitAt: lastExitAt
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let session = restoredModel.tabs.first?.splitController.terminalSessions
            .first(where: { $0.0 == paneID })?.1 else {
            XCTFail("Expected restored session for pane \(paneID)")
            return
        }

        // Per-pane AI/lifecycle metadata is applied in the async
        // executeRestoreBody phase, so wait until the restored agent start
        // timestamp lands (the full-restore call sets it to `startedAt`).
        waitForCondition { session.agentStartedAt == startedAt }

        XCTAssertEqual(session.lastAISessionIdentitySource, .explicit)
        XCTAssertEqual(session.lastInputDate, lastInputAt)
        XCTAssertEqual(session.lastOutputDate, startedAt)
        XCTAssertEqual(session.status, .done)
        XCTAssertEqual(session.lastAgentLaunchCommand, "codex --model gpt-5.3-codex")
        XCTAssertEqual(session.agentStartedAt, startedAt)
        XCTAssertEqual(session.lastExitCode, 0)
        XCTAssertEqual(session.lastExitAt, lastExitAt)
    }

    func testRestorePreservesSyntheticSessionIdentityWithoutResumeCommand() {
        let paneID = UUID()
        let split = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let syntheticID = "synth:claude:deadbeef"
        let directory = makeTemporaryRepoRoot().standardized.path

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Synthetic Session",
                color: TabColor.purple.rawValue,
                directory: directory,
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: paneID.uuidString,
                paneStates: [
                    SavedTerminalPaneState(
                        paneID: paneID.uuidString,
                        directory: directory,
                        scrollbackContent: nil,
                        aiResumeCommand: nil,
                        aiProvider: "claude",
                        aiSessionId: syntheticID,
                        aiSessionIdSource: .synthetic
                    )
                ]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let session = restoredModel.tabs.first?.splitController.terminalSessions
            .first(where: { $0.0 == paneID })?.1 else {
            XCTFail("Expected restored synthetic session")
            return
        }

        // Synthetic identity is applied in the async executeRestoreBody phase.
        waitForCondition { session.effectiveAISessionId != nil }

        XCTAssertEqual(session.effectiveAISessionId, syntheticID)
        XCTAssertEqual(session.effectiveAISessionIdentitySource, .synthetic)
    }

    func testRestorePrefillsDistinctCodexResumeCommandsPerTab() {
        // Both tabs restore into a shared on-disk directory so the prefill
        // delivery directory gate is satisfied for each pane.
        let sharedDir = makeTemporaryRepoRoot().standardized.path
        let firstPaneID = UUID()
        let secondPaneID = UUID()

        let firstSplit = SavedSplitNode(
            kind: .terminal,
            id: firstPaneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let secondSplit = SavedSplitNode(
            kind: .terminal,
            id: secondPaneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )

        let firstPaneState = SavedTerminalPaneState(
            paneID: firstPaneID.uuidString,
            directory: sharedDir,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: "codex",
            aiSessionId: "codex-session-111"
        )
        let secondPaneState = SavedTerminalPaneState(
            paneID: secondPaneID.uuidString,
            directory: sharedDir,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: "codex",
            aiSessionId: "codex-session-222"
        )

        storeSavedTabStates([
            SavedTabState(
                tabID: UUID().uuidString,
                customTitle: "First",
                color: TabColor.purple.rawValue,
                directory: sharedDir,
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: firstSplit,
                focusedPaneID: firstPaneID.uuidString,
                paneStates: [firstPaneState]
            ),
            SavedTabState(
                tabID: UUID().uuidString,
                customTitle: "Second",
                color: TabColor.blue.rawValue,
                directory: sharedDir,
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: secondSplit,
                focusedPaneID: secondPaneID.uuidString,
                paneStates: [secondPaneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let firstSession = restoredModel.tabs.first(where: { $0.customTitle == "First" })?
            .splitController.terminalSessions.first(where: { $0.0 == firstPaneID })?.1,
            let secondSession = restoredModel.tabs.first(where: { $0.customTitle == "Second" })?
            .splitController.terminalSessions.first(where: { $0.0 == secondPaneID })?.1 else {
            XCTFail("Expected restored sessions for both saved tabs")
            return
        }

        let firstView = RustTerminalView(frame: .zero)
        let secondView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        firstView.onInput = { capturedInputs.append($0) }
        secondView.onInput = { capturedInputs.append($0) }
        firstSession.attachRustTerminal(firstView)
        secondSession.attachRustTerminal(secondView)
        firstSession.isShellLoading = false
        firstSession.isAtPrompt = true
        firstSession.status = .idle
        secondSession.isShellLoading = false
        secondSession.isAtPrompt = true
        secondSession.status = .idle

        // Only the selected tab is restored synchronously and prefilled; the
        // second tab is queued for deferred restore (background-identity-only,
        // which does NOT schedule a resume prefill). Selecting it promotes it
        // to the interactive restore path that prefills its own command.
        if let secondTabID = restoredModel.tabs.first(where: { $0.customTitle == "Second" })?.id {
            restoredModel.selectTab(id: secondTabID)
        }

        let expectationDone = expectation(description: "restore restores each codex pane with distinct session id")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            let expected: Set = ["codex resume codex-session-111", "codex resume codex-session-222"]
            XCTAssertEqual(Set(capturedInputs), expected)
            XCTAssertEqual(capturedInputs.count, 2)
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 2.0)
    }

    func testRestorePrefillsResumeCommandInActiveOrAvailablePane() {
        let activePaneID = UUID()
        let secondaryPaneID = UUID()
        let split = SavedSplitNode(
            kind: .split,
            id: UUID().uuidString,
            direction: .horizontal,
            ratio: 0.5,
            first: SavedSplitNode(
                kind: .terminal,
                id: activePaneID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil
            ),
            second: SavedSplitNode(
                kind: .terminal,
                id: secondaryPaneID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil
            ),
            textEditorPath: nil
        )

        // Both panes must restore into on-disk directories so the prefill
        // delivery directory gate passes for the pane carrying the command.
        let primaryDir = makeTemporaryRepoRoot().standardized.path
        let secondaryDir = makeTemporaryRepoRoot().standardized.path
        let activePaneState = SavedTerminalPaneState(
            paneID: activePaneID.uuidString,
            directory: primaryDir,
            scrollbackContent: nil,
            aiResumeCommand: nil
        )
        let fallbackPaneState = SavedTerminalPaneState(
            paneID: secondaryPaneID.uuidString,
            directory: secondaryDir,
            scrollbackContent: nil,
            aiResumeCommand: "codex resume fallback-001"
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Split AI",
                color: TabColor.orange.rawValue,
                directory: secondaryDir,
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: activePaneID.uuidString,
                paneStates: [activePaneState, fallbackPaneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let tab = restoredModel.tabs.first else {
            XCTFail("Expected restored tab")
            return
        }

        guard let activeSession = tab.splitController.root.findSession(id: activePaneID),
              let secondarySession = tab.splitController.root.findSession(id: secondaryPaneID) else {
            XCTFail("Expected both restore sessions to exist")
            return
        }

        let activeView = RustTerminalView(frame: .zero)
        let secondaryView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        activeView.onInput = { capturedInputs.append("active:\($0)") }
        secondaryView.onInput = { capturedInputs.append("secondary:\($0)") }
        activeSession.attachRustTerminal(activeView)
        secondarySession.attachRustTerminal(secondaryView)

        activeSession.isShellLoading = false
        activeSession.isAtPrompt = true
        activeSession.status = .idle
        secondarySession.isShellLoading = false
        secondarySession.isAtPrompt = true
        secondarySession.status = .idle

        let expectationDone = expectation(description: "resume command routed to secondary pane fallback target")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            XCTAssertEqual(capturedInputs.count, 1)
            XCTAssertEqual(capturedInputs.first, "secondary:codex resume fallback-001")
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 2.0)
    }

    func testRestorePrefillsResumeCommandsPerPaneInSplitTab() {
        let focusedPaneID = UUID()
        let secondaryPaneID = UUID()
        let split = SavedSplitNode(
            kind: .split,
            id: UUID().uuidString,
            direction: .horizontal,
            ratio: 0.5,
            first: SavedSplitNode(
                kind: .terminal,
                id: focusedPaneID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil
            ),
            second: SavedSplitNode(
                kind: .terminal,
                id: secondaryPaneID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil
            ),
            textEditorPath: nil
        )

        // Each pane must restore into an on-disk directory so the prefill
        // delivery directory gate passes per pane.
        let focusedDir = makeTemporaryRepoRoot().standardized.path
        let secondaryDir = makeTemporaryRepoRoot().standardized.path
        let focusedPaneState = SavedTerminalPaneState(
            paneID: focusedPaneID.uuidString,
            directory: focusedDir,
            scrollbackContent: nil,
            aiResumeCommand: "codex resume focused-001"
        )
        let secondaryPaneState = SavedTerminalPaneState(
            paneID: secondaryPaneID.uuidString,
            directory: secondaryDir,
            scrollbackContent: nil,
            aiResumeCommand: "codex resume secondary-001"
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Split Pane Ownership",
                color: TabColor.orange.rawValue,
                directory: focusedDir,
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: focusedPaneID.uuidString,
                paneStates: [focusedPaneState, secondaryPaneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let tab = restoredModel.tabs.first else {
            XCTFail("Expected restored tab")
            return
        }

        guard let focusedSession = tab.splitController.root.findSession(id: focusedPaneID),
              let secondarySession = tab.splitController.root.findSession(id: secondaryPaneID) else {
            XCTFail("Expected restored split sessions")
            return
        }

        let focusedView = RustTerminalView(frame: .zero)
        let secondaryView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        focusedView.onInput = { capturedInputs.append("focused:\($0)") }
        secondaryView.onInput = { capturedInputs.append("secondary:\($0)") }
        focusedSession.attachRustTerminal(focusedView)
        secondarySession.attachRustTerminal(secondaryView)
        focusedSession.isShellLoading = false
        focusedSession.isAtPrompt = true
        focusedSession.status = .idle
        secondarySession.isShellLoading = false
        secondarySession.isAtPrompt = true
        secondarySession.status = .idle

        let expectationDone = expectation(description: "resume commands remain bound to owning panes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            let expected: Set = [
                "focused:codex resume focused-001",
                "secondary:codex resume secondary-001"
            ]
            XCTAssertEqual(Set(capturedInputs), expected)
            XCTAssertEqual(capturedInputs.count, 2)
            XCTAssertEqual(
                restoredModel.resumeRestoreDeliveryStateByPaneID[focusedPaneID]?.outcome,
                .delivered
            )
            XCTAssertEqual(
                restoredModel.resumeRestoreDeliveryStateByPaneID[secondaryPaneID]?.outcome,
                .delivered
            )
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 2.0)
    }

    func testRestoreRejectsResumePrefillWhenPaneOwnershipDrifts() {
        let paneID = UUID()
        let split = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: "/tmp/owned-pane",
            scrollbackContent: nil,
            aiResumeCommand: "codex resume owned-001"
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Ownership Drift",
                color: TabColor.pink.rawValue,
                directory: "/tmp/owned-pane",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: paneID.uuidString,
                paneStates: [paneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let session = restoredModel.tabs.first?.splitController.root.findSession(id: paneID) else {
            XCTFail("Expected restored pane")
            return
        }

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { capturedInputs.append($0) }
        session.attachRustTerminal(terminalView)
        session.updateCurrentDirectory("/tmp/drifted-pane")
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let expectationDone = expectation(description: "resume prefill skipped when ownership validation fails")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            XCTAssertTrue(capturedInputs.isEmpty)
            XCTAssertEqual(
                restoredModel.resumeRestoreDeliveryStateByPaneID[paneID]?.outcome,
                .rejected
            )
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 2.0)
    }

    func testRestoreIgnoresInvalidPersistedResumeCommand() {
        let paneID = UUID()
        let split = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: "/tmp/chau7-restore-invalid-command",
            scrollbackContent: nil,
            aiResumeCommand: "rm -rf /"
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Invalid Resume",
                color: TabColor.pink.rawValue,
                directory: "/tmp/chau7-restore-invalid-command",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: paneID.uuidString,
                paneStates: [paneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let session = restoredModel.tabs.first?.splitController.terminalSessions
            .first(where: { $0.0 == paneID })?.1 else {
            XCTFail("Expected restored session for pane \(paneID)")
            return
        }

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { text in
            capturedInputs.append(text)
        }
        session.attachRustTerminal(terminalView)
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let expectationDone = expectation(description: "invalid resume command is ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            XCTAssertTrue(capturedInputs.isEmpty)
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 2.5)
    }

    func testScheduleResumeCommandPreservesLatestDeliveredStateWhenOlderRetryBecomesStale() {
        guard let tab = model.tabs.first,
              let (paneID, session) = tab.splitController.terminalSessions.first else {
            XCTFail("Expected initial terminal pane")
            return
        }

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { text in
            capturedInputs.append(text)
        }
        session.attachRustTerminal(terminalView)
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let oldToken = "restore-old-token"
        let newToken = "restore-new-token"
        let oldIntent = OverlayTabsModel.ResumeRestoreIntent(
            paneID: paneID,
            command: "claude --resume old-001",
            expectedDirectory: session.currentDirectory,
            expectedProvider: nil,
            expectedSessionID: nil,
            expectedSessionIDSource: nil,
            isFocusedPane: true
        )
        let newIntent = OverlayTabsModel.ResumeRestoreIntent(
            paneID: paneID,
            command: "claude --resume new-001",
            expectedDirectory: session.currentDirectory,
            expectedProvider: nil,
            expectedSessionID: nil,
            expectedSessionIDSource: nil,
            isFocusedPane: true
        )

        model.latestRestoreResumeTokenByPaneID[paneID] = oldToken
        model.recordResumeRestoreDeliveryState(
            paneID: paneID,
            token: oldToken,
            outcome: .pending,
            tabID: tab.id,
            reason: "test_old_schedule"
        )
        model.scheduleResumeCommand(
            intent: oldIntent,
            targetTabID: tab.id,
            restoreToken: oldToken,
            remainingAttempts: 1,
            delay: 0.25
        )

        model.latestRestoreResumeTokenByPaneID[paneID] = newToken
        model.recordResumeRestoreDeliveryState(
            paneID: paneID,
            token: newToken,
            outcome: .pending,
            tabID: tab.id,
            reason: "test_new_schedule"
        )
        model.scheduleResumeCommand(
            intent: newIntent,
            targetTabID: tab.id,
            restoreToken: newToken,
            remainingAttempts: 1,
            delay: 0
        )

        let expectationDone = expectation(description: "stale retry does not overwrite newer delivered state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            XCTAssertEqual(capturedInputs, ["claude --resume new-001"])
            XCTAssertEqual(
                self.model.resumeRestoreDeliveryStateByPaneID[paneID],
                OverlayTabsModel.ResumeRestoreDeliveryState(
                    token: newToken,
                    outcome: .delivered
                )
            )
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 1.5)
    }

    func testRecordResumeRestoreDeliveryStatePreservesDeliveredOutcomeAgainstSameTokenSuperseded() {
        guard let tab = model.tabs.first,
              let (paneID, _) = tab.splitController.terminalSessions.first else {
            XCTFail("Expected initial terminal pane")
            return
        }

        let token = "restore-same-token"
        model.recordResumeRestoreDeliveryState(
            paneID: paneID,
            token: token,
            outcome: .delivered,
            tabID: tab.id,
            reason: "test_delivered"
        )

        model.recordResumeRestoreDeliveryState(
            paneID: paneID,
            token: token,
            outcome: .superseded,
            tabID: tab.id,
            reason: "test_stale_retry"
        )

        XCTAssertEqual(
            model.resumeRestoreDeliveryStateByPaneID[paneID],
            OverlayTabsModel.ResumeRestoreDeliveryState(
                token: token,
                outcome: .delivered
            )
        )
    }

    // MARK: - forceTabIdle ("Move to Idle Tabs" right-click action)

    /// Regression: previously the function silently returned when called on
    /// the currently selected tab. Right-clicking the focused tab and
    /// choosing "Move to Idle Tabs" looked broken — no log, no UX feedback,
    /// no state change. The action must instead switch selection to a
    /// neighbor and idle the original.
    func testForceTabIdleOnSelectedTabSwitchesToNeighborAndIdlesOriginal() {
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 3)

        let originalSelected = model.selectedTabID
        guard let targetIndex = model.tabs.firstIndex(where: { $0.id == originalSelected }) else {
            XCTFail("selected tab should exist in tabs array")
            return
        }

        model.forceTabIdle(id: originalSelected)

        XCTAssertNotEqual(
            model.selectedTabID,
            originalSelected,
            "Selection must move off the tab being idled"
        )
        XCTAssertTrue(
            model.suspendedTabIDs.contains(originalSelected),
            "Original tab must be in suspendedTabIDs (the observable signal that drives the idle dropdown)"
        )
        // Neighbor selection should land on the next index (or previous if at end).
        let expectedNeighborIndex = targetIndex + 1 < model.tabs.count ? targetIndex + 1 : targetIndex - 1
        XCTAssertEqual(
            model.selectedTabID,
            model.tabs[expectedNeighborIndex].id,
            "Selection should jump to the immediate neighbor"
        )
    }

    /// Non-selected tab: existing happy path. Confirms the inserts still work
    /// for the un-broken case so the selected-tab branch above doesn't
    /// accidentally rewrite the normal path.
    func testForceTabIdleOnUnselectedTabKeepsSelectionAndIdlesTarget() {
        model.newTab()
        model.newTab()
        let selected = model.selectedTabID
        guard let target = model.tabs.first(where: { $0.id != selected }) else {
            XCTFail("expected at least one non-selected tab")
            return
        }

        model.forceTabIdle(id: target.id)

        XCTAssertEqual(
            model.selectedTabID,
            selected,
            "Selection must NOT change when idling an unselected tab"
        )
        XCTAssertTrue(
            model.suspendedTabIDs.contains(target.id),
            "Target tab must be in suspendedTabIDs"
        )
    }

    /// Edge: when this is the only tab in the window, there's no neighbor to
    /// fall back to. Refusing with a warning (instead of silently failing)
    /// is intentional — never break the only-tab invariant.
    func testForceTabIdleOnOnlyTabIsRejected() {
        XCTAssertEqual(model.tabs.count, 1, "test assumes a single starter tab")
        let onlyTab = model.tabs[0].id

        model.forceTabIdle(id: onlyTab)

        XCTAssertEqual(model.selectedTabID, onlyTab, "Selection must not move (no neighbor)")
        XCTAssertFalse(
            model.suspendedTabIDs.contains(onlyTab),
            "Only tab must NOT be moved to idle — would leave the window with nothing visible"
        )
    }

    /// Unknown tab ID: just warn and bail, no side effects on selection or
    /// the idle set. Prevents a stale UI sending an action for a tab that's
    /// already gone from racing other state.
    func testForceTabIdleWithUnknownIDIsNoOp() {
        let before = model.selectedTabID
        let suspendedBefore = model.suspendedTabIDs

        model.forceTabIdle(id: UUID())

        XCTAssertEqual(model.selectedTabID, before)
        XCTAssertEqual(model.suspendedTabIDs, suspendedBefore)
    }
}

@MainActor
extension OverlayTabsModelTests {
    func testQueuedResumePrefillRevalidatesOwnershipAtActualDelivery() {
        guard let tab = model.tabs.first,
              let (paneID, session) = tab.splitController.terminalSessions.first else {
            XCTFail("Expected initial terminal pane")
            return
        }

        // updateCurrentDirectory only adopts an on-disk path, and the
        // ownership gate compares expected vs actual directory — use real
        // temp dirs for both the owned and drifted locations.
        let ownedDir = makeTemporaryRepoRoot().standardized.path
        let driftedDir = makeTemporaryRepoRoot().standardized.path
        session.updateCurrentDirectory(ownedDir)
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let token = "restore-queued-drift"
        let intent = OverlayTabsModel.ResumeRestoreIntent(
            paneID: paneID,
            command: "claude --resume drift-001",
            expectedDirectory: ownedDir,
            expectedProvider: nil,
            expectedSessionID: nil,
            expectedSessionIDSource: nil,
            isFocusedPane: true
        )

        model.latestRestoreResumeTokenByPaneID[paneID] = token
        let deliveredImmediately = model.enqueueResumePrefill(
            intent: intent,
            into: session,
            targetTabID: tab.id,
            restoreToken: token,
            queuedReason: "test_waiting_for_view",
            deliveredReason: "test_prefilled_after_waiting_for_view"
        )
        XCTAssertFalse(deliveredImmediately)
        XCTAssertEqual(
            model.resumeRestoreDeliveryStateByPaneID[paneID]?.outcome,
            .queued
        )

        session.updateCurrentDirectory(driftedDir)

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { text in
            capturedInputs.append(text)
        }
        session.attachRustTerminal(terminalView)

        let expectationDone = expectation(description: "queued prefill is rejected after ownership drift")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(capturedInputs.isEmpty)
            XCTAssertEqual(
                self.model.resumeRestoreDeliveryStateByPaneID[paneID]?.outcome,
                .rejected
            )
            XCTAssertNil(self.model.latestRestoreResumeTokenByPaneID[paneID])
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 1.0)
    }

    func testQueuedResumePrefillUpgradesLedgerToDeliveredWhenItEventuallyLands() {
        guard let tab = model.tabs.first,
              let (paneID, session) = tab.splitController.terminalSessions.first else {
            XCTFail("Expected initial terminal pane")
            return
        }

        // updateCurrentDirectory only adopts an on-disk path and the
        // ownership gate compares expected vs actual directory — use a real
        // temp dir matching the intent's expectedDirectory.
        let ownedDir = makeTemporaryRepoRoot().standardized.path
        session.updateCurrentDirectory(ownedDir)
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let token = "restore-queued-delivered"
        let intent = OverlayTabsModel.ResumeRestoreIntent(
            paneID: paneID,
            command: "claude --resume delivered-001",
            expectedDirectory: ownedDir,
            expectedProvider: nil,
            expectedSessionID: nil,
            expectedSessionIDSource: nil,
            isFocusedPane: true
        )

        model.latestRestoreResumeTokenByPaneID[paneID] = token
        let deliveredImmediately = model.enqueueResumePrefill(
            intent: intent,
            into: session,
            targetTabID: tab.id,
            restoreToken: token,
            queuedReason: "test_waiting_for_view",
            deliveredReason: "test_prefilled_after_waiting_for_view"
        )
        XCTAssertFalse(deliveredImmediately)
        XCTAssertEqual(
            model.resumeRestoreDeliveryStateByPaneID[paneID]?.outcome,
            .queued
        )

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { text in
            capturedInputs.append(text)
        }
        session.attachRustTerminal(terminalView)

        let expectationDone = expectation(description: "queued prefill upgrades ledger when delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(capturedInputs, ["claude --resume delivered-001"])
            XCTAssertEqual(
                self.model.resumeRestoreDeliveryStateByPaneID[paneID]?.outcome,
                .delivered
            )
            XCTAssertNil(self.model.latestRestoreResumeTokenByPaneID[paneID])
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 1.0)
    }

}

@MainActor
final class OverlayTabsModelUtilityTests: XCTestCase {
    func testReadFirstLineFromDataSupportsVeryLongLine() {
        let longLine = String(repeating: "a", count: 12000) + "\n" + String(repeating: "b", count: 20)
        guard let data = longLine.data(using: .utf8) else {
            XCTFail("Failed to encode test payload")
            return
        }

        let line = OverlayTabsModel.readFirstLine(from: data)
        XCTAssertEqual(line, String(repeating: "a", count: 12000))
    }

    func testReadFirstLineFromDataReturnsNilWhenAboveCap() {
        let oversizedLine = String(repeating: "x", count: 20000)
        guard let data = oversizedLine.data(using: .utf8) else {
            XCTFail("Failed to encode test payload")
            return
        }

        XCTAssertNil(OverlayTabsModel.readFirstLine(from: data, maxBytes: 16000))
    }

    func testStripRestoreArtifactsPreservesAnsiStyledContent() {
        let redLine = "\u{1B}[31mred output\u{1B}[0m"
        let greenLine = "\u{1B}[32mgreen output\u{1B}[0m"
        let artifact = "\u{1B}[2m stty -echo && cat '/tmp/chau7_restore.txt' && clear && stty echo\u{1B}[0m"

        let stripped = OverlayTabsModel.stripRestoreArtifacts(
            from: [redLine, artifact, greenLine].joined(separator: "\n")
        )

        XCTAssertTrue(stripped.contains(redLine))
        XCTAssertTrue(stripped.contains(greenLine))
        XCTAssertTrue(stripped.contains("\u{1B}[31m"))
        XCTAssertTrue(stripped.contains("\u{1B}[32m"))
        XCTAssertFalse(stripped.contains("stty -echo"))
        XCTAssertFalse(stripped.contains("chau7_restore.txt"))
    }

    func testScrollbackLinesWithinByteLimitDropsOldestLines() throws {
        let lines = (0 ..< 8).map { "line-\($0)-" + String(repeating: "x", count: 24) }

        let capped = try XCTUnwrap(
            OverlayTabsModel.scrollbackLinesWithinByteLimit(lines, maxBytes: 120)
        )
        let payload = capped.joined(separator: "\n")

        XCTAssertLessThanOrEqual(payload.utf8.count, 120)
        XCTAssertEqual(capped.last, lines.last)
        XCTAssertFalse(capped.contains(lines.first!))
    }

    func testScrollbackLinesWithinByteLimitRejectsSingleOversizedLine() {
        let oversized = String(repeating: "x", count: 128)

        XCTAssertNil(
            OverlayTabsModel.scrollbackLinesWithinByteLimit([oversized], maxBytes: 64)
        )
    }
}

// swiftlint:enable type_body_length
