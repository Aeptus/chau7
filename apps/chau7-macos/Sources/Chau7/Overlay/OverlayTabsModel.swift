import Foundation
import AppKit
import Chau7Core
import SwiftUI

// MARK: - Tab Notification Styling

/// Visual styling that can be applied to a tab via the notification system.
/// Use this to indicate states like "waiting for input", "error occurred", "task complete", etc.
struct TabNotificationStyle: Equatable {
    /// Override color for the tab title (nil = use default)
    var titleColor: Color?

    /// Make the title italic (e.g., for "waiting" states)
    var isItalic = false

    /// Make the title bold (e.g., for "attention needed")
    var isBold = false

    /// Subtle pulse animation to draw attention
    var shouldPulse = false

    /// Optional icon to show (SF Symbol name)
    var icon: String?

    /// Icon color (nil = inherit from titleColor or default)
    var iconColor: Color?

    /// Border color for the tab (nil = no border)
    var borderColor: Color?

    /// Border width (default 0 = no border)
    var borderWidth: CGFloat = 0

    /// Border dash pattern (nil = solid, e.g. [4, 3] = dotted)
    var borderDash: [CGFloat]?

    /// Badge text overlay (e.g., "!", "3") — nil = no badge
    var badgeText: String?

    /// Badge color (defaults to red)
    var badgeColor: Color = .red

    /// When true, the style persists even when the tab is selected.
    /// Used for permission requests that need attention until resolved.
    var persistent = false

    /// Predefined styles for common states
    static let waiting = TabNotificationStyle(
        titleColor: .orange,
        isItalic: true,
        shouldPulse: true,
        icon: "ellipsis.circle",
        borderColor: .orange,
        borderWidth: 1.5
    )

    static let error = TabNotificationStyle(
        titleColor: .red,
        isBold: true,
        icon: "exclamationmark.triangle.fill",
        iconColor: .red,
        borderColor: .red,
        borderWidth: 1.5
    )

    static let success = TabNotificationStyle(
        titleColor: .green,
        icon: "checkmark.circle.fill",
        iconColor: .green
    )

    static let attention = TabNotificationStyle(
        titleColor: .yellow,
        isBold: true,
        shouldPulse: true,
        icon: "bell.fill",
        iconColor: .yellow,
        borderColor: .yellow,
        borderWidth: 1.5
    )
}

struct OverlayTab: Identifiable, Equatable {
    let id: UUID
    let splitController: SplitPaneController
    let createdAt: Date
    var customTitle: String?
    var color: TabColor = .blue
    var autoColor: TabColor? // F05: Auto-assigned color based on AI model
    var isManualColorOverride = false
    var lastCommand: LastCommandInfo? // F20: Last command tracking
    var bookmarks: [BookmarkManager.Bookmark] = [] // F17: Bookmarks

    // MARK: - MCP Control

    /// Whether this tab was created by an MCP client.
    var isMCPControlled = false

    // MARK: - Token Optimization (CTO) Per-Tab Override

    /// Per-tab override for token optimization. Defaults to `.default` which
    /// follows the global mode. Users can force-on or force-off per tab.
    var tokenOptOverride: TabTokenOptOverride = .default

    // MARK: - Notification Styling

    /// Active notification style for this tab (nil = default appearance)
    var notificationStyle: TabNotificationStyle?
    /// The attention style currently owned by terminal session state.
    ///
    /// Notification actions may also style tabs for success/error/conflict
    /// events. This marker lets the state reconciler repair and clear only the
    /// persistent waiting/approval style it owns.
    var stateAttentionKind: TabAttentionKind = .none

    // MARK: - Repo Grouping

    /// Repo group membership. nil = ungrouped.
    /// Value is the canonical git root path (e.g. "/Users/me/repos/Chau7").
    var repoGroupID: String?
    /// Whether repo group membership was inherited from another tab and should
    /// be dropped if the tab's actual git root diverges.
    var hasInheritedRepoGroup = false

