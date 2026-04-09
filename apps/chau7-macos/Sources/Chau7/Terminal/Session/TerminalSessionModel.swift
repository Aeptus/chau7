import Foundation
import AppKit
import Darwin
import Chau7Core

extension Notification.Name {
    static let terminalSessionRenderSuspensionStateChanged =
        Notification.Name("com.chau7.terminalSessionRenderSuspensionStateChanged")
    static let terminalSessionRuntimeReadinessChanged =
        Notification.Name("com.chau7.terminalSessionRuntimeReadinessChanged")
}

enum CommandStatus: String {
    case idle
    case running
    case waitingForInput // AI agent waiting for user input/permission
    case stuck // Running for too long without output
    case exited
}

/// Model for a terminal session, managing shell state, search, and output capture.
/// - Note: Thread Safety - Properties must be modified on main thread.
///   Callbacks may arrive on background threads and dispatch to main via DispatchQueue.main.async.
@Observable
final class TerminalSessionModel {
    private enum PendingTerminalAction {
        case text(String)
        case keyPress(TerminalKeyPress)
    }

    struct LatencySampleBuffer {
        var buffer: [Int]
        var index = 0
        private(set) var count = 0

        init(capacity: Int) {
            self.buffer = Array(repeating: 0, count: max(1, capacity))
        }

        mutating func append(_ value: Int) {
            buffer[index] = value
            index = (index + 1) % buffer.count
            count = min(count + 1, buffer.count)
        }

        mutating func reset() {
            index = 0
            count = 0
        }

        var isEmpty: Bool {
            count == 0 // swiftlint:disable:this empty_count
        }

        func values() -> [Int] {
            if count >= buffer.count {
                return buffer
            }
            return Array(buffer.prefix(count))
        }

        /// Sliding-window average over the most recent samples in the buffer.
        func recentAverage() -> Int? {
            guard !isEmpty else { return nil }
            let vals = values()
            return vals.reduce(0, +) / vals.count
        }
    }

    enum LagKind: String, CaseIterable {
        case input
        case output
        case highlight
    }

    struct LagEvent: Identifiable, Equatable {
        let id = UUID()
        let kind: LagKind
        let elapsedMs: Int
        let averageMs: Int
        let p50: Int?
        let p95: Int?
        let sampleCount: Int
        let timestamp: Date
        let tabTitle: String
        let appName: String
        let cwd: String
    }

    var title = "Shell" {
        didSet { onSessionStateChanged?() }
    }

    var currentDirectory: String = TerminalSessionModel.defaultStartDirectory() {
        didSet { onSessionStateChanged?() }
    }

    /// Unique identifier for this terminal tab, used for task lifecycle tracking
    @ObservationIgnored let tabIdentifier: String = UUID().uuidString

    /// Callback invoked when session state changes, for non-SwiftUI observers
    /// (e.g. RemoteControlManager). Replaces the old objectWillChange.sink pattern.
    @ObservationIgnored var onSessionStateChanged: (() -> Void)?

    /// The owning tab's UUID, set by OverlayTabsModel at tab creation time.
    /// Propagated to ShellEventDetector so emitted events carry a deterministic tabID
    /// for the fast-path in TabResolver.
    @ObservationIgnored var ownerTabID: UUID? {
        didSet { shellEventDetector.ownerTabID = ownerTabID }
    }

    var status: CommandStatus = .idle {
        didSet {
            onSessionStateChanged?()
            if status != oldValue {
                postRuntimeReadinessChange(source: "status")
            }
        }
    }

    var isGitRepo = false
    var gitBranch: String?
    var repositoryAccessSnapshot = ProtectedPathAccessPolicy.accessSnapshot(
        root: nil,
        isProtectedPath: false,
        isFeatureEnabled: false,
        hasActiveScope: false,
        hasSecurityScopedBookmark: false,
        isDeniedByCooldown: false,
        hasKnownIdentity: false
    )
    /// Callback invoked when `gitRootPath` changes (used by OverlayTabsModel for auto-grouping).
    @ObservationIgnored var onGitRootPathChanged: ((String?) -> Void)?

    var gitRootPath: String? {
        didSet { onGitRootPathChanged?(gitRootPath) }
    }

    var activeAppName: String? {
        didSet {
            recalculateCTOFlag()
            onSessionStateChanged?()
            if activeAppName != oldValue {
                postRuntimeReadinessChange(source: "active_app")
                NotificationCenter.default.post(
                    name: .terminalSessionRenderSuspensionStateChanged,
                    object: self
                )
            }
        }
    }

    /// Effective app name for UI branding and diagnostics.
    /// Falls back to the last known persisted metadata provider if active
    /// detection from output/command history is not currently available.
    var aiDisplayAppName: String? {
        if let active = activeAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !active.isEmpty {
            return active
        }
        return Self.displayName(fromProvider: lastAIProvider)
    }

    var effectiveAIProvider: String? {
        // lastDetectedAppName is set by live command + output detection and
        // survives process exit — it's the most authoritative signal for which
        // CLI tool was running (e.g. "Codex"), independent of the LLM backend.
        if let provider = AIResumeParser.normalizeProviderName(lastDetectedAppName ?? "") {
            return provider
        }
        if let provider = AIResumeParser.normalizeProviderName(lastAIProvider ?? "") {
            return provider
        }
        if let provider = TelemetryRecorder.shared.activeRunForTab(tabIdentifier)?.provider {
            return AIResumeParser.normalizeProviderName(provider)
        }
        return nil
    }

    var effectiveAISessionId: String? {
        if let sessionId = lastAISessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           AIResumeParser.isValidSessionId(sessionId) {
            return sessionId
        }

        let telemetrySessionId = TelemetryRecorder.shared.activeRunForTab(tabIdentifier)?.sessionID
        guard let telemetrySessionId = telemetrySessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              AIResumeParser.isValidSessionId(telemetrySessionId) else {
            return nil
        }
        return telemetrySessionId
    }

    var effectiveStatus: CommandStatus {
        guard let historyState = matchedAIHistoryState else { return status }
        return Self.resolveEffectiveStatus(historyState: historyState, fallback: status)
    }

    var effectiveIsAtPrompt: Bool {
        guard let historyState = matchedAIHistoryState else { return isAtPrompt }
        return Self.resolveEffectivePromptState(historyState: historyState, fallback: isAtPrompt)
    }

    /// Whether the AI logo should appear at full opacity.
    /// Grey (false) only for restored sessions that haven't been re-detected live.
    /// True when an AI tool is actively detected as running (colored icon).
    /// False when the tool has finished / shell prompt returned (grey icon),
    /// or when the session was restored from disk but not yet re-detected live.
    var isAIRunning: Bool {
        guard activeAppName != nil else { return false }
        return !aiDetection.isRestored
    }

    var shouldKeepLiveRenderingInBackground: Bool {
        // Only keep live rendering when an AI tool is actively running (activeAppName
        // is set). Previously used hasBackgroundRenderingAIContext which included
        // persisted provider/sessionId — making every tab that EVER ran an AI tool
        // permanently exempt from suspension.
        guard activeAppName != nil else { return false }
        return effectiveStatus != .exited
    }

    var renderSuspensionDebugSummary: String {
        let app = aiDisplayAppName
            ?? Self.displayName(fromProvider: effectiveAIProvider)
            ?? "shell"
        let provider = effectiveAIProvider ?? "nil"
        let sessionId = effectiveAISessionId ?? "nil"
        return "app=\(app) provider=\(provider) sessionId=\(sessionId) status=\(effectiveStatus.rawValue) prompt=\(effectiveIsAtPrompt)"
    }

    var devServer: DevServerMonitor.DevServerInfo?
    var processGroup: ProcessGroupSnapshot?
    var tabTitleOverride: String?
    var fontSize: CGFloat = 13
    var searchMatches: [SearchMatch] = []
    var activeSearchIndex = 0
    /// Whether the shell is at a prompt (not running a command). Used by history key monitor.
    var isAtPrompt = true {
        didSet {
            onSessionStateChanged?()
            if isAtPrompt != oldValue {
                postRuntimeReadinessChange(source: "prompt")
            }
        }
    }

    /// Called when a permission/question is answered (user submits input after waiting).
    /// Used to clear the persistent red border on the tab.
    @ObservationIgnored var onPermissionResolved: (() -> Void)?

    /// Whether the shell is still loading (no prompt yet). Cleared on first OSC 7.
    var isShellLoading = true {
        didSet {
            if isShellLoading != oldValue {
                postRuntimeReadinessChange(source: "shell_loading")
            }
        }
    }

    /// Set to true when no PTY output arrives within the startup timeout (shell may be hung).
    /// Cleared automatically on first output.
    var shellStartupSlow = false

    /// Last time output was observed for this terminal session.
    /// Used by tab restore logic to choose the best-matching AI session when
    /// multiple candidate sessions exist for the same directory.
    var lastOutputDate: Date {
        lastOutputAt
    }

    /// The most recent input or output activity timestamp.
    var lastActivityDate: Date {
        max(lastInputAt, lastOutputAt)
    }

    private func postRuntimeReadinessChange(source: String) {
        NotificationCenter.default.post(
            name: .terminalSessionRuntimeReadinessChanged,
            object: self,
            userInfo: ["source": source]
        )
    }

    /// Backdate activity timestamps to force the tab into the idle dropdown.
    /// Uses 11 minutes ago (just over the 10-minute threshold) rather than
    /// distantPast, which would trigger the fallback completion timer and
    /// corrupt the command-tracking state for running commands.
    func resetActivityForIdleGrouping() {
        let backdated = Date(timeIntervalSinceNow: -660) // 11 minutes ago
        lastInputAt = backdated
        lastOutputAt = backdated
    }

