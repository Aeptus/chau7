import XCTest
@testable import Chau7

/// SPM-runnable tests for `TabStateBackupStore`, the pure static tab-state
/// backup machinery extracted from `OverlayTabsModel`. The members exercised
/// here touch no filesystem (decode + in-memory merge) or only the static
/// archive-throttle bookkeeping (`shouldArchiveMultiWindowBackup`), so they
/// run under `swift test` without standing up the real app-support directory.
final class TabStateBackupStoreTests: XCTestCase {

    private var savedFingerprint: Int?
    private var savedArchivedAt: Date = .distantPast

    override func setUp() {
        super.setUp()
        // Preserve and reset the shared archive-throttle state so these tests
        // neither observe nor leak process-global bookkeeping.
        savedFingerprint = TabStateBackupStore.lastArchivedMultiWindowTabStateFingerprint
        savedArchivedAt = TabStateBackupStore.lastArchivedMultiWindowTabStateAt
        TabStateBackupStore.lastArchivedMultiWindowTabStateFingerprint = nil
        TabStateBackupStore.lastArchivedMultiWindowTabStateAt = .distantPast
    }

    override func tearDown() {
        TabStateBackupStore.lastArchivedMultiWindowTabStateFingerprint = savedFingerprint
        TabStateBackupStore.lastArchivedMultiWindowTabStateAt = savedArchivedAt
        super.tearDown()
    }

