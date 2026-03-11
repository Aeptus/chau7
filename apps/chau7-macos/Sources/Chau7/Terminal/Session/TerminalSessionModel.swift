import Foundation
import AppKit
import Darwin
import Chau7Core

extension Notification.Name {
    static let terminalSessionRenderSuspensionStateChanged =
        Notification.Name("com.chau7.terminalSessionRenderSuspensionStateChanged")
}

enum CommandStatus: String {
    case idle
    case running
    case waitingForInput // AI agent waiting for user input/permission
    case stuck // Running for too long without output
    case exited
}

/// Model for a terminal session, managing shell state, search, and output capture.
/// - Note: Thread Safety - @Published properties must be modified on main thread.
///   Callbacks may arrive on background threads and dispatch to main via DispatchQueue.main.async.
final class TerminalSessionModel: NSObject, ObservableObject {
    private struct LatencySampleBuffer {
        private var buffer: [Int]
        private var index = 0
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

    @Published var title = "Shell"
    @Published var currentDirectory: String = TerminalSessionModel.defaultStartDirectory()

    /// Unique identifier for this terminal tab, used for task lifecycle tracking
    let tabIdentifier: String = UUID().uuidString

    /// The owning tab's UUID, set by OverlayTabsModel at tab creation time.
    /// Propagated to ShellEventDetector so emitted events carry a deterministic tabID
    /// for the fast-path in TabResolver.
    var ownerTabID: UUID? {
        didSet { shellEventDetector.ownerTabID = ownerTabID }
    }
    @Published var status: CommandStatus = .idle
    @Published var isGitRepo = false
    @Published var gitBranch: String?
    @Published var gitRootPath: String?
    @Published var activeAppName: String? {
        didSet {
            recalculateCTOFlag()
            if activeAppName != oldValue {
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
    var isAIRunning: Bool {
        guard aiDisplayAppName != nil else { return false }
        return !aiDetection.isRestored
    }

    var shouldKeepLiveRenderingInBackground: Bool {
        guard hasBackgroundRenderingAIContext else { return false }
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

    @Published var devServer: DevServerMonitor.DevServerInfo?
    @Published var processGroup: ProcessGroupSnapshot?
    @Published var tabTitleOverride: String?
    @Published var fontSize: CGFloat = 13
    @Published var searchMatches: [SearchMatch] = []
    @Published var activeSearchIndex = 0
    /// Whether the shell is at a prompt (not running a command). Used by history key monitor.
    @Published var isAtPrompt = true

    /// Whether the shell is still loading (no prompt yet). Cleared on first OSC 7.
    @Published var isShellLoading = true

    /// Set to true when no PTY output arrives within the startup timeout (shell may be hung).
    /// Cleared automatically on first output.
    @Published var shellStartupSlow = false

    /// Last time output was observed for this terminal session.
    /// Used by tab restore logic to choose the best-matching AI session when
    /// multiple candidate sessions exist for the same directory.
    var lastOutputDate: Date {
        lastOutputAt
    }

    private(set) var lastAIProvider: String?
    private(set) var lastAISessionId: String?

    private var hasBackgroundRenderingAIContext: Bool {
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

    private static func displayName(fromProvider provider: String?) -> String? {
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

    // These change on every keystroke. Keeping them as @Published would cause
    // SwiftUI to trigger updateNSView on every keystroke, adding unnecessary overhead.
    // The debug console has its own 1-second refresh timer to read these values.
    var inputLatencyMs: Int?
    var inputLatencyAverageMs: Int?
    var outputLatencyMs: Int?
    var outputLatencyAverageMs: Int?
    var dangerousHighlightDelayMs: Int?
    var dangerousHighlightAverageMs: Int?
    @Published private(set) var lagTimeline: [LagEvent] = []

    private weak var appModel: AppModel?
    /// Rust terminal view
    private weak var rustTerminalView: RustTerminalView?
    /// Strong reference to keep the Rust terminal view alive across SwiftUI view recreations
    private var retainedRustTerminalView: RustTerminalView?
    /// Prefill command queued when restore/restoration occurs before terminal is ready.
    private var pendingPrefillInput: String?
    /// Retry counter for pending prefill flush attempts.
    private var pendingPrefillRetries = 0
    /// Restore commands (cd, scrollback cat) queued when the terminal view hasn't been
    /// created yet. Flushed on view attachment before the prefill command.
    private var pendingRestoreInput: String?
    /// Cached snapshot of the last rendered terminal frame, used for instant tab-switch visuals
    /// when the actual NSView has been removed from the hierarchy (distant-tab optimization).
    var lastRenderedSnapshot: NSImage?
    private var settingsObservers: [NSObjectProtocol] = []
    private var idleTimer: DispatchSourceTimer?
    private var lastInputAt = Date.distantPast
    private var lastOutputAt = Date.distantPast
    private var commandStartedAt = Date.distantPast // Track when command started for "stuck" detection
    private var hasPendingCommand = false
    private var inputBuffer = ""
    private var gitCheckWorkItem: DispatchWorkItem?
    private let gitQueue = DispatchQueue(label: "com.chau7.git", qos: .utility)
    private var searchUpdateWorkItem: DispatchWorkItem?
    private let searchQueue = DispatchQueue(label: "com.chau7.search", qos: .utility)
    private var searchQuery = ""
    private var cachedBufferData: Data? // Cached buffer data for search
    private var bufferNeedsRefresh = true // Flag to invalidate cache on output
    private var bufferLineCount = 0
    private var pendingInputLatencyAt: CFAbsoluteTime?
    private var inputLatencySampleCount = 0
    private var inputLatencyTotalMs: Double = 0
    private var pendingOutputLatencyAt: CFAbsoluteTime?
    private var pendingAITimingInputAt: Date?
    private var pendingAITimingInputChars = 0
    private var outputLatencySampleCount = 0
    private var outputLatencyTotalMs: Double = 0
    private let inputLagLogThresholdMs: Double = 60
    private let outputLagLogThresholdMs: Double = 120
    private let highlightLagLogThresholdMs: Double = 120
    private let maxAcceptedLatencyMs: Double = 10000
    private let latencyLogCooldownSeconds: TimeInterval = 15
    private var lastInputLagLogAt: Date?
    private var lastOutputLagLogAt: Date?
    private var lastHighlightLagLogAt: Date?
    private let lagTimelineCapacity = 120
    private let latencySampleCapacity = 120
    private var inputLatencySamples: LatencySampleBuffer
    private var outputLatencySamples: LatencySampleBuffer
    private var dangerousHighlightSamples: LatencySampleBuffer
    private var outputBurstStartAt = Date.distantPast
    private var outputBurstBytes = 0
    private var outputBurstChunks = 0
    private var outputBurstActive = false
    private let outputBurstWindowSeconds: TimeInterval = 2.0
    private let outputBurstIdleThreshold: TimeInterval = 0.35
    private let outputBurstBytesThreshold = 64 * 1024
    private let outputBurstChunksThreshold = 24
    private var dangerousHighlightSampleCount = 0
    private var dangerousHighlightTotalMs: Double = 0
    private var outputRiskCacheVersion = 0
    private var outputRiskCache: [Int: (version: Int, isRisk: Bool)] = [:]
    private let outputRiskCacheMaxEntries = 800
    private var dirtyOutputRange: ClosedRange<Int>?
    private var outputLatencyFallbackWorkItem: DispatchWorkItem?
    private let outputLatencyFallbackSeconds: TimeInterval = 0.2
    private let aiTimingWindowSeconds: TimeInterval = 120
    private let remoteOutputQueue = DispatchQueue(label: "com.chau7.remoteOutput", qos: .utility)
    /// Queue for heavy output processing to avoid blocking main thread (Fix #6)
    private let outputProcessingQueue = DispatchQueue(label: "com.chau7.outputProcessing", qos: .userInitiated)
    private var pendingRemoteOutput = Data()
    private var remoteOutputFlushWorkItem: DispatchWorkItem?
    private let remoteOutputFlushInterval: TimeInterval = 0.05
    private let remoteOutputMaxBufferBytes = 256 * 1024
    private let remoteOutputBatchingEnabled: Bool = {
        if let raw = EnvVars.get(EnvVars.remoteOutputBatch) {
            let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !(lowered == "0" || lowered == "false" || lowered == "off")
        }
        return true
    }()

    private var didClearOnLaunch = false
    private var didApplyShellIntegration = false
    private var shellIntegrationOutputCount = 0
    private var shouldAutoFocusOnAttach = true // Auto-focus when terminal view is attached
    private var didStartDevServerMonitor = false // Track if dev server monitor has started
    // AI detection state machine — handles sliding buffer, cooldown, re-detection
    // locking, and phase transitions. See AIDetectionState.swift for details.
    private var aiDetection = AIDetectionState()
    private var pendingCommandLine: String?
    private var promptSeenForPendingCommand = false
    private var commandFinishedNotified = false
    private let terminationStateQueue = DispatchQueue(label: "com.chau7.terminal.termination")
    private var didHandleProcessTermination = false
    private var closeSessionRequested = false
    private var forcedTerminationWorkItem: DispatchWorkItem?
    private let dangerousCommandTracker = InputLineTracker(maxEntries: FeatureSettings.shared.scrollbackLines)
    private var dangerousOutputHighlightWorkItem: DispatchWorkItem?
    private var dangerousOutputHighlightLastRun = Date.distantPast
    /// Cached dangerous output rows from the most recent async scan (for in-grid tinting).
    private var cachedDangerousOutputRowSet: Set<Int> = []
    private var scrollHighlightWorkItem: DispatchWorkItem?
    private let scrollHighlightDebounceSeconds: TimeInterval = 0.15

    private let semanticDetector = SemanticOutputDetector()
    private let devServerMonitor = DevServerMonitor()
    private let processResourceMonitor = ProcessResourceMonitor()
    private lazy var shellEventDetector = ShellEventDetector(appModel: appModel)
    private static let osc7Prefix = Data([0x1B, 0x5D, 0x37, 0x3B])
    private static let aiExitMarkerPrefix = Data("\u{001b}]9;chau7;exit=".utf8)
    private static let aiExitMarkerSuffix = Data([0x07])
    private static let aiExitMarkerKeepBytes = max(0, aiExitMarkerPrefix.count - 1)

    private struct AILogContext {
        let toolName: String
        let commandLine: String?
        let logPath: String
    }

    /// Serial queue for synchronizing AI log state access.
    /// Required because `processAILogOutput` runs on outputProcessingQueue while
    /// `finishAILogging` and `startAILoggingIfNeeded` run on the main thread.
    private let aiLogQueue = DispatchQueue(label: "com.chau7.terminal.ailog")
    private var aiLogSession: AITerminalLogSession?
    private var aiLogContext: AILogContext?
    private var aiLogPrefixBuffer = Data()

    private var notificationTabName: String {
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
    private var idleSeconds: TimeInterval {
        if let envValue = EnvVars.get(EnvVars.idleSeconds, legacy: EnvVars.legacyIdleSeconds),
           let seconds = Double(envValue), seconds > 0 {
            return seconds
        }
        return 3.0
    }

    /// Stuck timeout in seconds - when command runs this long without output, mark as stuck.
    private let stuckSeconds: TimeInterval = 30.0
    private var fallbackCompletionSeconds: TimeInterval {
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
        super.init()
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
                Log.info("Dev server detected: \(serverInfo.name) on port \(serverInfo.port ?? 0)")
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
        gitCheckWorkItem?.cancel()
        searchUpdateWorkItem?.cancel()
        aiLogSession?.close()
        devServerMonitor.stop()
        processResourceMonitor.stop()
        forcedTerminationWorkItem?.cancel()
    }

    // MARK: - Process Resource Monitoring (hover card)

    func startProcessMonitoring() {
        guard let rustView = rustTerminalView else { return }
        let pid = rustView.shellPid
        guard pid > 0 else {
            processGroup = nil
            return
        }
        processGroup = nil // Clear stale data from a previous hover
        processResourceMonitor.onUpdate = { [weak self] snapshot in
            DispatchQueue.main.async { self?.processGroup = snapshot }
        }
        processResourceMonitor.start(shellPID: pid)
    }

    func stopProcessMonitoring() {
        processResourceMonitor.stop()
        processGroup = nil
    }

    /// Returns the existing Rust terminal view if one exists
    var existingRustTerminalView: RustTerminalView? {
        retainedRustTerminalView
    }

    /// Accessor for the active terminal view
    private var activeTerminalView: (any TerminalViewLike)? {
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
            handlePromptDetected()
            // Use the same cooldown-aware clearing as OSC 7 prompt detection
            DispatchQueue.main.async { [weak self] in
                self?.clearActiveAppAfterPrompt()
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

        flushPendingRestoreInput()
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

    // MARK: - Shell Integration (Issue #8 fix)

    /// Schedules shell integration script to run after shell is ready.
    /// Instead of an arbitrary delay, we wait for initial output (prompt).
    func scheduleShellIntegration(for view: any TerminalViewLike) {
        // The shell integration will be applied when we detect the first few outputs,
        // indicating the shell has started and is ready for input.
        didApplyShellIntegration = false
        shellIntegrationOutputCount = 0
    }

    private func maybeApplyShellIntegration() {
        guard !didApplyShellIntegration else { return }
        guard let view = activeTerminalView else { return }

        // Wait for a few output events to ensure shell is ready
        shellIntegrationOutputCount += 1
        if shellIntegrationOutputCount >= 2 {
            didApplyShellIntegration = true
            applyShellIntegration(to: view)
        }
    }

    func handleInput(_ text: String) {
        lastInputAt = Date()
        let sanitizedText = sanitizeInputForBuffer(text)
        guard !sanitizedText.isEmpty else { return }

        if !sanitizedText.isEmpty {
            markInputLatencyStart()
        }
        inputBuffer.append(sanitizedText)
        aiLogQueue.sync {
            aiLogSession?.recordInput(sanitizedText)
        }
        if sanitizedText.contains("\n") || sanitizedText.contains("\r") {
            processInputBuffer()
            markRunning()
        }
    }

    func handleOutput(_ data: Data) {
        if shellStartupSlow { shellStartupSlow = false }

        // Fix #6: Split output processing - light work inline, heavy work on background queue
        let outputToken = FeatureProfiler.shared.begin(.outputProcessing, bytes: data.count)
        let now = Date()
        let outputGap = now.timeIntervalSince(lastOutputAt)
        lastOutputAt = now

        // Light operations that need immediate execution (timing-sensitive)
        if !data.isEmpty {
            updateOutputBurstState(bytes: data.count, outputGap: outputGap, now: now)
            markOutputLatencyStart()
            markDirtyOutputRange(for: data)
            noteAIFirstOutputIfNeeded(bytes: data.count, at: now)
        }
        bufferNeedsRefresh = true
        recordInputLatencyIfNeeded()

        // Remote output enqueueing (already uses its own queue internally)
        enqueueRemoteOutput(data)

        // Capture source for background processing
        let source = activeAppName ?? title

        // Heavy processing on background queue to avoid blocking UI
        outputProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            // Terminal output capture (thread-safe singleton)
            TerminalOutputCapture.shared.record(data: data, source: source)

            // Convert to text once for reuse
            let outputText = String(data: data, encoding: .utf8)

            // Shell event detection
            if let outputText {
                shellEventDetector.processOutput(outputText)
            }

            // Semantic detection (expensive)
            if FeatureSettings.shared.isSemanticSearchEnabled,
               data.contains(where: { $0 == 0x0A || $0 == 0x0D }) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let row = currentBufferRow() {
                        let token = FeatureProfiler.shared.begin(.semantic)
                        semanticDetector.updateCurrentRow(row)
                        FeatureProfiler.shared.end(token)
                    }
                }
            }

            // AI log processing (synchronized to prevent race with finishAILogging)
            var aiExitCode: Int?
            aiLogQueue.sync {
                let aiLogResult = self.processAILogOutput(data)
                if let logData = aiLogResult.loggable, !logData.isEmpty {
                    self.aiLogSession?.recordOutput(logData)
                }
                aiExitCode = aiLogResult.exitCode
            }

            // UI-related updates need main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let mainToken = FeatureProfiler.shared.begin(.outputMainThread, bytes: data.count)
                FeatureProfiler.shared.end(outputToken)

                if let exitCode = aiExitCode {
                    finishAILogging(exitCode: exitCode)
                }

                // Shell integration check
                maybeApplyShellIntegration()

                // Prompt update handling
                let promptToken = FeatureProfiler.shared.begin(.promptUpdate, bytes: data.count)
                let sawPromptUpdate = maybeHandlePromptUpdate(data)
                FeatureProfiler.shared.end(promptToken)

                // AI app detection
                if !sawPromptUpdate {
                    maybeDetectAppFromOutput(data)
                }

                // Dangerous output recording
                if outputText != nil {
                    recordDangerousOutputIfNeeded()
                }

                // AI waiting detection
                maybeDetectAIWaitingForInput(data)

                // Dev server detection
                let devToken = FeatureProfiler.shared.begin(.devServerDetect, bytes: data.count)
                maybeDetectDevServer(data)
                FeatureProfiler.shared.end(devToken)

                FeatureProfiler.shared.end(mainToken)
            }
        }
    }

    private func maybeDetectDevServer(_ data: Data) {
        // Start the dev server monitor if not already started
        if !didStartDevServerMonitor {
            var pid: pid_t = 0

            if let rustView = rustTerminalView {
                pid = rustView.shellPid
                Log.trace("TerminalSessionModel: Got shell PID from Rust backend: \(pid)")
            }

            if pid > 0 {
                didStartDevServerMonitor = true
                devServerMonitor.start(shellPID: pid)
                Log.info("TerminalSessionModel: Started dev server monitor with PID \(pid)")
            }
        }

        // Check output for dev server patterns
        guard devServer == nil else { return } // Already detected
        let checkData = data.prefix(2048)
        guard let output = String(data: checkData, encoding: .utf8) else { return }
        devServerMonitor.checkOutput(output)
    }

    /// Detects when an AI agent is waiting for user input (prompts, permission requests, etc.)
    private func maybeDetectAIWaitingForInput(_ data: Data) {
        guard activeAppName != nil else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        let token = FeatureProfiler.shared.begin(.aiDetect, bytes: data.count, metadata: "wait-for-input")
        defer { FeatureProfiler.shared.end(token) }

        // Common AI input waiting patterns
        let waitingPatterns = [
            "Yes/No",
            "[y/N]",
            "[Y/n]",
            "(y/n)",
            "Allow?",
            "Approve?",
            "Continue?",
            "Proceed?",
            "Permission",
            "> ", // Common prompt indicator
            "? ", // Question prompt
            "Enter your",
            "Type your",
            "waiting for"
        ]

        let lowercased = text.lowercased()
        let loweredPatterns = waitingPatterns.map { $0.lowercased() }
        let isWaiting: Bool
        if let rustMatch = RustPatternMatcher.waitPatterns.containsAny(haystack: lowercased, patterns: loweredPatterns) {
            isWaiting = rustMatch
        } else {
            isWaiting = waitingPatterns.contains { pattern in
                lowercased.contains(pattern.lowercased())
            }
        }

        if isWaiting {
            DispatchQueue.main.async { [weak self] in
                guard let self, status == .running else { return }
                status = .waitingForInput
                Log.trace("AI agent waiting for input detected")
            }
        }
    }

    private func processAILogOutput(_ data: Data) -> (loggable: Data?, exitCode: Int?) {
        guard aiLogSession != nil || !aiLogPrefixBuffer.isEmpty else { return (nil, nil) }
        var combined = aiLogPrefixBuffer
        combined.append(data)
        aiLogPrefixBuffer.removeAll(keepingCapacity: true)

        if let prefixRange = combined.range(of: Self.aiExitMarkerPrefix) {
            let loggable = Data(combined[..<prefixRange.lowerBound])
            let afterPrefix = prefixRange.upperBound
            if let suffixRange = combined.range(of: Self.aiExitMarkerSuffix, in: afterPrefix ..< combined.endIndex) {
                let payload = combined[afterPrefix ..< suffixRange.lowerBound]
                let exitCode = parseAIExitCode(payload)
                aiLogPrefixBuffer.removeAll(keepingCapacity: true)
                return (loggable, exitCode)
            }
            aiLogPrefixBuffer = Data(combined[prefixRange.lowerBound...])
            return (loggable, nil)
        }

        let keep = Self.aiExitMarkerKeepBytes
        if combined.count > keep {
            let cutIndex = combined.count - keep
            let loggable = Data(combined[..<cutIndex])
            aiLogPrefixBuffer = Data(combined[cutIndex...])
            return (loggable, nil)
        }

        aiLogPrefixBuffer = combined
        return (nil, nil)
    }

    private func parseAIExitCode(_ payload: Data) -> Int? {
        let raw = String(decoding: payload, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(raw) {
            return value
        }
        if let range = raw.range(of: "exit=") {
            let digits = raw[range.upperBound...].prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    private func startAILoggingIfNeeded(toolName: String, commandLine: String?) {
        // Synchronized access to AI log state
        aiLogQueue.sync {
            guard aiLogSession == nil else { return }
            let logPath = terminalLogPath(for: toolName)
            aiLogSession = AITerminalLogSession(toolName: toolName, logPath: logPath)
            let trimmedCommand = commandLine?.trimmingCharacters(in: .whitespacesAndNewlines)
            aiLogContext = AILogContext(toolName: toolName, commandLine: trimmedCommand, logPath: logPath)
            aiLogPrefixBuffer.removeAll(keepingCapacity: true)

            let message: String
            if let trimmedCommand, !trimmedCommand.isEmpty {
                message = "Started: \(trimmedCommand)"
            } else {
                message = "Started (detected from output)"
            }
            AIEventLogWriter.appendEvent(
                type: "info",
                tool: toolName,
                message: message,
                source: .terminalSession,
                logPath: eventsLogPath()
            )
        }
    }

    private func finishAILogging(exitCode: Int?) {
        // Telemetry: record run end
        TelemetryRecorder.shared.runEnded(tabID: tabIdentifier, exitStatus: exitCode)

        // Notify shell event detector (outside lock to avoid potential deadlock)
        commandFinishedNotified = true
        promptSeenForPendingCommand = true

        // Synchronized access to AI log state
        aiLogQueue.sync {
            shellEventDetector.commandFinished(exitCode: exitCode, command: aiLogContext?.commandLine)

            guard let context = aiLogContext else {
                // If aiLogSession still exists, a prior caller already cleared aiLogContext
                // but we never logged a "Finished" event — emit one now to avoid orphaned starts
                if let session = aiLogSession {
                    AIEventLogWriter.appendEvent(
                        type: "finished",
                        tool: session.toolName,
                        message: "Finished (cleanup)",
                        source: .terminalSession,
                        logPath: eventsLogPath()
                    )
                }
                aiLogSession?.close()
                aiLogSession = nil
                aiLogPrefixBuffer.removeAll(keepingCapacity: true)
                return
            }

            let type: String
            if let exitCode, exitCode != 0 {
                type = "failed"
            } else {
                type = "finished"
            }

            let message: String
            if let command = context.commandLine, !command.isEmpty {
                if let exitCode {
                    message = "\(type.capitalized) (exit \(exitCode)): \(command)"
                } else {
                    message = "\(type.capitalized): \(command)"
                }
            } else if let exitCode {
                message = "\(type.capitalized) (exit \(exitCode))"
            } else {
                message = "\(type.capitalized)"
            }

            AIEventLogWriter.appendEvent(
                type: type,
                tool: context.toolName,
                message: message,
                source: .terminalSession,
                logPath: eventsLogPath()
            )

            aiLogSession?.close()
            aiLogSession = nil
            aiLogContext = nil
            aiLogPrefixBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func eventsLogPath() -> String {
        let trimmed = appModel?.logPath.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-events.log").path
    }

    private func terminalLogPath(for toolName: String) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let appModel, let path = appModel.terminalLogPath(forToolName: trimmed), !path.isEmpty {
            return path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logDir = home.appendingPathComponent("Library/Logs/Chau7").path
        let slug = sanitizeToolName(trimmed)
        return "\(logDir)/\(slug)-pty.log"
    }

    private func sanitizeToolName(_ toolName: String) -> String {
        let lowercased = toolName.lowercased()
        var slug = ""
        slug.reserveCapacity(lowercased.count)
        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.append(Character(scalar))
            } else if scalar.value == 0x20 || scalar.value == 0x2D || scalar.value == 0x5F {
                if !slug.hasSuffix("-") {
                    slug.append("-")
                }
            }
        }
        if slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug.isEmpty ? "ai-cli" : slug
    }

    private func maybeHandlePromptUpdate(_ data: Data) -> Bool {
        guard data.range(of: Self.osc7Prefix) != nil else { return false }
        if Thread.isMainThread {
            clearActiveAppAfterPrompt()
            handlePromptDetected()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.clearActiveAppAfterPrompt()
                self?.handlePromptDetected()
            }
        }
        return true
    }

    private func clearActiveAppAfterPrompt() {
        guard aiDetection.handlePromptReturn() else { return }
        Log.trace("Clearing active app after OSC 7 prompt update.")
        activeAppName = aiDetection.currentApp // nil after prompt return
        // finishAILogging is idempotent and has internal synchronization
        finishAILogging(exitCode: nil)
    }

    private func handlePromptDetected() {
        if isShellLoading { isShellLoading = false }
        isAtPrompt = true
        createDeferredCTOFlag()
        devServerMonitor.commandDidFinish()
        flushPendingPrefillInputIfReady()
        guard hasPendingCommand, pendingCommandLine != nil else { return }
        promptSeenForPendingCommand = true
        if !commandFinishedNotified {
            commandFinishedNotified = true
            shellEventDetector.commandFinished(exitCode: nil, command: pendingCommandLine)
        }
    }

    private func markInputLatencyStart() {
        let timestamp = CFAbsoluteTimeGetCurrent()
        if Thread.isMainThread {
            pendingInputLatencyAt = timestamp
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pendingInputLatencyAt = timestamp
            }
        }
    }

    private func recordInputLatencyIfNeeded() {
        guard pendingInputLatencyAt != nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if Thread.isMainThread {
            recordInputLatencyIfNeeded(now: now)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.recordInputLatencyIfNeeded(now: now)
            }
        }
    }

    private func recordInputLatencyIfNeeded(now: CFAbsoluteTime) {
        guard let start = pendingInputLatencyAt else { return }
        pendingInputLatencyAt = nil
        let elapsedMs = max(0, (now - start) * 1000)
        guard elapsedMs <= maxAcceptedLatencyMs else {
            Log.debug("Discarded stale input latency sample: \(Int(elapsedMs.rounded()))ms")
            return
        }
        inputLatencySamples.append(Int(elapsedMs.rounded()))
        inputLatencySampleCount += 1
        inputLatencyTotalMs += elapsedMs
        inputLatencyMs = Int(elapsedMs.rounded())
        inputLatencyAverageMs = inputLatencySamples.recentAverage()
        maybeLogLatencySpike(
            kind: "input",
            elapsedMs: elapsedMs,
            averageMs: inputLatencyAverageMs,
            samples: inputLatencySamples,
            thresholdMs: inputLagLogThresholdMs,
            lastLoggedAt: &lastInputLagLogAt
        )
    }

    private func markOutputLatencyStart() {
        let timestamp = CFAbsoluteTimeGetCurrent()
        if Thread.isMainThread {
            if pendingOutputLatencyAt == nil {
                pendingOutputLatencyAt = timestamp
                scheduleOutputLatencyFallback()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if pendingOutputLatencyAt == nil {
                    pendingOutputLatencyAt = timestamp
                    scheduleOutputLatencyFallback()
                }
            }
        }
    }

    func recordOutputLatencyIfNeeded() {
        guard pendingOutputLatencyAt != nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if Thread.isMainThread {
            recordOutputLatencyIfNeeded(now: now)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.recordOutputLatencyIfNeeded(now: now)
            }
        }
    }

    private func recordOutputLatencyIfNeeded(now: CFAbsoluteTime) {
        guard let start = pendingOutputLatencyAt else { return }
        pendingOutputLatencyAt = nil
        outputLatencyFallbackWorkItem?.cancel()
        outputLatencyFallbackWorkItem = nil
        let elapsedMs = max(0, (now - start) * 1000)
        guard elapsedMs <= maxAcceptedLatencyMs else {
            Log.debug("Discarded stale output latency sample: \(Int(elapsedMs.rounded()))ms")
            return
        }
        outputLatencySamples.append(Int(elapsedMs.rounded()))
        outputLatencySampleCount += 1
        outputLatencyTotalMs += elapsedMs
        outputLatencyMs = Int(elapsedMs.rounded())
        outputLatencyAverageMs = outputLatencySamples.recentAverage()
        maybeLogLatencySpike(
            kind: "output",
            elapsedMs: elapsedMs,
            averageMs: outputLatencyAverageMs,
            samples: outputLatencySamples,
            thresholdMs: outputLagLogThresholdMs,
            lastLoggedAt: &lastOutputLagLogAt
        )
    }

    private func scheduleOutputLatencyFallback() {
        guard outputLatencyFallbackWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.clearPendingOutputLatencyMeasurement()
        }
        outputLatencyFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + outputLatencyFallbackSeconds, execute: work)
    }

    private func clearPendingOutputLatencyMeasurement() {
        guard pendingOutputLatencyAt != nil else { return }
        pendingOutputLatencyAt = nil
        outputLatencyFallbackWorkItem?.cancel()
        outputLatencyFallbackWorkItem = nil
        Log.trace("Cleared synthetic output latency sample after fallback timeout")
    }

    private func markDirtyOutputRange(for data: Data) {
        guard let endRow = currentBufferRow() else { return }
        var newlineCount = 0
        for byte in data where byte == 0x0A {
            newlineCount += 1
        }
        let startRow = max(0, endRow - max(1, newlineCount + 1))
        let newRange = startRow ... endRow
        if let existing = dirtyOutputRange {
            dirtyOutputRange = min(existing.lowerBound, newRange.lowerBound) ... max(existing.upperBound, newRange.upperBound)
        } else {
            dirtyOutputRange = newRange
        }
    }

    private func updateOutputBurstState(bytes: Int, outputGap: TimeInterval, now: Date) {
        if outputGap > outputBurstIdleThreshold {
            outputBurstStartAt = now
            outputBurstBytes = 0
            outputBurstChunks = 0
            outputBurstActive = false
        }

        outputBurstBytes += bytes
        outputBurstChunks += 1

        let window = now.timeIntervalSince(outputBurstStartAt)
        if !outputBurstActive {
            if window > outputBurstWindowSeconds {
                outputBurstStartAt = now
                outputBurstBytes = bytes
                outputBurstChunks = 1
            }
            let inWindow = now.timeIntervalSince(outputBurstStartAt) <= outputBurstWindowSeconds
            if inWindow,
               outputBurstBytes >= outputBurstBytesThreshold || outputBurstChunks >= outputBurstChunksThreshold {
                outputBurstActive = true
            }
        }
    }

    private func enqueueRemoteOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        if !remoteOutputBatchingEnabled {
            let sessionID = tabIdentifier
            Task { @MainActor in
                RemoteControlManager.shared.recordOutput(data, sessionIdentifier: sessionID)
            }
            return
        }
        remoteOutputQueue.async { [weak self] in
            guard let self else { return }
            pendingRemoteOutput.append(data)

            if pendingRemoteOutput.count >= remoteOutputMaxBufferBytes {
                remoteOutputFlushWorkItem?.cancel()
                remoteOutputFlushWorkItem = nil
                flushRemoteOutput()
                return
            }

            if remoteOutputFlushWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.flushRemoteOutput()
                }
                remoteOutputFlushWorkItem = work
                remoteOutputQueue.asyncAfter(deadline: .now() + remoteOutputFlushInterval, execute: work)
            }
        }
    }

