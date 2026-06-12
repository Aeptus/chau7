import Foundation
import CryptoKit
import Chau7Core

struct TabRestoreBundleRef: Codable, Equatable {
    let path: String
    let sha256: String
    let byteCount: Int
}

struct PaneRestoreIdentity: Codable, Equatable {
    let paneID: String
    let directory: String
    let aiResumeCommand: String?
    let aiResumeDirectory: String?
    let aiProvider: String?
    let aiSessionId: String?
    let aiSessionIdSource: AISessionIdentitySource?
    let lastOutputAt: Date?
    let lastInputAt: Date?
    let knownRepoRoot: String?
    let knownGitBranch: String?
    let lastStatus: CommandStatus?
    let agentLaunchCommand: String?
    let agentStartedAt: Date?
    let lastExitCode: Int?
    let lastExitAt: Date?
    let contextRef: TabRestoreBundleRef?
}

struct PaneRestoreContext: Codable, Equatable {
    let schemaVersion: Int
    let paneID: String
    let scrollbackContent: String?

    init(paneID: String, scrollbackContent: String?) {
        self.schemaVersion = 1
        self.paneID = paneID
        self.scrollbackContent = scrollbackContent
    }
}

struct TabRestoreContext: Codable, Equatable {
    let schemaVersion: Int
    let tabID: String?
    let scrollbackContent: String?
    let commandBlocks: [CommandBlock]?
    let previewSnapshotPNGData: Data?

    init(
        tabID: String?,
        scrollbackContent: String?,
        commandBlocks: [CommandBlock]?,
        previewSnapshotPNGData: Data?
    ) {
        self.schemaVersion = 1
        self.tabID = tabID
        self.scrollbackContent = scrollbackContent
        self.commandBlocks = commandBlocks
        self.previewSnapshotPNGData = previewSnapshotPNGData
    }
}

struct TabRestoreManifest: Codable, Equatable {
    let tabID: String?
    let selectedTabID: String?
    let customTitle: String?
    let color: String
    let directory: String
    let selectedIndex: Int?
    let tokenOptOverride: String?
    let aiResumeCommand: String?
    let aiProvider: String?
    let aiSessionId: String?
    let aiSessionIdSource: AISessionIdentitySource?
    let splitLayout: SavedSplitNode?
    let focusedPaneID: String?
    let paneIdentities: [PaneRestoreIdentity]?
    let createdAt: String?
    let repoGroupID: String?
    let knownRepoRoot: String?
    let knownGitBranch: String?
    let lastInputAt: Date?
    let lastStatus: CommandStatus?
    let agentLaunchCommand: String?
    let agentStartedAt: Date?
    let lastExitCode: Int?
    let lastExitAt: Date?
    let contextRef: TabRestoreBundleRef?
}

struct TabRestoreBundleEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let savedAt: Date
    let reason: String
    let sourceFingerprint: String
    let windows: [[TabRestoreManifest]]
    /// Token of the save cycle this bundle belongs to. The UserDefaults
    /// restore index stamps the same token on every save, so restore can tell
    /// whether the bundle still reflects the latest save (token equality)
    /// even though unchanged-content saves skip rewriting the sidecars.
    /// Optional: manifests written before this field decode as nil.
    let saveToken: String?

    init(
        savedAt: Date,
        reason: TabStateSaveReason,
        sourceFingerprint: String,
        windows: [[TabRestoreManifest]],
        saveToken: String? = nil
    ) {
        self.schemaVersion = 1
        self.savedAt = savedAt
        self.reason = reason.rawValue
        self.sourceFingerprint = sourceFingerprint
        self.windows = windows
        self.saveToken = saveToken
    }

    /// Copy carrying a refreshed save token + timestamp; used when an
    /// unchanged-content save skips rewriting sidecars but must still mark
    /// the bundle as belonging to the latest save cycle.
    init(refreshing existing: TabRestoreBundleEnvelope, savedAt: Date, saveToken: String?) {
        self.schemaVersion = existing.schemaVersion
        self.savedAt = savedAt
        self.reason = existing.reason
        self.sourceFingerprint = existing.sourceFingerprint
        self.windows = existing.windows
        self.saveToken = saveToken
    }
}

