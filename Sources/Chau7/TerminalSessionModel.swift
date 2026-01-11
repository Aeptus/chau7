import Foundation
import AppKit
import SwiftTerm
import Darwin

enum CommandStatus: String {
    case idle
    case running
    case exited
}

final class TerminalSessionModel: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var title: String = "Shell"
    @Published var currentDirectory: String = TerminalSessionModel.defaultStartDirectory()
    @Published var status: CommandStatus = .idle
    @Published var isGitRepo: Bool = false
    @Published var gitBranch: String? = nil
    @Published var activeAppName: String? = nil
    @Published var fontSize: CGFloat = 13
    @Published var searchMatches: [SearchMatch] = []
    @Published var activeSearchIndex: Int = 0

    private weak var appModel: AppModel?
    private weak var terminalView: Chau7TerminalView?
    private var settingsObservers: [NSObjectProtocol] = []
    private var idleTimer: DispatchSourceTimer?
    private var lastInputAt = Date.distantPast
    private var lastOutputAt = Date.distantPast
    private var hasPendingCommand = false
    private var inputBuffer = ""
    private var gitCheckWorkItem: DispatchWorkItem?
    private let gitQueue = DispatchQueue(label: "com.chau7.git", qos: .utility)
    private var searchUpdateWorkItem: DispatchWorkItem?
    private let searchQueue = DispatchQueue(label: "com.chau7.search", qos: .utility)
    private var searchQuery: String = ""
    private var cachedBufferData: Data?  // Cached buffer data for search
    private var bufferNeedsRefresh: Bool = true  // Flag to invalidate cache on output
    private var didClearOnLaunch = false
    private var didApplyShellIntegration = false
    private var shellIntegrationOutputCount = 0
    private var shouldAutoFocusOnAttach = true  // Auto-focus when terminal view is attached

    private let appNameMap: [String: String] = [
        // OpenAI Codex
        "codex": "Codex",
        "codex-cli": "Codex",
        "codex-pty": "Codex",
        "codex-wrapper": "Codex",
        // Anthropic Claude
        "claude": "Claude",
        "claude-code": "Claude",
        "claude-cli": "Claude",
        "claude-pty": "Claude",
        "claude-wrapper": "Claude",
        // Google Gemini
        "gemini": "Gemini",
        "gemini-cli": "Gemini",
        "gemini-pty": "Gemini",
        // OpenAI ChatGPT
        "chatgpt": "ChatGPT",
        "chatgpt-cli": "ChatGPT",
        "gpt": "ChatGPT",
        "gpt-cli": "ChatGPT",
        "openai": "ChatGPT",
        // GitHub Copilot
        "copilot": "Copilot",
        "copilot-cli": "Copilot",
        "github-copilot": "Copilot",
        // Aider
        "aider": "Aider",
        "aider-chat": "Aider",
        // Cursor
        "cursor": "Cursor"
    ]

    /// Output patterns that indicate a specific AI CLI is running
    /// These catch cases where command detection fails (e.g., first tab, piped commands)
    private static let defaultOutputDetectionPatterns: [(pattern: String, appName: String)] = [
        // Claude Code banners
        ("╭─ Claude", "Claude"),
        ("claude.ai", "Claude"),
        ("Anthropic", "Claude"),
        // Gemini patterns
        ("Google AI", "Gemini"),
        ("Gemini Pro", "Gemini"),
        ("gemini.google", "Gemini"),
        // ChatGPT patterns
        ("ChatGPT", "ChatGPT"),
        ("openai.com", "ChatGPT"),
        // Copilot patterns
        ("GitHub Copilot", "Copilot"),
        ("Copilot CLI", "Copilot"),
        // Codex patterns
        ("OpenAI Codex", "Codex"),
        ("codex-cli", "Codex"),
        ("Codex CLI", "Codex"),
        ("╭─ Codex", "Codex"),  // Similar banner style to Claude
        ("codex.openai", "Codex"),
        // Aider patterns
        ("Aider", "Aider"),
        ("aider.chat", "Aider"),
        // Cursor patterns
        ("Cursor", "Cursor"),
        ("cursor.sh", "Cursor")
    ]

    private static let wrapperCommands: Set<String> = [
        "command",
        "builtin",
        "exec",
        "noglob",
        "time"
    ]

    private static let sudoOptionsWithValue: Set<String> = [
        "-u",
        "-g",
        "-h",
        "-p",
        "-a",
        "-c",
        "-t",
        "-r"
    ]

    /// Idle timeout in seconds. Configurable via environment variable.
    private var idleSeconds: TimeInterval {
        if let envValue = EnvVars.get(EnvVars.idleSeconds, legacy: EnvVars.legacyIdleSeconds),
           let seconds = Double(envValue), seconds > 0 {
            return seconds
        }
        return 3.0
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
        applyDefaultFontSize()
        installSettingsObservers()
        refreshGitStatus(path: currentDirectory)
        SnippetManager.shared.updateContextPath(currentDirectory)
        startIdleTimer()
    }

    deinit {
        // Clean up resources
        for observer in settingsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        stopIdleTimer()
        gitCheckWorkItem?.cancel()
        searchUpdateWorkItem?.cancel()
    }

    func attachTerminal(_ view: Chau7TerminalView) {
        terminalView = view
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
        inputBuffer.append(text)
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
        TerminalOutputCapture.shared.record(data: data, source: activeAppName ?? title)
        // Check if we should apply shell integration
        maybeApplyShellIntegration()
        // Try to detect AI app from output if not already detected
        maybeDetectAppFromOutput(data)
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
        return Self.defaultOutputDetectionPatterns + custom
    }

    private func markRunning() {
        if status != .running {
            status = .running
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
        guard trimmed.hasPrefix("cd") else { return }

        let remainder = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        var target: String
        if remainder.isEmpty {
            target = FileManager.default.homeDirectoryForCurrentUser.path
        } else if remainder == "-" {
            return
        } else {
            target = remainder
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
        guard status == .running, hasPendingCommand else { return }
        let lastActivity = max(lastInputAt, lastOutputAt)
        let idleFor = Date().timeIntervalSince(lastActivity)
        if idleFor < idleSeconds {
            return
        }

        status = .idle
        hasPendingCommand = false

        let message = "Command idle for \(Int(idleFor))s"
        appModel?.recordEvent(
            type: "finished",
            tool: "Chau7",
            message: message,
            notify: true
        )
    }

    private func updateActiveAppName(from commandLine: String) {
        let tokens = tokenizeCommandLine(commandLine)
        guard let token = extractCommandToken(from: commandLine) else {
            Log.trace("AI detection: no command token in '\(commandLine.prefix(50))'")
            return
        }
        let normalized = normalizeCommandToken(token)
        Log.trace("AI detection: command='\(normalized)' from '\(commandLine.prefix(50))'")

        // Check for direct match
        if let match = appNameMap[normalized] {
            activeAppName = match
            Log.info("AI detected: \(match) from command '\(normalized)'")
            return
        }

        // Special case: gh copilot (GitHub CLI with copilot subcommand)
        if normalized == "gh" {
            if findSubcommand(tokens: tokens, after: "gh", looking: ["copilot"]) != nil {
                activeAppName = "Copilot"
                return
            }
        }

        // Special case: npx/bunx with AI CLI packages
        if normalized == "npx" || normalized == "bunx" || normalized == "pnpm" {
            if let aiApp = findSubcommand(tokens: tokens, after: normalized, looking: Array(appNameMap.keys)) {
                activeAppName = appNameMap[aiApp]
                return
            }
        }

        // Custom detection rules (substring match on command line)
        let lowercasedLine = commandLine.lowercased()
        for rule in FeatureSettings.shared.customAIDetectionRules {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern.isEmpty { continue }
            if lowercasedLine.contains(pattern) {
                let name = rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                activeAppName = name.isEmpty ? "Custom AI" : name
                return
            }
        }

        activeAppName = nil
    }

    /// Finds a subcommand after a given command, skipping options
    private func findSubcommand(tokens: [String], after command: String, looking targets: [String]) -> String? {
        guard let cmdIndex = tokens.firstIndex(where: { normalizeCommandToken($0) == command }) else { return nil }
        for i in (cmdIndex + 1)..<tokens.count {
            let token = tokens[i]
            if token.hasPrefix("-") { continue }  // Skip options
            let normalized = normalizeCommandToken(token)
            if targets.contains(normalized) {
                return normalized
            }
            // First non-option argument after command
            break
        }
        return nil
    }

    private func extractCommandToken(from commandLine: String) -> String? {
        let tokens = tokenizeCommandLine(commandLine)
        guard !tokens.isEmpty else { return nil }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.isEmpty {
                index += 1
                continue
            }

            if isEnvAssignment(token) {
                index += 1
                continue
            }

            let lower = token.lowercased()
            if lower == "env" {
                index = consumeEnv(tokens: tokens, start: index + 1)
                continue
            }

            if lower == "sudo" {
                index = consumeSudo(tokens: tokens, start: index + 1)
                continue
            }

            if Self.wrapperCommands.contains(lower) {
                index += 1
                continue
            }

            if lower.hasPrefix("-") {
                index += 1
                continue
            }

            return token
        }

        return nil
    }

    private func consumeEnv(tokens: [String], start: Int) -> Int {
        var index = start
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                return index + 1
            }
            if token.hasPrefix("-") || isEnvAssignment(token) {
                index += 1
                continue
            }
            break
        }
        return index
    }

    private func consumeSudo(tokens: [String], start: Int) -> Int {
        var index = start
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                return index + 1
            }
            if token.hasPrefix("-") {
                if Self.sudoOptionsWithValue.contains(token), index + 1 < tokens.count {
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            break
        }
        return index
    }

    private func tokenizeCommandLine(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        func flushCurrent() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for char in line {
            if isEscaped {
                current.append(char)
                isEscaped = false
                continue
            }

            if char == "\\" && !inSingleQuote {
                isEscaped = true
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if !inSingleQuote && !inDoubleQuote {
                if char == "#" {
                    break
                }
                if char == "|" || char == ";" || char == "&" {
                    break
                }
                if char.isWhitespace {
                    flushCurrent()
                    continue
                }
            }

            current.append(char)
        }

        flushCurrent()
        return tokens
    }

    private func normalizeCommandToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathComponent = (trimmed as NSString).lastPathComponent
        let baseName = (pathComponent as NSString).deletingPathExtension
        return baseName.lowercased()
    }

    private func isEnvAssignment(_ token: String) -> Bool {
        guard let eqIndex = token.firstIndex(of: "=") else { return false }
        let name = token[..<eqIndex]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        for ch in name.dropFirst() {
            if ch != "_" && !ch.isLetter && !ch.isNumber {
                return false
            }
        }
        return true
    }

    private func recordInputLineIfNeeded() {
        guard let app = activeAppName, app == "Codex" else { return }
        terminalView?.recordInputLine()
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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        smartoverlay_precmd() { print -Pn "\\e]7;file://$HOSTNAME$PWD\\a"; }
        autoload -Uz add-zsh-hook 2>/dev/null
        if command -v add-zsh-hook >/dev/null 2>&1; then
          add-zsh-hook precmd smartoverlay_precmd
        else
          precmd_functions+=smartoverlay_precmd
        fi
        smartoverlay_precmd
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
        PROMPT_COMMAND="smartoverlay_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
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
          printf '\\e]7;file://%s%s\\a' (hostname) (pwd)
        end
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
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.status = .exited
        }
        let message = exitCode == nil ? "Shell exited." : "Shell exited with code \(exitCode!)."
        appModel?.recordEvent(type: "failed", tool: "Chau7", message: message, notify: true)
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
        highlightView?.needsDisplay = true
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
        var result: UnsafeMutablePointer<passwd>? = UnsafeMutablePointer<passwd>.allocate(capacity: 1)
        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) != 0 {
            return "/bin/zsh"
        }
        return String(cString: pwd.pw_shell)
    }

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
        dict["CHAU7_START_DIR"] = Self.defaultStartDirectory()

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
        highlightView?.needsDisplay = true
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
        }
        return cachedBufferData
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
        highlightView?.needsDisplay = true
        return SearchSummary(count: computed.matches.count, previewLines: computed.previewLines, error: computed.error)
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
                self.highlightView?.needsDisplay = true
            }
        }
        searchUpdateWorkItem = work
        searchQueue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        activeSearchIndex = (activeSearchIndex + 1) % searchMatches.count
        highlightView?.needsDisplay = true
    }

    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        activeSearchIndex = (activeSearchIndex - 1 + searchMatches.count) % searchMatches.count
        highlightView?.needsDisplay = true
    }

    func currentMatch() -> SearchMatch? {
        guard !searchMatches.isEmpty else { return nil }
        let index = max(0, min(activeSearchIndex, searchMatches.count - 1))
        return searchMatches[index]
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