    private func flushRemoteOutput() {
        let payload = pendingRemoteOutput
        pendingRemoteOutput.removeAll(keepingCapacity: true)
        remoteOutputFlushWorkItem = nil
        guard !payload.isEmpty else { return }
        let sessionID = tabIdentifier
        Task { @MainActor in
            RemoteControlManager.shared.recordOutput(payload, sessionIdentifier: sessionID)
        }
    }

    /// Attempts to detect AI CLI from output patterns when command detection missed it.
    ///
    /// Improvements over the original implementation:
    /// Detects AI tool from terminal output using the `AIDetectionState` state machine.
    ///
    /// The state machine handles: sliding buffer, phase gating, cooldown,
    /// re-detection locking (same tool only), and retry window exhaustion.
    /// This method only does pattern matching and fires side effects on state change.
    private func maybeDetectAppFromOutput(_ data: Data) {
        // State machine handles phase checks, sliding buffer, and retry window.
        // Returns nil when scanning should be skipped (already detected, window exhausted, etc.)
        let failuresBefore = aiDetection.utf8DecodeFailures
        guard let haystack = aiDetection.prepareHaystack(chunk: data) else {
            if aiDetection.utf8DecodeFailures > failuresBefore {
                if aiDetection.utf8DecodeFailures == 1 {
                    Log.warn("First UTF-8 decode failure in AI detection sliding buffer — may indicate encoding issue")
                } else {
                    Log.trace("UTF-8 decode failure in AI detection sliding buffer (total: \(aiDetection.utf8DecodeFailures))")
                }
            }
            return
        }

        let token = FeatureProfiler.shared.begin(.aiDetect, bytes: data.count, metadata: "output-patterns")
        defer { FeatureProfiler.shared.end(token) }

        let patterns = outputDetectionPatterns()
        let patternStrings = patterns.map { $0.pattern }

        // Find a match — state machine will decide whether to accept it
        var matchedApp: String?
        var matchedPattern: String?

        // Fast path: Rust Aho-Corasick on the lowercased haystack
        if let index = RustPatternMatcher.outputPatterns.firstMatchIndex(haystack: haystack, patterns: patternStrings) {
            if index >= 0, index < patterns.count {
                matchedApp = patterns[index].appName
                matchedPattern = patterns[index].pattern
            }
        }

        // Fallback: linear scan (patterns already lowercased, haystack already lowercased)
        if matchedApp == nil {
            for (pattern, appName) in patterns {
                if haystack.contains(pattern) {
                    matchedApp = appName
                    matchedPattern = pattern
                    break
                }
            }
        }

        // State machine filters: redetecting rejects different tools, detected is unreachable
        guard aiDetection.handleOutputMatch(appName: matchedApp),
              let app = aiDetection.currentApp else { return }

        // State changed → sync @Published property and fire side effects
        activeAppName = app
        startAILoggingIfNeeded(toolName: app, commandLine: nil)

        TelemetryRecorder.shared.runStarted(
            tabID: tabIdentifier,
            provider: AIResumeParser.normalizeProviderName(app) ?? app,
            cwd: currentDirectory,
            repoPath: gitRootPath,
            sessionID: lastAISessionId
        )

        Log.info("AI detected from output pattern: \(app) (matched: \(matchedPattern ?? "unknown"))")
    }

