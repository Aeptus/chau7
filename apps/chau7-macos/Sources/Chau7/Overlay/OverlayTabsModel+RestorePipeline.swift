import Foundation
import AppKit
import Chau7Core

extension OverlayTabsModel {

    static let restoreDelaySeconds: TimeInterval = 0.2
    static let resumeCommandDelaySeconds: TimeInterval = 0.25
    static let resumeCommandRetryDelaySeconds: TimeInterval = 0.25
    static let resumeCommandMaxRetryDelay: TimeInterval = 1.5
    static let resumeCommandMaxAttempts = 16

    enum RestoreExecutionProfile: String {
        case interactiveFull = "interactive_full"
        case backgroundIdentityOnly = "background_identity_only"

        var tracksStartupBootstrap: Bool {
            self == .interactiveFull
        }

        var appliesCommandBlocks: Bool {
            self == .interactiveFull
        }

        var appliesFocusedPane: Bool {
            self == .interactiveFull
        }

        var activatesRestoredAIApp: Bool {
            self == .interactiveFull
        }

        var schedulesResumePrefills: Bool {
            self == .interactiveFull
        }
    }

    static func paneStateMap(from states: [SavedTerminalPaneState]?) -> [UUID: SavedTerminalPaneState] {
        guard let states else { return [:] }
        var map: [UUID: SavedTerminalPaneState] = [:]
        for state in states {
            guard let uuid = UUID(uuidString: state.paneID) else { continue }
            map[uuid] = state
        }
        return map
    }

    static func estimatedRestorePayloadBytes(for state: SavedTabState) -> Int {
        func byteCount(_ value: String?) -> Int {
            value?.utf8.count ?? 0
        }

        var total = 0
        total += byteCount(state.tabID)
        total += byteCount(state.selectedTabID)
        total += byteCount(state.customTitle)
        total += byteCount(state.color)
        total += byteCount(state.directory)
        total += byteCount(state.tokenOptOverride)
        total += byteCount(state.scrollbackContent)
        total += byteCount(state.aiResumeCommand)
        total += byteCount(state.aiProvider)
        total += byteCount(state.aiSessionId)
        total += byteCount(state.focusedPaneID)
        total += byteCount(state.createdAt)
        total += byteCount(state.repoGroupID)
        total += byteCount(state.knownRepoRoot)
        total += byteCount(state.knownGitBranch)
        total += byteCount(state.agentLaunchCommand)
        total += state.previewSnapshotPNGData?.count ?? 0
        for pane in state.paneStates ?? [] {
            total += byteCount(pane.paneID)
            total += byteCount(pane.directory)
            total += byteCount(pane.scrollbackContent)
            total += byteCount(pane.aiResumeCommand)
            total += byteCount(pane.aiProvider)
            total += byteCount(pane.aiSessionId)
            total += byteCount(pane.knownRepoRoot)
            total += byteCount(pane.knownGitBranch)
            total += byteCount(pane.agentLaunchCommand)
        }
        return total
    }

    /// Restore the primary window from the first saved window entry.
    /// Preference order:
    /// 1. Multi-window state key → first saved window
    /// 2. Legacy single-window key
    /// 3. Latest backup payloads
    static func restoreSavedTabs(appModel: AppModel) -> RestorableTabsPayload? {
        let multiData = UserDefaults.standard.data(forKey: SavedMultiWindowState.userDefaultsKey)
        if let multiState = Persist.decodeLogged(
            SavedMultiWindowState.self,
            from: multiData,
            context: "restore.multiWindowState"
        ),
            let primaryWindowStates = multiState.windows.first,
            !primaryWindowStates.isEmpty {
            let mergedWindows = mergedWindowStatesWithBackupFallbacks(baseWindows: multiState.windows)
            maybeRepairUserDefaultsMultiWindowState(
                originalWindows: multiState.windows,
                mergedWindows: mergedWindows
            )
            return decodeRestorableTabs(
                fromStates: mergedWindows.first ?? primaryWindowStates,
                appModel: appModel
            )
        }

        let singleData = UserDefaults.standard.data(forKey: SavedTabState.userDefaultsKey)
        if let singleWindowStates = Persist.decodeLogged(
            [SavedTabState].self,
            from: singleData,
            context: "restore.singleWindowState"
        ),
            !singleWindowStates.isEmpty {
            let mergedWindows = mergedWindowStatesWithBackupFallbacks(baseWindows: [singleWindowStates])
            maybeRepairUserDefaultsSingleWindowState(
                originalWindows: [singleWindowStates],
                mergedWindows: mergedWindows
            )
            if let restored = decodeRestorableTabs(
                fromStates: mergedWindows.first ?? singleWindowStates,
                appModel: appModel
            ) {
                return restored
            }
        }

        return restoreSavedTabsFromBackups(appModel: appModel)
    }

    /// Decode from pre-decoded states (multi-window restore — avoids UserDefaults round-trip).
    static func decodeRestorableTabs(fromStates states: [SavedTabState], appModel: AppModel) -> RestorableTabsPayload? {
        guard !states.isEmpty else { return nil }
        return hydrateRestorableTabs(from: states, appModel: appModel)
    }

    static func decodeRestorableTabs(from data: Data, appModel: AppModel) -> RestorableTabsPayload? {
        guard let states = Persist.decodeLogged(
            [SavedTabState].self,
            from: data,
            context: "restore.restorableTabs"
        ),
            !states.isEmpty else {
            return nil
        }
        return hydrateRestorableTabs(from: states, appModel: appModel)
    }

