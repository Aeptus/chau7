import Foundation
import Chau7Core

/// Static tab-state backup machinery extracted from `OverlayTabsModel`.
///
/// Owns the on-disk backup directory (`latest.json` + `archive/`), the
/// UserDefaults/backup restore-candidate chain, the AI-resume-metadata
/// merge/repair passes, and the archive throttle bookkeeping. All members
/// are `static` and pure (no `OverlayTabsModel` instance state); the
/// hydration layer that turns `[SavedTabState]` into live `OverlayTab`s
/// stays on `OverlayTabsModel` (`decodeRestorableTabs` / `restoreSavedTabs`),
/// which calls into this store for the merge/repair/persist primitives.
///
/// The single-model save path (`saveTabState`/instance `persistTabStateBackups`)
/// is gone: it had zero production callers and maintained instance-level
/// archive fingerprints parallel to the static multi-window pair used by
/// `persistWindowStateBackups` — two accounting systems for the same
/// archive directory, waiting to desync the 300s/dedup throttles. This store
/// is now the single accounting system for the window-state archive; the
/// instance save path in `OverlayTabsModel` writes the restore index/bundle
/// and is deliberately kept separate (do not unify the two).
enum TabStateBackupStore {

    // Archive throttle bookkeeping. Read by `shouldArchiveMultiWindowBackup`,
    // written by `persistWindowStateBackups` — the single accounting pair for
    // the window-state archive directory.
    static var lastArchivedMultiWindowTabStateFingerprint: Int?
    static var lastArchivedMultiWindowTabStateAt: Date = .distantPast

    static func restoreAdditionalWindowStatesFromBackups() -> [[SavedTabState]]? {
        guard let windows = mergedBackupWindowStatesFromCandidates(),
              windows.count > 1 else {
            return nil
        }
        Log.info("Recovered \(windows.count) window state set(s) from merged backup candidates")
        return windows
    }

    static func mergedBackupWindowStatesFromCandidates() -> [[SavedTabState]]? {
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

    static func mergedWindowStatesWithBackupFallbacks(baseWindows: [[SavedTabState]]) -> [[SavedTabState]] {
        let decodedCandidates = tabStateRestoreCandidateURLs().compactMap { url -> [[SavedTabState]]? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decodeBackupWindowStates(from: data)
        }
        return mergedWindowStates(baseWindows: baseWindows, fallbackCandidates: decodedCandidates)
    }

    static func mergedWindowStates(
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

    static func maybeRepairLatestBackup(baseWindows: [[SavedTabState]], mergedWindows: [[SavedTabState]]) {
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

    static func maybeRepairUserDefaultsMultiWindowState(
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

    static func maybeRepairUserDefaultsSingleWindowState(
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

    static func aiResumePayloadScore(in windows: [[SavedTabState]]) -> Int {
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
        UserDefaults.standard.removeObject(forKey: SavedTabState.restoreIndexSaveTokenKey)
        try? TabRestoreBundleStore.clearCurrentBundle()
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
}