    /// Display name derived from repo group path (e.g. "Chau7")
    var repoGroupName: String? {
        guard let path = repoGroupID else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Tab Switch Optimization: Cached Snapshot

    /// Cached screenshot of terminal content for instant visual feedback during tab switch
    var cachedSnapshot: NSImage?
    /// Last known cursor position for cursor-first rendering
    var lastCursorPosition: CGPoint = .zero
    /// Last known prompt text for cursor placeholder
    var lastPromptText = ""

    /// Passive preview restored from persisted state. Only shown while the
    /// shell-backed restore bootstrap is still in progress.
    var restorePreviewSnapshot: NSImage?

    /// The primary terminal session (first terminal in split tree)
    var session: TerminalSessionModel? {
        splitController.primarySession
    }

    /// Session shown in tab chrome, based on the current terminal presentation
    /// pane. Non-terminal side panes keep the last focused terminal as the
    /// presentation source so tab metadata and rendering do not drift.
    var displaySession: TerminalSessionModel? {
        splitController.presentationSession
    }

    var agentCount: Int {
        splitController.root.allSessions.reduce(into: 0) { count, session in
            if session.aiDisplayAppName != nil
                || session.effectiveAIProvider != nil
                || session.effectiveAISessionId != nil {
                count += 1
            }
        }
    }

    init(appModel: AppModel) {
        self.id = UUID()
        self.splitController = SplitPaneController(appModel: appModel)
        self.createdAt = Date()
    }

    /// Init with a pre-built split controller (for dashboard tabs).
    init(appModel: AppModel, splitController: SplitPaneController) {
        self.id = UUID()
        self.splitController = splitController
        self.createdAt = Date()
    }

    /// Whether this tab is a multi-agent dashboard (no terminal).
    var isDashboard: Bool {
        if case .dashboard = splitController.root { return true }
        return false
    }

    /// Point-in-time computation of this tab's display title.
    ///
    /// `OverlayTab` is a `struct`, so SwiftUI re-renders callers of this
    /// property only when the struct itself is diffed — not when the
    /// underlying `@Observable` session's `aiDisplayAppName`, `devServer`,
    /// or `title` changes. For live tab chrome, use `TabSessionContent`
    /// (which observes `session` directly and re-resolves the title
    /// reactively). This property is safe to call from:
    ///   - UI paths that already observe the parent `OverlayTabsModel`
    ///     (which re-renders when `tabs` mutates) and don't need sub-
    ///     second freshness,
    ///   - One-shot read-and-forget callers: log messages, the Cmd+Shift+T
    ///     closed-tab log, the MCP `listTabs` snapshot response, the
    ///     command palette, etc. — where a slightly-stale title is
    ///     acceptable.
    var displayTitle: String {
        if isDashboard { return customTitle ?? L("tab.overview", "Overview") }
        let shellTitle = L("tab.shell", "Shell")
        let resolved = TabTitleFormatter.resolvedTitle(
            customTitle: customTitle,
            aiDisplayAppName: displaySession?.aiDisplayAppName,
            devServerName: session?.devServer?.name,
            customTitleOnly: FeatureSettings.shared.customTitleOnly,
            shellFallback: shellTitle
        )
        if resolved != shellTitle {
            return resolved
        }
        // If no terminals exist, show "Editor" instead of "Shell"
        if splitController.root.allTerminalIDs.isEmpty {
            return L("tab.editor", "Editor")
        }
        return L("tab.shell", "Shell")
    }

    /// Returns the effective tab color - auto color if enabled and detected, otherwise manual color
    var effectiveColor: TabColor {
        if isManualColorOverride {
            return color
        }
        if FeatureSettings.shared.isAutoTabThemeEnabled, let auto = autoColor {
            return auto
        }
        return color
    }

    /// F20: Badge text for last command (duration + exit status)
    var commandBadge: String? {
        guard FeatureSettings.shared.isLastCommandBadgeEnabled else { return nil }
        return lastCommand?.badgeText
    }

    /// Whether CTO (token optimization) is currently active on this tab.
    var isTokenOptActive: Bool {
        let mode = FeatureSettings.shared.tokenOptimizationMode
        let isAI = displaySession?.aiDisplayAppName != nil
        return shouldBeActive(mode: mode, override: tokenOptOverride, isAIActive: isAI)
    }

    /// Visual state for optimizer tab badge: nil = hidden, true = active override, false = inactive override.
    /// Only non-nil when this tab deviates from its mode's default behavior.
    var optimizerOverrideState: Bool? {
        let mode = FeatureSettings.shared.tokenOptimizationMode
        switch mode {
        case .off: return nil
        case .allTabs: return tokenOptOverride == .forceOff ? false : nil
        case .manual: return tokenOptOverride == .forceOn ? true : nil
        case .aiOnly:
            switch tokenOptOverride {
            case .forceOn: return true
            case .forceOff: return false
            case .default: return nil
            }
        }
    }

    /// Equatable conformance is what SwiftUI's diffing engine uses to
    /// decide whether a tab-chip view needs to re-render. Any field
    /// rendered into `displayTitle` / `effectiveColor` / the F20 badge
    /// must therefore be compared here, otherwise mutations to that
    /// field will silently be diffed-equal and the on-screen tab will
    /// stay stale.
    ///
    /// Symptom that motivated this list: renaming a tab via
    /// `OverlayTabsModel.commitRename` writes `tabs[index].customTitle`,
    /// but if `customTitle` is missing from `==` SwiftUI thinks the tab
    /// is unchanged and skips updating the chip — the user types a new
    /// name, presses Save, and the chip keeps the old name.
    ///
    /// Fields covered:
    ///   - id / isMCPControlled / tokenOptOverride / notificationStyle /
    ///     stateAttentionKind / repoGroupID / hasInheritedRepoGroup — original list
    ///   - customTitle — rename + MCP renameTab
    ///   - color / autoColor / isManualColorOverride — color picker +
    ///     F05 auto-color
    ///   - lastCommand — F20 badge
    ///
    /// Fields deliberately NOT compared:
    ///   - splitController — class reference; identity-stable across
    ///     mutations to the tab struct
    ///   - bookmarks — F17 list; not rendered on the tab chip itself
    ///   - createdAt — immutable
    static func == (lhs: OverlayTab, rhs: OverlayTab) -> Bool {
        lhs.id == rhs.id
            && lhs.customTitle == rhs.customTitle
            && lhs.color == rhs.color
            && lhs.autoColor == rhs.autoColor
            && lhs.isManualColorOverride == rhs.isManualColorOverride
            && lhs.lastCommand == rhs.lastCommand
            && lhs.isMCPControlled == rhs.isMCPControlled
            && lhs.tokenOptOverride == rhs.tokenOptOverride
            && lhs.notificationStyle == rhs.notificationStyle
            && lhs.stateAttentionKind == rhs.stateAttentionKind
            && lhs.repoGroupID == rhs.repoGroupID
            && lhs.hasInheritedRepoGroup == rhs.hasInheritedRepoGroup
    }

    // MARK: - Split Pane Operations

    func splitHorizontally() {
        splitController.splitWithTerminal(direction: .horizontal)
    }

    func splitVertically() {
        splitController.splitWithTerminal(direction: .vertical)
    }

    func openTextEditor(filePath: String? = nil) {
        splitController.splitWithTextEditor(direction: .horizontal, filePath: filePath)
    }

    func closeFocusedPane() {
        splitController.closeFocusedPane()
    }

    func focusNextPane() {
        splitController.focusNextPane()
    }

    func focusPreviousPane() {
        splitController.focusPreviousPane()
    }

    func appendSelectionToEditor(_ text: String) {
        splitController.appendSelectionToEditor(text)
    }

    func openFilePreview(filePath: String? = nil) {
        if let path = filePath {
            splitController.openFilePreview(path: path)
        } else {
            splitController.splitWithFilePreview(direction: .horizontal)
        }
    }

    func openDiffViewer(filePath: String, directory: String, mode: DiffMode = .workingTree) {
        splitController.openDiffViewer(filePath: filePath, directory: directory, mode: mode)
    }

    func openRepositoryPane(directory: String) {
        splitController.openRepositoryPane(directory: directory)
    }

    func toggleTextEditor(filePath: String? = nil) {
        splitController.toggleTextEditor(filePath: filePath)
    }

    func toggleFilePreview(filePath: String? = nil) {
        splitController.toggleFilePreview(filePath: filePath)
    }

    func toggleRepositoryPane(directory: String) {
        splitController.toggleRepositoryPane(directory: directory)
    }

    init(appModel: AppModel, splitController: SplitPaneController, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.splitController = splitController
        self.createdAt = createdAt
    }

    /// Propagates this tab's UUID to the split controller and all current terminal
    /// sessions so events carry a deterministic tabID for the TabResolver fast-path.
    /// Must be called after the tab's `id` is finalized (i.e. after init or restore).
    mutating func stampOwnerTabID() {
        let tabID = id
        splitController.ownerTabID = tabID
        splitController.terminalSessionConfigurator = { session in
            session.ownerTabID = tabID
            session.onPermissionResolved = {
                DispatchQueue.main.async {
                    _ = TerminalControlService.shared.clearPersistentNotificationStyleAcrossWindows(tabID: tabID)
                }
            }
        }
    }
}

// MARK: - Tab State Persistence

struct SavedTerminalPaneState: Codable {
    let paneID: String
    let directory: String
    let scrollbackContent: String? // last N lines of terminal output
    let aiResumeCommand: String? // e.g. "claude --resume abc123"
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

    init(
        paneID: String,
        directory: String,
        scrollbackContent: String?,
        aiResumeCommand: String?,
        aiProvider: String? = nil,
        aiSessionId: String? = nil,
        aiSessionIdSource: AISessionIdentitySource? = nil,
        lastOutputAt: Date? = nil,
        lastInputAt: Date? = nil,
        knownRepoRoot: String? = nil,
        knownGitBranch: String? = nil,
        lastStatus: CommandStatus? = nil,
        agentLaunchCommand: String? = nil,
        agentStartedAt: Date? = nil,
        lastExitCode: Int? = nil,
        lastExitAt: Date? = nil
    ) {
        self.paneID = paneID
        self.directory = directory
        self.scrollbackContent = scrollbackContent
        self.aiResumeCommand = aiResumeCommand
        self.aiProvider = aiProvider
        self.aiSessionId = aiSessionId
        self.aiSessionIdSource = aiSessionIdSource
        self.lastOutputAt = lastOutputAt
        self.lastInputAt = lastInputAt
        self.knownRepoRoot = knownRepoRoot
        self.knownGitBranch = knownGitBranch
        self.lastStatus = lastStatus
        self.agentLaunchCommand = agentLaunchCommand
        self.agentStartedAt = agentStartedAt
        self.lastExitCode = lastExitCode
        self.lastExitAt = lastExitAt
    }
}

extension SavedTerminalPaneState {
    /// Directory the restored shell should land in.
    ///
    /// For Codex tabs, the saved `directory` is the **shell** cwd at save
    /// time — i.e. wherever the user typed `codex resume <id>` from. Codex
    /// itself records a different cwd in its rollout file (the directory
    /// the session was started in), and that's the one the user mentally
    /// associates with the tab. When both are available and codex's value
    /// still exists on disk, prefer it.
    ///
    /// Falls back to `directory` for non-codex tabs, missing/invalid codex
    /// metadata, or codex paths that no longer exist.
    var preferredRestoreDirectory: String {
        guard let normalizedProvider = AIResumeParser.normalizeProviderName(aiProvider ?? ""),
              normalizedProvider == "codex",
              let sessionId = aiSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty,
              let metadata = CodexSessionResolver.metadata(forSessionID: sessionId),
              !metadata.cwd.isEmpty
        else {
            return directory
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: metadata.cwd, isDirectory: &isDir),
              isDir.boolValue
        else {
            return directory
        }
        if metadata.cwd != directory {
            Log.info(
                "SavedTerminalPaneState: codex session=\(sessionId.prefix(8)) override directory \"\(directory)\" → \"\(metadata.cwd)\""
            )
        }
        return metadata.cwd
    }
}

private enum SavedAIResumePayload {
    struct Fields {
        let command: String?
        let provider: String?
        let sessionId: String?
        let sessionIdSource: AISessionIdentitySource?
    }

    static func normalizedCommand(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              commandMetadata(trimmed) != nil else {
            return nil
        }
        return trimmed
    }

    static func commandMetadata(_ value: String?) -> AIResumeParser.ResumeMetadata? {
        guard let value else { return nil }
        return AIResumeParser.extractMetadata(from: value)
    }

    static func concreteSessionId(_ value: String?, source: AISessionIdentitySource?) -> String? {
        guard source != .synthetic,
              let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              AIResumeParser.isValidSessionId(trimmed) else {
            return nil
        }
        return trimmed
    }

    static func persistedSessionId(_ value: String?, source: AISessionIdentitySource?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if source == .synthetic, trimmed.hasPrefix("synth:") {
            return trimmed
        }
        return AIResumeParser.isValidSessionId(trimmed) ? trimmed : nil
    }