    /// Builds `OverlayTab` + `SplitPaneController` instances from an array
    /// of already-decoded `SavedTabState` values. Shared by both entry
    /// points so the multi-window restore path doesn't need to re-encode
    /// then re-decode JSON just to reuse this hydration logic.
    private static func hydrateRestorableTabs(from states: [SavedTabState], appModel: AppModel) -> RestorableTabsPayload? {
        let hydratedStates = sanitizeRestoredAIResumeOwnership(states: states)
        let colors = TabColor.allCases
        var restoredTabs: [OverlayTab] = []
        var selectedID: UUID?
        var fallbackSelectedIndex: Int?
        var persistedStates: [SavedTabState] = []

        for (i, state) in hydratedStates.enumerated() {
            if selectedID == nil, let selected = Self.validatedUUID(from: state.selectedTabID) {
                selectedID = selected
            } else if state.selectedTabID != nil {
                Log.warn("restoreSavedTabs: multiple selected tab markers found in state; using first match")
            }

            let controller = Self.buildRestorableController(
                appModel: appModel,
                splitLayout: state.splitLayout,
                focusedPaneID: state.focusedPaneID,
                paneStates: state.paneStates,
                directory: state.directory,
                knownRepoRoot: state.knownRepoRoot ?? state.repoGroupID,
                knownGitBranch: state.knownGitBranch
            )

            let restoredTabID = Self.validatedUUID(from: state.tabID) ?? UUID()
            let restoredCreatedAt: Date
            if let iso = state.createdAt,
               let parsed = DateFormatters.iso8601.date(from: iso) {
                restoredCreatedAt = parsed
            } else {
                restoredCreatedAt = Date()
            }
            var tab = OverlayTab(appModel: appModel, splitController: controller, id: restoredTabID, createdAt: restoredCreatedAt)
            tab.customTitle = state.customTitle
            // Mirror the custom title onto every terminal session's
            // tabTitleOverride so notifications match the UI chrome for
            // restored renamed tabs. The runtime rename paths (commitRename
            // in OverlayTabsModel, renameTab in TerminalControlService) both
            // do this mirror — but on launch, decodeRestorableTabs only
            // hydrates the OverlayTab struct, so notifications would fall
            // through to session.title ("Shell" or OSC-driven) or active
            // AppName and silently diverge from what the user renamed the
            // tab to in a previous session.
            if let customTitle = state.customTitle {
                for (_, session) in controller.terminalSessions {
                    session.tabTitleOverride = customTitle
                }
            }
            tab.color = TabColor(rawValue: state.color) ?? colors[i % colors.count]
            tab.stampOwnerTabID()
            controller.restoreAttachedSessionNoteIfNeeded()
            if let preview = Self.restorePreviewImage(from: state.previewSnapshotPNGData) {
                tab.restorePreviewSnapshot = preview
                Log.info("Restore preview hydrated for tab=\(restoredTabID)")
            }

            // Restore per-tab token optimization override
            if let overrideRaw = state.tokenOptOverride,
               let override = TabTokenOptOverride(rawValue: overrideRaw) {
                tab.tokenOptOverride = override
                // Sync to session so activeAppName.didSet uses the restored value
                tab.session?.tokenOptOverride = override
            }

            // Restore repo group membership
            tab.repoGroupID = state.repoGroupID

            if state.selectedIndex != nil {
                if fallbackSelectedIndex == nil {
                    fallbackSelectedIndex = i
                }
            }

            restoredTabs.append(tab)
            persistedStates.append(state)
        }

        guard !restoredTabs.isEmpty else { return nil }
        let fallbackSelectedID = fallbackSelectedIndex.flatMap { index in
            index < restoredTabs.count ? restoredTabs[index].id : nil
        }

        let finalSelectedID: UUID
        if let explicit = selectedID, restoredTabs.contains(where: { $0.id == explicit }) {
            finalSelectedID = explicit
        } else if let explicit = selectedID {
            if fallbackSelectedID != nil {
                Log.warn("restoreSavedTabs: explicit selected tab ID \(explicit) not found; falling back to legacy marker")
            } else {
                Log.warn("restoreSavedTabs: explicit selected tab ID \(explicit) not found; falling back to first tab")
            }
            finalSelectedID = fallbackSelectedID ?? restoredTabs[0].id
        } else {
            finalSelectedID = fallbackSelectedID ?? restoredTabs[0].id
        }

        if selectedID == nil, finalSelectedID != fallbackSelectedID, fallbackSelectedIndex == nil {
            Log.warn("restoreSavedTabs: falling back to first tab because no explicit or legacy selected marker was found")
        }

        return RestorableTabsPayload(
            tabs: restoredTabs,
            selectedID: finalSelectedID,
            rawStates: persistedStates
        )
    }

    static func restoreAdditionalWindowStatesFromBackups() -> [[SavedTabState]]? {
        guard let windows = mergedBackupWindowStatesFromCandidates(),
              windows.count > 1 else {
            return nil
        }
        Log.info("Recovered \(windows.count) window state set(s) from merged backup candidates")
        return windows
    }

    static func restoreSavedTabsFromBackups(appModel: AppModel) -> RestorableTabsPayload? {
        guard let windows = mergedBackupWindowStatesFromCandidates() else { return nil }
        for windowStates in windows where !windowStates.isEmpty {
            guard let payload = decodeRestorableTabs(fromStates: windowStates, appModel: appModel) else { continue }
            Log.info("Restored \(payload.tabs.count) tab(s) from merged backup candidates")
            return payload
        }
        return nil
    }

    private static func mergedBackupWindowStatesFromCandidates() -> [[SavedTabState]]? {
        let decodedCandidates = tabStateRestoreCandidateURLs().compactMap { url -> [[SavedTabState]]? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decodeBackupWindowStates(from: data)
        }
        guard let baseWindows = decodedCandidates.first else { return nil }
        let mergedWindows = mergedWindowStates(
            baseWindows: baseWindows,
            fallbackCandidates: Array(decodedCandidates.dropFirst())
        )
        maybeRepairLatestBackup(baseWindows: baseWindows, mergedWindows: mergedWindows)
        return mergedWindows
    }

    private static func mergedWindowStatesWithBackupFallbacks(baseWindows: [[SavedTabState]]) -> [[SavedTabState]] {
        let decodedCandidates = tabStateRestoreCandidateURLs().compactMap { url -> [[SavedTabState]]? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decodeBackupWindowStates(from: data)
        }
        return mergedWindowStates(baseWindows: baseWindows, fallbackCandidates: decodedCandidates)
    }

    private static func mergedWindowStates(
        baseWindows: [[SavedTabState]],
        fallbackCandidates: [[[SavedTabState]]]
    ) -> [[SavedTabState]] {
        let fallbackByTabID = fallbackCandidates.reduce(into: [String: SavedTabState]()) { result, windows in
            for tabs in windows {
                for state in tabs {
                    guard let tabID = state.tabID,
                          state.aiResumeRestorationScore > 0 else {
                        continue
                    }
                    if let existing = result[tabID],
                       existing.aiResumeRestorationScore >= state.aiResumeRestorationScore {
                        continue
                    }
                    result[tabID] = state
                }
            }
        }

        return baseWindows.map { tabs in
            tabs.map { state in
                guard let tabID = state.tabID,
                      let fallback = fallbackByTabID[tabID] else { return state }
                let merged = state.mergedAIResumePayload(with: fallback)
                if merged.aiResumeRestorationScore > state.aiResumeRestorationScore {
                    // Surface exactly which tab got repaired and the score
                    // delta so operators can trace a tab back to the
                    // archive it was upgraded from if the merge picked a
                    // stale record. Payload preview is provider+sessionID
                    // prefix only — no directories, no command bodies.
                    Log.info(
                        """
                        Restore AI resume metadata upgrade tab=\(tabID) \
                        score=\(state.aiResumeRestorationScore)->\(merged.aiResumeRestorationScore) \
                        provider=\(state.aiProvider ?? "nil")->\(merged.aiProvider ?? "nil") \
                        session=\(state.aiSessionId?.prefix(8) ?? "nil")->\(merged.aiSessionId?.prefix(8) ?? "nil") \
                        hadCommand=\(state.aiResumeCommand != nil)->\(merged.aiResumeCommand != nil)
                        """
                    )
                }
                return merged
            }
        }
    }

