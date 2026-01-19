import Foundation
import Chau7Core

/// Detects and emits shell-related events for the notification system.
/// Handles: exit codes, output pattern matching, long-running commands, directory/git changes.
final class ShellEventDetector {
    private weak var appModel: AppModel?
    private var config: ShellEventConfig { FeatureSettings.shared.shellEventConfig }

    // Track state for change detection
    private var lastDirectory: String?
    private var lastGitBranch: String?
    private var commandStartTime: Date?
    private var longRunningTimer: DispatchSourceTimer?
    private var hasEmittedLongRunning = false

    // Pattern matching cache (synchronized access via patternQueue)
    private var compiledPatterns: [(ShellOutputPattern, NSRegularExpression)] = []
    private var lastPatternConfigHash: Int = 0
    private let patternQueue = DispatchQueue(label: "com.chau7.shellEventDetector.patterns")

    // Rate limiting for pattern matches (prevents notification flooding)
    private var lastPatternMatchTime: [UUID: Date] = [:]
    private let patternCooldownSeconds: TimeInterval = 5.0  // Min seconds between same pattern matches

    init(appModel: AppModel?) {
        self.appModel = appModel
        recompilePatterns()
    }

    // MARK: - Configuration

    /// Recompile regex patterns when config changes (thread-safe)
    func recompilePatterns() {
        patternQueue.sync {
            let currentHash = config.outputPatterns.hashValue
            guard currentHash != lastPatternConfigHash else { return }
            lastPatternConfigHash = currentHash

            compiledPatterns = config.outputPatterns.compactMap { pattern -> (ShellOutputPattern, NSRegularExpression)? in
                guard pattern.isEnabled else { return nil }
                do {
                    let regex = try NSRegularExpression(pattern: pattern.pattern, options: [])
                    return (pattern, regex)
                } catch {
                    Log.warn("Invalid shell pattern '\(pattern.name)': \(error.localizedDescription)")
                    return nil
                }
            }
        }
    }

    // MARK: - Command Lifecycle

    /// Called when a command starts executing
    func commandStarted(command: String?, in directory: String) {
        commandStartTime = Date()
        hasEmittedLongRunning = false
        startLongRunningTimer()

        // Emit process_started event
        emitEvent(
            type: "process_started",
            message: command ?? "Command started"
        )
    }

    /// Called when a command completes
    func commandFinished(exitCode: Int?, command: String?) {
        stopLongRunningTimer()

        let exitCodeValue = exitCode ?? 0
        let commandDesc = command?.prefix(100).description ?? "Command"

        // Check if this exit code should trigger exit_code_match
        if let code = exitCode, config.watchedExitCodes.contains(code) {
            emitEvent(
                type: "exit_code_match",
                message: "Exit code \(code): \(commandDesc)"
            )
        }

        // Emit command_finished or command_failed
        if exitCodeValue != 0 {
            emitEvent(
                type: "command_failed",
                message: "Exit \(exitCodeValue): \(commandDesc)"
            )
        } else if config.notifyOnAllCommandCompletion {
            emitEvent(
                type: "command_finished",
                message: commandDesc
            )
        }

        // Emit process_ended
        emitEvent(
            type: "process_ended",
            message: "Exit \(exitCodeValue)"
        )

        commandStartTime = nil
    }

    // MARK: - Output Processing

    /// Process command output for pattern matching (thread-safe, rate-limited)
    func processOutput(_ text: String) {
        recompilePatterns()

        // Get a snapshot of patterns under lock
        let patterns = patternQueue.sync { compiledPatterns }
        let now = Date()

        for (pattern, regex) in patterns {
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                // Rate limiting: check if this pattern fired recently
                if let lastMatch = lastPatternMatchTime[pattern.id] {
                    let elapsed = now.timeIntervalSince(lastMatch)
                    if elapsed < patternCooldownSeconds {
                        continue  // Skip, pattern is in cooldown
                    }
                }

                lastPatternMatchTime[pattern.id] = now
                emitEvent(
                    type: pattern.notificationType,
                    message: "Pattern '\(pattern.name)' matched"
                )
            }
        }
    }

    // MARK: - Directory & Git Changes

    /// Called when directory changes (from OSC 7)
    func directoryChanged(to newDirectory: String) {
        let oldDirectory = lastDirectory
        lastDirectory = newDirectory

        guard let old = oldDirectory, old != newDirectory else { return }
        guard config.notifyOnDirectoryChange else { return }

        emitEvent(
            type: "directory_changed",
            message: "Changed to \(newDirectory)"
        )
    }

    /// Called when git branch changes
    func gitBranchChanged(to newBranch: String?) {
        let oldBranch = lastGitBranch
        lastGitBranch = newBranch

        guard config.notifyOnGitBranchChange else { return }
        guard oldBranch != newBranch else { return }

        if let new = newBranch {
            if let old = oldBranch {
                emitEvent(
                    type: "git_branch_changed",
                    message: "Switched from \(old) to \(new)"
                )
            } else {
                emitEvent(
                    type: "git_branch_changed",
                    message: "Entered git repo on branch \(new)"
                )
            }
        } else if oldBranch != nil {
            emitEvent(
                type: "git_branch_changed",
                message: "Left git repository"
            )
        }
    }

    // MARK: - Long-Running Detection

    private func startLongRunningTimer() {
        stopLongRunningTimer()

        let threshold = config.longRunningThresholdSeconds
        guard threshold > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(threshold))
        timer.setEventHandler { [weak self] in
            self?.checkLongRunning()
        }
        timer.resume()
        longRunningTimer = timer
    }

    private func stopLongRunningTimer() {
        longRunningTimer?.cancel()
        longRunningTimer = nil
    }

    private func checkLongRunning() {
        guard !hasEmittedLongRunning else { return }
        guard let startTime = commandStartTime else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        let threshold = Double(config.longRunningThresholdSeconds)

        if elapsed >= threshold {
            hasEmittedLongRunning = true
            let minutes = Int(elapsed / 60)
            let seconds = Int(elapsed) % 60
            emitEvent(
                type: "long_running",
                message: "Command running for \(minutes)m \(seconds)s"
            )
        }
    }

    // MARK: - Event Emission

    private func emitEvent(type: String, message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.appModel?.recordEvent(
                source: .shell,
                type: type,
                tool: "Shell",
                message: message,
                notify: true
            )
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        stopLongRunningTimer()
    }

    deinit {
        cleanup()
    }
}
