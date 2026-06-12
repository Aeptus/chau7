import XCTest
import Chau7Core
@testable import Chau7

final class TabRestoreBundleStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TabRestoreBundleStore.resetCacheForTesting()
    }

    override func tearDown() {
        TabRestoreBundleStore.resetCacheForTesting()
        super.tearDown()
    }

    func testPersistedBundleSeparatesManifestIdentityFromPaneContext() throws {
        let root = try temporaryRoot()
        let state = makeSavedTabState()

        let envelope = try XCTUnwrap(try TabRestoreBundleStore.persistCurrentBundle(
            windowStates: [[state]],
            reason: .autosave,
            sourceData: Data("legacy-payload-v1".utf8),
            rootURL: root,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.reason, TabStateSaveReason.autosave.rawValue)
        let manifest = try XCTUnwrap(envelope.windows.first?.first)
        XCTAssertEqual(manifest.tabID, state.tabID)
        XCTAssertEqual(manifest.selectedTabID, state.selectedTabID)
        XCTAssertEqual(manifest.aiResumeCommand, "claude --resume session-1")
        XCTAssertEqual(manifest.aiProvider, "claude")
        XCTAssertEqual(manifest.aiSessionId, "session-1")
        XCTAssertEqual(manifest.splitLayout?.id, state.focusedPaneID)

        let paneIdentity = try XCTUnwrap(manifest.paneIdentities?.first)
        XCTAssertEqual(paneIdentity.paneID, state.focusedPaneID)
        XCTAssertEqual(paneIdentity.aiResumeCommand, "claude --resume session-1")
        XCTAssertEqual(paneIdentity.aiResumeDirectory, "/tmp/project")
        XCTAssertEqual(paneIdentity.aiProvider, "claude")
        XCTAssertEqual(paneIdentity.aiSessionId, "session-1")
        XCTAssertNotNil(manifest.contextRef)
        XCTAssertNotNil(paneIdentity.contextRef)

        let tabContext = try readContext(
            TabRestoreContext.self,
            ref: XCTUnwrap(manifest.contextRef),
            rootURL: root
        )
        XCTAssertEqual(tabContext.scrollbackContent, "legacy top scrollback")
        XCTAssertEqual(tabContext.commandBlocks?.first?.command, "pnpm test")

        let paneContext = try readContext(
            PaneRestoreContext.self,
            ref: XCTUnwrap(paneIdentity.contextRef),
            rootURL: root
        )
        XCTAssertEqual(paneContext.scrollbackContent, "heavy pane output")

        let restored = try XCTUnwrap(TabRestoreBundleStore.loadCurrentWindowStates(rootURL: root))
        let restoredState = try XCTUnwrap(restored.first?.first)
        XCTAssertEqual(restoredState.scrollbackContent, state.scrollbackContent)
        XCTAssertEqual(restoredState.commandBlocks?.first?.command, "pnpm test")
        XCTAssertEqual(restoredState.paneStates?.first?.scrollbackContent, "heavy pane output")
        XCTAssertEqual(restoredState.paneStates?.first?.aiResumeCommand, "claude --resume session-1")
        XCTAssertEqual(restoredState.paneStates?.first?.knownGitBranch, "main")
    }

    func testLoadCurrentWindowStatesRejectsMissingContext() throws {
        let root = try temporaryRoot()
        let state = makeSavedTabState()

        let envelope = try XCTUnwrap(try TabRestoreBundleStore.persistCurrentBundle(
            windowStates: [[state]],
            reason: .autosave,
            sourceData: Data("legacy-payload-v1".utf8),
            rootURL: root,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let paneContextRef = try XCTUnwrap(envelope.windows.first?.first?.paneIdentities?.first?.contextRef)

        try FileManager.default.removeItem(at: currentURL(root).appendingPathComponent(paneContextRef.path))

        XCTAssertNil(TabRestoreBundleStore.loadCurrentWindowStates(rootURL: root))
    }

    func testLoadCurrentWindowStatesRejectsCorruptContext() throws {
        let root = try temporaryRoot()
        let state = makeSavedTabState()

        let envelope = try XCTUnwrap(try TabRestoreBundleStore.persistCurrentBundle(
            windowStates: [[state]],
            reason: .autosave,
            sourceData: Data("legacy-payload-v1".utf8),
            rootURL: root,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let paneContextRef = try XCTUnwrap(envelope.windows.first?.first?.paneIdentities?.first?.contextRef)

        try Data("corrupt context".utf8).write(
            to: currentURL(root).appendingPathComponent(paneContextRef.path),
            options: .atomic
        )

        XCTAssertNil(TabRestoreBundleStore.loadCurrentWindowStates(rootURL: root))
    }

    func testPersistCurrentBundleSkipsUnchangedSourceFingerprint() throws {
        let root = try temporaryRoot()
        let state = makeSavedTabState()
        let sourceData = Data("stable-legacy-payload".utf8)
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let laterDate = Date(timeIntervalSince1970: 1_800_000_900)

        let first = try XCTUnwrap(try TabRestoreBundleStore.persistCurrentBundle(
            windowStates: [[state]],
            reason: .autosave,
            sourceData: sourceData,
            rootURL: root,
            now: firstDate
        ))
        let second = try XCTUnwrap(try TabRestoreBundleStore.persistCurrentBundle(
            windowStates: [[state]],
            reason: .termination,
            sourceData: sourceData,
            rootURL: root,
            now: laterDate
        ))

        XCTAssertEqual(first.savedAt, firstDate)
        XCTAssertEqual(second.savedAt, firstDate)
        XCTAssertEqual(second.reason, TabStateSaveReason.autosave.rawValue)
    }

    func testUnchangedContentSaveStillRefreshesSaveToken() throws {
        // Content-unchanged saves skip rewriting sidecars, but the manifest
        // must adopt the new save token — otherwise the freshness arbiter
        // would wrongly conclude the bundle missed the latest save cycle.
        let root = try temporaryRoot()
        let state = makeSavedTabState()
        let sourceData = Data("stable-legacy-payload".utf8)

        let first = try XCTUnwrap(try TabRestoreBundleStore.persistCurrentBundle(
            windowStates: [[state]],
            reason: .autosave,
            sourceData: sourceData,
            saveToken: "save-1",
            rootURL: root,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        XCTAssertEqual(first.saveToken, "save-1")

        let second = try XCTUnwrap(try TabRestoreBundleStore.persistCurrentBundle(
            windowStates: [[state]],
            reason: .autosave,
            sourceData: sourceData,
            saveToken: "save-2",
            rootURL: root,
            now: Date(timeIntervalSince1970: 1_800_000_900)
        ))
        XCTAssertEqual(second.saveToken, "save-2")

        // The refreshed token must be durable in the manifest on disk, and
        // the sidecar content must still load.
        let reloaded = try XCTUnwrap(TabRestoreBundleStore.loadEnvelope(rootURL: root))
        XCTAssertEqual(reloaded.saveToken, "save-2")
        XCTAssertNotNil(TabRestoreBundleStore.loadCurrentWindowStates(rootURL: root))
    }

    func testClearCurrentBundleRemovesSidecar() throws {
        let root = try temporaryRoot()

        _ = try TabRestoreBundleStore.persistCurrentBundle(
            windowStates: [[makeSavedTabState()]],
            reason: .autosave,
            sourceData: Data("legacy-payload-v1".utf8),
            rootURL: root,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertNotNil(TabRestoreBundleStore.loadEnvelope(rootURL: root))

        try TabRestoreBundleStore.clearCurrentBundle(rootURL: root)

        XCTAssertNil(TabRestoreBundleStore.loadEnvelope(rootURL: root))
        XCTAssertNil(TabRestoreBundleStore.loadCurrentWindowStates(rootURL: root))
    }

    func testLoadCurrentWindowStatesRoundTripsMultipleWindows() throws {
        let root = try temporaryRoot()
        let state = makeSavedTabState()

        _ = try XCTUnwrap(try TabRestoreBundleStore.persistCurrentBundle(
            windowStates: [[state], [state]],
            reason: .autosave,
            sourceData: Data("multi-window-v1".utf8),
            rootURL: root,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        // The additional-windows restore path takes windows.dropFirst(), so every
        // window must round-trip in order through the file bundle.
        let restored = try XCTUnwrap(TabRestoreBundleStore.loadCurrentWindowStates(rootURL: root))
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].first?.scrollbackContent, state.scrollbackContent)
        XCTAssertEqual(restored[1].first?.paneStates?.first?.scrollbackContent, "heavy pane output")
    }

    private func makeSavedTabState() -> SavedTabState {
        let tabID = "11111111-1111-1111-1111-111111111111"
        let paneID = "22222222-2222-2222-2222-222222222222"
        let splitLayout = SavedSplitNode(
            kind: .terminal,
            id: paneID,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let pane = SavedTerminalPaneState(
            paneID: paneID,
            directory: "/tmp/project",
            scrollbackContent: "heavy pane output",
            aiResumeCommand: "claude --resume session-1",
            aiResumeDirectory: "/tmp/project",
            aiProvider: "claude",
            aiSessionId: "session-1",
            aiSessionIdSource: .explicit,
            lastOutputAt: Date(timeIntervalSince1970: 1_800_000_100),
            lastInputAt: Date(timeIntervalSince1970: 1_800_000_050),
            knownRepoRoot: "/tmp/project",
            knownGitBranch: "main",
            lastStatus: .running,
            agentLaunchCommand: "claude",
            agentStartedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastExitCode: nil,
            lastExitAt: nil
        )
        let commandBlock = CommandBlock(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            command: "pnpm test",
            startLine: 10,
            endLine: 20,
            startTime: Date(timeIntervalSince1970: 1_800_000_200),
            endTime: Date(timeIntervalSince1970: 1_800_000_205),
            exitCode: 0,
            directory: "/tmp/project",
            turnID: "turn-1"
        )

        return SavedTabState(
            tabID: tabID,
            selectedTabID: tabID,
            customTitle: "Optimization",
            color: "blue",
            directory: "/tmp/project",
            selectedIndex: 0,
            tokenOptOverride: nil,
            scrollbackContent: "legacy top scrollback",
            aiResumeCommand: "claude --resume session-1",
            aiProvider: "claude",
            aiSessionId: "session-1",
            aiSessionIdSource: .explicit,
            splitLayout: splitLayout,
            focusedPaneID: paneID,
            paneStates: [pane],
            createdAt: "2026-06-03T19:00:00Z",
            repoGroupID: "repo-group-1",
            knownRepoRoot: "/tmp/project",
            knownGitBranch: "main",
            lastInputAt: Date(timeIntervalSince1970: 1_800_000_050),
            lastStatus: .running,
            agentLaunchCommand: "claude",
            agentStartedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastExitCode: nil,
            lastExitAt: nil,
            commandBlocks: [commandBlock],
            previewSnapshotPNGData: Data([1, 2, 3])
        )
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-tab-restore-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func currentURL(_ rootURL: URL) -> URL {
        rootURL.appendingPathComponent("current", isDirectory: true)
    }

    private func readContext<T: Decodable>(
        _ type: T.Type,
        ref: TabRestoreBundleRef,
        rootURL: URL
    ) throws -> T {
        let url = currentURL(rootURL).appendingPathComponent(ref.path)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