    static func score(_ fields: Fields) -> Int {
        var score = 0
        if commandMetadata(fields.command) != nil {
            score += 100
        }
        if AIResumeParser.normalizeProviderName(fields.provider ?? "") != nil {
            score += 10
        }
        if concreteSessionId(fields.sessionId, source: fields.sessionIdSource) != nil {
            score += 40
        } else if persistedSessionId(fields.sessionId, source: fields.sessionIdSource) != nil {
            score += 1
        }
        return score
    }

    static func merged(current: Fields, fallback: Fields?) -> Fields {
        guard let fallback else { return current }

        let currentCommand = normalizedCommand(current.command)
        let fallbackCommand = normalizedCommand(fallback.command)
        let fallbackCommandMetadata = commandMetadata(fallback.command)
        let currentConcreteSession = concreteSessionId(
            current.sessionId,
            source: current.sessionIdSource
        )
        let currentPersistedSession = persistedSessionId(
            current.sessionId,
            source: current.sessionIdSource
        )
        let currentSessionId = currentConcreteSession ?? currentPersistedSession
        let currentSessionIdSource = currentSessionId == nil ? nil : current.sessionIdSource
        let currentProvider = AIResumeParser.normalizeProviderName(current.provider ?? "")
        let fallbackFieldProvider = AIResumeParser.normalizeProviderName(fallback.provider ?? "")
        let fallbackKnownProvider = fallbackCommandMetadata?.provider ?? fallbackFieldProvider
        let fallbackMatchesCurrentProvider = currentProvider == nil
            || fallbackKnownProvider == nil
            || fallbackKnownProvider == currentProvider
        let fallbackCommandMatchesCurrent = currentConcreteSession == nil
            || fallbackCommandMetadata?.sessionId == currentConcreteSession
        let shouldUseFallbackCommand = currentCommand == nil
            && fallbackCommand != nil
            && fallbackMatchesCurrentProvider
            && fallbackCommandMatchesCurrent
        let shouldUseFallbackIdentity = shouldUseFallbackCommand
            && currentConcreteSession == nil

        let fallbackProvider: String?
        let fallbackConcreteSession: String?
        let fallbackPersistedSession: String?
        if fallbackMatchesCurrentProvider {
            fallbackProvider = shouldUseFallbackCommand
                ? (fallbackCommandMetadata?.provider ?? fallback.provider)
                : fallback.provider
            fallbackConcreteSession = concreteSessionId(
                fallback.sessionId,
                source: fallback.sessionIdSource
            )
            fallbackPersistedSession = persistedSessionId(
                fallback.sessionId,
                source: fallback.sessionIdSource
            )
        } else {
            fallbackProvider = nil
            fallbackConcreteSession = nil
            fallbackPersistedSession = nil
        }
        let fallbackCommandSession = shouldUseFallbackCommand ? fallbackCommandMetadata?.sessionId : nil
        let fallbackSessionId = fallbackCommandSession
            ?? fallbackConcreteSession
            ?? fallbackPersistedSession
        let fallbackSessionIdSource: AISessionIdentitySource? = {
            if fallbackCommandSession != nil {
                return .explicit
            }
            if fallbackConcreteSession != nil {
                return fallback.sessionIdSource
            }
            if fallbackPersistedSession != nil {
                return fallback.sessionIdSource
            }
            return nil
        }()
        let mergedSessionId = shouldUseFallbackIdentity
            ? (fallbackSessionId ?? currentSessionId)
            : (currentSessionId ?? fallbackSessionId)

        return Fields(
            command: currentCommand ?? (shouldUseFallbackCommand ? fallbackCommand : nil),
            provider: shouldUseFallbackIdentity
                ? (fallbackProvider ?? current.provider)
                : (current.provider ?? fallbackProvider),
            sessionId: mergedSessionId,
            sessionIdSource: mergedSessionId == nil
                ? nil
                : (shouldUseFallbackIdentity
                    ? (fallbackSessionIdSource ?? currentSessionIdSource)
                    : (currentSessionIdSource ?? fallbackSessionIdSource))
        )
    }
}

extension SavedTerminalPaneState {
    var hasAIResumePayload: Bool {
        aiProvider != nil || aiSessionId != nil || aiResumeCommand != nil
    }

    var aiResumeRestorationScore: Int {
        SavedAIResumePayload.score(
            SavedAIResumePayload.Fields(
                command: aiResumeCommand,
                provider: aiProvider,
                sessionId: aiSessionId,
                sessionIdSource: aiSessionIdSource
            )
        )
    }

    func mergedAIResumePayload(with fallback: SavedTerminalPaneState?) -> SavedTerminalPaneState {
        guard let fallback else { return self }
        let merged = SavedAIResumePayload.merged(
            current: SavedAIResumePayload.Fields(
                command: aiResumeCommand,
                provider: aiProvider,
                sessionId: aiSessionId,
                sessionIdSource: aiSessionIdSource
            ),
            fallback: SavedAIResumePayload.Fields(
                command: fallback.aiResumeCommand,
                provider: fallback.aiProvider,
                sessionId: fallback.aiSessionId,
                sessionIdSource: fallback.aiSessionIdSource
            )
        )
        return SavedTerminalPaneState(
            paneID: paneID,
            directory: directory,
            scrollbackContent: scrollbackContent,
            aiResumeCommand: merged.command,
            aiProvider: merged.provider,
            aiSessionId: merged.sessionId,
            aiSessionIdSource: merged.sessionIdSource,
            lastOutputAt: lastOutputAt,
            lastInputAt: lastInputAt,
            knownRepoRoot: knownRepoRoot,
            knownGitBranch: knownGitBranch,
            lastStatus: lastStatus,
            agentLaunchCommand: agentLaunchCommand,
            agentStartedAt: agentStartedAt,
            lastExitCode: lastExitCode,
            lastExitAt: lastExitAt
        )
    }
}

/// Lightweight Codable snapshot of a tab's restorable state.
/// Captures working directory, title, color, and the last N lines of
/// terminal scrollback so the user has context when tabs are restored.
struct SavedTabState: Codable {
    let tabID: String? // Persisted overlay tab ID
    let selectedTabID: String? // Explicit selected marker for stable restore
    let customTitle: String?
    let color: String // TabColor.rawValue
    let directory: String
    let selectedIndex: Int? // non-nil only for the selected tab
    let tokenOptOverride: String? // TabTokenOptOverride.rawValue (nil = .default for backwards compat)
    let scrollbackContent: String? // backward compatibility (legacy single-pane restore)
    let aiResumeCommand: String? // backward compatibility (legacy single-pane restore)
    let aiProvider: String?
    let aiSessionId: String?
    let aiSessionIdSource: AISessionIdentitySource?
    let splitLayout: SavedSplitNode? // split tree including editor panes
    let focusedPaneID: String? // persisted focused pane ID
    let paneStates: [SavedTerminalPaneState]?
    let createdAt: String? // ISO8601 encoded, nil for legacy saves
    let repoGroupID: String? // repo grouping membership, nil = ungrouped
    let knownRepoRoot: String?
    let knownGitBranch: String?
    let lastInputAt: Date?
    let lastStatus: CommandStatus?
    let agentLaunchCommand: String?
    let agentStartedAt: Date?
    let lastExitCode: Int?
    let lastExitAt: Date?
    let commandBlocks: [CommandBlock]?
    /// Legacy-only: old versions persisted PNG-encoded terminal snapshots
    /// for the restore-preview UI. New saves always write nil (see commit
    /// 31d08d0 "Stop encoding PNG preview snapshots in auto-save"). Kept
    /// on SavedTabState so decoding an older on-disk backup still hydrates
    /// `OverlayTab.restorePreviewSnapshot` — the field naturally sunsets
    /// when the user's saved state is overwritten by a new save.
    let previewSnapshotPNGData: Data?

    static let userDefaultsKey = "com.chau7.savedTabState"