    var lastAIProvider: String?
    var lastAISessionId: String?
    /// The last app name set by live detection (command or output).
    /// Unlike `activeAppName`, this is NOT cleared on process exit,
    /// so it survives across save/restore boundaries.
    var lastDetectedAppName: String?

    /// Update the last detected app name and clear stale session metadata
    /// when the provider changes. For example, if `lastAIProvider` is "claude"
    /// (from a wrong restore) but output detection identifies "Codex",
    /// the Claude session ID in `lastAISessionId` is invalid for Codex.
    func updateLastDetectedApp(_ app: String) {
        lastDetectedAppName = app
        if let newProvider = AIResumeParser.normalizeProviderName(app),
           let oldProvider = AIResumeParser.normalizeProviderName(lastAIProvider ?? ""),
           newProvider != oldProvider {
            lastAISessionId = nil
        }
    }

    var hasBackgroundRenderingAIContext: Bool {
        aiDisplayAppName != nil || effectiveAIProvider != nil || effectiveAISessionId != nil
    }

    private var matchedAIHistoryState: HistorySessionState? {
        guard let appModel,
              let provider = effectiveAIProvider,
              let sessionId = effectiveAISessionId else {
            return nil
        }

        let toolName = Self.displayName(fromProvider: provider) ?? provider.capitalized
        return appModel.latestSessionStatus(toolName: toolName, sessionId: sessionId)?.state
    }

    static func displayName(fromProvider provider: String?) -> String? {
        guard let normalized = AIResumeParser.normalizeProviderName(provider ?? "") else {
            return nil
        }
        if let tool = AIToolRegistry.allTools.first(where: { $0.resumeProviderKey == normalized }) {
            return tool.displayName
        }
        return normalized.capitalized
    }

    static func resolveEffectiveStatus(
        historyState: HistorySessionState,
        fallback: CommandStatus
    ) -> CommandStatus {
        switch historyState {
        case .active:
            return fallback == .waitingForInput ? .waitingForInput : .running
        case .idle:
            return fallback == .exited ? .exited : .idle
        case .closed:
            return fallback
        }
    }

    static func resolveEffectivePromptState(
        historyState: HistorySessionState,
        fallback: Bool
    ) -> Bool {
        switch historyState {
        case .active:
            return false
        case .idle:
            return true
        case .closed:
            return fallback
        }
    }

    // MARK: - Latency Telemetry (non-Published for performance)

    // These change on every keystroke. @ObservationIgnored prevents SwiftUI from
    // triggering updateNSView on every keystroke, adding unnecessary overhead.
    // The debug console has its own 1-second refresh timer to read these values.
    @ObservationIgnored var inputLatencyMs: Int?
    @ObservationIgnored var inputLatencyAverageMs: Int?
    @ObservationIgnored var outputLatencyMs: Int?
    @ObservationIgnored var outputLatencyAverageMs: Int?
    @ObservationIgnored var dangerousHighlightDelayMs: Int?
    @ObservationIgnored var dangerousHighlightAverageMs: Int?
    var lagTimeline: [LagEvent] = []

    @ObservationIgnored weak var appModel: AppModel?
    /// Rust terminal view
    @ObservationIgnored weak var rustTerminalView: RustTerminalView?
    /// Strong reference to keep the Rust terminal view alive across SwiftUI view recreations
    @ObservationIgnored private var retainedRustTerminalView: RustTerminalView?
    /// Prefill command queued when restore/restoration occurs before terminal is ready.
    @ObservationIgnored private var pendingPrefillInput: String?
    /// Retry counter for pending prefill flush attempts.
    @ObservationIgnored private var pendingPrefillRetries = 0
    /// The next echoed command line that should be treated as a system-injected
    /// restore command rather than explicit user input.
    @ObservationIgnored var pendingSystemRestoreInputLine: String?
    var hasPendingResumePrefillActivity: Bool {
        pendingPrefillInput != nil || pendingPrefillRetries > 0 || isShellLoading
    }

    /// Input queued before the terminal view exists. Preserves ordering between raw
    /// text input and synthesized key presses, then flushes on view attachment.
    @ObservationIgnored private var pendingTerminalActions: [PendingTerminalAction] = []
    /// Cached snapshot of the last rendered terminal frame, used for instant tab-switch visuals
    /// when the actual NSView has been removed from the hierarchy (distant-tab optimization).
    @ObservationIgnored var lastRenderedSnapshot: NSImage?
    @ObservationIgnored private var settingsObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var idleTimer: DispatchSourceTimer?
    @ObservationIgnored var lastInputAt = Date()
    @ObservationIgnored var lastOutputAt = Date()
    @ObservationIgnored var commandStartedAt = Date.distantPast // Track when command started for "stuck" detection
    @ObservationIgnored var hasPendingCommand = false
    @ObservationIgnored var inputBuffer = ""
    /// Shared repository model for this session's current git repo (nil if not in a repo)
    var repositoryModel: RepositoryModel?
    @ObservationIgnored var searchUpdateWorkItem: DispatchWorkItem?
    @ObservationIgnored let searchQueue = DispatchQueue(label: "com.chau7.search", qos: .utility)
    @ObservationIgnored var searchQuery = ""
    @ObservationIgnored var cachedBufferData: Data? // Cached buffer data for search
    @ObservationIgnored var bufferNeedsRefresh = true // Flag to invalidate cache on output
    @ObservationIgnored var bufferLineCount = 0
    @ObservationIgnored var pendingInputLatencyAt: CFAbsoluteTime?
    @ObservationIgnored var inputLatencySampleCount = 0
    @ObservationIgnored var inputLatencyTotalMs: Double = 0
    @ObservationIgnored var pendingOutputLatencyAt: CFAbsoluteTime?
    @ObservationIgnored var pendingAITimingInputAt: Date?
    @ObservationIgnored var pendingAITimingInputChars = 0
    @ObservationIgnored var pendingAIRoundTripCompleted = false
    @ObservationIgnored var pendingWaitingInputFallbackArmed = false
    @ObservationIgnored var pendingWaitingInputFallbackSawLiveOutput = false
    @ObservationIgnored var suppressWaitingInputFallbackUntilNextUserCommand = false
    @ObservationIgnored var didLogRestoreSuppressionOnce = false
    @ObservationIgnored var deliveredSystemResumePrefillSinceLastUserCommand = false
    @ObservationIgnored var outputLatencySampleCount = 0
    @ObservationIgnored var outputLatencyTotalMs: Double = 0
    @ObservationIgnored let inputLagLogThresholdMs: Double = 60
    @ObservationIgnored let outputLagLogThresholdMs: Double = 120
    @ObservationIgnored let highlightLagLogThresholdMs: Double = 120
    @ObservationIgnored let maxAcceptedLatencyMs: Double = 10000
    @ObservationIgnored let latencyLogCooldownSeconds: TimeInterval = 15
    @ObservationIgnored var lastInputLagLogAt: Date?
    @ObservationIgnored var lastOutputLagLogAt: Date?
    @ObservationIgnored var lastHighlightLagLogAt: Date?
    @ObservationIgnored let lagTimelineCapacity = 120
    @ObservationIgnored private let latencySampleCapacity = 120
    @ObservationIgnored var inputLatencySamples: LatencySampleBuffer
    @ObservationIgnored var outputLatencySamples: LatencySampleBuffer
    @ObservationIgnored var dangerousHighlightSamples: LatencySampleBuffer
    @ObservationIgnored var outputBurstStartAt = Date.distantPast
    @ObservationIgnored var outputBurstBytes = 0
    @ObservationIgnored var outputBurstChunks = 0
    @ObservationIgnored var outputBurstActive = false
    @ObservationIgnored let outputBurstWindowSeconds: TimeInterval = 2.0
    @ObservationIgnored let outputBurstIdleThreshold: TimeInterval = 0.35
    @ObservationIgnored let outputBurstBytesThreshold = 64 * 1024
    @ObservationIgnored let outputBurstChunksThreshold = 24
    @ObservationIgnored var dangerousHighlightSampleCount = 0
    @ObservationIgnored var dangerousHighlightTotalMs: Double = 0
    @ObservationIgnored var outputRiskCacheVersion = 0
    @ObservationIgnored var outputRiskCache: [Int: (version: Int, isRisk: Bool)] = [:]
    @ObservationIgnored let outputRiskCacheMaxEntries = 800
    @ObservationIgnored var dirtyOutputRange: ClosedRange<Int>?
    @ObservationIgnored var outputLatencyFallbackWorkItem: DispatchWorkItem?
    @ObservationIgnored let outputLatencyFallbackSeconds: TimeInterval = 0.2
    @ObservationIgnored let aiTimingWindowSeconds: TimeInterval = 120
    @ObservationIgnored let remoteOutputQueue = DispatchQueue(label: "com.chau7.remoteOutput", qos: .utility)
    /// Queue for heavy output processing to avoid blocking main thread (Fix #6)
    @ObservationIgnored let outputProcessingQueue = DispatchQueue(label: "com.chau7.outputProcessing", qos: .userInitiated)
    @ObservationIgnored var pendingRemoteOutput = Data()
    @ObservationIgnored var remoteOutputFlushWorkItem: DispatchWorkItem?
    @ObservationIgnored let remoteOutputFlushInterval: TimeInterval = 0.05
    @ObservationIgnored let remoteOutputMaxBufferBytes = 256 * 1024
    @ObservationIgnored let remoteOutputBatchingEnabled: Bool = {
        if let raw = EnvVars.get(EnvVars.remoteOutputBatch) {
            let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !(lowered == "0" || lowered == "false" || lowered == "off")
        }
        return true
    }()