    private func makeState(
        tabID: UUID,
        provider: String?,
        sessionId: String?,
        command: String?
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
            aiResumeCommand: command,
            aiProvider: provider,
            aiSessionId: sessionId,
            aiSessionIdSource: sessionId == nil ? nil : .explicit,
            splitLayout: nil,
            focusedPaneID: nil,
            paneStates: nil
        )
    }

    // MARK: - decodeBackupWindowStates

    func testDecodeBackupWindowStatesDecodesMultiWindowPayload() throws {
        let windows = [
            [makeState(tabID: UUID(), provider: "codex", sessionId: "s1", command: "codex resume s1")],
            [makeState(tabID: UUID(), provider: "claude", sessionId: "s2", command: "claude --resume s2")]
        ]
        let data = try XCTUnwrap(Persist.encodeLogged(
            SavedMultiWindowState(windows: windows),
            context: "test.multi"
        ))

        let decoded = try XCTUnwrap(TabStateBackupStore.decodeBackupWindowStates(from: data))

        XCTAssertEqual(decoded.count, 2, "Both windows survive the multi-window decode")
        XCTAssertEqual(decoded[0].first?.aiSessionId, "s1")
        XCTAssertEqual(decoded[1].first?.aiSessionId, "s2")
    }

    func testDecodeBackupWindowStatesDecodesLegacySingleWindowPayload() throws {
        // Legacy format: a bare [SavedTabState] array (one window), not wrapped
        // in SavedMultiWindowState.
        let single = [makeState(tabID: UUID(), provider: "codex", sessionId: "s9", command: nil)]
        let data = try XCTUnwrap(Persist.encodeLogged(single, context: "test.single"))

        let decoded = try XCTUnwrap(TabStateBackupStore.decodeBackupWindowStates(from: data))

        XCTAssertEqual(decoded.count, 1, "Single-window fallback yields exactly one window")
        XCTAssertEqual(decoded[0].first?.aiSessionId, "s9")
    }

    func testDecodeBackupWindowStatesReturnsNilForCorruptOrEmptyData() {
        XCTAssertNil(TabStateBackupStore.decodeBackupWindowStates(from: Data("not json".utf8)))
        XCTAssertNil(TabStateBackupStore.decodeBackupWindowStates(from: Data()))
    }

    // MARK: - shouldArchiveMultiWindowBackup

    func testShouldArchiveAlwaysTrueForTerminationAndRestoreSource() {
        let data = Data("payload".utf8)
        // Prime state so the throttle path *would* say false, proving the
        // reason short-circuit wins.
        TabStateBackupStore.lastArchivedMultiWindowTabStateFingerprint = data.hashValue
        TabStateBackupStore.lastArchivedMultiWindowTabStateAt = Date()

        XCTAssertTrue(TabStateBackupStore.shouldArchiveMultiWindowBackup(data: data, reason: .termination))
        XCTAssertTrue(TabStateBackupStore.shouldArchiveMultiWindowBackup(data: data, reason: .restoreSource))
    }

    func testShouldArchiveDedupesIdenticalFingerprintForAutosave() {
        let data = Data("payload".utf8)
        TabStateBackupStore.lastArchivedMultiWindowTabStateFingerprint = data.hashValue
        TabStateBackupStore.lastArchivedMultiWindowTabStateAt = .distantPast

        XCTAssertFalse(
            TabStateBackupStore.shouldArchiveMultiWindowBackup(data: data, reason: .autosave),
            "Identical fingerprint is deduped even when the throttle window has elapsed"
        )
    }

    func testShouldArchiveTrueForNewFingerprintPastThrottleWindow() {
        let data = Data("payload".utf8)
        TabStateBackupStore.lastArchivedMultiWindowTabStateFingerprint = data.hashValue &+ 1
        TabStateBackupStore.lastArchivedMultiWindowTabStateAt = .distantPast

        XCTAssertTrue(
            TabStateBackupStore.shouldArchiveMultiWindowBackup(data: data, reason: .autosave),
            "A new fingerprint past the 300s window archives"
        )
    }

    func testShouldArchiveFalseForNewFingerprintWithinThrottleWindow() {
        let data = Data("payload".utf8)
        TabStateBackupStore.lastArchivedMultiWindowTabStateFingerprint = data.hashValue &+ 1
        TabStateBackupStore.lastArchivedMultiWindowTabStateAt = Date()

        XCTAssertFalse(
            TabStateBackupStore.shouldArchiveMultiWindowBackup(data: data, reason: .autosave),
            "A new fingerprint inside the 300s window is throttled"
        )
    }

    // MARK: - mergedWindowStates (merge-with-fallbacks)

    func testMergedWindowStatesUpgradesTabFromHigherScoringFallback() {
        let tabID = UUID()
        // Base tab knows only the provider — no session id, no command.
        let base = [[makeState(tabID: tabID, provider: "codex", sessionId: nil, command: nil)]]
        // A fallback candidate for the same tab carries a full identity.
        let fallback = [[[makeState(
            tabID: tabID,
            provider: "codex",
            sessionId: "recovered-session",
            command: "codex resume recovered-session"
        )]]]

        let merged = TabStateBackupStore.mergedWindowStates(
            baseWindows: base,
            fallbackCandidates: fallback
        )

        let mergedTab = merged.first?.first
        XCTAssertEqual(
            mergedTab?.aiSessionId,
            "recovered-session",
            "The missing session id is filled from the higher-scoring fallback"
        )
        XCTAssertGreaterThan(
            mergedTab?.aiResumeRestorationScore ?? 0,
            base[0][0].aiResumeRestorationScore,
            "Merged payload strictly improves the restoration score"
        )
    }

    func testMergedWindowStatesLeavesTabsWithoutFallbackUnchanged() {
        let tabID = UUID()
        let otherID = UUID()
        let base = [[makeState(tabID: tabID, provider: "codex", sessionId: nil, command: nil)]]
        // Fallback only has a *different* tab, so the base tab is untouched.
        let fallback = [[[makeState(
            tabID: otherID,
            provider: "claude",
            sessionId: "s",
            command: "claude --resume s"
        )]]]

        let merged = TabStateBackupStore.mergedWindowStates(
            baseWindows: base,
            fallbackCandidates: fallback
        )

        XCTAssertNil(merged.first?.first?.aiSessionId, "No fallback for this tab id leaves the state as-is")
        XCTAssertEqual(merged.first?.first?.tabID, tabID.uuidString)
    }

    func testMergedWindowStatesIgnoresZeroScoreFallback() {
        let tabID = UUID()
        let base = [[makeState(tabID: tabID, provider: "codex", sessionId: nil, command: nil)]]
        // Fallback for the same tab has no AI payload at all (score 0) → skipped.
        let fallback = [[[makeState(tabID: tabID, provider: nil, sessionId: nil, command: nil)]]]

        let merged = TabStateBackupStore.mergedWindowStates(
            baseWindows: base,
            fallbackCandidates: fallback
        )

        XCTAssertNil(
            merged.first?.first?.aiSessionId,
            "A zero-score fallback contributes nothing to the merge"
        )
        XCTAssertEqual(merged.first?.first?.aiProvider, "codex", "Base provider is preserved")
    }
}