    private func outputDetectionPatterns() -> [(pattern: String, appName: String)] {
        let custom = FeatureSettings.shared.customAIDetectionRules.compactMap { rule -> (String, String)? in
            let trimmedPattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedName = rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPattern.isEmpty else { return nil }
            let name = trimmedName.isEmpty ? "Custom AI" : trimmedName
            return (trimmedPattern, name)
        }
        return CommandDetection.outputDetectionPatterns + custom
    }

    private func markRunning() {
        if status != .running, status != .stuck {
            status = .running
            commandStartedAt = Date()
        }
        hasPendingCommand = true
    }

    private func sanitizeInputForBuffer(_ text: String) -> String {
        guard text.contains("\u{1b}") else { return text }
        guard let data = text.data(using: .utf8) else { return text }

        var output = Data()
        var index = 0
        while index < data.count {
            let byte = data[index]
            if byte != 0x1B {
                output.append(byte)
                index += 1
                continue
            }

            index += 1
            guard index < data.count else { break }

            let next = data[index]
            if next == 0x5B {
                // CSI sequence: ESC [ ... final byte [@-~]
                index += 1
                while index < data.count {
                    let current = data[index]
                    if current >= 0x40, current <= 0x7E {
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }

            if next == 0x5D || next == 0x50 {
                // OSC / DCS sequence (terminated by BEL or ESC \)
                index += 1
                while index < data.count {
                    if data[index] == 0x07 {
                        index += 1
                        break
                    }
                    if data[index] == 0x1B,
                       index + 1 < data.count,
                       data[index + 1] == 0x5C {
                        index += 2
                        break
                    }
                    index += 1
                }
                continue
            }

            // Generic escape + one byte (legacy function keys / modifier codes)
            index += 1
        }

        return String(data: output, encoding: .utf8) ?? text
    }

    private func processInputBuffer() {
        let normalized = inputBuffer.replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.components(separatedBy: "\n")
        if parts.count <= 1 {
            return
        }
        for line in parts.dropLast() {
            handleInputLine(line)
        }
        inputBuffer = parts.last ?? ""
    }

    private func applyCTOPrefixIfNeeded(to line: String) -> String {
        guard FeatureSettings.shared.isCTOEnabled(forTabIdentifier: tabIdentifier) else { return line }
        let prefix = FeatureSettings.shared.ctoPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return line }
        guard !line.isEmpty else { return line }
        if line.hasPrefix(prefix) { return line }
        let needsSeparator = !prefix.hasSuffix(" ") && !line.hasPrefix(" ")
        return needsSeparator ? "\(prefix) \(line)" : "\(prefix)\(line)"
    }

    private func handleInputLine(_ line: String) {
        // Sanitize input to remove escape sequences that contaminate history/logs
        let sanitized = EscapeSequenceSanitizer.sanitize(line)
        let transformed = applyCTOPrefixIfNeeded(to: sanitized)
        let trimmed = transformed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pendingCommandLine = nil
            promptSeenForPendingCommand = false
            commandFinishedNotified = false
            return
        }
        pendingCommandLine = trimmed
        promptSeenForPendingCommand = false
        commandFinishedNotified = false
        isAtPrompt = false

        // Security: check if the PTY has echo disabled (password prompt, passphrase, etc.)
        // If so, mark as sensitive to prevent recording in history.
        let echoDisabled = activeTerminalView?.isPtyEchoDisabled ?? false
        CommandHistoryManager.shared.recordCommand(trimmed, tabID: tabIdentifier, isSensitive: echoDisabled)
        shellEventDetector.commandStarted(command: trimmed, in: currentDirectory)
        trackAIResumeMetadata(from: trimmed)
        updateActiveAppName(from: trimmed)
        noteAIInputTimingIfNeeded(for: trimmed)
        recordInputLineIfNeeded()
        trackSemanticCommand(trimmed)
        recordDangerousCommandLineIfNeeded(trimmed)
        guard let targetRaw = cdTarget(from: trimmed) else { return }

        var target: String
        if targetRaw.isEmpty {
            target = FileManager.default.homeDirectoryForCurrentUser.path
        } else {
            target = targetRaw
        }

        if target.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            target = home + target.dropFirst()
        }