    private static func maybeRepairLatestBackup(baseWindows: [[SavedTabState]], mergedWindows: [[SavedTabState]]) {
        guard aiResumePayloadScore(in: mergedWindows) > aiResumePayloadScore(in: baseWindows) else { return }
        guard let payload = Persist.encodeLogged(
            SavedMultiWindowState(windows: mergedWindows),
            context: "maybeRepairLatestBackup"
        ) else { return }
        do {
            try writeLatestTabStateBackup(payload)
            Log.info("Repaired latest tab-state backup from archived AI resume metadata")
        } catch {
            Log.warn("Failed to repair latest tab-state backup: \(error)")
        }
    }

    private static func maybeRepairUserDefaultsMultiWindowState(
        originalWindows: [[SavedTabState]],
        mergedWindows: [[SavedTabState]]
    ) {
        guard aiResumePayloadScore(in: mergedWindows) > aiResumePayloadScore(in: originalWindows) else { return }
        guard let payload = Persist.encodeLogged(
            SavedMultiWindowState(windows: mergedWindows),
            context: "maybeRepairUserDefaultsMultiWindowState"
        ) else { return }
        UserDefaults.standard.set(payload, forKey: SavedMultiWindowState.userDefaultsKey)
        Log.info("Repaired UserDefaults multi-window state from archived AI resume metadata")
    }

    private static func maybeRepairUserDefaultsSingleWindowState(
        originalWindows: [[SavedTabState]],
        mergedWindows: [[SavedTabState]]
    ) {
        guard aiResumePayloadScore(in: mergedWindows) > aiResumePayloadScore(in: originalWindows),
              let firstWindow = mergedWindows.first,
              let payload = Persist.encodeLogged(
                  firstWindow,
                  context: "maybeRepairUserDefaultsSingleWindowState"
              ) else {
            return
        }
        UserDefaults.standard.set(payload, forKey: SavedTabState.userDefaultsKey)
        Log.info("Repaired UserDefaults single-window state from archived AI resume metadata")
    }

    private static func aiResumePayloadScore(in windows: [[SavedTabState]]) -> Int {
        windows
            .flatMap { $0 }
            .reduce(0) { $0 + $1.aiResumeRestorationScore }
    }

    static func decodeBackupWindowStates(from data: Data) -> [[SavedTabState]]? {
        // Intentional schema probe: backup payloads may be either
        // `SavedMultiWindowState` or a bare `[SavedTabState]` (legacy). Using
        // `Persist.decodeLogged` here would warn on every single-window
        // backup (the multi-window decode fails legitimately before the
        // fallback succeeds), so keep silent `try?` for this two-format race.
        if let multiState = try? JSONDecoder().decode(SavedMultiWindowState.self, from: data),
           !multiState.windows.isEmpty {
            return multiState.windows
        }
        if let singleWindow = try? JSONDecoder().decode([SavedTabState].self, from: data),
           !singleWindow.isEmpty {
            return [singleWindow]
        }
        return nil
    }

    static func persistWindowStateBackups(windowStates: [[SavedTabState]], reason: TabStateSaveReason) {
        guard !windowStates.isEmpty else { return }
        let payload: Data?
        if windowStates.count == 1 {
            payload = Persist.encodeLogged(
                windowStates[0],
                context: "persistWindowStateBackups.single[\(reason.rawValue)]"
            )
        } else {
            payload = Persist.encodeLogged(
                SavedMultiWindowState(windows: windowStates),
                context: "persistWindowStateBackups.multi[\(reason.rawValue)]"
            )
        }
        guard let payload else { return }
        do {
            try writeLatestTabStateBackup(payload)
            if shouldArchiveMultiWindowBackup(data: payload, reason: reason) {
                try writeArchivedTabStateBackup(payload, reason: reason)
                lastArchivedMultiWindowTabStateFingerprint = payload.hashValue
                lastArchivedMultiWindowTabStateAt = Date()
            }
        } catch {
            Log.warn("Failed to persist multi-window tab state backup [\(reason.rawValue)]: \(error)")
        }
    }