enum TabRestoreBundleStore {
    private static let directoryName = "TabRestoreBundles"
    private static let currentDirectoryName = "current"
    private static let manifestFileName = "manifest.json"

    private static var lastPersistedSourceFingerprint: String?

    static func defaultRootURL() -> URL {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    @discardableResult
    static func persistCurrentBundle(
        windowStates: [[SavedTabState]],
        reason: TabStateSaveReason,
        sourceData: Data?,
        saveToken: String? = nil,
        rootURL: URL = defaultRootURL(),
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> TabRestoreBundleEnvelope? {
        guard !windowStates.isEmpty else {
            try clearCurrentBundle(rootURL: rootURL, fileManager: fileManager)
            return nil
        }

        let sourceFingerprint = try fingerprint(for: windowStates, sourceData: sourceData)
        let currentURL = rootURL.appendingPathComponent(currentDirectoryName, isDirectory: true)
        if sourceFingerprint == lastPersistedSourceFingerprint,
           fileManager.fileExists(atPath: currentURL.appendingPathComponent(manifestFileName).path),
           let existing = loadEnvelope(rootURL: rootURL, fileManager: fileManager) {
            // Content unchanged — skip the sidecar rewrite, but stamp the new
            // save token onto the manifest so the freshness arbiter knows this
            // bundle still belongs to the latest save cycle.
            if let saveToken, existing.saveToken != saveToken {
                let refreshed = TabRestoreBundleEnvelope(refreshing: existing, savedAt: now, saveToken: saveToken)
                try writeJSON(refreshed, to: currentURL.appendingPathComponent(manifestFileName))
                return refreshed
            }
            return existing
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let tempURL = rootURL.appendingPathComponent("current.tmp-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: tempURL)
        try fileManager.createDirectory(at: tempURL, withIntermediateDirectories: true)

        do {
            let envelope = try buildEnvelope(
                windowStates: windowStates,
                reason: reason,
                sourceFingerprint: sourceFingerprint,
                bundleRootURL: tempURL,
                fileManager: fileManager,
                now: now,
                saveToken: saveToken
            )
            try writeJSON(envelope, to: tempURL.appendingPathComponent(manifestFileName))

            // Atomic swap: delete-then-move leaves a no-bundle window if the
            // process dies between the two calls (restore then silently
            // degrades to the scrollback-stripped index). replaceItemAt keeps
            // the old bundle in place until the new one takes over.
            if fileManager.fileExists(atPath: currentURL.path) {
                _ = try fileManager.replaceItemAt(currentURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: currentURL)
            }
            lastPersistedSourceFingerprint = sourceFingerprint
            return envelope
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    static func loadCurrentWindowStates(
        rootURL: URL = defaultRootURL(),
        fileManager: FileManager = .default
    ) -> [[SavedTabState]]? {
        guard let envelope = loadEnvelope(rootURL: rootURL, fileManager: fileManager) else {
            return nil
        }
        let currentURL = rootURL.appendingPathComponent(currentDirectoryName, isDirectory: true)
        return restoreWindowStates(from: envelope, bundleRootURL: currentURL, fileManager: fileManager)
    }

    static func loadEnvelope(
        rootURL: URL = defaultRootURL(),
        fileManager: FileManager = .default
    ) -> TabRestoreBundleEnvelope? {
        let url = rootURL
            .appendingPathComponent(currentDirectoryName, isDirectory: true)
            .appendingPathComponent(manifestFileName)
        // A corrupt manifest must be distinguishable from "no bundle" in the
        // logs — restore silently falling through to the stripped index was
        // undiagnosable when this decode was a bare try?.
        switch Persist.loadLogged(TabRestoreBundleEnvelope.self, from: url, context: "restoreBundle.manifest", decoder: decoder) {
        case .loaded(let envelope):
            return envelope
        case .notFound, .failed:
            return nil
        }
    }

    static func clearCurrentBundle(
        rootURL: URL = defaultRootURL(),
        fileManager: FileManager = .default
    ) throws {
        let currentURL = rootURL.appendingPathComponent(currentDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: currentURL.path) {
            try fileManager.removeItem(at: currentURL)
        }
        lastPersistedSourceFingerprint = nil
    }

    static func resetCacheForTesting() {
        lastPersistedSourceFingerprint = nil
    }

    private static func buildEnvelope(
        windowStates: [[SavedTabState]],
        reason: TabStateSaveReason,
        sourceFingerprint: String,
        bundleRootURL: URL,
        fileManager: FileManager,
        now: Date,
        saveToken: String? = nil
    ) throws -> TabRestoreBundleEnvelope {
        let windows = try windowStates.enumerated().map { windowIndex, states in
            try states.enumerated().map { tabIndex, state in
                try manifest(
                    from: state,
                    windowIndex: windowIndex,
                    tabIndex: tabIndex,
                    bundleRootURL: bundleRootURL,
                    fileManager: fileManager
                )
            }
        }
        return TabRestoreBundleEnvelope(
            savedAt: now,
            reason: reason,
            sourceFingerprint: sourceFingerprint,
            windows: windows,
            saveToken: saveToken
        )
    }

    private static func manifest(
        from state: SavedTabState,
        windowIndex: Int,
        tabIndex: Int,
        bundleRootURL: URL,
        fileManager: FileManager
    ) throws -> TabRestoreManifest {
        let tabComponent = stableComponent(
            state.tabID,
            fallback: "window-\(windowIndex)-tab-\(tabIndex)"
        )
        let tabContext = TabRestoreContext(
            tabID: state.tabID,
            scrollbackContent: state.scrollbackContent,
            commandBlocks: state.commandBlocks,
            previewSnapshotPNGData: state.previewSnapshotPNGData
        )
        let tabContextRef = try writeContextIfNeeded(
            tabContext,
            hasContent: tabContext.scrollbackContent != nil
                || tabContext.commandBlocks?.isEmpty == false
                || tabContext.previewSnapshotPNGData != nil,
            relativePath: "contexts/windows/\(windowIndex)/tabs/\(tabComponent)/tab.json",
            bundleRootURL: bundleRootURL,
            fileManager: fileManager
        )

        let paneIdentities = try state.paneStates?.enumerated().map { paneIndex, pane in
            try paneIdentity(
                from: pane,
                paneIndex: paneIndex,
                tabComponent: tabComponent,
                windowIndex: windowIndex,
                bundleRootURL: bundleRootURL,
                fileManager: fileManager
            )
        }

        return TabRestoreManifest(
            tabID: state.tabID,
            selectedTabID: state.selectedTabID,
            customTitle: state.customTitle,
            color: state.color,
            directory: state.directory,
            selectedIndex: state.selectedIndex,
            tokenOptOverride: state.tokenOptOverride,
            aiResumeCommand: state.aiResumeCommand,
            aiProvider: state.aiProvider,
            aiSessionId: state.aiSessionId,
            aiSessionIdSource: state.aiSessionIdSource,
            splitLayout: state.splitLayout,
            focusedPaneID: state.focusedPaneID,
            paneIdentities: paneIdentities,
            createdAt: state.createdAt,
            repoGroupID: state.repoGroupID,
            knownRepoRoot: state.knownRepoRoot,
            knownGitBranch: state.knownGitBranch,
            lastInputAt: state.lastInputAt,
            lastStatus: state.lastStatus,
            agentLaunchCommand: state.agentLaunchCommand,
            agentStartedAt: state.agentStartedAt,
            lastExitCode: state.lastExitCode,
            lastExitAt: state.lastExitAt,
            contextRef: tabContextRef
        )
    }

    private static func paneIdentity(
        from pane: SavedTerminalPaneState,
        paneIndex: Int,
        tabComponent: String,
        windowIndex: Int,
        bundleRootURL: URL,
        fileManager: FileManager
    ) throws -> PaneRestoreIdentity {
        let paneComponent = stableComponent(pane.paneID, fallback: "pane-\(paneIndex)")
        let paneContext = PaneRestoreContext(
            paneID: pane.paneID,
            scrollbackContent: pane.scrollbackContent
        )
        let paneContextRef = try writeContextIfNeeded(
            paneContext,
            hasContent: paneContext.scrollbackContent != nil,
            relativePath: "contexts/windows/\(windowIndex)/tabs/\(tabComponent)/panes/\(paneComponent).json",
            bundleRootURL: bundleRootURL,
            fileManager: fileManager
        )

        return PaneRestoreIdentity(
            paneID: pane.paneID,
            directory: pane.directory,
            aiResumeCommand: pane.aiResumeCommand,
            aiResumeDirectory: pane.aiResumeDirectory,
            aiProvider: pane.aiProvider,
            aiSessionId: pane.aiSessionId,
            aiSessionIdSource: pane.aiSessionIdSource,
            lastOutputAt: pane.lastOutputAt,
            lastInputAt: pane.lastInputAt,
            knownRepoRoot: pane.knownRepoRoot,
            knownGitBranch: pane.knownGitBranch,
            lastStatus: pane.lastStatus,
            agentLaunchCommand: pane.agentLaunchCommand,
            agentStartedAt: pane.agentStartedAt,
            lastExitCode: pane.lastExitCode,
            lastExitAt: pane.lastExitAt,
            contextRef: paneContextRef
        )
    }

    private static func restoreWindowStates(
        from envelope: TabRestoreBundleEnvelope,
        bundleRootURL: URL,
        fileManager: FileManager
    ) -> [[SavedTabState]]? {
        guard envelope.schemaVersion == 1 else { return nil }
        var windows: [[SavedTabState]] = []
        for window in envelope.windows {
            var states: [SavedTabState] = []
            for manifest in window {
                guard let state = restoreTabState(
                    from: manifest,
                    bundleRootURL: bundleRootURL,
                    fileManager: fileManager
                ) else {
                    return nil
                }
                states.append(state)
            }
            windows.append(states)
        }
        return windows
    }

    private static func restoreTabState(
        from manifest: TabRestoreManifest,
        bundleRootURL: URL,
        fileManager: FileManager
    ) -> SavedTabState? {
        let tabContext: TabRestoreContext?
        if let ref = manifest.contextRef {
            guard let decoded = readContext(
                TabRestoreContext.self,
                ref: ref,
                bundleRootURL: bundleRootURL,
                fileManager: fileManager
            ) else {
                return nil
            }
            tabContext = decoded
        } else {
            tabContext = nil
        }

        let paneStates: [SavedTerminalPaneState]?
        if let identities = manifest.paneIdentities {
            var panes: [SavedTerminalPaneState] = []
            for identity in identities {
                let paneContext: PaneRestoreContext?
                if let ref = identity.contextRef {
                    guard let decoded = readContext(
                        PaneRestoreContext.self,
                        ref: ref,
                        bundleRootURL: bundleRootURL,
                        fileManager: fileManager
                    ) else {
                        return nil
                    }
                    paneContext = decoded
                } else {
                    paneContext = nil
                }
                panes.append(SavedTerminalPaneState(
                    paneID: identity.paneID,
                    directory: identity.directory,
                    scrollbackContent: paneContext?.scrollbackContent,
                    aiResumeCommand: identity.aiResumeCommand,
                    aiResumeDirectory: identity.aiResumeDirectory,
                    aiProvider: identity.aiProvider,
                    aiSessionId: identity.aiSessionId,
                    aiSessionIdSource: identity.aiSessionIdSource,
                    lastOutputAt: identity.lastOutputAt,
                    lastInputAt: identity.lastInputAt,
                    knownRepoRoot: identity.knownRepoRoot,
                    knownGitBranch: identity.knownGitBranch,
                    lastStatus: identity.lastStatus,
                    agentLaunchCommand: identity.agentLaunchCommand,
                    agentStartedAt: identity.agentStartedAt,
                    lastExitCode: identity.lastExitCode,
                    lastExitAt: identity.lastExitAt
                ))
            }
            paneStates = panes
        } else {
            paneStates = nil
        }

        return SavedTabState(
            tabID: manifest.tabID,
            selectedTabID: manifest.selectedTabID,
            customTitle: manifest.customTitle,
            color: manifest.color,
            directory: manifest.directory,
            selectedIndex: manifest.selectedIndex,
            tokenOptOverride: manifest.tokenOptOverride,
            scrollbackContent: tabContext?.scrollbackContent,
            aiResumeCommand: manifest.aiResumeCommand,
            aiProvider: manifest.aiProvider,
            aiSessionId: manifest.aiSessionId,
            aiSessionIdSource: manifest.aiSessionIdSource,
            splitLayout: manifest.splitLayout,
            focusedPaneID: manifest.focusedPaneID,
            paneStates: paneStates,
            createdAt: manifest.createdAt,
            repoGroupID: manifest.repoGroupID,
            knownRepoRoot: manifest.knownRepoRoot,
            knownGitBranch: manifest.knownGitBranch,
            lastInputAt: manifest.lastInputAt,
            lastStatus: manifest.lastStatus,
            agentLaunchCommand: manifest.agentLaunchCommand,
            agentStartedAt: manifest.agentStartedAt,
            lastExitCode: manifest.lastExitCode,
            lastExitAt: manifest.lastExitAt,
            commandBlocks: tabContext?.commandBlocks,
            previewSnapshotPNGData: tabContext?.previewSnapshotPNGData
        )
    }

    private static func writeContextIfNeeded(
        _ context: some Encodable,
        hasContent: Bool,
        relativePath: String,
        bundleRootURL: URL,
        fileManager: FileManager
    ) throws -> TabRestoreBundleRef? {
        guard hasContent else { return nil }
        let data = try encoder.encode(context)
        let url = bundleRootURL.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return TabRestoreBundleRef(
            path: relativePath,
            sha256: sha256Hex(data),
            byteCount: data.count
        )
    }

    private static func readContext<T: Decodable>(
        _ type: T.Type,
        ref: TabRestoreBundleRef,
        bundleRootURL: URL,
        fileManager: FileManager
    ) -> T? {
        let url = bundleRootURL.appendingPathComponent(ref.path)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            Log.error("restoreBundle.context missing/unreadable path=\(ref.path)")
            return nil
        }
        guard data.count == ref.byteCount, sha256Hex(data) == ref.sha256 else {
            Log.error("restoreBundle.context integrity mismatch path=\(ref.path) bytes=\(data.count)/\(ref.byteCount)")
            return nil
        }
        return Persist.decodeLogged(type, from: data, context: "restoreBundle.context(\(ref.path))", decoder: decoder)
    }

    private static func writeJSON(_ value: some Encodable, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func fingerprint(for windowStates: [[SavedTabState]], sourceData: Data?) throws -> String {
        if let sourceData {
            return sha256Hex(sourceData)
        }
        let data = try encoder.encode(SavedMultiWindowState(windows: windowStates))
        return sha256Hex(data)
    }

    private static func stableComponent(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String
        if let trimmed, !trimmed.isEmpty {
            source = trimmed
        } else {
            source = fallback
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = source.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let normalized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? fallback : String(normalized.prefix(96))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