    init(
        tabID: String? = nil,
        selectedTabID: String? = nil,
        customTitle: String?,
        color: String,
        directory: String,
        selectedIndex: Int?,
        tokenOptOverride: String?,
        scrollbackContent: String?,
        aiResumeCommand: String?,
        aiProvider: String? = nil,
        aiSessionId: String? = nil,
        aiSessionIdSource: AISessionIdentitySource? = nil,
        splitLayout: SavedSplitNode?,
        focusedPaneID: String?,
        paneStates: [SavedTerminalPaneState]?,
        createdAt: String? = nil,
        repoGroupID: String? = nil,
        knownRepoRoot: String? = nil,
        knownGitBranch: String? = nil,
        lastInputAt: Date? = nil,
        lastStatus: CommandStatus? = nil,
        agentLaunchCommand: String? = nil,
        agentStartedAt: Date? = nil,
        lastExitCode: Int? = nil,
        lastExitAt: Date? = nil,
        commandBlocks: [CommandBlock]? = nil,
        previewSnapshotPNGData: Data? = nil
    ) {
        self.tabID = tabID
        self.selectedTabID = selectedTabID
        self.customTitle = customTitle
        self.color = color
        self.directory = directory
        self.selectedIndex = selectedIndex
        self.tokenOptOverride = tokenOptOverride
        self.scrollbackContent = scrollbackContent
        self.aiResumeCommand = aiResumeCommand
        self.aiProvider = aiProvider
        self.aiSessionId = aiSessionId
        self.aiSessionIdSource = aiSessionIdSource
        self.splitLayout = splitLayout
        self.focusedPaneID = focusedPaneID
        self.paneStates = paneStates
        self.createdAt = createdAt
        self.repoGroupID = repoGroupID
        self.knownRepoRoot = knownRepoRoot
        self.knownGitBranch = knownGitBranch
        self.lastInputAt = lastInputAt
        self.lastStatus = lastStatus
        self.agentLaunchCommand = agentLaunchCommand
        self.agentStartedAt = agentStartedAt
        self.lastExitCode = lastExitCode
        self.lastExitAt = lastExitAt
        self.commandBlocks = commandBlocks
        self.previewSnapshotPNGData = previewSnapshotPNGData
    }
}

extension SavedTabState {
    var hasAIResumePayload: Bool {
        aiProvider != nil || aiSessionId != nil || aiResumeCommand != nil
            || (paneStates?.contains(where: \.hasAIResumePayload) ?? false)
    }

    var aiResumeRestorationScore: Int {
        let topLevelScore = SavedAIResumePayload.score(
            SavedAIResumePayload.Fields(
                command: aiResumeCommand,
                provider: aiProvider,
                sessionId: aiSessionId,
                sessionIdSource: aiSessionIdSource
            )
        )
        return topLevelScore + (paneStates?.reduce(0) { $0 + $1.aiResumeRestorationScore } ?? 0)
    }

    func mergedAIResumePayload(with fallback: SavedTabState?) -> SavedTabState {
        guard let fallback else { return self }
        let merged = SavedAIResumePayload.merged(
            current: SavedAIResumePayload.Fields(
                command: aiResumeCommand,
                provider: aiProvider,
                sessionId: aiSessionId,
                sessionIdSource: aiSessionIdSource
            ),
            fallback: SavedAIResumePayload.Fields(
                command: fallback.aiResumeCommand,
                provider: fallback.aiProvider,
                sessionId: fallback.aiSessionId,
                sessionIdSource: fallback.aiSessionIdSource
            )
        )

        let mergedPaneStates: [SavedTerminalPaneState]?
        if let paneStates {
            let fallbackByPaneID = Dictionary(
                uniqueKeysWithValues: (fallback.paneStates ?? []).map { ($0.paneID, $0) }
            )
            mergedPaneStates = paneStates.map { pane in
                pane.mergedAIResumePayload(with: fallbackByPaneID[pane.paneID])
            }
        } else {
            mergedPaneStates = fallback.paneStates
        }

        return SavedTabState(
            tabID: tabID,
            selectedTabID: selectedTabID,
            customTitle: customTitle,
            color: color,
            directory: directory,
            selectedIndex: selectedIndex,
            tokenOptOverride: tokenOptOverride,
            scrollbackContent: scrollbackContent,
            aiResumeCommand: merged.command,
            aiProvider: merged.provider,
            aiSessionId: merged.sessionId,
            aiSessionIdSource: merged.sessionIdSource,
            splitLayout: splitLayout,
            focusedPaneID: focusedPaneID,
            paneStates: mergedPaneStates,
            createdAt: createdAt,
            repoGroupID: repoGroupID,
            knownRepoRoot: knownRepoRoot,
            knownGitBranch: knownGitBranch,
            lastInputAt: lastInputAt,
            lastStatus: lastStatus,
            agentLaunchCommand: agentLaunchCommand,
            agentStartedAt: agentStartedAt,
            lastExitCode: lastExitCode,
            lastExitAt: lastExitAt,
            commandBlocks: commandBlocks,
            previewSnapshotPNGData: previewSnapshotPNGData
        )
    }
}

/// Multi-window save format: each entry is one window's tab states.
struct SavedMultiWindowState: Codable {
    static let userDefaultsKey = "com.chau7.savedMultiWindowState"
    let windows: [[SavedTabState]]
}

enum TabStateSaveReason: String {
    case autosave
    case termination
    case manual
    case restoreSource = "restore-source"
}

/// In-memory record of a closed tab, enabling "Reopen Closed Tab" (Cmd+Shift+T).
/// Wraps the existing `SavedTabState` with positional + temporal metadata.
/// Not persisted to disk — the stack resets on app quit, matching browser behavior.
struct ClosedTabEntry {
    let state: SavedTabState
    let originalIndex: Int
    let closedAt: Date
}

/// Manages terminal tabs, search, and broadcast mode for the overlay window.
/// - Note: Thread Safety - observed properties must be modified on main thread.
///   All methods assume main thread execution.
@Observable
final class OverlayTabsModel {
    static var lastArchivedMultiWindowTabStateFingerprint: Int?
    static var lastArchivedMultiWindowTabStateAt: Date = .distantPast

    var tabs: [OverlayTab] {
        didSet { onTabsChanged?() }
    }

    var selectedTabID: UUID {
        didSet {
            if activeDashboardGroupID != nil { activeDashboardGroupID = nil }
            onSelectedTabIDChanged?()
        }
    }

    /// Shared Metal renderer for this window. One coordinator renders all tabs;
    /// `switchToView()` swaps the grid provider on tab change. Created lazily
    /// when the first selected tab starts its terminal.
    var sharedMetalCoordinator: RustMetalDisplayCoordinator?

    /// When set, the content area shows the agent dashboard for this repo group.
    var activeDashboardGroupID: String?
    private var dashboardModels: [String: AgentDashboardModel] = [:]

    func dashboardModel(for repoGroupID: String) -> AgentDashboardModel {
        if let existing = dashboardModels[repoGroupID] { return existing }
        let model = AgentDashboardModel(repoGroupID: repoGroupID)
        model.onSwitchToTab = { [weak self] tabID in
            self?.activeDashboardGroupID = nil
            self?.selectTab(id: tabID)
        }
        dashboardModels[repoGroupID] = model
        return model
    }

    var isSearchVisible = false
    var searchQuery = ""
    var searchResults: [String] = []
    var searchMatchCount = 0
    var isCaseSensitive = false
    var isRegexSearch = false
    var isSemanticSearch = false
    var searchError: String?
    var isRenameVisible = false
    var renameText = ""
    var renameColor: TabColor = .blue
    var suspendedTabIDs: Set<UUID> = []

    // MARK: - Tab Switch Optimization State

    /// Previous tab index for directional animation
    var previousTabIndex = 0
    /// Tab kept alive briefly after selection changes so the renderer hierarchy
    /// is not torn down mid-switch.
    var previousLiveHierarchyTabID: UUID?
    struct SelectedSurfacePresentation: Equatable {
        let phase: TerminalPresentationPhase
        let isAwaitingVisibleFrame: Bool

        var isLivePresentable: Bool {
            phase == .live
        }
    }

    var selectedSurfacePresentation: SelectedSurfacePresentation {
        guard let tab = selectedTab,
              let session = selectedPresentationSession(for: tab) else {
            return SelectedSurfacePresentation(
                phase: .live,
                isAwaitingVisibleFrame: false
            )
        }
        let state = session.presentationSurfaceState
        return SelectedSurfacePresentation(
            phase: state.phase,
            isAwaitingVisibleFrame: state.awaitingVisibleFrameReady
        )
    }

    /// Whether the selected terminal content is ready to display (for snapshot swap)
    var isTerminalReady = true

    var usesStartupLoadingCover = false

    var shouldShowStartupLoadingCover: Bool {
        false
    }

    var shouldShowSelectedSurfaceLiveRepaintCover: Bool {
        false
    }