        let resolved: String
        if target.hasPrefix("/") {
            resolved = String(target)
        } else {
            let base = URL(fileURLWithPath: currentDirectory)
            resolved = base.appendingPathComponent(String(target)).standardized.path
        }

        updateCurrentDirectory(resolved)
    }

    private func markIdleIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Don't transition from waitingForInput - user needs to respond
            guard status == .running || status == .stuck else { return }
            guard hasPendingCommand else { return }

            let latestActivity = max(lastInputAt, lastOutputAt)
            let latestIdleFor = Date().timeIntervalSince(latestActivity)
            let runningFor = Date().timeIntervalSince(commandStartedAt)

            // Check for "stuck" - running for too long without recent output
            // Only applies to .running status, not waitingForInput
            if status == .running, runningFor >= stuckSeconds {
                let outputIdleFor = Date().timeIntervalSince(lastOutputAt)
                if outputIdleFor >= stuckSeconds {
                    status = .stuck
                    Log.info("Command marked as stuck after \(Int(runningFor))s")
                    return
                }
            }

            // Prefer prompt-based completion, but fall back after a long idle if prompt updates are missing.
            if !promptSeenForPendingCommand {
                if latestIdleFor >= fallbackCompletionSeconds {
                    promptSeenForPendingCommand = true
                    if !commandFinishedNotified {
                        commandFinishedNotified = true
                        shellEventDetector.commandFinished(exitCode: nil, command: pendingCommandLine)
                    }
                    Log.info("Fallback completion after \(Int(latestIdleFor))s without prompt")
                } else {
                    return
                }
            }

            // Check for idle - no activity for idleSeconds
            guard latestIdleFor >= idleSeconds else { return }

            status = .idle
            hasPendingCommand = false
            promptSeenForPendingCommand = false
            pendingCommandLine = nil

            let message = "Command idle for \(Int(latestIdleFor))s"
            appModel?.recordEvent(
                source: .terminalSession,
                type: "finished",
                tool: notificationTabName,
                message: message,
                notify: true,
                directory: currentDirectory,
                tabID: ownerTabID
            )
        }
    }

    private func updateActiveAppName(from commandLine: String) {
        if let match = CommandDetection.detectApp(from: commandLine) {
            aiDetection.handleCommand(appName: match)
            activeAppName = match
            Log.info("AI detected: \(match) from command '\(commandLine.prefix(50))'")
            startAILoggingIfNeeded(toolName: match, commandLine: commandLine)
            return
        }

        // Check for dev server command
        if let devServerName = CommandDetection.detectDevServer(from: commandLine) {
            Log.trace("Dev server command detected: \(devServerName) from '\(commandLine.prefix(50))'")
            devServerMonitor.setCommandHint(devServerName)
        }

        // Custom detection rules (substring match on command line)
        let lowercasedLine = commandLine.lowercased()
        for rule in FeatureSettings.shared.customAIDetectionRules {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern.isEmpty { continue }
            if lowercasedLine.contains(pattern) {
                let name = rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = name.isEmpty ? "Custom AI" : name
                aiDetection.handleCommand(appName: displayName)
                activeAppName = displayName
                startAILoggingIfNeeded(toolName: displayName, commandLine: commandLine)
                return
            }
        }

        if activeAppName != nil, isExitCommand(commandLine) {
            // Keep lastAIProvider/lastAISessionId so tab restore can resume the
            // most recent session for this pane even after shell-level exits.
            Log.trace("Clearing active app due to exit command input.")
            aiDetection.handleExit()
            activeAppName = nil
        }
    }

    private func trackAIResumeMetadata(from commandLine: String) {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let metadata = AIResumeParser.extractMetadata(from: trimmed) {
            lastAIProvider = metadata.provider
            lastAISessionId = metadata.sessionId
            // Update telemetry run with discovered session ID
            if !metadata.sessionId.isEmpty {
                TelemetryRecorder.shared.updateSessionID(tabID: tabIdentifier, sessionID: metadata.sessionId)
            }
            return
        }

        if let detectedProvider = AIResumeParser.detectProvider(from: trimmed) {
            lastAIProvider = detectedProvider
            lastAISessionId = nil
        }
    }

    /// Restores AI metadata from persisted tab state without waiting for user input.
    /// This keeps explicit session metadata stable across restoration boundaries and
    /// prevents fallback logic from collapsing multiple tabs into one inferred session.
    func restoreAIMetadata(provider: String?, sessionId: String?) {
        let normalizedProvider = AIResumeParser.normalizeProviderName(
            provider ?? ""
        )
        let restoredDisplayName = Self.displayName(fromProvider: normalizedProvider)
        if let name = restoredDisplayName {
            aiDetection.handleRestore(appName: name)
        }
        activeAppName = restoredDisplayName
        lastAIProvider = normalizedProvider

        if let sessionId {
            let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            lastAISessionId = AIResumeParser.isValidSessionId(trimmed) ? trimmed : nil
            return
        }

        lastAISessionId = nil
    }

    private func isExitCommand(_ commandLine: String) -> Bool {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let exitCommands = ["exit", "logout", "quit"]
        for command in exitCommands {
            if lowered == command {
                return true
            }
            guard lowered.hasPrefix(command) else { continue }
            let nextIndex = lowered.index(lowered.startIndex, offsetBy: command.count)
            guard nextIndex < lowered.endIndex else { continue }
            let nextChar = lowered[nextIndex]
            if nextChar.isWhitespace || nextChar == ";" || nextChar == "&" || nextChar == "|" {
                return true
            }
        }
        return false
    }

    private func cdTarget(from commandLine: String) -> String? {
        let tokens = CommandDetection.tokenize(commandLine)
        guard let cmdIndex = CommandDetection.commandTokenIndex(from: tokens) else { return nil }
        let command = CommandDetection.normalizeToken(tokens[cmdIndex])
        guard command == "cd" else { return nil }

        let arguments = tokens[(cmdIndex + 1)...]
        guard let firstArg = arguments.first else { return "" }
        if firstArg == "-" {
            return nil
        }
        return firstArg
    }

    private func recordInputLineIfNeeded() {
        guard let view = activeTerminalView else { return }
        // Record input lines for semantic search or any active AI agent
        if FeatureSettings.shared.isSemanticSearchEnabled || activeAppName != nil {
            view.recordInputLine()
        }
    }

    private func noteAIInputTimingIfNeeded(for commandLine: String) {
        let detectedApp = CommandDetection.detectApp(from: commandLine)
        guard hasBackgroundRenderingAIContext || detectedApp != nil else {
            clearPendingAITiming()
            return
        }

        pendingAITimingInputAt = Date()
        pendingAITimingInputChars = commandLine.count
        let app = aiDisplayAppName
            ?? detectedApp
            ?? Self.displayName(fromProvider: effectiveAIProvider)
            ?? "unknown"
        Log.info(
            "AI timing: input submitted tab=\(tabIdentifier) app=\(app) provider=\(effectiveAIProvider ?? "nil") sessionId=\(effectiveAISessionId ?? "nil") chars=\(commandLine.count) status=\(effectiveStatus.rawValue) prompt=\(effectiveIsAtPrompt)"
        )
    }

    private func noteAIFirstOutputIfNeeded(bytes: Int, at now: Date) {
        guard let inputAt = pendingAITimingInputAt else { return }

        let elapsed = now.timeIntervalSince(inputAt)
        guard elapsed >= 0, elapsed <= aiTimingWindowSeconds else {
            clearPendingAITiming()
            return
        }

        let app = aiDisplayAppName
            ?? Self.displayName(fromProvider: effectiveAIProvider)
            ?? "unknown"
        Log.info(
            "AI timing: first output tab=\(tabIdentifier) app=\(app) provider=\(effectiveAIProvider ?? "nil") sessionId=\(effectiveAISessionId ?? "nil") inputChars=\(pendingAITimingInputChars) bytes=\(bytes) afterMs=\(Int((elapsed * 1000).rounded())) status=\(effectiveStatus.rawValue) prompt=\(effectiveIsAtPrompt)"
        )
        clearPendingAITiming()
    }

    private func clearPendingAITiming() {
        pendingAITimingInputAt = nil
        pendingAITimingInputChars = 0
    }

    private func recordDangerousCommandLineIfNeeded(_ commandLine: String) {
        let settings = FeatureSettings.shared
        guard CommandRiskDetection.isRisky(commandLine: commandLine, patterns: settings.dangerousCommandPatterns) else { return }
        guard let row = currentBufferRow() else { return }
        dangerousCommandTracker.record(row: row)
        if settings.dangerousCommandHighlightScope == .allOutputs {
            highlightView?.scheduleDisplay()
        }
    }

    private func recordDangerousOutputIfNeeded() {
        let settings = FeatureSettings.shared
        let scope = settings.dangerousCommandHighlightScope
        guard scope != .none else { return }
        if scope == .aiOutputs, activeAppName == nil { return }
        scheduleDangerousOutputHighlight()
    }

    func scheduleHighlightAfterScroll() {
        guard highlightView != nil else { return }
        scrollHighlightWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.highlightView?.scheduleDisplay()
        }
        scrollHighlightWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + scrollHighlightDebounceSeconds, execute: work)
    }

    private func scheduleDangerousOutputHighlight() {
        guard highlightView != nil else { return }
        let (idleDelay, maxInterval) = dangerousOutputHighlightTiming()
        let now = Date()
        let sinceLastRun = now.timeIntervalSince(dangerousOutputHighlightLastRun)
        let delay: TimeInterval = sinceLastRun >= maxInterval
            ? 0
            : idleDelay

        dangerousOutputHighlightWorkItem?.cancel()
        let expectedFireAt = CFAbsoluteTimeGetCurrent() + delay
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let congestionMs = max(0, (CFAbsoluteTimeGetCurrent() - expectedFireAt) * 1000.0)
            dangerousHighlightSamples.append(Int(congestionMs.rounded()))
            dangerousHighlightSampleCount += 1
            dangerousHighlightTotalMs += congestionMs
            dangerousHighlightDelayMs = Int(congestionMs.rounded())
            dangerousHighlightAverageMs = dangerousHighlightSamples.recentAverage()
            dangerousOutputHighlightLastRun = Date()
            maybeLogLatencySpike(
                kind: "highlight",
                elapsedMs: congestionMs,
                averageMs: dangerousHighlightAverageMs,
                samples: dangerousHighlightSamples,
                thresholdMs: highlightLagLogThresholdMs,
                lastLoggedAt: &lastHighlightLagLogAt
            )
            refreshCachedDangerousOutputRows()
            highlightView?.scheduleDisplay()
        }
        dangerousOutputHighlightWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dangerousOutputHighlightTiming() -> (idleDelay: TimeInterval, maxInterval: TimeInterval) {
        let settings = FeatureSettings.shared
        let idleMs = max(0, min(settings.dangerousOutputHighlightIdleDelayMs, 5000))
        let maxMs = max(250, min(settings.dangerousOutputHighlightMaxIntervalMs, 10000))
        let maxInterval = max(maxMs, idleMs)
        var idleDelay = TimeInterval(idleMs) / 1000.0
        var maxIntervalSeconds = TimeInterval(maxInterval) / 1000.0

        if outputBurstActive {
            // Cap highlight updates to ~2 Hz during sustained output.
            idleDelay = max(idleDelay, 0.5)
            maxIntervalSeconds = max(maxIntervalSeconds, 0.5)
        }
        if isCpuSaturated() {
            // Be more conservative when the UI is already struggling.
            idleDelay = max(idleDelay, 1.0)
            maxIntervalSeconds = max(maxIntervalSeconds, 1.0)
        }

        return (idleDelay, maxIntervalSeconds)
    }

    private func shouldUseLowPowerHighlights() -> Bool {
        guard FeatureSettings.shared.dangerousOutputHighlightLowPowerEnabled else { return false }
        return outputBurstActive || isCpuSaturated()
    }

    private func isCpuSaturated() -> Bool {
        // Only use input/output latency — these measure real main-thread congestion.
        // Highlight latency includes its own throttle delay, creating a feedback loop
        // where isCpuSaturated() → 1000ms delay → high average → isCpuSaturated() forever.
        let inputLag = inputLatencyAverageMs ?? inputLatencyMs ?? 0
        let outputLag = outputLatencyAverageMs ?? outputLatencyMs ?? 0
        let maxLag = max(inputLag, outputLag)
        return maxLag >= 80
    }

    private func trackSemanticCommand(_ command: String) {
        guard FeatureSettings.shared.isSemanticSearchEnabled else { return }
        guard let row = currentBufferRow() else { return }
        semanticDetector.commandStarted(command, atRow: row)
    }

    private func currentBufferRow() -> Int? {
        guard let view = activeTerminalView else { return nil }
        return view.currentAbsoluteRow
    }

    func dangerousCommandRowsVisible(top: Int, bottom: Int) -> [Int] {
        dangerousCommandTracker.visibleRows(top: top, bottom: bottom)
    }

    func dangerousOutputRowsVisible(top: Int, bottom: Int) -> [Int] {
        let settings = FeatureSettings.shared
        let scope = settings.dangerousCommandHighlightScope
        guard scope != .none else { return [] }
        if scope == .aiOutputs, activeAppName == nil { return [] }
        guard let view = activeTerminalView else { return [] }
        let cols = view.terminalCols
        guard cols > 0 else { return [] }

        let token = FeatureProfiler.shared.begin(.dangerScan, metadata: "rows \(top)-\(bottom)")
        defer { FeatureProfiler.shared.end(token) }

        let start = max(0, top)
        let end = max(start, bottom)
        let visibleCount = end - start + 1
        let lowPowerActive = shouldUseLowPowerHighlights()
        let maxComputations: Int
        if lowPowerActive {
            maxComputations = min(16, max(6, visibleCount / 3))
        } else {
            maxComputations = Int.max
        }
        var computedCount = 0
        var rows: [Int] = []
        rows.reserveCapacity(min(32, end - start + 1))

        if outputRiskCache.count > outputRiskCacheMaxEntries {
            outputRiskCache.removeAll(keepingCapacity: true)
        }
        let version = outputRiskCacheVersion
        let dirtyRange = dirtyOutputRange

        func lineText(for row: Int) -> String {
            return view.getLineText(absoluteRow: row)
        }

        for row in start ... end {
            let isDirty = dirtyRange?.contains(row) ?? false
            if !isDirty, let cached = outputRiskCache[row], cached.version == version {
                if cached.isRisk {
                    rows.append(row)
                }
                continue
            }

            if lowPowerActive, computedCount >= maxComputations {
                continue
            }

            let text = lineText(for: row)
            let sanitized = EscapeSequenceSanitizer.sanitize(text)
            var isRisk = CommandRiskDetection.isRisky(commandLine: sanitized, patterns: settings.dangerousCommandPatterns)
            if isRisk {
                outputRiskCache[row] = (version: version, isRisk: true)
                rows.append(row)
                computedCount += 1
                continue
            }

            if !lowPowerActive {
                let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= cols - 1, row + 1 <= end {
                    let nextText = lineText(for: row + 1)
                    let combined = trimmed + EscapeSequenceSanitizer.sanitize(nextText)
                    if CommandRiskDetection.isRisky(commandLine: combined, patterns: settings.dangerousCommandPatterns) {
                        isRisk = true
                        outputRiskCache[row] = (version: version, isRisk: true)
                        outputRiskCache[row + 1] = (version: version, isRisk: true)
                        rows.append(row)
                        rows.append(row + 1)
                        computedCount += 1
                        continue
                    }
                }
            }

            outputRiskCache[row] = (version: version, isRisk: isRisk)
            computedCount += 1
        }

        if let dirtyRange {
            if start <= dirtyRange.lowerBound, end >= dirtyRange.upperBound {
                dirtyOutputRange = nil
            } else if dirtyRange.lowerBound < start, dirtyRange.upperBound <= end {
                let newUpper = start - 1
                dirtyOutputRange = newUpper >= dirtyRange.lowerBound ? dirtyRange.lowerBound ... newUpper : nil
            } else if dirtyRange.lowerBound >= start, dirtyRange.upperBound > end {
                let newLower = end + 1
                dirtyOutputRange = newLower <= dirtyRange.upperBound ? newLower ... dirtyRange.upperBound : nil
            }
        }

        return rows
    }

    /// Refreshes the cached set of dangerous output rows using the current viewport.
    private func refreshCachedDangerousOutputRows() {
        guard let rustView = activeTerminalView as? RustTerminalView else {
            cachedDangerousOutputRowSet = []
            return
        }
        let top = rustView.renderTopVisibleRow
        let bottom = top + rustView.renderRows - 1
        cachedDangerousOutputRowSet = Set(dangerousOutputRowsVisible(top: top, bottom: bottom))
    }

    /// Returns cached dangerous output rows within the given viewport range.
    private func cachedDangerousOutputRows(top: Int, bottom: Int) -> [Int] {
        cachedDangerousOutputRowSet.filter { $0 >= top && $0 <= bottom }
    }

    /// Combines input command rows and cached output rows into a viewport tint map.
    /// Called at 60fps from `syncGridToRenderer()` — uses only cheap lookups and cached data.
    func dangerousRowTints(top: Int, bottom: Int) -> [Int: NSColor] {
        let scope = FeatureSettings.shared.dangerousCommandHighlightScope
        guard scope != .none else { return [:] }
        let dangerColor = NSColor.systemRed.withAlphaComponent(0.50)
        var tints: [Int: NSColor] = [:]
        // Input rows: always included (cheap set lookup)
        for row in dangerousCommandTracker.visibleRows(top: top, bottom: bottom) {
            tints[row] = dangerColor
        }
        // Output rows: use cached results only (no expensive scanning here)
        if scope == .allOutputs || (scope == .aiOutputs && activeAppName != nil) {
            for row in cachedDangerousOutputRows(top: top, bottom: bottom) {
                tints[row] = dangerColor
            }
        }
        return tints
    }

    // MARK: - Idle Timer (Issue #5 fix)

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
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Create .zshrc for zsh
        let zshrc = """
        # Chau7 wrapper - source user's shell config first
        export ZDOTDIR="\(home)"
        [ -f "\(home)/.zshenv" ] && source "\(home)/.zshenv"
        [ -f "\(home)/.zshrc" ] && source "\(home)/.zshrc"
        if [[ -o login ]]; then
          [ -f "\(home)/.zprofile" ] && source "\(home)/.zprofile"
          [ -f "\(home)/.zlogin" ] && source "\(home)/.zlogin"
        fi

        # Ensure Volta image node toolchains stay ahead of the legacy ~/.volta/bin shim.
        path=("${(s/:/)PATH}")
        for _codex_image_bin in "\(home)/.volta/tools/image/node/"*"/bin"(N); do
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
        [ -f "\(home)/.bashrc" ] && source "\(home)/.bashrc"
        [ -f "\(home)/.bash_profile" ] && source "\(home)/.bash_profile"

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
        if test -f "\(home)/.config/fish/config.fish"
          source "\(home)/.config/fish/config.fish"
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

    // MARK: - Session Control (Issue #5, #15 fixes)

    /// Closes the session by sending exit command and cleaning up resources.
    func closeSession() {
        terminationStateQueue.sync {
            closeSessionRequested = true
        }

        // Stop all background work
        stopIdleTimer()
        gitCheckWorkItem?.cancel()
        searchUpdateWorkItem?.cancel()

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

        forcedTerminationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.forceTerminateShellProcessGroupIfNeeded(expectedPID: shellPID)
        }
        forcedTerminationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func forceTerminateShellProcessGroupIfNeeded(expectedPID: pid_t) {
        var shouldForce = false
        terminationStateQueue.sync {
            shouldForce = closeSessionRequested && !didHandleProcessTermination
        }
        guard shouldForce else { return }

        let currentPID = existingRustTerminalView?.shellPid ?? 0
        guard currentPID == expectedPID, currentPID > 0 else { return }

        Log.warn("Force-terminating shell process group for session '\(title)' (pid=\(currentPID))")
        sendTerminationSignal(SIGTERM, toShellPID: currentPID)

        let hardKill = DispatchWorkItem { [weak self] in
            self?.forceKillShellProcessGroupIfNeeded(expectedPID: expectedPID)
        }
        forcedTerminationWorkItem = hardKill
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: hardKill)
    }

    private func forceKillShellProcessGroupIfNeeded(expectedPID: pid_t) {
        var shouldForce = false
        terminationStateQueue.sync {
            shouldForce = closeSessionRequested && !didHandleProcessTermination
        }
        guard shouldForce else { return }

        let currentPID = existingRustTerminalView?.shellPid ?? 0
        guard currentPID == expectedPID, currentPID > 0 else { return }

        Log.error("Shell process group still alive after SIGTERM; sending SIGKILL (pid=\(currentPID))")
        sendTerminationSignal(SIGKILL, toShellPID: currentPID)
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

    // MARK: - Paste (Issue #10 fix - delegate to terminal view)

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
        activeTerminalView?.send(txt: text)
    }

    /// Queues executable input (e.g. `cd /path\n`) for when the terminal view
    /// becomes available. Used during tab restore when the view hasn't been
    /// created yet. If the view already exists, sends immediately.
    func sendOrQueueInput(_ text: String) {
        guard !text.isEmpty else { return }
        if existingRustTerminalView != nil {
            sendInput(text)
        } else {
            if let existing = pendingRestoreInput {
                pendingRestoreInput = existing + text
            } else {
                pendingRestoreInput = text
            }
        }
    }

    private func flushPendingRestoreInput() {
        guard let text = pendingRestoreInput else { return }
        guard existingRustTerminalView != nil else { return }
        pendingRestoreInput = nil
        sendInput(text)
    }

    /// Prefills the terminal input line without executing it.
    /// This is used for restore-time resume workflows where the user should
    /// explicitly confirm execution.
    func prefillInput(_ text: String) {
        guard !text.isEmpty else { return }
        pendingPrefillInput = text
        flushPendingPrefillInputIfReady()
    }

    private func flushPendingPrefillInputIfReady() {
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

    // MARK: - Zoom (Issue #11 fix - only update @Published, let SwiftUI sync)

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
        highlightView?.scheduleDisplay() // Use batched display for better latency
    }

    // MARK: - Shell helpers

    static func resolveStartDirectory(_ rawValue: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return home }

        let expanded = (trimmed as NSString).expandingTildeInPath
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

    func buildEnvironment() -> [String] {
        var dict: [String: String] = [:]
        dict["TERM"] = "xterm-256color"
        dict["COLORTERM"] = "truecolor"

        let current = ProcessInfo.processInfo.environment
        let ctoEnabled = FeatureSettings.shared.tokenOptimizationMode != .off

        // Guarantee a usable PATH even if the parent process env is corrupt.
        let macOSDefault = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let inherited = current["PATH"] ?? ""
        let basePath = inherited.contains("/usr/bin") ? inherited : macOSDefault

        if ctoEnabled {
            dict["PATH"] = CTOManager.shared.prependedPATH(original: basePath)
        } else {
            dict["PATH"] = basePath
        }
        if let home = current["HOME"] {
            dict["HOME"] = home
        }
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

            // Codex CLI / OpenAI SDK — routed through the TLS port so that
            // subscription-based Codex can do its native WSS upgrade through
            // the proxy. The self-signed cert is trusted via the login keychain.
            dict["OPENAI_BASE_URL"] = "\(tlsBase)/v1"

            // Gemini CLI / Google GenAI SDK (HTTP — no WebSocket needed)
            dict["GOOGLE_GEMINI_BASE_URL"] = proxyBase

            // Session ID for correlation with terminal session
            dict["CHAU7_SESSION_ID"] = dict["TERM_SESSION_ID"] ?? UUID().uuidString

            // Tab ID for task lifecycle tracking (unique per terminal tab)
            dict["CHAU7_TAB_ID"] = tabIdentifier

            // Project path for repo switch detection
            // Note: Use cwd directly to avoid blocking main thread during shell startup.
            // Git root detection happens asynchronously via checkGitStatus().
            dict["CHAU7_PROJECT"] = currentDirectory
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

    // MARK: - Search (Issue #6, #13, #23 fixes - thread-safe buffer access, case sensitivity)

    private var searchCaseSensitive = false
    private var searchRegexEnabled = false

    /// Returns cached buffer data or fetches fresh data if needed (memory optimization).
    private func getBufferData() -> Data? {
        guard let view = activeTerminalView else { return nil }

        if bufferNeedsRefresh || cachedBufferData == nil {
            cachedBufferData = view.getBufferAsData()
            bufferNeedsRefresh = false
            if let data = cachedBufferData {
                updateBufferLineCount(from: data)
            }
        }
        return cachedBufferData
    }

    func captureRemoteSnapshot() -> Data? {
        guard let view = activeTerminalView else { return nil }
        let data = view.getBufferAsData()
        cachedBufferData = data
        bufferNeedsRefresh = false
        if let data { updateBufferLineCount(from: data) }
        return data
    }

    private func updateBufferLineCount(from bufferData: Data) {
        let newlineCount = bufferData.reduce(0) { count, byte in
            count + (byte == 0x0A ? 1 : 0)
        }
        bufferLineCount = max(1, newlineCount + 1)
    }

    func updateSearch(query: String, maxMatches: Int, maxPreviewLines: Int, caseSensitive: Bool = false, regexEnabled: Bool = false) -> SearchSummary {
        let previousQuery = searchQuery
        let previousCaseSensitive = searchCaseSensitive
        let previousRegex = searchRegexEnabled
        searchQuery = query
        searchCaseSensitive = caseSensitive
        searchRegexEnabled = regexEnabled

        guard let bufferData = getBufferData() else {
            searchMatches = []
            activeSearchIndex = 0
            return SearchSummary(count: 0, previewLines: [], error: nil)
        }

        // Use cached buffer data (refreshed only when new output arrives)
        let computed: (matches: [SearchMatch], previewLines: [String], error: String?)
        if regexEnabled {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: query, options: options) else {
                searchMatches = []
                activeSearchIndex = 0
                return SearchSummary(count: 0, previewLines: [], error: "Invalid regex")
            }
            let result = computeRegexMatches(
                regex: regex,
                maxMatches: maxMatches,
                maxPreviewLines: maxPreviewLines,
                bufferData: bufferData
            )
            computed = (result.matches, result.previewLines, nil)
        } else {
            let result = computeSearchMatches(
                query: query,
                maxMatches: maxMatches,
                maxPreviewLines: maxPreviewLines,
                bufferData: bufferData,
                caseSensitive: caseSensitive
            )
            computed = (result.matches, result.previewLines, nil)
        }

        searchMatches = computed.matches
        if previousQuery != query || previousCaseSensitive != caseSensitive || previousRegex != regexEnabled {
            activeSearchIndex = 0
        } else if activeSearchIndex >= computed.matches.count {
            activeSearchIndex = max(0, computed.matches.count - 1)
        }
        highlightView?.scheduleDisplay() // Use batched display for better latency
        return SearchSummary(count: computed.matches.count, previewLines: computed.previewLines, error: computed.error)
    }

    func updateSemanticSearch(query: String, maxMatches: Int, maxPreviewLines: Int) -> SearchSummary {
        searchQuery = query
        searchCaseSensitive = false
        searchRegexEnabled = false

        _ = getBufferData()
        let blocks = semanticDetector.search(query: query)
        let limited = Array(blocks.prefix(maxMatches))

        searchMatches = limited.map { block in
            SearchMatch(row: block.startRow, col: 0, length: max(1, block.command.count))
        }
        activeSearchIndex = 0
        highlightView?.scheduleDisplay() // Use batched display for better latency

        let previews = limited.prefix(maxPreviewLines).map { block -> String in
            if let exitCode = block.exitCode {
                return "\(block.command) (exit \(exitCode))"
            }
            return block.command
        }
        return SearchSummary(count: searchMatches.count, previewLines: previews, error: nil)
    }

    func scheduleSearchRefresh() {
        guard !searchQuery.isEmpty else { return }

        // Use cached buffer data (refreshed only when new output arrives)
        guard let bufferData = getBufferData() else { return }
        let query = searchQuery
        let caseSensitive = searchCaseSensitive
        let regexEnabled = searchRegexEnabled

        searchUpdateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let computed: (matches: [SearchMatch], previewLines: [String])
            if regexEnabled {
                let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
                guard let regex = try? NSRegularExpression(pattern: query, options: options) else {
                    return
                }
                computed = computeRegexMatches(
                    regex: regex,
                    maxMatches: 400,
                    maxPreviewLines: 12,
                    bufferData: bufferData
                )
            } else {
                computed = computeSearchMatches(
                    query: query,
                    maxMatches: 400,
                    maxPreviewLines: 12,
                    bufferData: bufferData,
                    caseSensitive: caseSensitive
                )
            }

            DispatchQueue.main.async {
                guard self.searchQuery == query else { return }
                self.searchMatches = computed.matches
                if self.activeSearchIndex >= computed.matches.count {
                    self.activeSearchIndex = max(0, computed.matches.count - 1)
                }
                self.highlightView?.scheduleDisplay() // Use batched display for better latency
            }
        }
        searchUpdateWorkItem = work
        // Adaptive debounce based on buffer size (latency optimization)
        // Smaller buffers get faster updates, larger buffers need more debounce
        let debounceInterval: TimeInterval
        if bufferLineCount < 1000 {
            debounceInterval = 0.05 // 50ms for small buffers
        } else if bufferLineCount < 5000 {
            debounceInterval = 0.1 // 100ms for medium buffers
        } else {
            debounceInterval = 0.15 // 150ms for large buffers (was 200ms)
        }
        searchQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        activeSearchIndex = (activeSearchIndex + 1) % searchMatches.count
        highlightView?.scheduleDisplay() // Use batched display for better latency
        scrollToActiveMatch()
    }

    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        activeSearchIndex = (activeSearchIndex - 1 + searchMatches.count) % searchMatches.count
        highlightView?.scheduleDisplay() // Use batched display for better latency
        scrollToActiveMatch()
    }

    func currentMatch() -> SearchMatch? {
        guard !searchMatches.isEmpty else { return nil }
        let index = max(0, min(activeSearchIndex, searchMatches.count - 1))
        return searchMatches[index]
    }

    private func scrollToActiveMatch() {
        guard let view = activeTerminalView, let match = currentMatch() else { return }
        let visibleRows = max(1, view.terminalRows)
        let maxScrollback = max(1, bufferLineCount - visibleRows)
        let clampedRow = max(0, min(match.row, maxScrollback))
        let position = Double(clampedRow) / Double(maxScrollback)
        view.scroll(toPosition: position)
    }

    /// Computes search matches from pre-captured buffer data (thread-safe).
    /// Supports case-sensitive and case-insensitive search (Issue #23).
    /// Memory-optimized: uses Substring to avoid copies, case-insensitive option instead of lowercased()
    private func computeSearchMatches(
        query: String,
        maxMatches: Int,
        maxPreviewLines: Int,
        bufferData: Data,
        caseSensitive: Bool = false
    ) -> (matches: [SearchMatch], previewLines: [String]) {
        guard !query.isEmpty else {
            return ([], [])
        }

        // Decode buffer data to string
        let text = String(decoding: bufferData, as: UTF8.self)

        // Pre-allocate with reasonable capacity
        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(maxMatches, 100))
        var previews: [String] = []
        previews.reserveCapacity(maxPreviewLines)

        // Search options - use case insensitive option instead of creating lowercased copies
        let searchOptions: String.CompareOptions = caseSensitive ? [] : .caseInsensitive

        // Process line by line using Substring (no copy) instead of String
        var lineStart = text.startIndex
        var row = 0

        while lineStart < text.endIndex, matches.count < maxMatches {
            // Find end of current line
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex

            // Use Substring directly - no memory copy
            let lineSlice = text[lineStart ..< lineEnd]

            if !lineSlice.isEmpty {
                var searchStart = lineSlice.startIndex

                // Search within the slice without creating copies
                while searchStart < lineSlice.endIndex {
                    guard let range = lineSlice.range(
                        of: query,
                        options: searchOptions,
                        range: searchStart ..< lineSlice.endIndex
                    ) else { break }

                    let col = lineSlice.distance(from: lineSlice.startIndex, to: range.lowerBound)
                    matches.append(SearchMatch(row: row, col: col, length: query.count))

                    if matches.count >= maxMatches { break }
                    searchStart = range.upperBound
                }

                // Only create String copy for preview lines
                if !matches.isEmpty, matches.last?.row == row, previews.count < maxPreviewLines {
                    previews.append(String(lineSlice))
                }
            }

            // Move to next line
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            row += 1
        }

        return (matches, previews)
    }

    private func computeRegexMatches(
        regex: NSRegularExpression,
        maxMatches: Int,
        maxPreviewLines: Int,
        bufferData: Data
    ) -> (matches: [SearchMatch], previewLines: [String]) {
        // Decode buffer data to string
        let text = String(decoding: bufferData, as: UTF8.self)

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(maxMatches, 100))
        var previews: [String] = []
        previews.reserveCapacity(maxPreviewLines)

        var lineStart = text.startIndex
        var row = 0

        while lineStart < text.endIndex, matches.count < maxMatches {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let lineSlice = text[lineStart ..< lineEnd]

            if !lineSlice.isEmpty {
                let lineString = String(lineSlice)
                let nsLine = lineString as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                regex.enumerateMatches(in: lineString, options: [], range: range) { match, _, stop in
                    guard let match = match else { return }
                    let col = match.range.location
                    let length = match.range.length
                    matches.append(SearchMatch(row: row, col: col, length: length))
                    if matches.count >= maxMatches {
                        stop.pointee = true
                    }
                }

                if !matches.isEmpty, matches.last?.row == row, previews.count < maxPreviewLines {
                    previews.append(lineString)
                }
            }

            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            row += 1
        }

        return (matches, previews)
    }

    func displayPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
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

    var inputLatencySummary: String {
        guard let last = inputLatencyMs else { return "n/a" }
        if let avg = inputLatencyAverageMs {
            return "\(last)ms (avg \(avg)ms)"
        }
        return "\(last)ms"
    }

    var outputLatencySummary: String {
        guard let last = outputLatencyMs else { return "n/a" }
        if let avg = outputLatencyAverageMs {
            return "\(last)ms (avg \(avg)ms)"
        }
        return "\(last)ms"
    }

    var dangerousHighlightLatencySummary: String {
        guard let last = dangerousHighlightDelayMs else { return "n/a" }
        if let avg = dangerousHighlightAverageMs {
            return "\(last)ms (avg \(avg)ms)"
        }
        return "\(last)ms"
    }

    var inputLatencyPercentilesSummary: String {
        latencyPercentilesSummary(for: inputLatencySamples)
    }

    var outputLatencyPercentilesSummary: String {
        latencyPercentilesSummary(for: outputLatencySamples)
    }

    var dangerousHighlightPercentilesSummary: String {
        latencyPercentilesSummary(for: dangerousHighlightSamples)
    }

    private func latencyPercentilesSummary(for buffer: LatencySampleBuffer) -> String {
        let samples = buffer.values()
        guard !samples.isEmpty else { return "n/a" }
        guard let p50 = percentileValue(from: samples, percentile: 0.50),
              let p95 = percentileValue(from: samples, percentile: 0.95) else {
            return "n/a"
        }
        return "\(p50)ms / \(p95)ms (n=\(samples.count))"
    }

    private func latencyPercentiles(for buffer: LatencySampleBuffer) -> (p50: Int?, p95: Int?, count: Int) {
        let samples = buffer.values()
        guard !samples.isEmpty else { return (nil, nil, 0) }
        let p50 = percentileValue(from: samples, percentile: 0.50)
        let p95 = percentileValue(from: samples, percentile: 0.95)
        return (p50, p95, samples.count)
    }

    private func maybeLogLatencySpike(
        kind: String,
        elapsedMs: Double,
        averageMs: Int?,
        samples: LatencySampleBuffer,
        thresholdMs: Double,
        lastLoggedAt: inout Date?
    ) {
        guard elapsedMs >= thresholdMs else { return }
        let now = Date()
        if let last = lastLoggedAt, now.timeIntervalSince(last) < latencyLogCooldownSeconds {
            return
        }
        lastLoggedAt = now
        let percentiles = latencyPercentilesSummary(for: samples)
        let tabName = (tabTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? tabTitleOverride!
            : title
        let appName = activeAppName ?? "shell"
        let avg = averageMs ?? -1
        Log.warn("Latency spike: \(kind)=\(Int(elapsedMs.rounded()))ms avg=\(avg)ms p50/p95=\(percentiles) tab=\(tabName) app=\(appName) cwd=\(tabPathDisplayName())")

        let percentileValues = latencyPercentiles(for: samples)
        recordLagEvent(
            kind: LagKind(rawValue: kind) ?? .input,
            elapsedMs: Int(elapsedMs.rounded()),
            averageMs: avg,
            p50: percentileValues.p50,
            p95: percentileValues.p95,
            sampleCount: percentileValues.count,
            tabTitle: tabName,
            appName: appName,
            cwd: tabPathDisplayName()
        )
    }

    private func recordLagEvent(
        kind: LagKind,
        elapsedMs: Int,
        averageMs: Int,
        p50: Int?,
        p95: Int?,
        sampleCount: Int,
        tabTitle: String,
        appName: String,
        cwd: String
    ) {
        let event = LagEvent(
            kind: kind,
            elapsedMs: elapsedMs,
            averageMs: averageMs,
            p50: p50,
            p95: p95,
            sampleCount: sampleCount,
            timestamp: Date(),
            tabTitle: tabTitle,
            appName: appName,
            cwd: cwd
        )
        let append = {
            self.lagTimeline.append(event)
            if self.lagTimeline.count > self.lagTimelineCapacity {
                self.lagTimeline.removeFirst(self.lagTimeline.count - self.lagTimelineCapacity)
            }
        }
        if Thread.isMainThread {
            append()
        } else {
            DispatchQueue.main.async(execute: append)
        }
    }

    func clearLagTimeline() {
        if Thread.isMainThread {
            lagTimeline.removeAll()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.lagTimeline.removeAll()
            }
        }
    }

    private func percentileValue(from samples: [Int], percentile: Double) -> Int? {
        guard !samples.isEmpty else { return nil }
        let clamped = max(0.0, min(1.0, percentile))
        let sorted = samples.sorted()
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.toNearestOrEven))
        return sorted[index]
    }

    /// Updates the current directory and refreshes git status.
    /// Call this instead of setting currentDirectory directly to ensure git badge updates.
    func updateCurrentDirectory(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardized.path
        guard currentDirectory != normalized else { return }
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
    }

    private func refreshGitStatus(path: String) {
        gitCheckWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if ProtectedPathPolicy.shouldSkipAutoAccess(path: path) {
                DispatchQueue.main.async {
                    self.isGitRepo = false
                    self.gitBranch = nil
                    self.gitRootPath = nil
                }
                return
            }
            let result = queryGitStatus(path: path)
            DispatchQueue.main.async {
                self.isGitRepo = result.isRepo
                let oldBranch = self.gitBranch
                self.gitBranch = result.branch
                self.gitRootPath = result.root
                // Notify shell event detector of branch change
                if oldBranch != result.branch {
                    self.shellEventDetector.gitBranchChanged(to: result.branch)
                }
            }
        }
        gitCheckWorkItem = work
        gitQueue.async(execute: work)
    }

    private func queryGitStatus(path: String) -> (isRepo: Bool, branch: String?, root: String?) {
        if ProtectedPathPolicy.shouldSkipAutoAccess(path: path) {
            return (false, nil, nil)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return (false, nil, nil)
        }

        let process = Process()
        process.executableURL = GitBinary.path
        process.arguments = ["-C", path, "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, nil, nil)
        }

        guard process.terminationStatus == 0 else {
            return (false, nil, nil)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return (false, nil, nil)
        }
        let root = lines.first
        let branch = lines.count > 1 ? lines.last : nil
        return (true, branch, root)
    }
}