    @ObservationIgnored private var didClearOnLaunch = false
    @ObservationIgnored var didApplyShellIntegration = false
    @ObservationIgnored var shellIntegrationOutputCount = 0
    @ObservationIgnored private var shouldAutoFocusOnAttach = true // Auto-focus when terminal view is attached
    @ObservationIgnored var didStartDevServerMonitor = false // Track if dev server monitor has started
    // AI detection state machine — handles sliding buffer, cooldown, re-detection
    // locking, and phase transitions. See AIDetectionState.swift for details.
    @ObservationIgnored var aiDetection = AIDetectionState()
    @ObservationIgnored var pendingCommandLine: String?
    @ObservationIgnored var promptSeenForPendingCommand = false
    @ObservationIgnored var commandFinishedNotified = false
    /// True once the shell sends any OSC 133 marker. When set, heuristic
    /// command detection (echo-based start, timeout-based finish) is suppressed
    /// in favor of the authoritative shell signals.
    @ObservationIgnored private(set) var hasShellIntegration = false
    @ObservationIgnored private let terminationStateQueue = DispatchQueue(label: "com.chau7.terminal.termination")
    @ObservationIgnored private var didHandleProcessTermination = false
    @ObservationIgnored private var closeSessionRequested = false
    @ObservationIgnored private var closeSessionRequestedAt: Date?
    @ObservationIgnored private var sigintSentAt: Date?
    @ObservationIgnored private var sigtermSentAt: Date?
    @ObservationIgnored private var forcedTerminationWorkItem: DispatchWorkItem?
    @ObservationIgnored let dangerousCommandTracker = InputLineTracker(maxEntries: FeatureSettings.shared.scrollbackLines)
    @ObservationIgnored var dangerousOutputHighlightWorkItem: DispatchWorkItem?
    @ObservationIgnored var dangerousOutputHighlightLastRun = Date.distantPast
    /// Cached dangerous output rows from the most recent async scan (for in-grid tinting).
    @ObservationIgnored var cachedDangerousOutputRowSet: Set<Int> = []
    @ObservationIgnored var scrollHighlightWorkItem: DispatchWorkItem?
    @ObservationIgnored let scrollHighlightDebounceSeconds: TimeInterval = 0.15

    @ObservationIgnored let semanticDetector = SemanticOutputDetector()
    @ObservationIgnored let devServerMonitor = DevServerMonitor()
    @ObservationIgnored let processResourceMonitor = ProcessResourceMonitor()
    @ObservationIgnored lazy var shellEventDetector = ShellEventDetector(appModel: appModel)
    @ObservationIgnored private let gitDiffTracker = GitDiffTracker()
    static let osc7Prefix = Data([0x1B, 0x5D, 0x37, 0x3B])
    static let aiExitMarkerPrefix = Data("\u{001b}]9;chau7;exit=".utf8)
    static let aiExitMarkerSuffix = Data([0x07])
    static let aiExitMarkerKeepBytes = max(0, aiExitMarkerPrefix.count - 1)

    struct AILogContext {
        let toolName: String
        let commandLine: String?
        let logPath: String
    }

    /// Serial queue for synchronizing AI log state access.
    /// Required because `processAILogOutput` runs on outputProcessingQueue while
    /// `finishAILogging` and `startAILoggingIfNeeded` run on the main thread.
    @ObservationIgnored let aiLogQueue = DispatchQueue(label: "com.chau7.terminal.ailog")
    @ObservationIgnored var aiLogSession: AITerminalLogSession?
    @ObservationIgnored var aiLogContext: AILogContext?
    @ObservationIgnored var aiLogPrefixBuffer = Data()

    /// Path to the most recent AI session's PTY log. Preserved after the session ends
    /// so MCP tools (tab_output source=pty_log, tab_last_response) can read it.
    @ObservationIgnored var lastPTYLogPath: String?

    /// When true, output-based AI detection is suppressed to give command-based
    /// detection priority. Set when input containing a newline is sent (a command
    /// is being submitted), cleared when handleInputLine processes it.
    /// Prevents false positives where output pattern matching (e.g. "cline" in
    /// "decline") fires before command tokenization (e.g. "claude") runs.
    @ObservationIgnored var commandPendingDetection = false

    var notificationTabName: String {
        if let override = tabTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        if let active = activeAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !active.isEmpty {
            return active
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Shell" : trimmedTitle
    }

    /// Idle timeout in seconds. Configurable via environment variable.
    var idleSeconds: TimeInterval {
        if let envValue = EnvVars.get(EnvVars.idleSeconds, legacy: EnvVars.legacyIdleSeconds),
           let seconds = Double(envValue), seconds > 0 {
            return seconds
        }
        return 3.0
    }

    /// Stuck timeout in seconds - when command runs this long without output, mark as stuck.
    let stuckSeconds: TimeInterval = 30.0
    var fallbackCompletionSeconds: TimeInterval {
        if let raw = EnvVars.get(EnvVars.commandFallbackSeconds, legacy: EnvVars.legacyCommandFallbackSeconds),
           let value = Double(raw), value > 0 {
            return value
        }
        return max(30.0, max(idleSeconds * 3.0, stuckSeconds * 2.0))
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        self.inputLatencySamples = LatencySampleBuffer(capacity: latencySampleCapacity)
        self.outputLatencySamples = LatencySampleBuffer(capacity: latencySampleCapacity)
        self.dangerousHighlightSamples = LatencySampleBuffer(capacity: latencySampleCapacity)
        applyDefaultFontSize()
        installSettingsObservers()
        refreshGitStatus(path: currentDirectory)
        SnippetManager.shared.updateContextPath(currentDirectory)
        startIdleTimer()
        setupDevServerMonitor()
    }

    private func setupDevServerMonitor() {
        devServerMonitor.onDevServerChanged = { [weak self] serverInfo in
            self?.devServer = serverInfo
            if let serverInfo {
                Log.info("Dev server detected: \(serverInfo.name)\(serverInfo.port.map { " on port \($0)" } ?? " (port pending)")")
            } else {
                Log.info("Dev server stopped")
            }
        }
    }

    deinit {
        // Clean up resources
        for observer in settingsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        stopIdleTimer()
        repositoryModel?.onBranchChange = nil
        searchUpdateWorkItem?.cancel()
        aiLogSession?.close()
        devServerMonitor.stop()
        processResourceMonitor.stop()
        forcedTerminationWorkItem?.cancel()
    }

    // Process monitoring methods moved to TerminalSessionModel+ProcessMonitor.swift

    /// Returns the existing Rust terminal view if one exists
    var existingRustTerminalView: RustTerminalView? {
        retainedRustTerminalView
    }

    /// Exposed for background-tab coordination and tests.
    var autoFocusOnAttachEnabled: Bool {
        shouldAutoFocusOnAttach
    }

    func setAutoFocusOnAttach(_ enabled: Bool) {
        shouldAutoFocusOnAttach = enabled
    }

    /// Accessor for the active terminal view
    var activeTerminalView: (any TerminalViewLike)? {
        rustTerminalView ?? retainedRustTerminalView
    }

    func attachRustTerminal(_ view: RustTerminalView) {
        rustTerminalView = view
        retainedRustTerminalView = view // Keep strong reference to survive view recreation
        view.currentDirectory = currentDirectory

        // Configure scrollback buffer size from settings
        let scrollbackLines = FeatureSettings.shared.scrollbackLines
        view.applyScrollbackLines(scrollbackLines)
        Log.trace("Configured Rust terminal scrollback: \(scrollbackLines) lines")

        // Wire up title change callback
        view.onTitleChanged = { [weak self] title in
            DispatchQueue.main.async {
                let newTitle = title.isEmpty ? "Shell" : title
                guard self?.title != newTitle else { return }
                self?.title = newTitle
            }
        }

        // Wire up process termination callback
        view.onProcessTerminated = { [weak self] (exitCode: Int32?) in
            self?.handleProcessTermination(exitCode: exitCode)
        }

        // Wire up directory change callback
        view.onDirectoryChanged = { [weak self] (directory: String) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.updateCurrentDirectory(directory)
            }
            // When OSC 133 is active, it provides authoritative prompt signals —
            // don't infer "at prompt" from directory changes (keep OSC 7 for CWD only).
            if !hasShellIntegration {
                handlePromptDetected()
            }
            DispatchQueue.main.async { [weak self] in
                self?.clearActiveAppAfterPrompt()
            }
        }

        view.onShellIntegrationEvent = { [weak self] event in
            guard let self = self else { return }
            hasShellIntegration = true
            switch event {
            case .promptStart:
                handlePromptDetected()
            case .commandStart:
                isAtPrompt = false
                status = .running
                hasPendingCommand = true
                commandStartedAt = Date()
                commandFinishedNotified = false
                promptSeenForPendingCommand = false
                // Clear persistent permission border — user answered the prompt
                onPermissionResolved?()
            case .commandExecuted:
                shellEventDetector.commandStarted(command: pendingCommandLine, in: currentDirectory)
                notifyCommandBlockStarted()
                if isGitRepo {
                    let dir = currentDirectory
                    let tracker = gitDiffTracker
                    DispatchQueue.global(qos: .utility).async { tracker.snapshot(directory: dir) }
                }
            case .commandFinished(let exitCode):
                guard !commandFinishedNotified else { return }
                commandFinishedNotified = true
                hasPendingCommand = false
                promptSeenForPendingCommand = true
                shellEventDetector.commandFinished(exitCode: Int(exitCode), command: pendingCommandLine)
                notifyCommandBlockFinished(exitCode: Int(exitCode))
                if isGitRepo {
                    let dir = currentDirectory
                    let tabID = ownerTabID?.uuidString
                    let tracker = gitDiffTracker
                    DispatchQueue.global(qos: .utility).async {
                        let changed = tracker.changedFiles(directory: dir)
                        guard !changed.isEmpty, let tabID else { return }
                        DispatchQueue.main.async {
                            CommandBlockManager.shared.setChangedFiles(changed, forLastBlockIn: tabID)
                            ConflictDetector.shared.checkForConflicts()
                        }
                    }
                }
            }
        }

        // Auto-focus on attach for newly created tabs
        if shouldAutoFocusOnAttach {
            shouldAutoFocusOnAttach = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                guard let view = view, let window = view.window else { return }
                window.makeFirstResponder(view)
                Log.trace("Auto-focused Rust terminal view on attach")
            }
        }