    /// Generation counter for isTerminalReady — prevents stale asyncAfter
    /// callbacks from clobbering the state after rapid tab switches.
    @ObservationIgnored var terminalReadyGeneration: UInt64 = 0
    @ObservationIgnored var terminalReadyCommitWorkItem: DispatchWorkItem?
    @ObservationIgnored var selectedTerminalRevealTimeoutWorkItem: DispatchWorkItem?
    @ObservationIgnored static let terminalReadyCompositingDelay: TimeInterval = 1.0 / 60.0
    @ObservationIgnored static let selectedTerminalRevealTimeout: TimeInterval = 0.75
    @ObservationIgnored static let deferredRestoreStepInterval: TimeInterval = 0.35
    /// Set of tab IDs currently being pre-warmed (on hover)
    @ObservationIgnored var prewarmingTabIDs: Set<UUID> = []
    @ObservationIgnored static let previousLiveHierarchyKeepAliveInterval: TimeInterval = 0.5

    // MARK: - Tab Bar Recovery

    /// Tab hit-test ranges for right-click context menu (populated by SwiftUI preference changes).
    /// Each entry maps a tab UUID to its global x-range (minX, maxX) in the window.
    @ObservationIgnored var tabHitTestFrames: [(tabID: UUID, minX: CGFloat, maxX: CGFloat)] = []

    /// Group bracket hit-test ranges for right-click and drag (populated by SwiftUI preferences).
    /// Segment identity keeps duplicate same-repo visual runs from overwriting each other.
    @ObservationIgnored var groupBracketHitTestFrames: [(segmentID: String, repoGroupID: String, firstTabID: UUID, minX: CGFloat, maxX: CGFloat)] = []

    /// Token to force SwiftUI to re-render the tab bar when incremented
    var tabBarRefreshToken = 0

    /// Callback for moving a tab to another window. Wired by AppDelegate.
    @ObservationIgnored var onMoveTabToWindow: ((UUID, Int) -> Void)?
    /// Callback for moving a repo group to another window. Wired by AppDelegate.
    @ObservationIgnored var onMoveGroupToWindow: ((String, Int) -> Void)?
    /// Callback to refresh window titles on demand (for context menu). Wired by AppDelegate.
    @ObservationIgnored var onRefreshWindowTitles: (() -> Void)?

    /// List of other windows for the "Move to Window" context menu. Populated by AppDelegate.
    var otherWindowTitles: [WindowMenuItem] = []

    struct WindowMenuItem: Identifiable {
        let id: Int // window index
        let title: String
    }

    /// Last reported rendered tab count from the view (for watchdog)
    /// -1 means the view hasn't reported yet (avoids false positive on startup)
    @ObservationIgnored var lastReportedRenderedCount: Int = -1
    /// Last reported tab bar size (for visibility-based recovery)
    @ObservationIgnored var lastReportedTabBarSize: CGSize = .zero
    /// Timestamp of last preference update from the view (for staleness detection)
    @ObservationIgnored var lastPreferenceUpdateTime = Date()
    /// How long without a preference update before considering the view stale
    @ObservationIgnored let stalenessThreshold: TimeInterval = 20.0
    @ObservationIgnored let refreshCooldown: TimeInterval = 10.0
    @ObservationIgnored var lastForcedRefreshAt: Date = .distantPast
    @ObservationIgnored var watchdogRecoveryCount = 0
    @ObservationIgnored var watchdogSkipCount = 0
    @ObservationIgnored var lastWatchdogSummaryAt = Date()
    @ObservationIgnored var lastWatchdogReason = ""
    /// Timer for watchdog that checks tab bar health
    @ObservationIgnored var tabBarWatchdogTimer: DispatchSourceTimer?
    @ObservationIgnored var consecutiveHealthyChecks = 0
    /// Counter to limit consecutive watchdog refresh attempts
    @ObservationIgnored var watchdogRefreshAttempts = 0
    /// Minimum acceptable tab bar width per tab (for visibility detection)
    @ObservationIgnored let minWidthPerTab: CGFloat = 30
    /// Last reported tab bar frame in global coordinates for cross-window tab drops.
    @ObservationIgnored var tabBarDropFrame: CGRect = .zero
    /// Tracks whether the tab bar is expected to be visible
    @ObservationIgnored var isTabBarVisible = true
    @ObservationIgnored var lastTabBarVisibilityLogAt: Date = .distantPast

    // F13: Broadcast Input
    var isBroadcastMode = false
    var broadcastExcludedTabIDs: Set<UUID> = []

    // F16: Clipboard History
    var isClipboardHistoryVisible = false

    // F17: Bookmarks
    var isBookmarkListVisible = false

    // F21: Snippets
    var isSnippetManagerVisible = false

    // Hover Card
    var hoverCardTabID: UUID?
    var hoverCardAnchorX: CGFloat = 0
    @ObservationIgnored var hoverCardTimer: DispatchWorkItem?
    @ObservationIgnored var hoverCardDismissTimer: DispatchWorkItem?

    // Task Lifecycle (v1.1)
    var currentCandidate: TaskCandidate?
    var currentTask: TrackedTask?
    var isTaskAssessmentVisible = false

    // Reopen Closed Tab (Cmd+Shift+T)
    /// LIFO stack of recently closed tabs (max 10, in-memory only)
    @ObservationIgnored var closedTabStack: [ClosedTabEntry] = []
    @ObservationIgnored let maxClosedTabs = 10

    /// Whether there are any closed tabs available to reopen
    var canReopenClosedTab: Bool {
        !closedTabStack.isEmpty
    }

    // Git root path observation is now handled via session.onGitRootPathChanged callbacks
    @ObservationIgnored var renameTabID: UUID?
    @ObservationIgnored var renameOriginalTitle = ""
    /// Snapshot of `tabs[index].customTitle` taken when the rename dialog
    /// opens. Used at commit time to detect whether another mutator (MCP
    /// `renameTab`, an extension, etc.) modified the tab's custom title
    /// while the user was typing — so we can log the conflict instead of
    /// silently overwriting the external change.
    @ObservationIgnored var renameOriginalCustomTitle: String?
    @ObservationIgnored var renameOriginalColor: TabColor = .blue
    @ObservationIgnored var suspendWorkItems: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored var previousLiveHierarchyReleaseWorkItem: DispatchWorkItem?
    /// Restored tabs need a real terminal view at least once so scrollback can be
    /// injected and resume commands can land without falling back to "no view"
    /// retries. The set is harmless after attach because `shouldKeep...` only
    /// honors it while any terminal pane still lacks a Rust view.
    @ObservationIgnored var restoreBootstrapTabIDs: Set<UUID> = []
    /// Per-pane token for restore-time resume prefills.
    /// Prevents stale delayed retries from writing outdated commands.
    @ObservationIgnored var latestRestoreResumeTokenByPaneID: [UUID: String] = [:]
    /// Per-pane restore outcome ledger for resume prefills.
    /// Keeps supersession, queued, delivered, and rejected states explicit so
    /// restore retries remain diagnosable and stale callbacks cannot silently win.
    @ObservationIgnored var resumeRestoreDeliveryStateByPaneID: [UUID: ResumeRestoreDeliveryState] = [:]
    @ObservationIgnored var isRenderSuspensionEnabled = false
    // Reduced from 5.0s to 2.0s — combined with CVDisplayLink pausing, this
    // means background tabs stop rendering 3 seconds sooner, saving significant CPU.
    @ObservationIgnored var renderSuspensionDelay: TimeInterval = 5.0
    @ObservationIgnored var needsFreshTabOnShow = false
    @ObservationIgnored var isDiagnosticsLoggingEnabled = false
    /// Auto-save timer moved to AppDelegate for coordinated multi-window saves.
    /// Last archived snapshot fingerprint to avoid writing duplicate archive files.
    @ObservationIgnored var lastArchivedTabStateFingerprint: Int?
    /// Minimum time between archived snapshots unless we're terminating.
    @ObservationIgnored var lastArchivedTabStateAt: Date = .distantPast
    /// CTO notification observer tokens (stored for cleanup in deinit)
    @ObservationIgnored var ctoModeObserver: NSObjectProtocol?
    @ObservationIgnored var renderSuspensionObserver: NSObjectProtocol?
    @ObservationIgnored var visibleFrameReadyObserver: NSObjectProtocol?
    @ObservationIgnored var terminalDidStartObserver: NSObjectProtocol?
    @ObservationIgnored var terminalRuntimeReadinessObserver: NSObjectProtocol?
    @ObservationIgnored var repoGroupingModeObserver: NSObjectProtocol?
    var renderLifecycleRefreshToken = UUID()
    @ObservationIgnored var suspensionDebounceItem: DispatchWorkItem?
    @ObservationIgnored var lastObservedTokenOptimizationMode: TokenOptimizationMode = FeatureSettings.shared.tokenOptimizationMode
    @ObservationIgnored var codexResumeFallbackCache: [ObjectIdentifier: CachedCodexResumeFallback] = [:]
    @ObservationIgnored let renderLifecycleController = TabRenderLifecycleController()

