import Foundation
import Chau7Core

/// Detects and emits shell-related events for the notification system.
/// Handles: exit codes, output pattern matching, long-running commands, directory/git changes.
final class ShellEventDetector {
    private weak var appModel: AppModel?
    private var config: ShellEventConfig {
        FeatureSettings.shared.shellEventConfig
    }

    // Track state for change detection
    private var lastDirectory: String?
    private var lastGitBranch: String?
    private var commandStartTime: Date?
    private var longRunningTimer: DispatchSourceTimer?
    // Tiered long-running notification thresholds (in seconds)
    private static let longRunningTiers: [Int] = [30, 60, 300] // 30s, 1m, 5m
    private var emittedTiers: Set<Int> = [] // Track which tiers have been emitted

    // Pattern matching cache (synchronized access via patternQueue)
    private var compiledPatterns: [(ShellOutputPattern, NSRegularExpression)] = []
    private var lastPatternConfigHash = 0
    private let patternQueue = DispatchQueue(label: "com.chau7.shellEventDetector.patterns")

    // Rate limiting for pattern matches (prevents notification flooding)
    private var lastPatternMatchTime: [UUID: Date] = [:]
    private let patternCooldownSeconds: TimeInterval = 5.0 // Min seconds between same pattern matches

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
        if lastDirectory == nil, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastDirectory = directory
        }
        commandStartTime = Date()
        emittedTiers.removeAll()
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
                        continue // Skip, pattern is in cooldown
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
        let normalizedDirectory = URL(fileURLWithPath: newDirectory).standardized.path
        let oldDirectory = lastDirectory
        lastDirectory = normalizedDirectory

        guard let old = oldDirectory, old != normalizedDirectory else { return }
        guard config.notifyOnDirectoryChange else { return }

        emitEvent(
            type: "directory_changed",
            message: "Changed to \(normalizedDirectory)"
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

    // MARK: - Long-Running Detection (Tiered: 30s, 1m, 5m)

    private func startLongRunningTimer() {
        stopLongRunningTimer()

        // Use a repeating timer to check at regular intervals for tiered notifications
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Check every 5 seconds for responsive tiered notifications
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
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
        guard let startTime = commandStartTime else { return }

        let elapsed = Int(Date().timeIntervalSince(startTime))

        // Check each tier and emit if not already emitted
        for tier in Self.longRunningTiers {
            if elapsed >= tier, !emittedTiers.contains(tier) {
                emittedTiers.insert(tier)
                let minutes = tier / 60
                let seconds = tier % 60
                let timeStr = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
                emitEvent(
                    type: "long_running",
                    message: "Command running for \(timeStr)"
                )
            }
        }

        // Stop timer if all tiers have been emitted
        if emittedTiers.count >= Self.longRunningTiers.count {
            stopLongRunningTimer()
        }
    }

    // MARK: - Event Emission

    private func emitEvent(type: String, message: String) {
        let dir = lastDirectory
        DispatchQueue.main.async { [weak self] in
            self?.appModel?.recordEvent(
                source: .shell,
                type: type,
                tool: "Shell",
                message: message,
                notify: true,
                directory: dir
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