        flushPendingTerminalActions()
        flushPendingPrefillInputIfReady()
    }

    func focusTerminal(in window: NSWindow?, retryCount: Int = 0) {
        guard let window else { return }
        let candidateView = rustTerminalView ?? retainedRustTerminalView

        if let view = candidateView,
           view.window === window,
           window.makeFirstResponder(view) {
            return
        }

        if retryCount < 8 {
            // The terminal view may exist but not be attached yet after tab switch.
            // Retry until the selected tab's view is in-window and focusable.
            let attempt = retryCount + 1
            Log.trace("focusTerminal: view not ready for '\(title)', retry \(attempt)/8 in 75ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.075) { [weak self] in
                self?.focusTerminal(in: window, retryCount: attempt)
            }
            return
        }

        Log.warn("focusTerminal: unable to focus terminal for '\(title)' after 8 retries")
    }

    // Shell Integration methods moved to TerminalSessionModel+ShellIntegration.swift

    // MARK: - Idle Timer

    private func startIdleTimer() {
        stopIdleTimer() // Ensure no duplicate timers

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.markIdleIfNeeded()
        }
        timer.resume()
        idleTimer = timer
    }

    private func stopIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private static let zdotdirPath: String = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smartoverlay")
        FileOperations.createDirectory(at: dir)
        return dir.path
    }()

    private static var didWriteShellIntegration = false

    /// Call this at app launch to create shell integration files for all supported shells
    /// This runs shell integration at startup (not as a command) so it won't be in history
    static func preInitialize() {
        let fallbackHome = ShellLaunchEnvironment.userHome()
        let fallbackZdotdir = ShellLaunchEnvironment.userZdotdir()
        let fallbackXDGConfigHome = ShellLaunchEnvironment.userXDGConfigHome()

        // Create .zshrc for zsh
        let zshrc = """
        # Chau7 wrapper - source user's shell config first
        export CHAU7_USER_HOME="${CHAU7_USER_HOME:-${HOME:-\(fallbackHome)}}"
        export CHAU7_USER_ZDOTDIR="${CHAU7_USER_ZDOTDIR:-\(fallbackZdotdir)}"
        export ZDOTDIR="$CHAU7_USER_ZDOTDIR"
        [ -f "$CHAU7_USER_ZDOTDIR/.zshenv" ] && source "$CHAU7_USER_ZDOTDIR/.zshenv"
        [ -f "$CHAU7_USER_ZDOTDIR/.zshrc" ] && source "$CHAU7_USER_ZDOTDIR/.zshrc"
        if [[ -o login ]]; then
          [ -f "$CHAU7_USER_ZDOTDIR/.zprofile" ] && source "$CHAU7_USER_ZDOTDIR/.zprofile"
          [ -f "$CHAU7_USER_ZDOTDIR/.zlogin" ] && source "$CHAU7_USER_ZDOTDIR/.zlogin"
        fi
        # Ensure Volta image node toolchains stay ahead of the legacy ~/.volta/bin shim.
        path=("${(s/:/)PATH}")
        for _codex_image_bin in "$CHAU7_USER_HOME/.volta/tools/image/node/"*"/bin"(N); do
          [ -x "$_codex_image_bin/codex" ] && path=($_codex_image_bin $path)
        done
        typeset -U path
        export PATH="${(j/:/)path}"
        unset _codex_image_bin
        # Disable PROMPT_CR - prevents the 143 spaces + CRs before each prompt
        # that can cause visual artifacts in some terminals
        setopt NO_PROMPT_CR
        # Chau7 default start directory
        if [ -n "$CHAU7_START_DIR" ] && [ -d "$CHAU7_START_DIR" ]; then
          cd "$CHAU7_START_DIR"
        fi
        # Chau7 startup command
        if [ -n "$CHAU7_STARTUP_CMD" ]; then
          eval "$CHAU7_STARTUP_CMD"
        fi
        # Chau7 shell integration (runs at startup, not in history)
        chau7_emit_exit_status() {
          local code=$?
          print -Pn "\\e]9;chau7;exit=${code}\\a"
        }
        smartoverlay_precmd() { print -Pn "\\e]7;file://$HOSTNAME$PWD\\a"; }
        autoload -Uz add-zsh-hook 2>/dev/null
        if command -v add-zsh-hook >/dev/null 2>&1; then
          add-zsh-hook precmd chau7_emit_exit_status
          add-zsh-hook precmd smartoverlay_precmd
        else
          precmd_functions+=chau7_emit_exit_status
          precmd_functions+=smartoverlay_precmd
        fi
        smartoverlay_precmd
        # Chau7 CLI header injection for Claude Code
        chau7_update_project() {
          local git_root=$(git rev-parse --show-toplevel 2>/dev/null)
          export CHAU7_PROJECT="${git_root:-$PWD}"
          export ANTHROPIC_EXTRA_HEADERS="X-Chau7-Session:${CHAU7_SESSION_ID:-},X-Chau7-Tab:${CHAU7_TAB_ID:-},X-Chau7-Project:${CHAU7_PROJECT:-}"
        }
        chau7_update_project
        if command -v add-zsh-hook >/dev/null 2>&1; then
          add-zsh-hook chpwd chau7_update_project
        fi
        """

        // Create .bashrc for bash
        let bashrc = """
        # Chau7 wrapper - source user's real .bashrc first
        export CHAU7_USER_HOME="${CHAU7_USER_HOME:-${HOME:-\(fallbackHome)}}"
        [ -f "$CHAU7_USER_HOME/.bashrc" ] && source "$CHAU7_USER_HOME/.bashrc"
        [ -f "$CHAU7_USER_HOME/.bash_profile" ] && source "$CHAU7_USER_HOME/.bash_profile"
        # Chau7 default start directory
        if [ -n "$CHAU7_START_DIR" ] && [ -d "$CHAU7_START_DIR" ]; then
          cd "$CHAU7_START_DIR"
        fi
        # Chau7 startup command
        if [ -n "$CHAU7_STARTUP_CMD" ]; then
          eval "$CHAU7_STARTUP_CMD"
        fi
        # Chau7 shell integration
        smartoverlay_precmd() {
          printf '\\e]7;file://%s%s\\a' "$HOSTNAME" "$PWD"
        }
        chau7_emit_exit_status() {
          local code=$?
          printf '\\e]9;chau7;exit=%s\\a' "$code"
        }
        PROMPT_COMMAND="smartoverlay_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        # Chau7 CLI header injection for Claude Code
        chau7_update_project() {
          local git_root=$(git rev-parse --show-toplevel 2>/dev/null)
          export CHAU7_PROJECT="${git_root:-$PWD}"
          export ANTHROPIC_EXTRA_HEADERS="X-Chau7-Session:${CHAU7_SESSION_ID:-},X-Chau7-Tab:${CHAU7_TAB_ID:-},X-Chau7-Project:${CHAU7_PROJECT:-}"
        }
        chau7_update_project
        # Update on directory change via PROMPT_COMMAND
        PROMPT_COMMAND="chau7_update_project${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        PROMPT_COMMAND="chau7_emit_exit_status${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        """

        // Create config.fish for fish
        let fishConfig = """
        # Chau7 wrapper - source user's real config.fish first
        set -gx CHAU7_USER_HOME (string trim -- "$CHAU7_USER_HOME")
        if test -z "$CHAU7_USER_HOME"
          if test -n "$HOME"
            set -gx CHAU7_USER_HOME "$HOME"
          else
            set -gx CHAU7_USER_HOME "\(fallbackHome)"
          end
        end
        set -gx CHAU7_USER_XDG_CONFIG_HOME (string trim -- "$CHAU7_USER_XDG_CONFIG_HOME")
        if test -z "$CHAU7_USER_XDG_CONFIG_HOME"
          set -gx CHAU7_USER_XDG_CONFIG_HOME "\(fallbackXDGConfigHome)"
        end
        if test -f "$CHAU7_USER_XDG_CONFIG_HOME/fish/config.fish"
          source "$CHAU7_USER_XDG_CONFIG_HOME/fish/config.fish"
        end
        # Chau7 default start directory
        if test -n "$CHAU7_START_DIR"; and test -d "$CHAU7_START_DIR"
          cd "$CHAU7_START_DIR"
        end
        # Chau7 startup command
        if test -n "$CHAU7_STARTUP_CMD"
          eval "$CHAU7_STARTUP_CMD"
        end
        # Chau7 shell integration
        function smartoverlay_precmd --on-event fish_prompt
          set -l code $status
          printf '\\e]9;chau7;exit=%s\\a' $code
          printf '\\e]7;file://%s%s\\a' (hostname) (pwd)
        end
        # Chau7 CLI header injection for Claude Code
        function chau7_update_project --on-variable PWD
          set -l git_root (git rev-parse --show-toplevel 2>/dev/null)
          if test -n "$git_root"
            set -gx CHAU7_PROJECT $git_root
          else
            set -gx CHAU7_PROJECT $PWD
          end
          set -gx ANTHROPIC_EXTRA_HEADERS "X-Chau7-Session:$CHAU7_SESSION_ID,X-Chau7-Tab:$CHAU7_TAB_ID,X-Chau7-Project:$CHAU7_PROJECT"
        end
        # Initialize on startup
        chau7_update_project
        """

        // Write all integration files
        do {
            try zshrc.write(toFile: zdotdirPath + "/.zshrc", atomically: true, encoding: .utf8)
            try bashrc.write(toFile: zdotdirPath + "/.bashrc", atomically: true, encoding: .utf8)

            // Create fish config directory
            let fishDir = zdotdirPath + "/.config/fish"
            try FileManager.default.createDirectory(atPath: fishDir, withIntermediateDirectories: true)
            try fishConfig.write(toFile: fishDir + "/config.fish", atomically: true, encoding: .utf8)

            didWriteShellIntegration = true
            Log.info("Created shell integration files at \(zdotdirPath)")
        } catch {
            Log.error("Failed to create shell integration files: \(error)")
        }
    }

    /// Returns the shell integration directory path
    static func getShellIntegrationDir() -> String? {
        return didWriteShellIntegration ? zdotdirPath : nil
    }

    /// Returns ZDOTDIR path for zsh environment (legacy compatibility)
    static func getZdotdir() -> String? {
        return didWriteShellIntegration ? zdotdirPath : nil
    }

    func applyShellIntegration(to view: any TerminalViewLike) {
        // No-op: integration now happens via shell rc files at startup
        Log.trace("Shell integration applied via shell config files.")
    }

    func maybeClearOnLaunch() {
        guard !didClearOnLaunch else { return }
        didClearOnLaunch = true
        let raw = EnvVars.get(EnvVars.clearOnLaunch, legacy: EnvVars.legacyClearOnLaunch)?.lowercased()
        if let raw, ["0", "false", "no"].contains(raw) {
            Log.info("Clear-on-launch disabled via CHAU7_CLEAR_ON_LAUNCH.")
            return
        }
        guard let view = activeTerminalView else { return }
        view.send(txt: "\u{0C}")
        Log.trace("Cleared terminal on launch.")
    }

    // MARK: - Session Control (close, invalidate idle timer, clean up resources)

    /// Closes the session by sending exit command and cleaning up resources.
    func closeSession() {
        terminationStateQueue.sync {
            closeSessionRequested = true
            closeSessionRequestedAt = Date()
            sigintSentAt = nil
            sigtermSentAt = nil
        }

        // Stop all background work
        stopIdleTimer()
        repositoryModel?.onBranchChange = nil
        searchUpdateWorkItem?.cancel()

        // Capture telemetry buffer before sending exit — the view may detach
        // before handleProcessTermination fires, losing the buffer snapshot.
        finishAILogging(exitCode: nil)

        // Send exit to the shell (works with both backends)
        activeTerminalView?.send(txt: "exit\n")
        scheduleForcedTerminationIfNeeded()
        Log.trace("Sent exit command to shell session.")
    }

    func closeSessionForTermination() {
        closeSession()
        let shellPID = existingRustTerminalView?.shellPid ?? 0
        guard shellPID > 0 else { return }
        Log.warn("App termination requested immediate shell shutdown for session '\(title)' (pid=\(shellPID))")
        sendTerminationSignal(SIGTERM, toShellPID: shellPID)
    }

    private func handleProcessTermination(exitCode: Int32?) {
        forcedTerminationWorkItem?.cancel()
        forcedTerminationWorkItem = nil
        var shouldEmit = false
        var requestedByClose = false
        terminationStateQueue.sync {
            requestedByClose = closeSessionRequested
            if didHandleProcessTermination {
                shouldEmit = false
            } else {
                didHandleProcessTermination = true
                shouldEmit = true
            }
        }

        guard shouldEmit else {
            Log.trace("Ignoring duplicate process termination callback (exitCode=\(String(describing: exitCode))).")
            return
        }

        DispatchQueue.main.async {
            self.status = .exited
            self.devServer = nil
        }
        devServerMonitor.stop()
        // finishAILogging is idempotent and has internal synchronization
        finishAILogging(exitCode: nil)

        let type: String
        let message: String
        let shouldNotify: Bool
        if requestedByClose {
            type = "finished"
            if let exitCode {
                message = "Shell closed with code \(exitCode)."
            } else {
                message = "Shell closed."
            }
            shouldNotify = false
        } else if let exitCode {
            type = exitCode == 0 ? "finished" : "failed"
            message = "Shell exited with code \(exitCode)."
            shouldNotify = true
        } else {
            type = "failed"
            message = "Shell exited."
            shouldNotify = true
        }

        appModel?.recordEvent(
            source: .terminalSession,
            type: type,
            tool: notificationTabName,
            message: message,
            notify: shouldNotify,
            directory: currentDirectory,
            tabID: ownerTabID
        )
    }

    private func scheduleForcedTerminationIfNeeded() {
        let shellPID = existingRustTerminalView?.shellPid ?? 0
        guard shellPID > 0 else { return }

        // AI tools (Claude Code, Codex) need longer to flush buffers and clean up
        // WebSocket connections on exit. Plain shells exit in <100ms.
        let graceDelay: TimeInterval = activeAppName != nil ? 3.0 : 1.0

        forcedTerminationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.forceTerminateShellProcessGroupIfNeeded(expectedPID: shellPID)
        }
        forcedTerminationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + graceDelay, execute: work)
    }

    private func forceTerminateShellProcessGroupIfNeeded(expectedPID: pid_t) {
        var shouldForce = false
        terminationStateQueue.sync {
            shouldForce = closeSessionRequested && !didHandleProcessTermination
        }
        guard shouldForce else { return }

        let currentPID = existingRustTerminalView?.shellPid ?? 0
        guard currentPID == expectedPID, currentPID > 0 else { return }

        // Stage 1: SIGINT — gives the process a chance to handle Ctrl+C gracefully
        terminationStateQueue.sync {
            if sigintSentAt == nil {
                sigintSentAt = Date()
            }
        }
        Log.warn("Force-terminating shell process group for session '\(title)' (pid=\(currentPID))")
        sendTerminationSignal(SIGINT, toShellPID: currentPID)

        // Stage 2: SIGTERM after 2s — standard termination request
        let isAISession = activeAppName != nil
        let sigtermDelay: TimeInterval = isAISession ? 2.0 : 0.5
        let sigterm = DispatchWorkItem { [weak self] in
            self?.escalateToSIGTERM(expectedPID: expectedPID)
        }
        forcedTerminationWorkItem = sigterm
        DispatchQueue.main.asyncAfter(deadline: .now() + sigtermDelay, execute: sigterm)
    }

    private func escalateToSIGTERM(expectedPID: pid_t) {
        var shouldForce = false
        terminationStateQueue.sync {
            shouldForce = closeSessionRequested && !didHandleProcessTermination
        }
        guard shouldForce else { return }

        let currentPID = existingRustTerminalView?.shellPid ?? 0
        guard currentPID == expectedPID, currentPID > 0 else { return }

        terminationStateQueue.sync {
            sigtermSentAt = Date()
        }
        let diagnostics = terminationDiagnosticsSummary(stage: "sigterm", shellPID: currentPID)
        Log.warn("Shell process group survived SIGINT; sending SIGTERM (pid=\(currentPID)) \(diagnostics)")
        sendTerminationSignal(SIGTERM, toShellPID: currentPID)

        // Stage 3: SIGKILL after 3s more — unconditional kill
        let hardKill = DispatchWorkItem { [weak self] in
            self?.forceKillShellProcessGroupIfNeeded(expectedPID: expectedPID)
        }
        forcedTerminationWorkItem = hardKill
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: hardKill)
    }

    private func forceKillShellProcessGroupIfNeeded(expectedPID: pid_t) {
        var shouldForce = false
        terminationStateQueue.sync {
            shouldForce = closeSessionRequested && !didHandleProcessTermination
        }
        guard shouldForce else { return }

        let currentPID = existingRustTerminalView?.shellPid ?? 0
        guard currentPID == expectedPID, currentPID > 0 else { return }

        let diagnostics = terminationDiagnosticsSummary(stage: "sigkill", shellPID: currentPID)
        Log.error("Shell process group still alive after SIGINT+SIGTERM; sending SIGKILL (pid=\(currentPID)) \(diagnostics)")
        sendTerminationSignal(SIGKILL, toShellPID: currentPID)
    }

    private func terminationDiagnosticsSummary(stage: String, shellPID: pid_t) -> String {
        let now = Date()
        let timing = terminationStateQueue.sync {
            (
                closeRequestedAt: closeSessionRequestedAt,
                sigintSentAt: sigintSentAt,
                sigtermSentAt: sigtermSentAt
            )
        }

        let closeMs = timing.closeRequestedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let sigintMs = timing.sigintSentAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let sigtermMs = timing.sigtermSentAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let processTree = terminationProcessTreeSummary(shellPID: shellPID)
        let ptyState = [
            "log_path=\(lastPTYLogPath ?? "nil")",
            "session_open=\(aiLogSession != nil)"
        ].joined(separator: ",")

        return "diagnostics={stage=\(stage) title='\(title)' pid=\(shellPID) " +
            "close_requested_ms=\(closeMs) sigint_ms=\(sigintMs) sigterm_ms=\(sigtermMs) " +
            "pty={\(ptyState)} process_tree=\(processTree)}"
    }

    private func terminationProcessTreeSummary(shellPID: pid_t) -> String {
        guard let output = SubprocessRunner.run(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,command="]
        ) else {
            return "unavailable"
        }

        struct ProcessRow {
            let pid: pid_t
            let parentPID: pid_t
            let command: String
        }

        var childrenOf: [pid_t: [pid_t]] = [:]
        var rowsByPID: [pid_t: ProcessRow] = [:]

        for line in output.split(separator: "\n") {
            let columns = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard columns.count >= 3,
                  let pid = Int32(columns[0]),
                  let parentPID = Int32(columns[1]) else {
                continue
            }

            let command = String(columns[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            childrenOf[parentPID, default: []].append(pid)
            rowsByPID[pid] = ProcessRow(pid: pid, parentPID: parentPID, command: command)
        }

        var descendants: [ProcessRow] = []
        var queue: [pid_t] = childrenOf[shellPID] ?? []
        var index = 0
        while index < queue.count {
            let pid = queue[index]
            index += 1
            if let row = rowsByPID[pid] {
                descendants.append(row)
            }
            if let children = childrenOf[pid] {
                queue.append(contentsOf: children)
            }
        }

        let prefix = rowsByPID[shellPID].map { "shell=\($0.pid):\($0.command)" } ?? "shell=\(shellPID)"
        guard !descendants.isEmpty else { return "\(prefix) children=[]" }

        let renderedChildren = descendants
            .prefix(8)
            .map { "\($0.pid)<-\($0.parentPID) \($0.command)" }
            .joined(separator: " | ")
        let remaining = max(0, descendants.count - 8)
        if remaining > 0 {
            return "\(prefix) children=[\(renderedChildren) | +\(remaining) more]"
        }
        return "\(prefix) children=[\(renderedChildren)]"
    }

    private func sendTerminationSignal(_ signal: Int32, toShellPID shellPID: pid_t) {
        if Darwin.kill(-shellPID, signal) == 0 {
            return
        }
        if errno == ESRCH {
            _ = Darwin.kill(shellPID, signal)
        } else {
            Log.warn("Failed to send signal \(signal) to process group \(shellPID): errno=\(errno)")
            _ = Darwin.kill(shellPID, signal)
        }
    }

    func copyOrInterrupt() {
        guard let view = rustTerminalView else { return }
        view.window?.makeFirstResponder(view)
        if let text = view.getSelectedText(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        Log.trace("Copy/interrupt requested from session model.")
    }

    func getSelectedText() -> String? {
        activeTerminalView?.getSelectedText()
    }

    // MARK: - Paste (delegates to the terminal view for proper first-responder handling)

    func paste() {
        guard let view = rustTerminalView else { return }
        view.window?.makeFirstResponder(view)
        if let text = NSPasteboard.general.string(forType: .string) {
            view.send(txt: text)
        }
    }

    // MARK: - F13: Broadcast Input Support

    /// Sends text input to the terminal (used for broadcast mode)
    func sendInput(_ text: String) {
        guard !text.isEmpty else { return }
        // If this input contains a newline (command submission), suppress output-based
        // AI detection until handleInputLine processes the echoed command. This gives
        // command-based detection (which tokenizes the exact command name) priority
        // over output pattern matching (which can false-positive on substrings).
        if text.contains("\n") || text.contains("\r") {
            commandPendingDetection = true
        }
        guard let activeTerminalView else {
            enqueuePendingTerminalAction(.text(text))
            return
        }
        activeTerminalView.send(txt: text)
    }

    /// Queues executable input (e.g. `cd /path\n`) for when the terminal view
    /// becomes available. Used during tab restore when the view hasn't been
    /// created yet. If the view already exists, sends immediately.
    func sendOrQueueInput(_ text: String) {
        trackAIResumeMetadata(from: text)
        sendInput(text)
    }

    /// Queues restore-time shell maintenance commands (scrollback replay, cd,
    /// clear) without letting their echoed input line unlock AI attention
    /// fallbacks that should remain suppressed until the next explicit user
    /// command.
    func sendOrQueueSystemRestoreInput(_ text: String) {
        let sanitized = EscapeSequenceSanitizer.sanitize(text)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSystemRestoreInputLine = trimmed.isEmpty ? nil : trimmed
        sendOrQueueInput(text)
    }

    func sendKeyPress(_ keyPress: TerminalKeyPress) {
        guard let activeTerminalView else {
            enqueuePendingTerminalAction(.keyPress(keyPress))
            return
        }
        activeTerminalView.send(keyPress: keyPress)
    }

    func sendOrQueueKeyPress(_ keyPress: TerminalKeyPress) {
        sendKeyPress(keyPress)
    }

    private func enqueuePendingTerminalAction(_ action: PendingTerminalAction) {
        switch (pendingTerminalActions.last, action) {
        case let (.some(.text(existingText)), .text(newText)):
            pendingTerminalActions[pendingTerminalActions.count - 1] = .text(existingText + newText)
        default:
            pendingTerminalActions.append(action)
        }
    }

    private func flushPendingTerminalActions() {
        guard existingRustTerminalView != nil else { return }
        let actions = pendingTerminalActions
        pendingTerminalActions.removeAll(keepingCapacity: true)
        for action in actions {
            switch action {
            case let .text(text):
                sendInput(text)
            case let .keyPress(keyPress):
                sendKeyPress(keyPress)
            }
        }
    }

    /// Prefills the terminal input line without executing it.
    /// This is used for restore-time resume workflows where the user should
    /// explicitly confirm execution.
    func prefillInput(_ text: String) {
        guard !text.isEmpty else { return }
        trackAIResumeMetadata(from: text)
        pendingPrefillInput = text
        pendingWaitingInputFallbackArmed = false
        pendingWaitingInputFallbackSawLiveOutput = false
        suppressWaitingInputFallbackUntilNextUserCommand = true
        flushPendingPrefillInputIfReady()
    }

    func flushPendingPrefillInputIfReady() {
        guard let text = pendingPrefillInput else {
            pendingPrefillRetries = 0
            return
        }

        // After several retries the shell has had time to start — force-clear
        // isShellLoading to break the deadlock where the initial OSC 7 directory
        // matches the saved directory and handlePromptDetected is never called.
        if pendingPrefillRetries >= 4, isShellLoading {
            isShellLoading = false
        }

        if canPrefillInput() {
            let insertion = SnippetInsertion(text: text, placeholders: [], finalCursorOffset: text.count)
            pendingPrefillInput = nil
            pendingPrefillRetries = 0
            deliveredSystemResumePrefillSinceLastUserCommand = true
            suppressWaitingInputFallbackUntilNextUserCommand = true
            pendingWaitingInputFallbackArmed = false
            pendingWaitingInputFallbackSawLiveOutput = false
            activeTerminalView?.insertSnippet(insertion)
            Log.info("Resume prefill delivered: \(text.prefix(60))")
            return
        }

        // No view yet — wait for attachRustTerminal to call us again.
        guard existingRustTerminalView != nil else { return }

        // View exists but shell isn't ready — schedule a retry.
        guard pendingPrefillRetries < 20 else {
            Log.warn("Resume prefill: retries exhausted, waiting for next prompt (\(text.prefix(60)))")
            pendingPrefillRetries = 0 // reset so handlePromptDetected can restart
            return
        }
        pendingPrefillRetries += 1
        let delay = min(0.3 + Double(pendingPrefillRetries) * 0.3, 3.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flushPendingPrefillInputIfReady()
        }
    }

    func canPrefillInput() -> Bool {
        Self.isPrefillReady(
            isShellLoading: isShellLoading,
            isAtPrompt: isAtPrompt,
            hasView: existingRustTerminalView != nil,
            status: status
        )
    }

    static func isPrefillReady(
        isShellLoading: Bool,
        isAtPrompt: Bool,
        hasView: Bool,
        status: CommandStatus
    ) -> Bool {
        guard !isShellLoading else { return false }
        guard isAtPrompt else { return false }
        guard hasView else { return false }

        // Prompt detection is more authoritative than laggy status transitions.
        return status != .exited
    }

    // MARK: - F21: Snippet Insertion

    func insertSnippet(_ entry: SnippetEntry) {
        guard FeatureSettings.shared.isSnippetsEnabled else { return }
        let insertion = SnippetManager.shared.prepareInsertion(
            snippet: entry.snippet,
            currentDirectory: currentDirectory
        )
        activeTerminalView?.insertSnippet(insertion)
    }

    // MARK: - Zoom (update observable state; SwiftUI drives the terminal resize)

    func zoomIn() {
        updateFontSize(fontSize + 1)
    }

    func zoomOut() {
        updateFontSize(fontSize - 1)
    }

    func zoomReset() {
        applyDefaultFontSize()
    }

    private func updateFontSize(_ newValue: CGFloat) {
        let clamped = max(8, min(newValue, 72))
        guard fontSize != clamped else { return }
        fontSize = clamped
        // Note: Font is now applied by TerminalViewRepresentable.updateNSView
        // to avoid race conditions with SwiftUI's update cycle.
    }

    private func applyDefaultFontSize() {
        let settings = FeatureSettings.shared
        let zoom = max(50, min(settings.defaultZoomPercent, 200))
        let scaled = CGFloat(settings.fontSize) * CGFloat(zoom) / 100.0
        updateFontSize(scaled)
    }

    private func installSettingsObservers() {
        let center = NotificationCenter.default
        settingsObservers.append(center.addObserver(
            forName: .terminalFontChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyDefaultFontSize()
        })
        settingsObservers.append(center.addObserver(
            forName: .terminalZoomChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyDefaultFontSize()
        })
        settingsObservers.append(center.addObserver(
            forName: .terminalDangerousCommandHighlightChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.outputRiskCacheVersion &+= 1
            self?.outputRiskCache.removeAll(keepingCapacity: true)
            self?.cachedDangerousOutputRowSet = []
            self?.dirtyOutputRange = nil
            self?.dangerousOutputHighlightWorkItem?.cancel()
            self?.dangerousOutputHighlightWorkItem = nil
            self?.dangerousOutputHighlightLastRun = .distantPast
            self?.dangerousHighlightSampleCount = 0
            self?.dangerousHighlightTotalMs = 0
            self?.dangerousHighlightDelayMs = nil
            self?.dangerousHighlightAverageMs = nil
            self?.dangerousHighlightSamples.reset()
            self?.highlightView?.scheduleDisplay()
        })
    }

    func clearSearch() {
        searchQuery = ""
        searchMatches = []
        activeSearchIndex = 0
        cachedBufferData = nil
        bufferNeedsRefresh = true
        highlightView?.scheduleDisplay() // Use batched display for better latency
    }

    // MARK: - Shell helpers

    static func resolveStartDirectory(_ rawValue: String) -> String {
        let home = RuntimeIsolation.homePath()
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return home }

        let expanded = RuntimeIsolation.expandTilde(in: trimmed)
        let resolved: String
        if expanded.hasPrefix("/") {
            resolved = expanded
        } else {
            resolved = (home as NSString).appendingPathComponent(expanded)
        }

        return URL(fileURLWithPath: resolved).standardized.path
    }

    static func defaultStartDirectory() -> String {
        resolveStartDirectory(FeatureSettings.shared.defaultStartDirectory)
    }

    private func startDirectoryForLaunch() -> String {
        let trimmed = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? Self.defaultStartDirectory() : Self.resolveStartDirectory(trimmed)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            return Self.defaultStartDirectory()
        }
        return resolved
    }

    func defaultShell() -> String {
        let settings = FeatureSettings.shared

        switch settings.shellType {
        case .system:
            // Use system default shell (from user's passwd entry)
            return systemDefaultShell()
        case .zsh:
            return "/bin/zsh"
        case .bash:
            return "/bin/bash"
        case .fish:
            // Apple Silicon path
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/fish") {
                return "/opt/homebrew/bin/fish"
            }
            // Intel path fallback
            if FileManager.default.fileExists(atPath: "/usr/local/bin/fish") {
                return "/usr/local/bin/fish"
            }
            // Fallback to zsh if fish not found
            return "/bin/zsh"
        case .fishIntel:
            if FileManager.default.fileExists(atPath: "/usr/local/bin/fish") {
                return "/usr/local/bin/fish"
            }
            return "/bin/zsh"
        case .custom:
            let customPath = settings.customShellPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !customPath.isEmpty, FileManager.default.fileExists(atPath: customPath) {
                return customPath
            }
            return systemDefaultShell()
        }
    }

    /// Returns the system's default shell from the user's passwd entry
    private func systemDefaultShell() -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else {
            return "/bin/zsh"
        }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer { buffer.deallocate() }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        guard getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) == 0,
              result != nil else {
            return "/bin/zsh"
        }
        return String(cString: pwd.pw_shell)
    }

    private static let defaultLsColors = "exfxcxdxbxegedabagacad"

    private func sharedEventsLogPathForEnvironment() -> String {
        let trimmed = appModel?.logPath.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return RuntimeIsolation.expandTilde(in: trimmed)
        }
        return RuntimeIsolation.pathInHome(".ai-events.log")
    }

    func launchPATHValue() -> String {
        let ctoEnabled = FeatureSettings.shared.tokenOptimizationMode != .off
        let basePath = ShellLaunchEnvironment.preferredPATH()

        if ctoEnabled {
            return CTOManager.shared.prependedPATH(original: basePath)
        }
        return basePath
    }

    func buildEnvironment() -> [String] {
        var dict: [String: String] = [:]
        dict["TERM"] = "xterm-256color"
        dict["COLORTERM"] = "truecolor"

        let current = ProcessInfo.processInfo.environment
        let ctoEnabled = FeatureSettings.shared.tokenOptimizationMode != .off

        dict["PATH"] = launchPATHValue()
        if let home = current["HOME"] {
            dict["HOME"] = home
        }
        dict["CHAU7_USER_HOME"] = ShellLaunchEnvironment.userHome(environment: current)
        dict["CHAU7_USER_ZDOTDIR"] = ShellLaunchEnvironment.userZdotdir(environment: current)
        dict["CHAU7_USER_XDG_CONFIG_HOME"] = ShellLaunchEnvironment.userXDGConfigHome(environment: current)
        dict["CHAU7_START_DIR"] = startDirectoryForLaunch()

        // CTO: set session ID for flag file lookup by wrapper scripts.
        // Uses a dedicated env var to avoid conflicting with CHAU7_SESSION_ID
        // which the analytics proxy uses for per-shell-launch correlation.
        if ctoEnabled {
            dict["CHAU7_CTO_SESSION"] = tabIdentifier
            dict["CHAU7_CTO_LOG"] = CTOManager.shared.commandLogPath.path
        }

        // Set startup command if configured
        let startupCmd = FeatureSettings.shared.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !startupCmd.isEmpty {
            dict["CHAU7_STARTUP_CMD"] = startupCmd
        }

        // Use Chau7 as TERM_PROGRAM to avoid sourcing /etc/zshrc_Apple_Terminal
        // which adds duplicate precmd hooks and can cause display issues.
        // CLI tools that check TERM_PROGRAM for theming will still work fine.
        dict["TERM_PROGRAM"] = "Chau7"
        dict["TERM_PROGRAM_VERSION"] = "1.0"
        dict["TERM_SESSION_ID"] = UUID().uuidString
        dict["SHELL"] = defaultShell()
        dict["CHAU7_SESSION_ID"] = dict["TERM_SESSION_ID"] ?? UUID().uuidString
        dict["CHAU7_TAB_ID"] = ownerTabID?.uuidString ?? tabIdentifier
        dict["CHAU7_PROJECT"] = currentDirectory
        dict["CHAU7_AI_EVENTS_LOG"] = sharedEventsLogPathForEnvironment()

        // Disable macOS shell session save/restore (avoids "Restored session" message and % marker)
        // Chau7 manages its own session state; macOS session restoration is designed for Terminal.app
        dict["SHELL_SESSIONS_DISABLE"] = "1"

        if FeatureSettings.shared.isLsColorsEnabled {
            dict["CLICOLOR"] = dict["CLICOLOR"] ?? "1"
            dict["LSCOLORS"] = dict["LSCOLORS"] ?? Self.defaultLsColors
        }

        // Set shell-specific environment variables based on configured shell
        if let integrationDir = Self.getShellIntegrationDir() {
            let shellPath = defaultShell()
            let shellName = (shellPath as NSString).lastPathComponent.lowercased()

            if shellName == "zsh" {
                // ZDOTDIR tells zsh where to look for .zshrc
                dict["ZDOTDIR"] = integrationDir
            } else if shellName == "bash" {
                // BASH_ENV is sourced for non-interactive shells
                // For interactive shells, we use --rcfile in arguments
                dict["BASH_ENV"] = integrationDir + "/.bashrc"
            } else if shellName == "fish" {
                // XDG_CONFIG_HOME tells fish where to find config.fish
                dict["XDG_CONFIG_HOME"] = integrationDir + "/.config"
            }
        }

        // MARK: - API Analytics Proxy Injection

        let settings = FeatureSettings.shared
        if settings.isAPIAnalyticsEnabled {
            let proxyBase = "http://127.0.0.1:\(settings.apiAnalyticsPort)"
            let tlsBase = "https://127.0.0.1:\(settings.apiAnalyticsPort + 1)"

            // Claude Code / Anthropic SDK (HTTP — no WebSocket needed)
            dict["ANTHROPIC_BASE_URL"] = proxyBase

            if settings.apiAnalyticsIncludeOpenAI {
                // Codex CLI / OpenAI SDK — routed through the TLS port so that
                // subscription-based Codex can do its native WSS upgrade through
                // the proxy. The self-signed cert is trusted via the login keychain.
                dict["OPENAI_BASE_URL"] = "\(tlsBase)/v1"
            } else {
                dict.removeValue(forKey: "OPENAI_BASE_URL")
            }

            // Gemini CLI / Google GenAI SDK (HTTP — no WebSocket needed)
            dict["GOOGLE_GEMINI_BASE_URL"] = proxyBase

        }

        return dict.map { "\($0.key)=\($0.value)" }
    }

    /// Returns shell arguments for the selected shell type
    func shellArguments() -> [String] {
        let shellPath = defaultShell()
        let shellName = (shellPath as NSString).lastPathComponent.lowercased()

        if shellName == "bash" {
            // Use --rcfile to specify our custom bashrc for interactive shells
            if let integrationDir = Self.getShellIntegrationDir() {
                return ["--rcfile", integrationDir + "/.bashrc"]
            }
        }

        // Default: no extra arguments (zsh uses ZDOTDIR, fish uses XDG_CONFIG_HOME)
        return []
    }

    private static let terminalAppVersion: String? = {
        let candidates = [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Utilities/Terminal.app"
        ]

        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if let bundle = Bundle(url: url),
               let info = bundle.infoDictionary,
               let version = info["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        return nil
    }()

    struct SearchMatch: Equatable, Identifiable {
        let id = UUID()
        let row: Int
        let col: Int
        let length: Int
        // Note: line text removed to save memory - previews are stored separately
    }

    struct SearchSummary {
        let count: Int
        let previewLines: [String]
        let error: String?
    }

    // MARK: - Token Optimization (CTO) Flag Recalculation

    /// Per-tab token optimization override. Set by `OverlayTabsModel` when the
    /// user toggles per-tab CTO. Stored here so `activeAppName.didSet` can
    /// access it without a back-reference to the tab model.
    var tokenOptOverride: TabTokenOptOverride = .default

    /// Whether the CTO flag creation was deferred until the first prompt.
    /// This avoids optimizer overhead during shell init scripts (NVM, compinit, etc.)
    /// that invoke coreutils thousands of times with flags chau7-optim can't handle.
    var ctoFlagDeferred = false
    private var ctoFlagDeferredAt: Date?

    /// Creates the CTO flag file after the shell has finished initializing.
    /// Called once from `handlePromptDetected()` on the first prompt.
    func createDeferredCTOFlag() {
        guard ctoFlagDeferred else { return }
        ctoFlagDeferred = false
        let delayMs = ctoFlagDeferredAt.map {
            Int(Date().timeIntervalSince($0) * 1000)
        } ?? 0
        ctoFlagDeferredAt = nil

        let mode = FeatureSettings.shared.tokenOptimizationMode
        let isAIActive = activeAppName != nil
        guard mode != .off else {
            CTORuntimeMonitor.shared.recordDeferredSkip(
                sessionID: tabIdentifier,
                reason: "mode-off",
                mode: mode,
                override: tokenOptOverride,
                isAIActive: isAIActive
            )
            return
        }

        let decision = CTOFlagManager.recalculate(
            sessionID: tabIdentifier,
            mode: mode,
            override: tokenOptOverride,
            isAIActive: isAIActive
        )
        let reason = decisionReason(
            mode: mode,
            override: tokenOptOverride,
            isAIActive: isAIActive
        )
        CTORuntimeMonitor.shared.recordDeferredFlush(
            sessionID: tabIdentifier,
            delayToActivateMs: delayMs,
            mode: mode,
            override: tokenOptOverride,
            isAIActive: isAIActive,
            previousState: decision.previousState,
            nextState: decision.nextState,
            changed: decision.changed,
            reason: reason
        )
        if decision.changed {
            NotificationCenter.default.post(name: .ctoFlagRecalculated, object: nil)
        }
    }

    /// Recalculates the CTO flag file for this session based on the current
    /// global mode, per-tab override, and AI detection state.
    /// Called automatically when `activeAppName` changes.
    func recalculateCTOFlag() {
        let mode = FeatureSettings.shared.tokenOptimizationMode
        guard mode != .off else { return }
        guard !ctoFlagDeferred else { return }
        let isAIActive = activeAppName != nil
        let decision = CTOFlagManager.recalculate(
            sessionID: tabIdentifier,
            mode: mode,
            override: tokenOptOverride,
            isAIActive: isAIActive
        )
        let reason = decisionReason(
            mode: mode,
            override: tokenOptOverride,
            isAIActive: isAIActive
        )
        CTORuntimeMonitor.shared.recordDecision(
            sessionID: tabIdentifier,
            mode: mode,
            override: tokenOptOverride,
            isAIActive: isAIActive,
            previousState: decision.previousState,
            nextState: decision.nextState,
            changed: decision.changed,
            reason: reason
        )

        // Notify tab bar to re-render bolt icon state (the OverlayTab struct
        // is a value type and doesn't observe session changes directly).
        NotificationCenter.default.post(name: .ctoFlagRecalculated, object: nil)
    }

    /// Marks this session as deferred for the first prompt in the current shell
    /// lifecycle. Deferred state is cleared automatically in `createDeferredCTOFlag()`.
    func markCTOFlagDeferred(mode: TokenOptimizationMode) {
        guard mode != .off else {
            ctoFlagDeferred = false
            ctoFlagDeferredAt = nil
            return
        }
        guard !ctoFlagDeferred else { return }
        ctoFlagDeferred = true
        ctoFlagDeferredAt = Date()
        CTORuntimeMonitor.shared.recordDeferredSet(sessionID: tabIdentifier)
    }

    weak var highlightView: TerminalHighlightView?

    func attachHighlightView(_ view: TerminalHighlightView) {
        highlightView = view
        highlightView?.scheduleDisplay() // Use batched display for better latency
    }

    func resetDangerousHighlights() {
        dangerousCommandTracker.reset()
        outputRiskCache.removeAll(keepingCapacity: true)
        cachedDangerousOutputRowSet = []
        dirtyOutputRange = nil
        dangerousOutputHighlightWorkItem?.cancel()
        dangerousOutputHighlightWorkItem = nil
        dangerousOutputHighlightLastRun = .distantPast
        dangerousHighlightSampleCount = 0
        dangerousHighlightTotalMs = 0
        dangerousHighlightDelayMs = nil
        dangerousHighlightAverageMs = nil
        dangerousHighlightSamples.reset()
        highlightView?.scheduleDisplay()
    }

    // Search methods moved to TerminalSessionModel+Search.swift

    var searchCaseSensitive = false
    var searchRegexEnabled = false
    var searchWholeWord = false

    func displayPath() -> String {
        let home = RuntimeIsolation.homePath()
        if currentDirectory == home {
            return "~"
        }
        if currentDirectory.hasPrefix(home + "/") {
            return "~" + String(currentDirectory.dropFirst(home.count))
        }
        return currentDirectory
    }

    func tabPathDisplayName() -> String {
        if let gitRootPath, !gitRootPath.isEmpty {
            return URL(fileURLWithPath: gitRootPath).lastPathComponent
        }
        return displayPath()
    }

    // Latency telemetry methods moved to TerminalSessionModel+Telemetry.swift

    /// Updates the current directory and refreshes git status.
    /// Call this instead of setting currentDirectory directly to ensure git badge updates.
    func updateCurrentDirectory(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardized.path
        guard currentDirectory != normalized else { return }
        let shouldSkipAutoAccess = ProtectedPathPolicy.shouldSkipAutoAccess(path: normalized)
        if shouldSkipAutoAccess {
            if StartupRestoreCoordinator.shared.shouldLogProtectedPathDeferral(forPath: normalized) {
                Log.info("updateCurrentDirectory: deferring protected path validation for \(normalized)")
            }
            currentDirectory = normalized
            rustTerminalView?.currentDirectory = normalized
            if title == "Shell" {
                title = URL(fileURLWithPath: normalized).lastPathComponent
            }
            refreshGitStatus(path: normalized)
            SnippetManager.shared.updateContextPath(normalized)
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue else {
            Log.debug("updateCurrentDirectory rejected non-existent path: \(normalized)")
            return
        }
        currentDirectory = normalized
        rustTerminalView?.currentDirectory = normalized
        // Notify shell event detector of directory change
        shellEventDetector.directoryChanged(to: normalized)
        if title == "Shell" {
            title = URL(fileURLWithPath: normalized).lastPathComponent
        }
        refreshGitStatus(path: normalized)
        SnippetManager.shared.updateContextPath(normalized)

        // Evaluate profile auto-switch rules on directory change
        let dir = normalized
        let branch = gitBranch
        let procs = processGroup?.children.map(\.name)
        Task { @MainActor in
            ProfileAutoSwitcher.shared.evaluateRules(
                directory: dir,
                gitBranch: branch,
                processes: procs
            )
        }
    }

    struct RepositoryStateSnapshot: Equatable {
        let accessSnapshot: ProtectedPathAccessSnapshot
        let isGitRepo: Bool
        let gitRootPath: String?
        let gitBranch: String?
    }

    static func repositoryState(from result: RepositoryResolutionResult) -> RepositoryStateSnapshot {
        switch result {
        case .live(let model, access: let access):
            return RepositoryStateSnapshot(
                accessSnapshot: access,
                isGitRepo: true,
                gitRootPath: model.rootPath,
                gitBranch: model.branch
            )
        case .cachedIdentity(identity: let identity, access: let access):
            return RepositoryStateSnapshot(
                accessSnapshot: access,
                isGitRepo: true,
                gitRootPath: identity.rootPath,
                gitBranch: identity.lastKnownBranch
            )
        case .blocked(let access), .notRepository(let access):
            return RepositoryStateSnapshot(
                accessSnapshot: access,
                isGitRepo: false,
                gitRootPath: nil,
                gitBranch: nil
            )
        }
    }

    private func refreshGitStatus(path: String) {
        RepositoryCache.shared.resolveDetailed(path: path) { [weak self] result in
            guard let self else { return }
            let resolved = Self.repositoryState(from: result)
            let model: RepositoryModel?

            switch result {
            case .live(let liveModel, access: _):
                model = liveModel
            case .cachedIdentity(identity: let identity, access: _):
                model = RepositoryCache.shared.cachedModel(forRoot: identity.rootPath)
            case .blocked, .notRepository:
                model = nil
            }

            let oldModel = repositoryModel
            let oldBranch = gitBranch

            // Update the shared model reference
            repositoryModel = model
            repositoryAccessSnapshot = resolved.accessSnapshot
            isGitRepo = resolved.isGitRepo
            gitRootPath = resolved.gitRootPath
            gitBranch = model?.branch ?? resolved.gitBranch

            // Subscribe to branch changes from the shared model via didSet callback
            if model !== oldModel {
                oldModel?.onBranchChange = nil
                model?.onBranchChange = { [weak self] newBranch in
                    DispatchQueue.main.async {
                        guard let self, self.gitBranch != newBranch else { return }
                        self.gitBranch = newBranch
                        if let rootPath = self.gitRootPath {
                            KnownRepoIdentityStore.shared.record(rootPath: rootPath, branch: newBranch)
                        }
                        self.shellEventDetector.gitBranchChanged(to: newBranch)
                    }
                }
            }

            // Notify shell event detector of branch change
            if oldBranch != gitBranch {
                shellEventDetector.gitBranchChanged(to: gitBranch)
            }
        }
    }
}