    /// Callback invoked when `tabs` changes — used by RemoteControlManager
    @ObservationIgnored var onTabsChanged: (() -> Void)?
    /// Callback invoked when `selectedTabID` changes — used by RemoteControlManager
    @ObservationIgnored var onSelectedTabIDChanged: (() -> Void)?
    /// Callback invoked the first time startup records a selected-tab live frame.
    @ObservationIgnored var onStartupSelectedTabLiveFrameRecorded: (() -> Void)?
    /// Callback invoked when startup restore work drains completely.
    @ObservationIgnored var onStartupRestoreWorkDrained: (() -> Void)?

    @ObservationIgnored weak var overlayWindow: NSWindow?
    @ObservationIgnored var onCloseLastTab: (() -> Void)?
    @ObservationIgnored var deferredRestoreStatesByTabID: [UUID: SavedTabState] = [:]
    @ObservationIgnored var deferredRestoreTabOrder: [UUID] = []
    @ObservationIgnored var persistedRestoreFallbackStatesByTabID: [UUID: SavedTabState] = [:]
    @ObservationIgnored var hasStartedDeferredRestore = false

    @ObservationIgnored let appModel: AppModel
    struct RestorableTabsPayload {
        let tabs: [OverlayTab]
        let selectedID: UUID
        let rawStates: [SavedTabState]
    }

    struct CodexResumeFallbackSignature: Equatable {
        let directory: String
        let explicitSessionId: String?
        let referenceTimestamp: TimeInterval?
        let claimedSessionFingerprint: Int
        let claimedSessionCount: Int
        let historyFingerprint: Int
    }

    struct ResumeRestoreDeliveryState: Equatable {
        enum Outcome: String, Equatable {
            case pending
            case queued
            case delivered
            case rejected
            case superseded
        }

        let token: String
        let outcome: Outcome
    }

    struct StableCodexResumeFallbackSignature: Equatable {
        let directory: String
        let explicitSessionId: String?
        let referenceTimestamp: TimeInterval?
        let claimedSessionFingerprint: Int
        let claimedSessionCount: Int
    }

    struct CachedCodexResumeFallback {
        let signature: CodexResumeFallbackSignature
        let stableSignature: StableCodexResumeFallbackSignature?
        let metadata: (provider: String, sessionId: String)?
    }

    func selectedPresentationSession(for tab: OverlayTab?) -> TerminalSessionModel? {
        guard let tab else { return nil }
        return tab.displaySession ?? tab.session
    }

    /// When `restoreState` is false, the model starts with a single fresh tab
    /// instead of loading saved state from disk. Used for Cmd+N new windows.
    /// When `restoringStates` is provided, those pre-decoded states are used
    /// directly instead of reading from UserDefaults (for multi-window restore).
    init(appModel: AppModel, restoreState: Bool = true, restoringStates: [SavedTabState]? = nil) {
        self.appModel = appModel
        let restoredPayload: RestorableTabsPayload?
        if let states = restoringStates {
            restoredPayload = Self.decodeRestorableTabs(fromStates: states, appModel: appModel)
        } else {
            restoredPayload = restoreState ? Self.restoreSavedTabs(appModel: appModel) : nil
        }
        let sanitizedRestoredStates = restoredPayload.map { payload in
            Self.sanitizeRestoredAIResumeOwnership(states: payload.rawStates)
        }

        if let restoredPayload {
            self.tabs = restoredPayload.tabs
            self.selectedTabID = restoredPayload.selectedID
            self.restoreBootstrapTabIDs = Set([restoredPayload.selectedID])
            Log.info("Restored \(restoredPayload.tabs.count) tab(s) from saved state")
        } else {
            // Fallback: create a single fresh tab
            var first = OverlayTab(appModel: appModel)
            if let firstColor = TabColor.allCases.first {
                first.color = firstColor
            }
            first.stampOwnerTabID()
            self.tabs = [first]
            self.selectedTabID = first.id
        }

        // Apply persisted terminal state (scrollback + resume command) after the
        // instance is fully initialized.
        if let sanitizedRestoredStates {
            for (index, state) in sanitizedRestoredStates.enumerated() where index < tabs.count {
                let tab = tabs[index]
                persistedRestoreFallbackStatesByTabID[tab.id] = state
                if tab.id == selectedTabID {
                    restoreTabState(for: tab, state: state)
                } else {
                    deferredRestoreStatesByTabID[tab.id] = state
                    deferredRestoreTabOrder.append(tab.id)
                }
            }
            if !deferredRestoreTabOrder.isEmpty {
                Log.info(
                    "Deferred restore queued for \(deferredRestoreTabOrder.count) background tab(s); selectedTab=\(selectedTabID)"
                )
            }
            requestSelectedTabAuthoritativeReveal(reason: "init_restore")
        }

        // Register for per-phase snapshot release. Multi-window safe: every
        // window model registers, and releases are dispatched to all (each
        // only acts on tabs it owns).
        TabGraphicsMemoryManager.shared.addSnapshotReleaser(self)

        // Setup task lifecycle observers (v1.1)
        setupTaskObservers()

        // Repo grouping: subscribe to mode changes and initial auto-group
        setupRepoGrouping()

        // Coalesce restored groups so same-repo tabs are contiguous.
        // setupRepoGrouping only coalesces in .auto mode, but restored tabs
        // may have repoGroupIDs in any mode.
        if restoredPayload != nil {
            var seen = Set<String>()
            for tab in tabs {
                guard let gid = tab.repoGroupID, seen.insert(gid).inserted else { continue }
                coalesceGroup(repoGroupID: gid)
            }
        }

        // Start tab bar watchdog immediately (model-owned lifecycle)
        // This ensures the watchdog runs regardless of view lifecycle events
        DispatchQueue.main.async { [weak self] in
            self?.startTabBarWatchdog()
        }

        DispatchQueue.main.async { [weak self] in
            self?.isDiagnosticsLoggingEnabled = true
            self?.logVisualState(reason: "init")
            self?.reconcileTabAttentionStyles(reason: "init")
        }

        // Per-window autosave removed — AppDelegate now coordinates multi-window saves
        // to avoid race conditions where each window overwrites the same UserDefaults key.

        // CTO: listen for global mode changes and recalculate all tab flags
        self.ctoModeObserver = NotificationCenter.default.addObserver(
            forName: .tokenOptimizationModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let previousMode = lastObservedTokenOptimizationMode
            let mode = FeatureSettings.shared.tokenOptimizationMode
            self.lastObservedTokenOptimizationMode = mode
            CTORuntimeMonitor.shared.recordModeChanged(from: previousMode, to: mode)
            recalculateAllCTOFlags()
            // Also setup/teardown wrappers when mode changes at runtime
            if mode == .off {
                CTOManager.shared.teardown()
            } else {
                CTOManager.shared.setup()
            }
        }

        self.renderSuspensionObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionRenderSuspensionStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let session = note.object as? TerminalSessionModel else { return }
            guard tabs.contains(where: { tab in
                tab.splitController.terminalSessions.contains { _, candidate in candidate === session }
            }) else { return }

            // Debounce: coalesce rapid state changes (e.g., spinner animations
            // updating activeAppName at ~1/sec) into a single evaluation.
            suspensionDebounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Log.trace("renderSuspension: session state changed tabSession=\(session.tabIdentifier)")
                updateSuspensionState()
                // Note: with @Observable, property mutations auto-trigger
                // observation — no manual send needed.
            }
            self.suspensionDebounceItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
        }

        self.terminalRuntimeReadinessObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionRuntimeReadinessChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let session = note.object as? TerminalSessionModel else { return }
            guard tabs.contains(where: { tab in
                tab.splitController.terminalSessions.contains { _, candidate in candidate === session }
            }) else { return }

