import Foundation
import AppKit
import SwiftTerm
import Darwin
import Chau7Core

enum CommandStatus: String {
    case idle
    case running
    case waitingForInput  // AI agent waiting for user input/permission
    case stuck            // Running for too long without output
    case exited
}

/// Model for a terminal session, managing shell state, search, and output capture.
/// - Note: Thread Safety - @Published properties must be modified on main thread.
///   Delegate callbacks from SwiftTerm may arrive on background threads and
///   dispatch to main via DispatchQueue.main.async.
final class TerminalSessionModel: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var title: String = "Shell"
    @Published var currentDirectory: String = TerminalSessionModel.defaultStartDirectory()

    /// Unique identifier for this terminal tab, used for task lifecycle tracking
    let tabIdentifier: String = UUID().uuidString
    @Published var status: CommandStatus = .idle
    @Published var isGitRepo: Bool = false
    @Published var gitBranch: String? = nil
    @Published var activeAppName: String? = nil
    @Published var devServer: DevServerMonitor.DevServerInfo? = nil
    @Published var tabTitleOverride: String? = nil
    @Published var fontSize: CGFloat = 13
    @Published var searchMatches: [SearchMatch] = []
    @Published var activeSearchIndex: Int = 0

    // MARK: - Latency Telemetry (non-Published for performance)
    // These change on every keystroke. Keeping them as @Published would cause
    // SwiftUI to trigger updateNSView on every keystroke, adding unnecessary overhead.
    // The debug console has its own 1-second refresh timer to read these values.
    var inputLatencyMs: Int? = nil
    var inputLatencyAverageMs: Int? = nil

    private weak var appModel: AppModel?
    private weak var terminalView: Chau7TerminalView?
    /// Strong reference to keep the terminal view alive across SwiftUI view recreations (e.g., when splitting)
    private var retainedTerminalView: Chau7TerminalView?
    private var settingsObservers: [NSObjectProtocol] = []
    private var idleTimer: DispatchSourceTimer?
    private var lastInputAt = Date.distantPast
    private var lastOutputAt = Date.distantPast
    private var commandStartedAt = Date.distantPast  // Track when command started for "stuck" detection
    private var hasPendingCommand = false
    private var inputBuffer = ""
    private var gitCheckWorkItem: DispatchWorkItem?
    private let gitQueue = DispatchQueue(label: "com.chau7.git", qos: .utility)
    private var searchUpdateWorkItem: DispatchWorkItem?
    private let searchQueue = DispatchQueue(label: "com.chau7.search", qos: .utility)
    private var searchQuery: String = ""
    private var cachedBufferData: Data?  // Cached buffer data for search
    private var bufferNeedsRefresh: Bool = true  // Flag to invalidate cache on output
    private var bufferLineCount: Int = 0
    private var pendingInputLatencyAt: CFAbsoluteTime?
    private var inputLatencySampleCount = 0
    private var inputLatencyTotalMs: Double = 0
    private var didClearOnLaunch = false
    private var didApplyShellIntegration = false
    private var shellIntegrationOutputCount = 0
    private var shouldAutoFocusOnAttach = true  // Auto-focus when terminal view is attached
    private var didStartDevServerMonitor = false  // Track if dev server monitor has started

    private let semanticDetector = SemanticOutputDetector()
    private let devServerMonitor = DevServerMonitor()
    private static let osc7Prefix = Data([0x1b, 0x5d, 0x37, 0x3b])
    private static let aiExitMarkerPrefix = Data("\u{001b}]9;chau7;exit=".utf8)
    private static let aiExitMarkerSuffix = Data([0x07])
    private static let aiExitMarkerKeepBytes = max(0, aiExitMarkerPrefix.count - 1)

    private struct AILogContext {
        let toolName: String
        let commandLine: String?
        let logPath: String
    }

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

    init(appModel: AppModel) {
        self.appModel = appModel
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
    }

    /// Returns the existing terminal view if one exists (to reuse across SwiftUI view recreations)
    var existingTerminalView: Chau7TerminalView? {
        retainedTerminalView
    }

    func attachTerminal(_ view: Chau7TerminalView) {
        terminalView = view
        retainedTerminalView = view  // Keep strong reference to survive view recreation
        view.currentDirectory = currentDirectory

        // Configure scrollback buffer size from settings
        let scrollbackLines = FeatureSettings.shared.scrollbackLines
        view.getTerminal().changeHistorySize(scrollbackLines)
        Log.info("Configured terminal scrollback: \(scrollbackLines) lines")

        // Auto-focus on attach for newly created tabs
        if shouldAutoFocusOnAttach {
            shouldAutoFocusOnAttach = false
            // Brief delay to ensure view is fully integrated into window hierarchy
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                guard let view = view, let window = view.window else { return }
                window.makeFirstResponder(view)
                Log.trace("Auto-focused terminal view on attach")
            }
        }
    }

    func focusTerminal(in window: NSWindow?) {
        guard let view = terminalView, let window else { return }
        window.makeFirstResponder(view)
    }

    // MARK: - Shell Integration (Issue #8 fix)

    /// Schedules shell integration script to run after shell is ready.
    /// Instead of an arbitrary delay, we wait for initial output (prompt).
    func scheduleShellIntegration(for view: TerminalView) {
        // The shell integration will be applied when we detect the first few outputs,
        // indicating the shell has started and is ready for input.
        didApplyShellIntegration = false
        shellIntegrationOutputCount = 0
    }

    private func maybeApplyShellIntegration() {
        guard !didApplyShellIntegration else { return }
        guard let terminalView else { return }

        // Wait for a few output events to ensure shell is ready
        shellIntegrationOutputCount += 1
        if shellIntegrationOutputCount >= 2 {
            didApplyShellIntegration = true
            applyShellIntegration(to: terminalView)
        }
    }

    func handleInput(_ text: String) {
        lastInputAt = Date()
        if !text.isEmpty {
            markInputLatencyStart()
        }
        inputBuffer.append(text)
        if let aiLogSession {
            aiLogSession.recordInput(text)
        }
        if text.contains("\n") || text.contains("\r") {
            processInputBuffer()
        }
        if text.contains("\n") || text.contains("\r") {
            markRunning()
        }
    }

    func handleOutput(_ data: Data) {
        lastOutputAt = Date()
        bufferNeedsRefresh = true  // Invalidate buffer cache on new output
        recordInputLatencyIfNeeded()
        TerminalOutputCapture.shared.record(data: data, source: activeAppName ?? title)
        if FeatureSettings.shared.isSemanticSearchEnabled,
           data.contains(where: { $0 == 0x0A || $0 == 0x0D }),
           let row = currentBufferRow() {
            semanticDetector.updateCurrentRow(row)
        }
        let aiLogResult = processAILogOutput(data)
        if let logData = aiLogResult.loggable, !logData.isEmpty {
            aiLogSession?.recordOutput(logData)
        }
        if let exitCode = aiLogResult.exitCode {
            finishAILogging(exitCode: exitCode)
        }
        // Check if we should apply shell integration
        maybeApplyShellIntegration()
        let sawPromptUpdate = maybeHandlePromptUpdate(data)
        // Try to detect AI app from output if not already detected
        if !sawPromptUpdate {
            maybeDetectAppFromOutput(data)
        }
        // Check if AI agent is waiting for user input
        maybeDetectAIWaitingForInput(data)
        // Check for dev server output patterns
        maybeDetectDevServer(data)
    }

    private func maybeDetectDevServer(_ data: Data) {
        // Start the dev server monitor if not already started
        if !didStartDevServerMonitor, let view = terminalView {
            let pid = view.process.shellPid
            if pid > 0 {
                didStartDevServerMonitor = true
                devServerMonitor.start(shellPID: pid)
            }
        }

        // Check output for dev server patterns
        guard devServer == nil else { return }  // Already detected
        guard let output = String(data: data, encoding: .utf8) else { return }
        devServerMonitor.checkOutput(output)
    }

    /// Detects when an AI agent is waiting for user input (prompts, permission requests, etc.)
    private func maybeDetectAIWaitingForInput(_ data: Data) {
        guard activeAppName != nil else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

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
            "> ",  // Common prompt indicator
            "? ",  // Question prompt
            "Enter your",
            "Type your",
            "waiting for",
        ]

        let lowercased = text.lowercased()
        let isWaiting = waitingPatterns.contains { pattern in
            lowercased.contains(pattern.lowercased())
        }

        if isWaiting {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.status == .running else { return }
                self.status = .waitingForInput
                Log.info("AI agent waiting for input detected")
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
            if let suffixRange = combined.range(of: Self.aiExitMarkerSuffix, in: afterPrefix..<combined.endIndex) {
                let payload = combined[afterPrefix..<suffixRange.lowerBound]
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

    private func finishAILogging(exitCode: Int?) {
        guard let context = aiLogContext else {
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
        if let appModel, trimmed.caseInsensitiveCompare("Codex") == .orderedSame {
            let path = appModel.codexTerminalPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return path
            }
        }
        if let appModel, trimmed.caseInsensitiveCompare("Claude") == .orderedSame {
            let path = appModel.claudeTerminalPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return path
            }
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
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.clearActiveAppAfterPrompt()
            }
        }
        return true
    }

    private func clearActiveAppAfterPrompt() {
        if activeAppName != nil {
            Log.info("Clearing active app after OSC 7 prompt update.")
            activeAppName = nil
        }
        if aiLogSession != nil {
            finishAILogging(exitCode: nil)
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
        inputLatencySampleCount += 1
        inputLatencyTotalMs += elapsedMs
        let avg = inputLatencyTotalMs / Double(inputLatencySampleCount)
        inputLatencyMs = Int(elapsedMs.rounded())
        inputLatencyAverageMs = Int(avg.rounded())
    }

    /// Attempts to detect AI CLI from output patterns when command detection missed it
    private func maybeDetectAppFromOutput(_ data: Data) {
        // Skip if we already detected an app
        guard activeAppName == nil else { return }

        // Convert to string for pattern matching (limit to first 500 bytes for performance)
        let checkData = data.prefix(500)
        guard let outputString = String(data: checkData, encoding: .utf8) else { return }

        for (pattern, appName) in outputDetectionPatterns() {
            if outputString.contains(pattern) {
                DispatchQueue.main.async { [weak self] in
                    self?.activeAppName = appName
                    self?.startAILoggingIfNeeded(toolName: appName, commandLine: nil)
                    Log.info("Detected \(appName) from output pattern: \(pattern)")
                }
                return
            }
        }
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
        if status != .running && status != .stuck {
            status = .running
            commandStartedAt = Date()
        }
        hasPendingCommand = true
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

    private func handleInputLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateActiveAppName(from: trimmed)
        recordInputLineIfNeeded()
        trackSemanticCommand(trimmed)
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
            guard self.status == .running || self.status == .stuck else { return }
            guard self.hasPendingCommand else { return }

            let latestActivity = max(self.lastInputAt, self.lastOutputAt)
            let latestIdleFor = Date().timeIntervalSince(latestActivity)
            let runningFor = Date().timeIntervalSince(self.commandStartedAt)

            // Check for "stuck" - running for too long without recent output
            // Only applies to .running status, not waitingForInput
            if self.status == .running && runningFor >= self.stuckSeconds {
                let outputIdleFor = Date().timeIntervalSince(self.lastOutputAt)
                if outputIdleFor >= self.stuckSeconds {
                    self.status = .stuck
                    Log.info("Command marked as stuck after \(Int(runningFor))s")
                    return
                }
            }

            // Check for idle - no activity for idleSeconds
            guard latestIdleFor >= self.idleSeconds else { return }

            self.status = .idle
            self.hasPendingCommand = false

            let message = "Command idle for \(Int(latestIdleFor))s"
            self.appModel?.recordEvent(
                source: .terminalSession,
                type: "finished",
                tool: self.notificationTabName,
                message: message,
                notify: true
            )
        }
    }

    private func updateActiveAppName(from commandLine: String) {
        if let match = CommandDetection.detectApp(from: commandLine) {
            activeAppName = match
            Log.info("AI detected: \(match) from command '\(commandLine.prefix(50))'")
            startAILoggingIfNeeded(toolName: match, commandLine: commandLine)
            return
        }

        // Check for dev server command
        if let devServerName = CommandDetection.detectDevServer(from: commandLine) {
            Log.info("Dev server command detected: \(devServerName) from '\(commandLine.prefix(50))'")
            devServerMonitor.setCommandHint(devServerName)
            // Don't set activeAppName for dev servers - they're different from AI tools
        }

        // Custom detection rules (substring match on command line)
        let lowercasedLine = commandLine.lowercased()
        for rule in FeatureSettings.shared.customAIDetectionRules {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern.isEmpty { continue }
            if lowercasedLine.contains(pattern) {
                let name = rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                activeAppName = name.isEmpty ? "Custom AI" : name
                if let activeAppName {
                    startAILoggingIfNeeded(toolName: activeAppName, commandLine: commandLine)
                }
                return
            }
        }

        if activeAppName != nil, isExitCommand(commandLine) {
            Log.info("Clearing active app due to exit command input.")
            activeAppName = nil
        }
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
        guard let terminalView else { return }
        if FeatureSettings.shared.isSemanticSearchEnabled || activeAppName == "Codex" {
            terminalView.recordInputLine()
        }
    }

    private func trackSemanticCommand(_ command: String) {
        guard FeatureSettings.shared.isSemanticSearchEnabled else { return }
        guard let row = currentBufferRow() else { return }
        semanticDetector.commandStarted(command, atRow: row)
    }

    private func currentBufferRow() -> Int? {
        guard let terminalView else { return nil }
        let terminal = terminalView.getTerminal()
        let cursor = terminal.getCursorLocation()
        return terminal.getTopVisibleRow() + cursor.y
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
        # Chau7 wrapper - source user's real .zshrc first
        export ZDOTDIR="\(home)"
        [ -f "\(home)/.zshrc" ] && source "\(home)/.zshrc"

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

    func applyShellIntegration(to view: TerminalView) {
        // No-op: integration now happens via shell rc files at startup
        Log.info("Shell integration applied via shell config files.")
    }

    func maybeClearOnLaunch() {
        guard !didClearOnLaunch else { return }
        didClearOnLaunch = true
        let raw = EnvVars.get(EnvVars.clearOnLaunch, legacy: EnvVars.legacyClearOnLaunch)?.lowercased()
        if let raw, ["0", "false", "no"].contains(raw) {
            Log.info("Clear-on-launch disabled via CHAU7_CLEAR_ON_LAUNCH.")
            return
        }
        guard let terminalView else { return }
        terminalView.send(txt: "\u{0C}")
        Log.info("Cleared terminal on launch.")
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // No-op: window controls layout.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async {
            self.title = title.isEmpty ? "Shell" : title
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        DispatchQueue.main.async {
            if let directory, let url = URL(string: directory) {
                self.updateCurrentDirectory(url.path)
            } else if let directory {
                self.updateCurrentDirectory(directory)
            }
            if self.activeAppName != nil {
                Log.info("Clearing active app after shell prompt update.")
                self.activeAppName = nil
            }
            if self.aiLogSession != nil {
                self.finishAILogging(exitCode: nil)
            }
            // Note: Don't clear devServer here - it persists until the server actually stops
            // The DevServerMonitor will detect when the server is no longer listening
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.status = .exited
            self.devServer = nil
        }
        devServerMonitor.stop()
        if aiLogSession != nil {
            finishAILogging(exitCode: nil)
        }
        let message = exitCode == nil ? "Shell exited." : "Shell exited with code \(exitCode!)."
        appModel?.recordEvent(source: .terminalSession, type: "failed", tool: notificationTabName, message: message, notify: true)
    }

    // MARK: - Session Control (Issue #5, #15 fixes)

    /// Closes the session by sending exit command and cleaning up resources.
    func closeSession() {
        // Stop all background work
        stopIdleTimer()
        gitCheckWorkItem?.cancel()
        searchUpdateWorkItem?.cancel()

        // Send exit to the shell
        terminalView?.send(txt: "exit\n")
        Log.info("Sent exit command to shell session.")
    }

    func copyOrInterrupt() {
        guard let terminalView else { return }
        terminalView.window?.makeFirstResponder(terminalView)
        Log.trace("Copy/interrupt requested from session model.")
        terminalView.copy(terminalView)
    }

    func getSelectedText() -> String? {
        terminalView?.getSelectedText()
    }

    // MARK: - Paste (Issue #10 fix - delegate to terminal view)

    func paste() {
        guard let terminalView else { return }
        terminalView.window?.makeFirstResponder(terminalView)
        terminalView.paste(terminalView)
    }

    // MARK: - F13: Broadcast Input Support

    /// Sends text input to the terminal (used for broadcast mode)
    func sendInput(_ text: String) {
        guard let terminalView else { return }
        terminalView.send(txt: text)
    }

    // MARK: - F21: Snippet Insertion

    func insertSnippet(_ entry: SnippetEntry) {
        guard FeatureSettings.shared.isSnippetsEnabled else { return }
        let insertion = SnippetManager.shared.prepareInsertion(
            snippet: entry.snippet,
            currentDirectory: currentDirectory
        )
        terminalView?.insertSnippet(insertion)
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
    }

    /// Called by TerminalViewRepresentable to apply font when SwiftUI updates.
    func applyFontSize() {
        // This is now handled by TerminalViewRepresentable.updateNSView
        // to avoid double-setting the font.
    }

    func clearSearch() {
        searchQuery = ""
        searchMatches = []
        activeSearchIndex = 0
        highlightView?.scheduleDisplay()  // Use batched display for better latency
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
            if !customPath.isEmpty && FileManager.default.fileExists(atPath: customPath) {
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
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        var dict: [String: String] = [:]
        for entry in env {
            if let idx = entry.firstIndex(of: "=") {
                dict[String(entry[..<idx])] = String(entry[entry.index(after: idx)...])
            }
        }

        let current = ProcessInfo.processInfo.environment
        if let path = current["PATH"] {
            dict["PATH"] = path
        }
        if let home = current["HOME"] {
            dict["HOME"] = home
        }
        dict["CHAU7_START_DIR"] = startDirectoryForLaunch()

        // Set startup command if configured
        let startupCmd = FeatureSettings.shared.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !startupCmd.isEmpty {
            dict["CHAU7_STARTUP_CMD"] = startupCmd
        }

        // Present as Terminal.app for better CLI theming parity.
        dict["TERM_PROGRAM"] = "Apple_Terminal"
        if let version = Self.terminalAppVersion {
            dict["TERM_PROGRAM_VERSION"] = version
        }
        dict["TERM_SESSION_ID"] = UUID().uuidString
        dict["SHELL"] = defaultShell()

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
            let openAIBase = "\(proxyBase)/v1"

            // Claude Code / Anthropic SDK
            dict["ANTHROPIC_BASE_URL"] = proxyBase

            // Codex CLI / OpenAI SDK
            dict["OPENAI_BASE_URL"] = openAIBase

            // Gemini CLI / Google GenAI SDK
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

    weak var highlightView: TerminalHighlightView?

    func attachHighlightView(_ view: TerminalHighlightView) {
        highlightView = view
        highlightView?.scheduleDisplay()  // Use batched display for better latency
    }

    // MARK: - Search (Issue #6, #13, #23 fixes - thread-safe buffer access, case sensitivity)

    private var searchCaseSensitive: Bool = false
    private var searchRegexEnabled: Bool = false

    /// Returns cached buffer data or fetches fresh data if needed (memory optimization)
    private func getBufferData() -> Data? {
        guard let terminalView else { return nil }

        if bufferNeedsRefresh || cachedBufferData == nil {
            cachedBufferData = terminalView.getTerminal().getBufferAsData()
            bufferNeedsRefresh = false
            if let data = cachedBufferData {
                updateBufferLineCount(from: data)
            }
        }
        return cachedBufferData
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
        highlightView?.scheduleDisplay()  // Use batched display for better latency
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
        highlightView?.scheduleDisplay()  // Use batched display for better latency

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
                computed = self.computeRegexMatches(
                    regex: regex,
                    maxMatches: 400,
                    maxPreviewLines: 12,
                    bufferData: bufferData
                )
            } else {
                computed = self.computeSearchMatches(
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
                self.highlightView?.scheduleDisplay()  // Use batched display for better latency
            }
        }
        searchUpdateWorkItem = work
        // Adaptive debounce based on buffer size (latency optimization)
        // Smaller buffers get faster updates, larger buffers need more debounce
        let debounceInterval: TimeInterval
        if bufferLineCount < 1000 {
            debounceInterval = 0.05  // 50ms for small buffers
        } else if bufferLineCount < 5000 {
            debounceInterval = 0.1   // 100ms for medium buffers
        } else {
            debounceInterval = 0.15  // 150ms for large buffers (was 200ms)
        }
        searchQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        activeSearchIndex = (activeSearchIndex + 1) % searchMatches.count
        highlightView?.scheduleDisplay()  // Use batched display for better latency
        scrollToActiveMatch()
    }

    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        activeSearchIndex = (activeSearchIndex - 1 + searchMatches.count) % searchMatches.count
        highlightView?.scheduleDisplay()  // Use batched display for better latency
        scrollToActiveMatch()
    }

    func currentMatch() -> SearchMatch? {
        guard !searchMatches.isEmpty else { return nil }
        let index = max(0, min(activeSearchIndex, searchMatches.count - 1))
        return searchMatches[index]
    }

    private func scrollToActiveMatch() {
        guard let terminalView, let match = currentMatch() else { return }
        let terminal = terminalView.getTerminal()
        let visibleRows = max(1, terminal.rows)
        let maxScrollback = max(1, bufferLineCount - visibleRows)
        let clampedRow = max(0, min(match.row, maxScrollback))
        let position = Double(clampedRow) / Double(maxScrollback)
        terminalView.scroll(toPosition: position)
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

        while lineStart < text.endIndex && matches.count < maxMatches {
            // Find end of current line
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex

            // Use Substring directly - no memory copy
            let lineSlice = text[lineStart..<lineEnd]

            if !lineSlice.isEmpty {
                var searchStart = lineSlice.startIndex

                // Search within the slice without creating copies
                while searchStart < lineSlice.endIndex {
                    guard let range = lineSlice.range(
                        of: query,
                        options: searchOptions,
                        range: searchStart..<lineSlice.endIndex
                    ) else { break }

                    let col = lineSlice.distance(from: lineSlice.startIndex, to: range.lowerBound)
                    matches.append(SearchMatch(row: row, col: col, length: query.count))

                    if matches.count >= maxMatches { break }
                    searchStart = range.upperBound
                }

                // Only create String copy for preview lines
                if !matches.isEmpty && matches.last?.row == row && previews.count < maxPreviewLines {
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

        while lineStart < text.endIndex && matches.count < maxMatches {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let lineSlice = text[lineStart..<lineEnd]

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

                if !matches.isEmpty && matches.last?.row == row && previews.count < maxPreviewLines {
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

    var inputLatencySummary: String {
        guard let last = inputLatencyMs else { return "n/a" }
        if let avg = inputLatencyAverageMs {
            return "\(last)ms (avg \(avg)ms)"
        }
        return "\(last)ms"
    }

    private func updateCurrentDirectory(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardized.path
        guard currentDirectory != normalized else { return }
        currentDirectory = normalized
        terminalView?.currentDirectory = normalized
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
            let result = self.queryGitStatus(path: path)
            DispatchQueue.main.async {
                self.isGitRepo = result.isRepo
                self.gitBranch = result.branch
            }
        }
        gitCheckWorkItem = work
        gitQueue.async(execute: work)
    }

    /// Detects the git root directory for a given path
    /// Returns nil if the path is not within a git repository
    private func detectGitRoot(path: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func queryGitStatus(path: String) -> (isRepo: Bool, branch: String?) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return (false, nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, nil)
        }

        guard process.terminationStatus == 0 else {
            return (false, nil)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = output.isEmpty ? nil : output
        return (true, branch)
    }
}