    static func clearPersistedWindowState() {
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        if let root = tabStateBackupRootURL(),
           FileManager.default.fileExists(atPath: root.path) {
            let archive = root.appendingPathComponent("archive", isDirectory: true)
            let latest = root.appendingPathComponent("latest.json")
            try? FileManager.default.removeItem(at: latest)
            if FileManager.default.fileExists(atPath: archive.path) {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: archive,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for url in contents where url.pathExtension == "json" {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    func persistTabStateBackups(data: Data, reason: TabStateSaveReason) {
        do {
            try Self.writeLatestTabStateBackup(data)
            if shouldArchiveTabStateBackup(data: data, reason: reason) {
                try Self.writeArchivedTabStateBackup(data, reason: reason)
                lastArchivedTabStateFingerprint = data.hashValue
                lastArchivedTabStateAt = Date()
            }
        } catch {
            Log.warn("Failed to persist tab state backup [\(reason.rawValue)]: \(error)")
        }
    }

    func shouldArchiveTabStateBackup(data: Data, reason: TabStateSaveReason) -> Bool {
        if reason == .termination || reason == .restoreSource {
            return true
        }
        let fingerprint = data.hashValue
        guard lastArchivedTabStateFingerprint != fingerprint else { return false }
        return Date().timeIntervalSince(lastArchivedTabStateAt) >= 300
    }

    static func shouldArchiveMultiWindowBackup(data: Data, reason: TabStateSaveReason) -> Bool {
        if reason == .termination || reason == .restoreSource {
            return true
        }
        let fingerprint = data.hashValue
        guard lastArchivedMultiWindowTabStateFingerprint != fingerprint else { return false }
        return Date().timeIntervalSince(lastArchivedMultiWindowTabStateAt) >= 300
    }

    static func archiveImportedTabStateIfNeeded(_ data: Data) {
        do {
            try writeLatestTabStateBackup(data)
            try writeArchivedTabStateBackup(data, reason: .restoreSource)
        } catch {
            Log.warn("Failed to archive imported tab state: \(error)")
        }
    }

    static func tabStateBackupRootURL() -> URL? {
        let backupDirectory = TabStateBackupNamespace.directoryName(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        return RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent(backupDirectory, isDirectory: true)
    }

    static func ensureTabStateBackupDirectories() throws -> (root: URL, archive: URL) {
        guard let root = tabStateBackupRootURL() else {
            throw NSError(domain: "Chau7.TabStateBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not resolve tab state backup directory"])
        }
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        return (root, archive)
    }

    static func writeLatestTabStateBackup(_ data: Data) throws {
        let urls = try ensureTabStateBackupDirectories()
        let latest = urls.root.appendingPathComponent("latest.json")
        try data.write(to: latest, options: .atomic)
    }

    static func writeArchivedTabStateBackup(_ data: Data, reason: TabStateSaveReason) throws {
        let urls = try ensureTabStateBackupDirectories()
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        let name = String(format: "%013lld-%@.json", millis, reason.rawValue)
        let archiveURL = urls.archive.appendingPathComponent(name)
        try data.write(to: archiveURL, options: .atomic)
        try pruneArchivedTabStateBackups(in: urls.archive)
    }

    static func pruneArchivedTabStateBackups(in archiveURL: URL) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: archiveURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let jsonFiles = contents.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)

        for url in jsonFiles.dropFirst(120) {
            try? fileManager.removeItem(at: url)
        }

        for url in jsonFiles.prefix(120) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modifiedAt = values?.contentModificationDate, modifiedAt < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    static func tabStateRestoreCandidateURLs() -> [URL] {
        guard let root = tabStateBackupRootURL() else { return [] }
        let latest = root.appendingPathComponent("latest.json")
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        let archiveFiles = (try? FileManager.default.contentsOfDirectory(
            at: archive,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []

        if FileManager.default.fileExists(atPath: latest.path) {
            return [latest] + archiveFiles
        }
        return archiveFiles
    }

    static func validatedUUID(from raw: String?) -> UUID? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    static func buildRestorableController(
        appModel: AppModel,
        splitLayout: SavedSplitNode?,
        focusedPaneID: String?,
        paneStates: [SavedTerminalPaneState]?,
        directory: String,
        knownRepoRoot: String?,
        knownGitBranch: String?
    ) -> SplitPaneController {
        guard let splitLayout else {
            let fallbackController = SplitPaneController(appModel: appModel)
            if let session = fallbackController.terminalSessions.first?.1 {
                if let knownRepoRoot = OverlayTabsModel.normalizedSavedRepoField(knownRepoRoot) {
                    KnownRepoIdentityStore.shared.record(
                        rootPath: knownRepoRoot,
                        branch: OverlayTabsModel.normalizedSavedRepoField(knownGitBranch)
                    )
                }
                if !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    session.updateCurrentDirectory(directory)
                }
            }
            if let focusedPaneID, let focusID = UUID(uuidString: focusedPaneID) {
                fallbackController.setFocusedPane(focusID)
            }
            return fallbackController
        }

        let stateByPaneID = paneStateMap(from: paneStates)
        let focusedUUID = focusedPaneID.flatMap(UUID.init)
        let root = SplitNode.fromSavedNode(splitLayout, appModel: appModel, paneStates: stateByPaneID)
        return SplitPaneController(appModel: appModel, root: root, focusedPaneID: focusedUUID)
    }

    /// Two adapters that bring older `SavedTabState` payloads up to the
    /// pane-native shape that `restoreTabState` expects:
    ///
    ///   1. **Legacy single-pane adapter** — when the payload has no
    ///      `paneStates` array, fabricate one from the top-level
    ///      `SavedTabState` fields (directory, scrollback, AI metadata,
    ///      etc.) keyed by the first live terminal session's pane ID.
    ///
    ///   2. **Legacy top-level AI metadata adapter** — for single-pane
    ///      tabs where the pane-state itself is missing AI metadata,
    ///      backfill it from the top-level fields. Older saves serialized
    ///      AI provider/session at the tab level only; without this
    ///      adapter the resume prefill never fires for restored tabs.
    ///
    /// Pure transform: takes the parsed pane-state map + the saved tab
    /// state + the live terminal sessions, returns the corrected map.
    /// Extracted so the synchronous prep in `restoreTabState` reads as a
    /// single line instead of 50 lines of struct copies, and so the
    /// adapter rules can be unit-tested without standing up a model.
    static func applyLegacyPaneStateAdapters(
        paneStatesByID: [UUID: SavedTerminalPaneState],
        terminalSessions: [(UUID, TerminalSessionModel)],
        state: SavedTabState
    ) -> [UUID: SavedTerminalPaneState] {
        var paneStatesToRestore = paneStatesByID

        // Legacy single-pane adapter. Remove once all persisted state uses paneStates.
        if paneStatesByID.isEmpty, let firstPaneID = terminalSessions.first?.0 {
            paneStatesToRestore[firstPaneID] = SavedTerminalPaneState(
                paneID: firstPaneID.uuidString,
                directory: state.directory,
                scrollbackContent: state.scrollbackContent,
                aiResumeCommand: state.aiResumeCommand,
                aiProvider: state.aiProvider,
                aiSessionId: state.aiSessionId,
                aiSessionIdSource: state.aiSessionIdSource,
                lastInputAt: state.lastInputAt,
                knownRepoRoot: state.knownRepoRoot ?? state.repoGroupID,
                knownGitBranch: state.knownGitBranch,
                lastStatus: state.lastStatus,
                agentLaunchCommand: state.agentLaunchCommand,
                agentStartedAt: state.agentStartedAt,
                lastExitCode: state.lastExitCode,
                lastExitAt: state.lastExitAt
            )
        }

        // Legacy top-level AI metadata adapter. Remove once all restore payloads are pane-native.
        if paneStatesToRestore.count == 1,
           let firstEntry = paneStatesToRestore.first {
            let firstPane = firstEntry.value
            if firstPane.aiProvider == nil, firstPane.aiSessionId == nil {
                let legacyCommand = firstPane.aiResumeCommand ?? state.aiResumeCommand
                paneStatesToRestore[firstEntry.key] = SavedTerminalPaneState(
                    paneID: firstPane.paneID,
                    directory: firstPane.directory,
                    scrollbackContent: firstPane.scrollbackContent,
                    aiResumeCommand: legacyCommand,
                    aiResumeDirectory: firstPane.aiResumeDirectory,
                    aiProvider: firstPane.aiProvider ?? state.aiProvider,
                    aiSessionId: firstPane.aiSessionId ?? state.aiSessionId,
                    aiSessionIdSource: firstPane.aiSessionIdSource ?? state.aiSessionIdSource,
                    lastOutputAt: firstPane.lastOutputAt,
                    lastInputAt: firstPane.lastInputAt ?? state.lastInputAt,
                    knownRepoRoot: firstPane.knownRepoRoot ?? state.knownRepoRoot ?? state.repoGroupID,
                    knownGitBranch: firstPane.knownGitBranch ?? state.knownGitBranch,
                    lastStatus: firstPane.lastStatus ?? state.lastStatus,
                    agentLaunchCommand: firstPane.agentLaunchCommand ?? state.agentLaunchCommand,
                    agentStartedAt: firstPane.agentStartedAt ?? state.agentStartedAt,
                    lastExitCode: firstPane.lastExitCode ?? state.lastExitCode,
                    lastExitAt: firstPane.lastExitAt ?? state.lastExitAt
                )
            }
        }

        return paneStatesToRestore
    }

    func restoreTabState(
        for tab: OverlayTab,
        state: SavedTabState,
        scheduledDelayOverride: TimeInterval? = nil,
        // Queue resume prefills directly on the session instead of retrying on
        // timers. This keeps restore mutation bound to the session lifecycle
        // and avoids post-reveal retry storms.
        useResumeRetryScheduler: Bool = false,
        executeSynchronouslyWhenPossible: Bool = false,
        executionProfile: RestoreExecutionProfile = .interactiveFull
    ) {
        let targetTabID = tab.id
        let terminalSessions = tab.splitController.terminalSessions
        Log.info(
            "restoreTabState: scheduled for tab=\(targetTabID), panes=\(terminalSessions.count) profile=\(executionProfile.rawValue)"
        )
        guard !terminalSessions.isEmpty else { return }
        let startupRestoreActive = StartupRestoreCoordinator.shared.isActive
            && executionProfile.tracksStartupBootstrap
        if startupRestoreActive {
            let previousHadPendingWork = hasPendingStartupRestoreWork
            restoreBootstrapTabIDs.insert(targetTabID)
            updateSuspensionState()
            notifyStartupRestoreWorkIfDrained(previousHadPendingWork: previousHadPendingWork)
        }

        // Keep the restored focus for the active terminal pane (or fallback to
        // first terminal if an editor pane was serialized).
        if executionProfile.appliesFocusedPane,
           let restoredFocus = state.focusedPaneID.flatMap(UUID.init),
           tab.splitController.root.paneType(for: restoredFocus) == .terminal {
            tab.splitController.setFocusedPane(restoredFocus)
        }

        let paneStatesByID = Self.paneStateMap(from: state.paneStates)
        let paneStatesToRestore = Self.applyLegacyPaneStateAdapters(
            paneStatesByID: paneStatesByID,
            terminalSessions: terminalSessions,
            state: state
        )

        if executionProfile.tracksStartupBootstrap {
            for (paneID, session) in terminalSessions {
                session.onRestoreBootstrapPhaseChanged = { [weak self] phase in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if phase == .settled {
                            StartupRestoreCoordinator.shared.noteRestoreBootstrapSettled(
                                tabID: targetTabID,
                                paneID: paneID,
                                source: "phase_changed"
                            )
                            if let restoredTab = self.tabs.first(where: { $0.id == targetTabID }) {
                                let currentSessions = restoredTab.splitController.terminalSessions.map(\.1)
                                if currentSessions.allSatisfy({ !$0.isRestoreBootstrapPending }) {
                                    let previousHadPendingWork = self.hasPendingStartupRestoreWork
                                    self.restoreBootstrapTabIDs.remove(targetTabID)
                                    self.updateSuspensionState()
                                    self.notifyStartupRestoreWorkIfDrained(previousHadPendingWork: previousHadPendingWork)
                                }
                            }
                        }
                        self.updateSuspensionState()
                        guard targetTabID == self.selectedTabID else { return }
                        guard StartupRestoreCoordinator.shared.isActive else {
                            Log.trace(
                                "restoreBootstrap: skipping runtime selected-tab reveal for \(targetTabID)"
                            )
                            return
                        }
                        if let selectedTab = self.selectedTab,
                           let selectedSession = selectedTab.displaySession ?? selectedTab.session,
                           selectedSession.existingRustTerminalView != nil,
                           selectedSession.presentationSurfaceState.isLivePresentable {
                            _ = self.noteStartupSelectedTabLiveFrameAfterRestoreBootstrapSettledIfNeeded(
                                tabID: targetTabID,
                                reason: "restore_bootstrap_settled"
                            )
                            Log.trace(
                                "restoreBootstrap: skipping selected-tab reveal for \(targetTabID) because the selected surface is already live"
                            )
                            return
                        }
                        let startupLiveFrameAlreadyRecorded = self.overlayWindow.map {
                            StartupRestoreCoordinator.shared.hasSelectedTabLiveFrame(windowNumber: $0.windowNumber)
                        } ?? false
                        if StartupRestoreCoordinator.shared.isActive,
                           startupLiveFrameAlreadyRecorded {
                            Log.trace(
                                "restoreBootstrap: skipping selected-tab reveal for \(targetTabID) after first startup live frame"
                            )
                            return
                        }
                        self.requestSelectedTabAuthoritativeReveal(reason: "restore_bootstrap_phase")
                    }
                }
            }
        }

        if executionProfile.tracksStartupBootstrap {
            for (paneID, session) in terminalSessions {
                let paneState = paneStatesToRestore[paneID]
                let expectsResumePrefill = Self.normalizedResumeCommand(paneState?.aiResumeCommand) != nil
                    || (paneState?.aiProvider != nil && paneState?.aiSessionId != nil)
                    || (paneStatesToRestore.isEmpty && terminalSessions.count == 1 && (
                        Self.normalizedResumeCommand(state.aiResumeCommand) != nil
                            || (state.aiProvider != nil && state.aiSessionId != nil)
                    ))
                if expectsResumePrefill {
                    StartupRestoreCoordinator.shared.noteRestoreBootstrapStarted(
                        tabID: targetTabID,
                        paneID: paneID,
                        expectsResumePrefill: expectsResumePrefill
                    )
                    session.beginRestoreBootstrap(expectsResumePrefill: expectsResumePrefill)
                }
            }
        }

        let isSelectedRestore = targetTabID == selectedTabID
        let scheduledDelay = scheduledDelayOverride ?? StartupWindowPresentationPolicy.restoreExecutionDelay(
            isStartupRestoreActive: StartupRestoreCoordinator.shared.isActive,
            isSelectedTab: isSelectedRestore,
            defaultDelay: Self.restoreDelaySeconds
        )
        let restoreScheduledAt = CFAbsoluteTimeGetCurrent()
        let executeRestore = { [weak self] in
            guard let self else { return }
            executeRestoreBody(
                targetTabID: targetTabID,
                state: state,
                paneStatesByID: paneStatesByID,
                paneStatesToRestore: paneStatesToRestore,
                terminalSessions: terminalSessions,
                isSelectedRestore: isSelectedRestore,
                scheduledDelay: scheduledDelay,
                restoreScheduledAt: restoreScheduledAt,
                useResumeRetryScheduler: useResumeRetryScheduler,
                startupRestoreActive: startupRestoreActive,
                executionProfile: executionProfile
            )
        }
        if executeSynchronouslyWhenPossible, scheduledDelay <= 0 {
            executeRestore()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + scheduledDelay, execute: executeRestore)
        }
    }

    /// Restore-blocks phase of `executeRestoreBody`. If the saved state
    /// has command blocks, restore them for the tab; otherwise clear any
    /// blocks left over from a previous tab with the same UUID.
    ///
    /// `MainActor.assumeIsolated` is required because
    /// `CommandBlockManager.shared` is `@MainActor`-isolated. The caller
    /// (`executeRestoreBody`) is dispatched on the main queue via
    /// `asyncAfter` but Swift's type system doesn't know that — the
    /// `assumeIsolated` is the runtime assertion that we are in fact on
    /// the main actor. Removing it breaks the build.
    ///
    /// `private` because no caller exists outside `executeRestoreBody`
    /// in this module, and tightening the contract is the cheapest
    /// defense against a future caller invoking this from a non-main
    /// context (the runtime would trap inside `assumeIsolated`).
    private static func restoreCommandBlocksForTab(state: SavedTabState, targetTabID: UUID) {
        if let restoredBlocks = state.commandBlocks {
            MainActor.assumeIsolated {
                CommandBlockManager.shared.restoreBlocks(restoredBlocks, for: targetTabID.uuidString)
            }
        } else {
            MainActor.assumeIsolated {
                CommandBlockManager.shared.clearBlocks(tabID: targetTabID.uuidString)
            }
        }
    }

    /// Metadata-resolution phase of `executeRestoreBody`. For each pane in
    /// `currentSessions`, resolves the AI resume metadata (provider +
    /// session-id + source) from saved state plus optional legacy
    /// fallback, applies it to the live `TerminalSessionModel` via
    /// `restoreAIMetadata`, and returns a fresh `[paneID: SavedTerminalPaneState]`
    /// map keyed by live pane IDs whose values reflect the resolved
    /// metadata.
    ///
    /// Side effects (intentional, not hidden):
    ///   - Per-pane: `session.restoreAIMetadata(...)` writes provider /
    ///     sessionId / launchCommand / lastInputAt / lastOutputAt /
    ///     lastStatus / lastExitCode / lastExitAt onto the live session.
    ///   - Per-pane: `paneStatesToRestore[paneID]` is updated to the
    ///     effective pane state (carries the resolved values forward in
    ///     case downstream telemetry reads from it; the original
    ///     pre-extraction code did the same).
    ///
    /// `inout paneStatesToRestore` semantics: Swift's `inout` is
    /// pass-by-value-result with copy-in/copy-out. The helper sees the
    /// full pre-call dictionary, mutates a local copy, and on return the
    /// caller's variable is fully overwritten with the final state. For
    /// our single-call-no-aliasing usage this is observationally
    /// identical to in-place mutation of a captured variable (which is
    /// what the pre-extraction closure did).
    ///
    /// `shouldUseLegacyTabFallback` toggles top-level SavedTabState
    /// fields as a fallback when the saved state has only one pane and
    /// no pane-level metadata — kept for back-compat with older saves
    /// that predate per-pane AI metadata.
    static func resolveAndApplyPaneMetadata(
        currentSessions: [(UUID, TerminalSessionModel)],
        paneStatesByID: [UUID: SavedTerminalPaneState],
        paneStatesToRestore: inout [UUID: SavedTerminalPaneState],
        state: SavedTabState,
        targetTabID: UUID,
        activateRestoredAppName: Bool = true
    ) -> [UUID: SavedTerminalPaneState] {
        var resolvedPaneStates: [UUID: SavedTerminalPaneState] = [:]
        let paneMapKeys = Set(paneStatesToRestore.keys.map { String($0.uuidString.prefix(8)) })
        for (paneID, session) in currentSessions {
            let paneHit = paneStatesToRestore[paneID] != nil
            let paneState = paneStatesToRestore[paneID] ?? SavedTerminalPaneState(
                paneID: paneID.uuidString,
                directory: session.currentDirectory,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                aiProvider: nil,
                aiSessionId: nil,
                aiSessionIdSource: nil,
                lastOutputAt: nil,
                lastInputAt: nil,
                knownRepoRoot: nil,
                knownGitBranch: nil,
                lastStatus: nil,
                agentLaunchCommand: nil,
                agentStartedAt: nil,
                lastExitCode: nil,
                lastExitAt: nil
            )
            let shouldUseLegacyTabFallback = paneStatesByID.isEmpty && currentSessions.count == 1
            let fallbackProvider = shouldUseLegacyTabFallback ? state.aiProvider : nil
            let fallbackSessionId = shouldUseLegacyTabFallback ? state.aiSessionId : nil
            let fallbackSessionSource = shouldUseLegacyTabFallback ? state.aiSessionIdSource : nil

            let resolvedMetadata = Self.resolveAIResumeMetadataFromSavedState(
                paneState: paneState,
                fallbackAIProvider: fallbackProvider,
                fallbackAISessionId: fallbackSessionId,
                fallbackAISessionIdSource: fallbackSessionSource
            )
            let resolvedCommand = Self.buildAIResumeCommand(
                provider: resolvedMetadata?.provider,
                sessionId: resolvedMetadata?.sessionId,
                sessionIdSource: resolvedMetadata?.sessionIdSource
            )
            let resolvedResumeDirectory = Self.resolveRestoreDirectoryForMetadata(
                provider: resolvedMetadata?.provider,
                sessionId: resolvedMetadata?.sessionId,
                savedDirectory: paneState.directory
            )

            Log.info(
                """
                restoreTabState: pane resolve tab=\(targetTabID) pane=\(paneID) \
                hit=\(paneHit) mapKeys=[\(paneMapKeys.sorted().joined(separator: ","))] \
                saved=(provider=\(paneState.aiProvider ?? "nil") session=\(paneState.aiSessionId?.prefix(8) ?? "nil") \
                cmd=\(paneState.aiResumeCommand?.prefix(30) ?? "nil")) \
                resolved=(provider=\(resolvedMetadata?.provider ?? "nil") session=\(resolvedMetadata?.sessionId.prefix(8) ?? "nil") \
                cmd=\(resolvedCommand?.prefix(30) ?? "nil")) \
                legacy=\(shouldUseLegacyTabFallback) fallbackProvider=\(fallbackProvider ?? "nil")
                """
            )

            session.restoreAIMetadata(
                provider: resolvedMetadata?.provider,
                sessionId: resolvedMetadata?.sessionId,
                sessionIdSource: resolvedMetadata?.sessionIdSource,
                launchCommand: paneState.agentLaunchCommand,
                startedAt: paneState.agentStartedAt,
                lastInputAt: paneState.lastInputAt,
                lastOutputAt: paneState.lastOutputAt,
                lastStatus: paneState.lastStatus,
                lastExitCode: paneState.lastExitCode,
                lastExitAt: paneState.lastExitAt,
                activateRestoredAppName: activateRestoredAppName
            )

            let effectivePaneState = SavedTerminalPaneState(
                paneID: paneState.paneID,
                directory: paneState.directory,
                scrollbackContent: paneState.scrollbackContent,
                aiResumeCommand: resolvedCommand ?? Self.normalizedResumeCommand(paneState.aiResumeCommand),
                aiResumeDirectory: resolvedResumeDirectory,
                aiProvider: resolvedMetadata?.provider,
                aiSessionId: resolvedMetadata?.sessionId,
                aiSessionIdSource: resolvedMetadata?.sessionIdSource,
                lastOutputAt: paneState.lastOutputAt,
                lastInputAt: paneState.lastInputAt,
                knownRepoRoot: paneState.knownRepoRoot,
                knownGitBranch: paneState.knownGitBranch,
                lastStatus: paneState.lastStatus,
                agentLaunchCommand: paneState.agentLaunchCommand,
                agentStartedAt: paneState.agentStartedAt,
                lastExitCode: paneState.lastExitCode,
                lastExitAt: paneState.lastExitAt
            )
            resolvedPaneStates[paneID] = effectivePaneState
            paneStatesToRestore[paneID] = effectivePaneState
        }
        return resolvedPaneStates
    }

    /// Resume-prefill scheduling phase of `executeRestoreBody`. Builds
    /// `ResumeRestoreIntent` per pane that has a resolvable resume
    /// command, then dispatches each intent through one of two paths:
    ///
    ///   - `useResumeRetryScheduler == true` — legacy retry path. Uses
    ///     `scheduleResumeCommand` which arms a delayed retry chain.
    ///     Kept for back-compat and edge cases where the pending-prefill
    ///     queue isn't appropriate.
    ///
    ///   - `useResumeRetryScheduler == false` — modern session-bound path.
    ///     Uses `enqueueResumePrefill` to queue the prefill on the
    ///     session's pending-prefill machinery. Avoids post-reveal retry
    ///     storms because delivery is bound to session lifecycle, not a
    ///     standalone timer.
    ///
    /// Both paths first record `outcome=.pending` via
    /// `recordResumeRestoreDeliveryState` and stamp
    /// `latestRestoreResumeTokenByPaneID[paneID]` with the per-restore
    /// token so the delivery state machine can recognize stale callbacks.
    ///
    /// Side effects:
    ///   - `resumeRestoreDeliveryStateByPaneID[paneID]` written via
    ///     `recordResumeRestoreDeliveryState` (rule-gated, see
    ///     `decideResumeRestoreDeliveryUpdate` in T4 tests).
    ///   - `latestRestoreResumeTokenByPaneID[paneID]` written for
    ///     **every pane that has a `resumeIntent`**, regardless of
    ///     which dispatch branch (retry-scheduler vs session-bound)
    ///     fires. Pre-W3.28.3 the assignment was duplicated inside
    ///     each branch; the hoisted single statement is equivalent.
    ///   - Calls into the resume-prefill delivery machinery
    ///     (`scheduleResumeCommand` / `enqueueResumePrefill`).
    private func scheduleResumePrefillsForRestore(
        currentSessions: [(UUID, TerminalSessionModel)],
        resolvedPaneStates: [UUID: SavedTerminalPaneState],
        focusedTerminalPaneID: UUID,
        targetTabID: UUID,
        useResumeRetryScheduler: Bool
    ) {
        let resumeIntents = currentSessions.compactMap { paneID, _ -> ResumeRestoreIntent? in
            guard let paneState = resolvedPaneStates[paneID],
                  let command = Self.normalizedResumeCommand(paneState.aiResumeCommand) else {
                return nil
            }
            return ResumeRestoreIntent(
                paneID: paneID,
                command: command,
                // Use the same effective directory as the launch path
                // (`SplitPaneController.fromSavedNode` → `preferredRestoreDirectory`)
                // so the directoryMatches gate doesn't reject delivery when
                // codex's session cwd differs from the shell-cwd we saved.
                expectedDirectory: paneState.preferredRestoreDirectory,
                expectedProvider: paneState.aiProvider,
                expectedSessionID: paneState.aiSessionId,
                expectedSessionIDSource: paneState.aiSessionIdSource,
                isFocusedPane: paneID == focusedTerminalPaneID
            )
        }
        if resumeIntents.isEmpty {
            Log.info("restoreTabState: no resume command candidate found for tab=\(targetTabID)")
        }

        let restoreToken = UUID().uuidString
        for (paneID, session) in currentSessions {
            guard let resumeIntent = resumeIntents.first(where: { $0.paneID == paneID }) else { continue }

            recordResumeRestoreDeliveryState(
                paneID: paneID,
                token: restoreToken,
                outcome: .pending,
                tabID: targetTabID,
                reason: "scheduled"
            )
            Log.info(
                """
                restoreTabState: scheduling resume command for tab=\(targetTabID) pane=\(paneID) \
                focused=\(resumeIntent.isFocusedPane) provider=\(resumeIntent.expectedProvider ?? "nil") \
                session=\(resumeIntent.expectedSessionID?.prefix(8) ?? "nil")
                """
            )
            // Hoisted from inside both branches of the original
            // `if useResumeRetryScheduler` (pre-W3.28.3 the assignment
            // was duplicated in each branch). Equivalent because both
            // branches unconditionally executed it; collapsed here so a
            // future third branch can't accidentally skip the stamp.
            latestRestoreResumeTokenByPaneID[paneID] = restoreToken
            if useResumeRetryScheduler {
                scheduleResumeCommand(
                    intent: resumeIntent,
                    targetTabID: targetTabID,
                    restoreToken: restoreToken,
                    remainingAttempts: Self.resumeCommandMaxAttempts,
                    delay: Self.resumeCommandDelaySeconds
                )
            } else {
                _ = enqueueResumePrefill(
                    intent: resumeIntent,
                    into: session,
                    targetTabID: targetTabID,
                    restoreToken: restoreToken,
                    queuedReason: "selected_on_demand_queued",
                    deliveredReason: "selected_on_demand_delivered"
                )
            }
        }
    }

    /// Async-dispatched body of `restoreTabState`. Originally an inline
    /// closure; extracted to a method so the outer scheduling logic and
    /// the executeRestore phase work can be reasoned about independently.
    /// All inputs are passed by value (paneStatesToRestore is `var` inside
    /// because the metadata phase mutates it for telemetry; the mutation
    /// doesn't need to escape the method).
    private func executeRestoreBody(
        targetTabID: UUID,
        state: SavedTabState,
        paneStatesByID: [UUID: SavedTerminalPaneState],
        paneStatesToRestore: [UUID: SavedTerminalPaneState],
        terminalSessions: [(UUID, TerminalSessionModel)],
        isSelectedRestore: Bool,
        scheduledDelay: TimeInterval,
        restoreScheduledAt: CFAbsoluteTime,
        useResumeRetryScheduler: Bool,
        startupRestoreActive: Bool,
        executionProfile: RestoreExecutionProfile
    ) {
        var paneStatesToRestore = paneStatesToRestore
        let restoreStartedAt = CFAbsoluteTimeGetCurrent()
        let restoreStartMemoryMB = PerfTracker.currentMemoryMB()
        let payloadBytes = Self.estimatedRestorePayloadBytes(for: state)
        let waitedMs = Int((restoreStartedAt - restoreScheduledAt) * 1000)
        Log.info(
            "restoreTabState: executing for tab=\(targetTabID) selected=\(isSelectedRestore) profile=\(executionProfile.rawValue) waited=\(waitedMs)ms scheduledDelayMs=\(Int((scheduledDelay * 1000).rounded()))"
        )
        // Sub-phase timing so profiling can identify which branch of
        // `executeRestore` consumes the main-thread budget. Previously
        // only the aggregate stall was logged; with 15-tab restores
        // each 200ms, that's 3s of main-thread blocking with no signal
        // which phase to target for batching.
        var phaseTimings: [(name: String, ms: Int)] = []
        func recordPhase(_ name: String, startedAt: CFAbsoluteTime) {
            let elapsed = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())
            phaseTimings.append((name: name, ms: elapsed))
        }
        defer {
            FeatureProfiler.shared.recordMainThreadStallIfNeeded(
                operation: "OverlayTabsModel.restoreTabState",
                startedAt: restoreStartedAt,
                thresholdMs: 150,
                metadata: "tab=\(targetTabID) panes=\(terminalSessions.count)"
            )
            let totalMs = Int(((CFAbsoluteTimeGetCurrent() - restoreStartedAt) * 1000).rounded())
            let endMemoryMB = PerfTracker.currentMemoryMB()
            let memoryDeltaMB: Double?
            if let restoreStartMemoryMB, let endMemoryMB {
                memoryDeltaMB = endMemoryMB - restoreStartMemoryMB
            } else {
                memoryDeltaMB = nil
            }
            let breakdown = phaseTimings.map { "\($0.name)=\($0.ms)ms" }.joined(separator: " ")
            let memoryLabel = if let endMemoryMB {
                String(format: "%.1fMB", endMemoryMB)
            } else {
                "nil"
            }
            let memoryDeltaLabel = if let memoryDeltaMB {
                String(format: "%+.1fMB", memoryDeltaMB)
            } else {
                "nil"
            }
            FeatureProfiler.shared.record(
                feature: .restorePipeline,
                durationMs: Double(totalMs),
                bytes: payloadBytes,
                metadata: """
                tab=\(targetTabID) profile=\(executionProfile.rawValue) selected=\(isSelectedRestore) \
                panes=\(terminalSessions.count) waited=\(waitedMs)ms scheduledDelayMs=\(Int((scheduledDelay * 1000).rounded())) \
                rss=\(memoryLabel) rssDelta=\(memoryDeltaLabel) stages=[\(breakdown)]
                """
            )
            Log.info(
                """
                restoreTabState: telemetry tab=\(targetTabID) profile=\(executionProfile.rawValue) \
                selected=\(isSelectedRestore) panes=\(terminalSessions.count) total=\(totalMs)ms waited=\(waitedMs)ms \
                payload=\(payloadBytes)B rss=\(memoryLabel) rssDelta=\(memoryDeltaLabel) stages=[\(breakdown)]
                """
            )
            if totalMs >= 50 {
                Log.trace("restoreTabState: phase breakdown tab=\(targetTabID) total=\(totalMs)ms \(breakdown)")
            }
        }
        guard let restoredTab = tabs.first(where: { $0.id == targetTabID }) else {
            Log.warn("restoreTabState: tab no longer exists for id=\(targetTabID)")
            return
        }
        if executionProfile == .backgroundIdentityOnly,
           deferredRestoreStatesByTabID[targetTabID] == nil {
            Log.trace(
                "restoreTabState: skipped stale background identity restore for tab=\(targetTabID)"
            )
            return
        }

        let phaseBlocksStart = CFAbsoluteTimeGetCurrent()
        if executionProfile.appliesCommandBlocks {
            Self.restoreCommandBlocksForTab(state: state, targetTabID: targetTabID)
        }
        recordPhase("blocks", startedAt: phaseBlocksStart)

        let currentSessions = restoredTab.splitController.terminalSessions
        guard !currentSessions.isEmpty else {
            Log.warn("restoreTabState: tab \(targetTabID) has no terminal sessions")
            return
        }

        let restoredFocus = state.focusedPaneID.flatMap(UUID.init)
        let focusedTerminalPaneID: UUID = if let restoredFocus,
                                             restoredTab.splitController.root.paneType(for: restoredFocus) == .terminal {
            restoredFocus
        } else {
            restoredTab.splitController.focusedTerminalSessionID() ?? currentSessions[0].0
        }

        if executionProfile.appliesFocusedPane,
           restoredTab.splitController.root.paneType(for: focusedTerminalPaneID) == .terminal {
            restoredTab.splitController.setFocusedPane(focusedTerminalPaneID)
        }

        let phaseMetadataStart = CFAbsoluteTimeGetCurrent()
        let resolvedPaneStates = Self.resolveAndApplyPaneMetadata(
            currentSessions: currentSessions,
            paneStatesByID: paneStatesByID,
            paneStatesToRestore: &paneStatesToRestore,
            state: state,
            targetTabID: targetTabID,
            activateRestoredAppName: executionProfile.activatesRestoredAIApp
        )
        recordPhase("metadata", startedAt: phaseMetadataStart)

        let phaseResumeStart = CFAbsoluteTimeGetCurrent()
        if executionProfile.schedulesResumePrefills {
            scheduleResumePrefillsForRestore(
                currentSessions: currentSessions,
                resolvedPaneStates: resolvedPaneStates,
                focusedTerminalPaneID: focusedTerminalPaneID,
                targetTabID: targetTabID,
                useResumeRetryScheduler: useResumeRetryScheduler
            )
        } else {
            Log.trace(
                "restoreTabState: deferred resume scheduling for tab=\(targetTabID) profile=\(executionProfile.rawValue)"
            )
        }
        recordPhase("resume", startedAt: phaseResumeStart)

        // Close the auto-grouping session-attach race: the initial
        // setupRepoGrouping pass at model init can iterate over a tab whose
        // session hasn't attached yet (deferred restore), leaving the tab
        // without an onGitRootPathChanged callback. Re-wire here now that
        // the session is attached and any restored cwd / gitRoot will
        // re-fire the callback as `refreshGitStatus` resolves async.
        if FeatureSettings.shared.repoGroupingMode == .auto {
            setupRepoGroupingForTab(restoredTab)
        }

        if startupRestoreActive,
           currentSessions.allSatisfy({ !$0.1.isRestoreBootstrapPending }) {
            let previousHadPendingWork = hasPendingStartupRestoreWork
            restoreBootstrapTabIDs.remove(targetTabID)
            updateSuspensionState()
            notifyStartupRestoreWorkIfDrained(previousHadPendingWork: previousHadPendingWork)
        }
    }

    var selectedTab: OverlayTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func notificationTabTitle(for target: TabTarget) -> String? {
        guard let id = TerminalControlService.shared.resolveTabID(for: target) else { return nil }
        return tabs.first(where: { $0.id == id })?.displayTitle
    }

    func notificationRepoName(for target: TabTarget) -> String? {
        guard let id = TerminalControlService.shared.resolveTabID(for: target),
              let tab = tabs.first(where: { $0.id == id }),
              let session = tab.displaySession ?? tab.session,
              let rootPath = session.gitRootPath else { return nil }
        return URL(fileURLWithPath: rootPath).lastPathComponent
    }

    var overlayWorkspaceIdentifier: String? {
        if let repoRoot = SnippetManager.shared.activeRepoRoot {
            return repoRoot
        }
        return selectedTab?.session?.currentDirectory
    }

    var hasActiveOverlay: Bool {
        isSearchVisible
            || isRenameVisible
            || isClipboardHistoryVisible
            || isBookmarkListVisible
            || isSnippetManagerVisible
    }

    func updateSnippetContextForSelection() {
        if let tab = selectedTab, let session = tab.session {
            SnippetManager.shared.updateContextPath(session.currentDirectory)
        }
    }

    func inheritedStartDirectory() -> String? {
        guard FeatureSettings.shared.newTabsUseCurrentDirectory else { return nil }
        guard let current = selectedTab?.session?.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
              !current.isEmpty else {
            return nil
        }
        let resolved = TerminalSessionModel.resolveStartDirectory(current)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return resolved
    }

}