            let source = note.userInfo?["source"] as? String ?? "unknown"
            reconcileTabAttentionStyles(reason: "runtime_readiness:\(source)")
        }

        self.visibleFrameReadyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionVisibleFrameReady,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let session = note.object as? TerminalSessionModel else { return }
            guard let selected = selectedTab else { return }
            let isSelectedSession = selectedPresentationSession(for: selected) === session
            guard isSelectedSession else { return }
            let state = session.presentationSurfaceState
            if let startedAt = state.revealStartedAt,
               let presentedAt = state.firstFramePresentedAt {
                let elapsedMs = Int((presentedAt - startedAt) * 1000)
                Log.trace("tab handoff: first frame presented for \(selected.id) after \(elapsedMs)ms")
            }
            if state.revealStartedAt != nil {
                scheduleSelectedTerminalPresentationCommit(
                    reason: "selected_live_frame_ready",
                    delay: Self.terminalReadyCompositingDelay
                )
            }
            noteStartupSelectedTabLiveFrameIfNeeded(reason: "visible_frame_ready")
        }

        // When a terminal starts (any tab), re-attempt shared Metal coordinator
        // creation for the selected tab. During startup restore, the selected tab
        // doesn't have a view yet when selectTab() first runs, so the coordinator
        // can't be created. This observer catches the moment the terminal is ready.
        self.terminalDidStartObserver = NotificationCenter.default.addObserver(
            forName: .terminalDidStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            _ = refreshSelectedTabInPlaceIfPossible(reason: "terminal_did_start")
        }
    }

    deinit {
        Log.warn("OverlayTabsModel deinit — tabs=\(tabs.count) pid=\(ProcessInfo.processInfo.processIdentifier)")
        stopTabBarWatchdog()
        if let ctoModeObserver { NotificationCenter.default.removeObserver(ctoModeObserver) }
        if let renderSuspensionObserver { NotificationCenter.default.removeObserver(renderSuspensionObserver) }
        if let repoGroupingModeObserver { NotificationCenter.default.removeObserver(repoGroupingModeObserver) }
        if let visibleFrameReadyObserver { NotificationCenter.default.removeObserver(visibleFrameReadyObserver) }
        if let terminalDidStartObserver { NotificationCenter.default.removeObserver(terminalDidStartObserver) }
        if let terminalRuntimeReadinessObserver { NotificationCenter.default.removeObserver(terminalRuntimeReadinessObserver) }
        sharedMetalCoordinator?.stop()
        previousLiveHierarchyReleaseWorkItem?.cancel()
        terminalReadyCommitWorkItem?.cancel()
        selectedTerminalRevealTimeoutWorkItem?.cancel()
        // Cancel pending async work that otherwise fires [weak self]→nil
        // noops against a dead model. Each of these schedules
        // DispatchQueue.main.asyncAfter closures that can delay
        // deallocation of captured state (and would fire strong-self if a
        // future refactor broke the weak-capture invariant).
        suspendWorkItems.values.forEach { $0.cancel() }
        suspendWorkItems.removeAll()
        hoverCardTimer?.cancel()
        hoverCardTimer = nil
        hoverCardDismissTimer?.cancel()
        hoverCardDismissTimer = nil
    }

    // MARK: - Tab State Serialization

    /// Saves current tab state to disk backups. Does NOT write to UserDefaults —
    /// that is handled centrally by AppDelegate.saveAllWindowStates() to avoid
    /// multi-window race conditions.
    func saveTabState(reason: TabStateSaveReason = .manual) {
        let states = exportTabStates()
        guard !states.isEmpty else { return }
        guard let data = Persist.encodeLogged(states, context: "saveTabState[\(reason.rawValue)]") else { return }
        persistTabStateBackups(data: data, reason: reason)
        Log.trace("Saved \(states.count) tab state(s) to disk backup [\(reason.rawValue)]")
    }

    /// Builds `[SavedTerminalPaneState]` from a tab's live sessions.
    ///
    /// Shared by `exportTabStates` (multi-tab save path) and the live-session
    /// branch of `captureClosedTabSnapshot` (single-tab undo capture). The two
    /// previously had a near-duplicate per-pane loop; the only behavioural
    /// distinction is whether a fallback `SavedTabState` is consulted when the
    /// live session lacks AI metadata.
    ///
    /// - Parameters:
    ///   - tab: tab whose `splitController.terminalSessions` are serialized
    ///   - maxLines: scrollback line cap (per `FeatureSettings.restoredScrollbackLines`)
    ///   - fallbackTabState: previously persisted state for the tab, used only
    ///     by the multi-tab save path to recover AI identity when the live
    ///     session has been wiped (e.g. shell exited but resume metadata is
    ///     still useful). Pass `nil` from single-tab capture call sites.
    ///   - claimedSessionIds: cross-pane dedup set; mutated in place. Pass an
    ///     empty (and discardable) set when called from a single-tab path.
    private func buildPaneStates(
        for tab: OverlayTab,
        maxLines: Int,
        fallbackTabState: SavedTabState?,
        claimedSessionIds: inout Set<String>
    ) -> [SavedTerminalPaneState] {
        let terminalSessions = tab.splitController.terminalSessions
        let fallbackPaneStatesByID = Self.paneStateMap(from: fallbackTabState?.paneStates)

        var paneStates: [SavedTerminalPaneState] = []
        for (paneID, session) in terminalSessions {
            let dir = session.currentDirectory
            let scrollback = Self.captureScrollback(from: session, maxLines: maxLines)
            let knownRepoIdentity = Self.persistedRepoIdentity(
                for: session,
                directory: dir,
                fallbackRoot: tab.repoGroupID
            )
            let persistedIdentity = persistedAISessionIdentity(
                from: session,
                claimedSessionIds: claimedSessionIds
            )
            let fallbackPaneState = fallbackPaneStatesByID[paneID]
            let fallbackMetadata = fallbackPaneState.flatMap {
                Self.resolveAIResumeMetadataFromSavedState(
                    paneState: $0,
                    fallbackAIProvider: fallbackTabState?.aiProvider,
                    fallbackAISessionId: fallbackTabState?.aiSessionId,
                    fallbackAISessionIdSource: fallbackTabState?.aiSessionIdSource
                )
            }
            let fallbackSanitized = AIResumeOwnership.sanitizeForPersistence(
                provider: fallbackMetadata?.provider,
                sessionId: fallbackMetadata?.sessionId,
                claimedSessionIds: claimedSessionIds
            )
            let effectiveProvider = persistedIdentity.provider ?? fallbackSanitized.provider
            let effectiveSessionID = persistedIdentity.sessionId ?? fallbackSanitized.sessionId
            let effectiveSessionIDSource: AISessionIdentitySource? = if effectiveSessionID == nil {
                nil
            } else {
                persistedIdentity.sessionIdSource ?? fallbackMetadata?.sessionIdSource
            }
            let resumeCommand = Self.buildAIResumeCommand(
                provider: effectiveProvider,
                sessionId: effectiveSessionID,
                sessionIdSource: effectiveSessionIDSource
            ) ?? Self.normalizedResumeCommand(fallbackPaneState?.aiResumeCommand)
            if let sessionId = effectiveSessionID { claimedSessionIds.insert(sessionId) }

            paneStates.append(SavedTerminalPaneState(
                paneID: paneID.uuidString,
                directory: dir,
                scrollbackContent: scrollback,
                aiResumeCommand: resumeCommand,
                aiProvider: effectiveProvider,
                aiSessionId: effectiveSessionID,
                aiSessionIdSource: effectiveSessionIDSource,
                lastOutputAt: Self.normalizedResumeReferenceDate(session.lastOutputDate),
                lastInputAt: session.lastInputDate,
                knownRepoRoot: knownRepoIdentity?.rootPath,
                knownGitBranch: knownRepoIdentity?.branch,
                lastStatus: session.effectiveStatus,
                agentLaunchCommand: session.lastAgentLaunchCommand,
                agentStartedAt: session.agentStartedAt,
                lastExitCode: session.lastExitCode,
                lastExitAt: session.lastExitAt
            ))
        }
        return paneStates
    }

    /// Exports current tab states without persisting to disk.
    /// Used by AppDelegate to collect all windows' states for multi-window save.
    func exportTabStates() -> [SavedTabState] {
        let selectedID = selectedTabID
        let maxLines = FeatureSettings.shared.restoredScrollbackLines
        var states: [SavedTabState] = []
        var claimedSessionIds = Set<String>()

        for (i, tab) in tabs.enumerated() {
            let terminalSessions = tab.splitController.terminalSessions
            let isSelected = tab.id == selectedID
            let overrideRaw: String? = tab.tokenOptOverride == .default ? nil : tab.tokenOptOverride.rawValue

            let paneStates = buildPaneStates(
                for: tab,
                maxLines: maxLines,
                fallbackTabState: persistedRestoreFallbackStatesByTabID[tab.id],
                claimedSessionIds: &claimedSessionIds
            )

            let primaryDirectory = terminalSessions.first?.1.currentDirectory
                ?? tab.session?.currentDirectory
                ?? TerminalSessionModel.defaultStartDirectory()
            let primaryKnownRepoIdentity = paneStates.first.flatMap(Self.persistedRepoIdentity(from:))
                ?? tab.session.flatMap {
                    Self.persistedRepoIdentity(
                        for: $0,
                        directory: primaryDirectory,
                        fallbackRoot: tab.repoGroupID
                    )
                }

            states.append(SavedTabState(
                tabID: tab.id.uuidString,
                selectedTabID: isSelected ? tab.id.uuidString : nil,
                customTitle: tab.customTitle,
                color: tab.color.rawValue,
                directory: primaryDirectory,
                selectedIndex: isSelected ? i : nil,
                tokenOptOverride: overrideRaw,
                scrollbackContent: paneStates.first?.scrollbackContent,
                aiResumeCommand: paneStates.first?.aiResumeCommand,
                aiProvider: paneStates.first?.aiProvider,
                aiSessionId: paneStates.first?.aiSessionId,
                aiSessionIdSource: paneStates.first?.aiSessionIdSource,
                splitLayout: tab.splitController.exportLayout(),
                focusedPaneID: tab.splitController.focusedTerminalSessionID()?.uuidString,
                paneStates: paneStates.isEmpty ? nil : paneStates,
                createdAt: DateFormatters.iso8601.string(from: tab.createdAt),
                repoGroupID: tab.repoGroupID,
                knownRepoRoot: primaryKnownRepoIdentity?.rootPath,
                knownGitBranch: primaryKnownRepoIdentity?.branch,
                lastInputAt: paneStates.first?.lastInputAt,
                lastStatus: paneStates.first?.lastStatus,
                agentLaunchCommand: paneStates.first?.agentLaunchCommand,
                agentStartedAt: paneStates.first?.agentStartedAt,
                lastExitCode: paneStates.first?.lastExitCode,
                lastExitAt: paneStates.first?.lastExitAt,
                commandBlocks: MainActor.assumeIsolated {
                    CommandBlockManager.shared.blocksForTab(tab.id.uuidString)
                },
                previewSnapshotPNGData: nil
            ))
        }
        return states
    }

    /// Captures a snapshot of a tab about to be closed and pushes it onto the
    /// closed-tab stack. Must be called BEFORE `closeAllSessions()` kills the shell,
    /// because we need the live scrollback buffer and active app name.
    func captureClosedTabSnapshot(tab: OverlayTab, at index: Int) {
        // If the tab was closed before its deferred restore ran, the live
        // session has only the eager-seeded provider and no other persisted
        // AI metadata — scrollback, aiSessionId, agentLaunchCommand, etc.
        // are still sitting in deferredRestoreStatesByTabID. Prefer the
        // deferred state directly so Cmd+Shift+T gets the full last-saved
        // record, and drain the dict/order so the state doesn't linger in
        // memory after the tab is gone.
        if let deferredState = deferredRestoreStatesByTabID.removeValue(forKey: tab.id) {
            deferredRestoreTabOrder.removeAll { $0 == tab.id }
            let archivedState = SavedTabState(
                tabID: deferredState.tabID,
                selectedTabID: nil,
                customTitle: deferredState.customTitle,
                color: deferredState.color,
                directory: deferredState.directory,
                selectedIndex: nil,
                tokenOptOverride: deferredState.tokenOptOverride,
                scrollbackContent: deferredState.scrollbackContent,
                aiResumeCommand: deferredState.aiResumeCommand,
                aiProvider: deferredState.aiProvider,
                aiSessionId: deferredState.aiSessionId,
                aiSessionIdSource: deferredState.aiSessionIdSource,
                splitLayout: deferredState.splitLayout,
                focusedPaneID: deferredState.focusedPaneID,
                paneStates: deferredState.paneStates,
                createdAt: deferredState.createdAt,
                repoGroupID: deferredState.repoGroupID,
                knownRepoRoot: deferredState.knownRepoRoot,
                knownGitBranch: deferredState.knownGitBranch,
                lastInputAt: deferredState.lastInputAt,
                lastStatus: deferredState.lastStatus,
                agentLaunchCommand: deferredState.agentLaunchCommand,
                agentStartedAt: deferredState.agentStartedAt,
                lastExitCode: deferredState.lastExitCode,
                lastExitAt: deferredState.lastExitAt,
                commandBlocks: deferredState.commandBlocks,
                previewSnapshotPNGData: nil
            )
            closedTabStack.append(ClosedTabEntry(
                state: archivedState,
                originalIndex: index,
                closedAt: Date()
            ))
            if closedTabStack.count > maxClosedTabs {
                closedTabStack.removeFirst(closedTabStack.count - maxClosedTabs)
            }
            Log.info(
                "Captured closed tab snapshot from deferred state: \"\(tab.displayTitle)\" at index \(index) (stack size: \(closedTabStack.count))"
            )
            return
        }

        let maxLines = FeatureSettings.shared.restoredScrollbackLines
        let terminalSessions = tab.splitController.terminalSessions

        // Single-tab capture has no cross-tab dedup concern — pass an
        // empty claimed set and discard. fallbackTabState is nil because
        // the closed-tab snapshot is built entirely from live session
        // state (the deferred-state branch above already handled the
        // case where the tab was closed before its restore ran).
        var localClaimedSessionIds = Set<String>()
        let paneStates = buildPaneStates(
            for: tab,
            maxLines: maxLines,
            fallbackTabState: nil,
            claimedSessionIds: &localClaimedSessionIds
        )

        let primaryDirectory = terminalSessions.first?.1.currentDirectory
            ?? tab.session?.currentDirectory
            ?? TerminalSessionModel.defaultStartDirectory()
        let primaryScrollback = paneStates.first?.scrollbackContent
        let primaryResumeCommand = paneStates.first?.aiResumeCommand
        let primaryKnownRepoIdentity = paneStates.first.flatMap(Self.persistedRepoIdentity(from:))
            ?? tab.session.flatMap {
                Self.persistedRepoIdentity(
                    for: $0,
                    directory: primaryDirectory,
                    fallbackRoot: tab.repoGroupID
                )
            }

        let overrideRaw = tab.tokenOptOverride == .default ? nil : tab.tokenOptOverride.rawValue
        let state = SavedTabState(
            tabID: tab.id.uuidString,
            selectedTabID: nil,
            customTitle: tab.customTitle,
            color: tab.color.rawValue,
            directory: primaryDirectory,
            selectedIndex: nil,
            tokenOptOverride: overrideRaw,
            scrollbackContent: primaryScrollback,
            aiResumeCommand: primaryResumeCommand,
            aiProvider: paneStates.first?.aiProvider,
            aiSessionId: paneStates.first?.aiSessionId,
            aiSessionIdSource: paneStates.first?.aiSessionIdSource,
            splitLayout: tab.splitController.exportLayout(),
            focusedPaneID: tab.splitController.focusedTerminalSessionID()?.uuidString,
            paneStates: paneStates.isEmpty ? nil : paneStates,
            createdAt: DateFormatters.iso8601.string(from: tab.createdAt),
            repoGroupID: tab.repoGroupID,
            knownRepoRoot: primaryKnownRepoIdentity?.rootPath,
            knownGitBranch: primaryKnownRepoIdentity?.branch,
            lastInputAt: paneStates.first?.lastInputAt,
            lastStatus: paneStates.first?.lastStatus,
            agentLaunchCommand: paneStates.first?.agentLaunchCommand,
            agentStartedAt: paneStates.first?.agentStartedAt,
            lastExitCode: paneStates.first?.lastExitCode,
            lastExitAt: paneStates.first?.lastExitAt,
            commandBlocks: MainActor.assumeIsolated {
                CommandBlockManager.shared.blocksForTab(tab.id.uuidString)
            },
            previewSnapshotPNGData: nil
        )

        closedTabStack.append(ClosedTabEntry(
            state: state,
            originalIndex: index,
            closedAt: Date()
        ))

        // Cap the stack
        if closedTabStack.count > maxClosedTabs {
            closedTabStack.removeFirst(closedTabStack.count - maxClosedTabs)
        }

        Log.info("Captured closed tab snapshot: \"\(tab.displayTitle)\" at index \(index) (stack size: \(closedTabStack.count))")
    }

}

extension String {
    func extractResumeSessionId(prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        let suffix = String(dropFirst(prefix.count))
        return suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : suffix
    }
}

// MARK: - TabSnapshotReleaser

extension OverlayTabsModel: TabSnapshotReleaser {
    @MainActor
    func releaseSnapshots(forTabID tabID: UUID, tier: TabGraphicsMemoryManager.ReleaseTier) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        switch tier {
        case .keepAll:
            break
        case .keepCachedOnly:
            tabs[index].restorePreviewSnapshot = nil
        case .releaseAll:
            tabs[index].restorePreviewSnapshot = nil
        }
    }
}
