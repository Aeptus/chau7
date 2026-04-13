import Foundation
import Chau7Core

// MARK: - Session Finder Registry

extension OverlayTabsModel {

    // MARK: - Session Finder Registry

    static var sessionFinderLock = NSLock()
    static var sessionFinders: [String: (String, Date?, Set<String>) -> String?] = [:]

    static func registerSessionFinder(
        forProviderKey key: String,
        finder: @escaping (String, Date?, Set<String>) -> String?
    ) {
        sessionFinderLock.lock()
        defer { sessionFinderLock.unlock() }
        sessionFinders[key] = finder
    }

    static func findAIResumeSessionId(
        for provider: String,
        directory: String,
        referenceDate: Date?,
        claimedSessionIds: Set<String> = []
    ) -> String? {
        sessionFinderLock.lock()
        let finder = sessionFinders[provider]
        sessionFinderLock.unlock()
        return finder?(directory, referenceDate, claimedSessionIds)
    }

    static func normalizedAIProvider(from value: String?) -> String? {
        guard let value else { return nil }
        return AIResumeParser.normalizeProviderName(value)
    }

    static func normalizeAISessionId(_ sessionId: String?) -> String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIResumeParser.isValidSessionId(trimmed) else { return nil }
        return trimmed
    }

    static func normalizePersistedAISessionId(
        _ sessionId: String?,
        source: AISessionIdentitySource?
    ) -> String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if AIResumeParser.isValidSessionId(trimmed) {
            return trimmed
        }
        if source == .synthetic, trimmed.hasPrefix("synth:") {
            return trimmed
        }
        return nil
    }

    static func findClaudeSessionId(
        forDirectory directory: String,
        referenceDate: Date? = nil,
        claimedSessionIds: Set<String> = []
    ) -> String? {
        let canonicalDirectory = normalizedSessionDirectory(directory)
        guard !canonicalDirectory.isEmpty else { return nil }

        let matches = ClaudeCodeMonitor.shared
            .sessionCandidates(forDirectory: canonicalDirectory)
            .compactMap { candidate -> (sessionId: String, touchedAt: Date)? in
                guard let normalizedSessionId = normalizeAISessionId(candidate.sessionId) else {
                    return nil
                }
                guard !claimedSessionIds.contains(normalizedSessionId) else { return nil }
                return (sessionId: normalizedSessionId, touchedAt: candidate.lastActivity)
            }

        guard !matches.isEmpty else { return nil }

        if let chosen = AIResumeParser.bestSessionMatch(candidates: matches, referenceDate: referenceDate) {
            if matches.count > 1 {
                Log.trace(
                    "findClaudeSessionId: selected sessionId=\(chosen) from \(matches.count) candidates for dir=\(canonicalDirectory)"
                )
            }
            return chosen
        }

        Log.warn("findClaudeSessionId: multiple session candidates for dir=\(canonicalDirectory); skipping to avoid cross-tab contamination")
        return nil
    }

    static func detectAIAppName(fromOutput output: String?) -> String? {
        guard let output else { return nil }
        return CommandDetection.detectAppFromOutput(output)
    }

    static func normalizedSessionDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = RuntimeIsolation.expandTilde(in: trimmed)
        return URL(fileURLWithPath: expanded).standardized.path
    }

    static func isSameSessionDirectory(_ lhs: String, as rhs: String) -> Bool {
        let left = normalizedSessionDirectory(lhs)
        let right = normalizedSessionDirectory(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.hasPrefix(right + "/")
    }

    static func isValidSessionId(_ id: String) -> Bool {
        AIResumeParser.isValidSessionId(id)
    }

    /// Find the most recent Codex session ID for a given directory.
    /// Scans ~/.codex/sessions/ day directories for session files whose
    /// cwd matches the given directory. Caps total file reads to avoid
    /// blocking the main thread.
    static func findCodexSessionId(
        forDirectory dir: String,
        referenceDate: Date? = nil,
        claimedSessionIds: Set<String> = []
    ) -> String? {
        let fm = FileManager.default
        let sessionsDir = RuntimeIsolation.urlInHome(".codex/sessions", fileManager: fm)

        // Filter helper: only include entries that look like date components (digits only)
        let isDateComponent = { (name: String) -> Bool in
            !name.isEmpty && name.allSatisfy(\.isNumber)
        }

        // Collect year/month/day directories, sorted most-recent-first
        guard let years = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else { return nil }
        var dayDirs: [URL] = []
        for year in years.filter(isDateComponent).sorted().reversed() {
            let yearURL = sessionsDir.appendingPathComponent(year)
            guard let months = try? fm.contentsOfDirectory(atPath: yearURL.path) else { continue }
            for month in months.filter(isDateComponent).sorted().reversed() {
                let monthURL = yearURL.appendingPathComponent(month)
                guard let days = try? fm.contentsOfDirectory(atPath: monthURL.path) else { continue }
                for day in days.filter(isDateComponent).sorted().reversed() {
                    dayDirs.append(monthURL.appendingPathComponent(day))
                }
            }
        }

        // Scan the 7 most recent day directories, capping total file reads
        var filesRead = 0
        var parsedLines = 0
        var matches: [(sessionId: String, touchedAt: Date, rank: Int)] = []
        let maxFileReads = 30
        for dayDir in dayDirs.prefix(7) {
            guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
            // Sort files reverse-alphabetically (most recent timestamp first)
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }.sorted().reversed()
            for file in jsonlFiles {
                guard filesRead < maxFileReads else { return nil }
                filesRead += 1
                let filePath = dayDir.appendingPathComponent(file).path
                guard let firstLine = readFirstLine(atPath: filePath) else { continue }
                parsedLines += 1
                // Parse session_meta to extract cwd and id
                if let (sessionCwd, sessionId) = parseCodexSessionMeta(firstLine),
                   let rank = DirectoryPathMatcher.bidirectionalPrefixRank(
                       targetPath: dir,
                       candidatePath: sessionCwd
                   ),
                   !claimedSessionIds.contains(sessionId) {
                    let touchedAt = (try? FileManager.default.attributesOfItem(atPath: filePath)[.modificationDate] as? Date) ?? Date.distantPast
                    matches.append((sessionId: sessionId, touchedAt: touchedAt, rank: rank))
                }
            }
        }

        if matches.isEmpty {
            if filesRead == 0 {
                Log.warn("findCodexSessionId: no .jsonl files found in recent directories for dir=\(dir)")
            } else if parsedLines == 0 {
                Log.warn("findCodexSessionId: no readable first lines found while scanning \(filesRead) files for dir=\(dir)")
            } else {
                Log.trace("findCodexSessionId: scanned \(filesRead) files without finding a session_meta match for dir=\(dir)")
            }
            return nil
        }

        let bestRank = matches.map(\.rank).min()
        let rankedMatches = bestRank.map { rank in
            matches
                .filter { $0.rank == rank }
                .map { (sessionId: $0.sessionId, touchedAt: $0.touchedAt) }
        } ?? []

        if let chosen = AIResumeParser.bestSessionMatch(candidates: rankedMatches, referenceDate: referenceDate) {
            if rankedMatches.count > 1 {
                Log.trace("findCodexSessionId: selected sessionId=\(chosen) from \(matches.count) candidates using activity hint for dir=\(dir)")
            }
            return chosen
        }

        Log.warn("findCodexSessionId: multiple session candidates for dir=\(dir); skipping to avoid cross-tab contamination")
        return nil
    }

    /// Read just the first line of a file without loading the entire contents.
    static func readFirstLine(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        // Large JSONL session files can exceed small read buffers due embedded
        // instructions/context, so read until the first newline (or a safe cap).
        let chunkSize = 4096
        let maxLineBytes = 262_144
        var buffer = Data()

        while buffer.count < maxLineBytes {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)

            if let newlineIndex = buffer.firstIndex(of: 10) {
                buffer = Data(buffer.prefix(upTo: newlineIndex))
                break
            }

            if buffer.count >= maxLineBytes {
                Log.warn(
                    """
                    findCodexSessionId: first line exceeded cap while reading \
                    \"\(path)\" (bufferBytes=\(buffer.count), cap=\(maxLineBytes))
                    """
                )
                break
            }
        }

        guard !buffer.isEmpty else { return nil }

        return readFirstLine(from: buffer)
    }

    static func readFirstLine(from data: Data, maxBytes: Int = 262_144) -> String? {
        guard data.count <= maxBytes else {
            return nil
        }

        guard !data.isEmpty else { return nil }

        if let newlineIndex = data.firstIndex(of: 10) {
            return String(decoding: data[..<newlineIndex], as: UTF8.self)
        }

        return String(decoding: data, as: UTF8.self)
    }

    /// Parse the first line of a Codex session file (session_meta JSON)
    /// to extract the cwd and session ID.
    static func parseCodexSessionMeta(_ line: String) -> (cwd: String, id: String)? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "session_meta",
              let payload = json["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              let id = payload["id"] as? String else {
            return nil
        }
        let normalizedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCwd.isEmpty, AIResumeParser.isValidSessionId(normalizedId) else {
            return nil
        }
        return (normalizedCwd, normalizedId)
    }

    static func captureScrollback(from session: TerminalSessionModel?, maxLines: Int) -> String? {
        guard maxLines > 0, let session, let data = session.captureRemoteSnapshot() else {
            return nil
        }

        let text = String(decoding: data, as: UTF8.self)
        // Strip trailing whitespace from each line — the terminal grid pads rows
        // to the full column width with spaces. Without this, injected scrollback
        // has 200+ trailing spaces per line that push content to wrong positions.
        var lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }

        // Strip lines that are restore command artifacts — previous launches may
        // have echoed cd/stty commands that were captured in the scrollback.
        lines = lines.filter { !Self.isRestoreArtifactLine($0) }

        // Strip trailing empty lines — the terminal buffer includes blank lines below
        // the cursor, which can otherwise pollute restore output.
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }

        if lines.isEmpty {
            return nil
        }

        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }

        var restored = lines.joined(separator: "\n")
        if restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        // Cap total size to avoid UserDefaults bloat (500KB per tab max)
        if restored.utf8.count > 500_000 {
            let reducedLineCount = max(1, maxLines / 2)
            restored = restored.components(separatedBy: "\n").suffix(reducedLineCount).joined(separator: "\n")
        }

        return restored
    }

    /// Returns true if a scrollback line looks like a restore command artifact
    /// (cd + clear chains, stty echo pairs) that should be filtered out.
    private static func isRestoreArtifactLine(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        if stripped.contains("stty -echo && "), stripped.contains("stty echo") { return true }
        if stripped.contains(" cd '"), stripped.hasSuffix("&& clear") { return true }
        return false
    }

    /// Strips restore command artifacts from scrollback content.
    /// Used on both save (captureScrollback) and inject (restore) paths to handle
    /// scrollback saved by older binaries that didn't have the save-side filter.
    static func stripRestoreArtifacts(from content: String) -> String {
        content.components(separatedBy: "\n")
            .filter { !isRestoreArtifactLine($0) }
            .joined(separator: "\n")
    }

    static func shellSafeSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let restoreDelaySeconds: TimeInterval = 0.8
    static let resumeCommandDelaySeconds: TimeInterval = 0.6
    static let resumeCommandRetryDelaySeconds: TimeInterval = 0.5
    static let resumeCommandMaxRetryDelay: TimeInterval = 4.0
    static let resumeCommandMaxAttempts = 16

    static func paneStateMap(from states: [SavedTerminalPaneState]?) -> [UUID: SavedTerminalPaneState] {
        guard let states else { return [:] }
        var map: [UUID: SavedTerminalPaneState] = [:]
        for state in states {
            guard let uuid = UUID(uuidString: state.paneID) else { continue }
            map[uuid] = state
        }
        return map
    }

    /// Restores tabs from saved state. Returns nil if no saved state exists
    /// or if decoding fails.
    static func restoreSavedTabs(appModel: AppModel) -> RestorableTabsPayload? {
        guard let data = UserDefaults.standard.data(forKey: SavedTabState.userDefaultsKey) else {
            return restoreSavedTabsFromBackups(appModel: appModel)
        }
        archiveImportedTabStateIfNeeded(data)
        // Clear saved state immediately so a crash during restoration
        // doesn't cause an infinite crash loop
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)

        if let payload = decodeRestorableTabs(from: data, appModel: appModel) {
            return payload
        }
        return restoreSavedTabsFromBackups(appModel: appModel)
    }

    /// Decode from pre-decoded states (multi-window restore — avoids UserDefaults round-trip).
    static func decodeRestorableTabs(fromStates states: [SavedTabState], appModel: AppModel) -> RestorableTabsPayload? {
        guard !states.isEmpty else { return nil }
        // Re-encode to reuse the existing decode path (the processing after
        // JSON decode is non-trivial and not worth duplicating).
        guard let data = try? JSONEncoder().encode(states) else { return nil }
        return decodeRestorableTabs(from: data, appModel: appModel)
    }

    static func decodeRestorableTabs(from data: Data, appModel: AppModel) -> RestorableTabsPayload? {
        guard let states = try? JSONDecoder().decode([SavedTabState].self, from: data),
              !states.isEmpty else {
            return nil
        }

        let colors = TabColor.allCases
        var restoredTabs: [OverlayTab] = []
        var selectedID: UUID?
        var fallbackSelectedIndex: Int?
        var persistedStates: [SavedTabState] = []

        for (i, state) in states.enumerated() {
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
            tab.color = TabColor(rawValue: state.color) ?? colors[i % colors.count]
            tab.stampOwnerTabID()

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
        for url in tabStateRestoreCandidateURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let windows = decodeBackupWindowStates(from: data), windows.count > 1 else { continue }
            Log.info("Recovered \(windows.count) window state set(s) from backup file \(url.lastPathComponent)")
            return windows
        }
        return nil
    }

    static func restoreSavedTabsFromBackups(appModel: AppModel) -> RestorableTabsPayload? {
        for url in tabStateRestoreCandidateURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let windows = decodeBackupWindowStates(from: data) else { continue }
            for windowStates in windows where !windowStates.isEmpty {
                guard let payload = decodeRestorableTabs(fromStates: windowStates, appModel: appModel) else { continue }
                Log.info("Restored \(payload.tabs.count) tab(s) from backup file \(url.lastPathComponent)")
                return payload
            }
        }
        return nil
    }

    static func decodeBackupWindowStates(from data: Data) -> [[SavedTabState]]? {
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
        let payload: Data
        do {
            if windowStates.count == 1 {
                payload = try JSONEncoder().encode(windowStates[0])
            } else {
                payload = try JSONEncoder().encode(SavedMultiWindowState(windows: windowStates))
            }
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
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("TabStateBackups", isDirectory: true)
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

    func restoreTabState(for tab: OverlayTab, state: SavedTabState) {
        let targetTabID = tab.id
        let terminalSessions = tab.splitController.terminalSessions
        Log.info("restoreTabState: scheduled for tab=\(targetTabID), panes=\(terminalSessions.count)")
        guard !terminalSessions.isEmpty else { return }

        // Keep the restored focus for the active terminal pane (or fallback to
        // first terminal if an editor pane was serialized).
        if let restoredFocus = state.focusedPaneID.flatMap(UUID.init),
           tab.splitController.root.paneType(for: restoredFocus) == .terminal {
            tab.splitController.setFocusedPane(restoredFocus)
        }

        let paneStatesByID = Self.paneStateMap(from: state.paneStates)
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

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelaySeconds) { [weak self] in
            guard let self else { return }
            let restoreStartedAt = CFAbsoluteTimeGetCurrent()
            defer {
                FeatureProfiler.shared.recordMainThreadStallIfNeeded(
                    operation: "OverlayTabsModel.restoreTabState",
                    startedAt: restoreStartedAt,
                    thresholdMs: 150,
                    metadata: "tab=\(targetTabID) panes=\(terminalSessions.count)"
                )
            }
            guard let restoredTab = tabs.first(where: { $0.id == targetTabID }) else {
                Log.warn("restoreTabState: tab no longer exists for id=\(targetTabID)")
                return
            }

            if let restoredBlocks = state.commandBlocks {
                MainActor.assumeIsolated {
                    CommandBlockManager.shared.restoreBlocks(restoredBlocks, for: targetTabID.uuidString)
                }
            } else {
                MainActor.assumeIsolated {
                    CommandBlockManager.shared.clearBlocks(tabID: targetTabID.uuidString)
                }
            }

            let currentSessions = restoredTab.splitController.terminalSessions
            guard !currentSessions.isEmpty else {
                Log.warn("restoreTabState: tab \(targetTabID) has no terminal sessions")
                return
            }

            let restoredFocus = state.focusedPaneID.flatMap(UUID.init)
            let activePaneID: UUID = if let restoredFocus,
                                        restoredTab.splitController.root.paneType(for: restoredFocus) == .terminal {
                restoredFocus
            } else {
                restoredTab.splitController.focusedTerminalSessionID() ?? currentSessions[0].0
            }

            if restoredTab.splitController.root.paneType(for: activePaneID) == .terminal {
                restoredTab.splitController.setFocusedPane(activePaneID)
            }

            var resolvedPaneStates: [UUID: SavedTerminalPaneState] = [:]
            for (paneID, session) in currentSessions {
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
                    lastExitAt: paneState.lastExitAt
                )

                let effectivePaneState = SavedTerminalPaneState(
                    paneID: paneState.paneID,
                    directory: paneState.directory,
                    scrollbackContent: paneState.scrollbackContent,
                    aiResumeCommand: resolvedCommand ?? Self.normalizedResumeCommand(paneState.aiResumeCommand),
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

            let normalizedResumeCommands = resolvedPaneStates.compactMap { paneID, paneState -> (UUID, String)? in
                guard let candidate = Self.normalizedResumeCommand(paneState.aiResumeCommand) else {
                    return nil
                }
                return (paneID, candidate)
            }
            let resumeTarget = normalizedResumeCommands.first(where: { $0.0 == activePaneID })
            if resumeTarget == nil {
                Log.info("restoreTabState: no resume command candidate found for tab=\(targetTabID)")
            }

            let restoreToken = UUID().uuidString
            for (paneID, session) in currentSessions {
                let effectivePaneState = resolvedPaneStates[paneID] ?? SavedTerminalPaneState(
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

                // Restore scrollback by injecting directly into the terminal
                // emulator via injectOutput — bypasses the shell entirely.
                // No stty, no temp files, no echo race.
                // Strip restore artifacts from saved scrollback that may have
                // been captured by an older binary before the save-side filter.
                if let raw = effectivePaneState.scrollbackContent,
                   !raw.isEmpty {
                    let scrollback = Self.stripRestoreArtifacts(from: raw)
                    if !scrollback.isEmpty {
                        if let view = session.existingRustTerminalView {
                            view.injectOutput(scrollback)
                        } else {
                            session.pendingRestoreScrollback = scrollback
                        }
                    }
                }

                // Restore CWD via minimal shell input. Leading space
                // suppresses shell history (HIST_IGNORE_SPACE).
                // No clear — the injected scrollback is already in the buffer
                // and clear would flash a visible echo before wiping it.
                if !effectivePaneState.directory.isEmpty {
                    session.sendOrQueueSystemRestoreInput(
                        " cd \(Self.shellSafeSingleQuote(effectivePaneState.directory))\n"
                    )
                }

                if let (resumePaneID, resumeCommand) = resumeTarget,
                   resumePaneID == paneID {
                    Log.info("restoreTabState: scheduling resume command for tab=\(targetTabID) pane=\(paneID)")
                    latestRestoreResumeTokenByPaneID[paneID] = restoreToken
                    scheduleResumeCommand(
                        command: resumeCommand,
                        targetTabID: targetTabID,
                        paneID: paneID,
                        restoreToken: restoreToken,
                        remainingAttempts: Self.resumeCommandMaxAttempts,
                        delay: Self.resumeCommandDelaySeconds
                    )
                }
            }

            // Assign render tiers for this window's tabs now that sessions
            // have views attached. Without this, non-primary windows never
            // get updateSuspensionState called and all tabs stay at .active.
            computeAndApplyRenderTiers()
        }
    }

    func scheduleResumeCommand(
        command: String,
        targetTabID: UUID,
        paneID: UUID,
        restoreToken: String,
        remainingAttempts: Int,
        delay: TimeInterval = 0
    ) {
        guard remainingAttempts > 0 else {
            // Last resort: queue the command so the session's own retry logic
            // can deliver it when the terminal becomes ready (e.g. tab unsuspends).
            if let tab = tabs.first(where: { $0.id == targetTabID }),
               let session = tab.splitController.root.findSession(id: paneID) {
                session.prefillInput(command)
                StartupRestoreCoordinator.shared.noteQueuedResumePrefill()
                Log.warn("restoreTabState: retries exhausted, queued prefill for tab=\(targetTabID) pane=\(paneID)")
            } else {
                Log.warn("restoreTabState: retries exhausted, tab/pane gone for tab=\(targetTabID) pane=\(paneID)")
            }
            latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard latestRestoreResumeTokenByPaneID[paneID] == restoreToken else {
                Log.trace("restoreTabState: skipping stale resume prefill for tab=\(targetTabID) pane=\(paneID)")
                return
            }

            guard let restoredTab = tabs.first(where: { $0.id == targetTabID }) else {
                Log.warn("restoreTabState: cannot send resume command for missing tab=\(targetTabID)")
                latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                return
            }

            guard let reResolvedSession = restoredTab.splitController.root.findSession(id: paneID) else {
                Log.warn("restoreTabState: cannot find pane=\(paneID) for tab=\(targetTabID)")
                latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                return
            }

            if !reResolvedSession.canPrefillInput() {
                let hasView = reResolvedSession.existingRustTerminalView != nil

                // No view means this tab is outside the nearby rendering range.
                if !hasView {
                    switch StartupRestoreCoordinator.shared.noViewResumeDecision(remainingAttempts: remainingAttempts) {
                    case .retryWaitingForView:
                        let nextDelay = min(delay + 0.15, 0.75)
                        Log.trace(
                            "restoreTabState: waiting for view before resume prefill for tab=\(targetTabID) pane=\(paneID) retry in \(String(format: "%.2f", nextDelay))s"
                        )
                        scheduleResumeCommand(
                            command: command,
                            targetTabID: targetTabID,
                            paneID: paneID,
                            restoreToken: restoreToken,
                            remainingAttempts: remainingAttempts - 1,
                            delay: nextDelay
                        )
                        return
                    case .queueSessionPrefill:
                        // Delegate to the session's pending prefill mechanism which will
                        // deliver the command when the view is eventually created via
                        // attachRustTerminal → flushPendingPrefillInputIfReady.
                        reResolvedSession.prefillInput(command)
                        StartupRestoreCoordinator.shared.noteQueuedResumePrefill()
                        latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                        Log.info("restoreTabState: no view for tab=\(targetTabID) pane=\(paneID), queued session-level prefill")
                        return
                    }
                }

                let nextDelay = min(delay + Self.resumeCommandRetryDelaySeconds, Self.resumeCommandMaxRetryDelay)
                let message =
                    """
                    restoreTabState: resume command not ready for tab=\(targetTabID) pane=\(paneID) \
                    (loading=\(reResolvedSession.isShellLoading), atPrompt=\(reResolvedSession.isAtPrompt), \
                    status=\(reResolvedSession.status), hasView=\(hasView)); \
                    retry in \(String(format: "%.2f", nextDelay))s
                    """
                if StartupRestoreCoordinator.shared.shouldWarnAboutResumeNotReady() {
                    Log.warn(message)
                } else {
                    Log.trace(message)
                }
                scheduleResumeCommand(
                    command: command,
                    targetTabID: targetTabID,
                    paneID: paneID,
                    restoreToken: restoreToken,
                    remainingAttempts: remainingAttempts - 1,
                    delay: nextDelay
                )
                return
            }

            // Prefill the command in the active terminal so user can confirm with Enter.
            reResolvedSession.prefillInput(command)
            StartupRestoreCoordinator.shared.noteDeliveredResumePrefill()
            latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
            Log.info("restoreTabState: resume command prefilling for tab=\(targetTabID) pane=\(paneID)")
        }
    }

    static func normalizedResumeCommand(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isSafeResumeCommand(trimmed) else { return nil }
        return trimmed
    }

    static func isSafeResumeCommand(_ command: String) -> Bool {
        if let sessionId = command.extractResumeSessionId(prefix: "claude --resume ") {
            return isValidSessionId(sessionId)
        }
        if let sessionId = command.extractResumeSessionId(prefix: "codex resume ") {
            return isValidSessionId(sessionId)
        }
        return false
    }

    var selectedTab: OverlayTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func notificationTabTitle(for target: TabTarget) -> String? {
        TabResolver.resolve(target, in: tabs)?.displayTitle
    }

    func notificationRepoName(for target: TabTarget) -> String? {
        guard let tab = TabResolver.resolve(target, in: tabs),
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
