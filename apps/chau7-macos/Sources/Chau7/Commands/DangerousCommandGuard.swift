import Foundation
import AppKit
import Chau7Core

/// Guards against accidental execution of dangerous commands.
/// When the user presses Enter and the current input line matches
/// a risky pattern, a confirmation dialog is shown before the
/// keystroke is forwarded to the shell.
///
/// This is a non-invasive guard: it only delays the Enter keystroke
/// delivery, never modifies the command text.
@MainActor
final class DangerousCommandGuard: ObservableObject {
    static let shared = DangerousCommandGuard()

    /// Whether the guard is currently active
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "feature.dangerousCommandGuard")
            Log.info("DangerousCommandGuard: \(isEnabled ? "enabled" : "disabled")")
        }
    }

    /// Commands that are always allowed (user has confirmed "always allow")
    @Published var allowList: Set<String> {
        didSet { saveAllowList() }
    }

    /// Commands that are always blocked
    @Published var blockList: Set<String> {
        didSet { saveBlockList() }
    }

    /// Per-directory allowlists: directory path → set of allowed commands.
    /// Commands in a directory allowlist are only allowed when the terminal's
    /// working directory matches (or is a child of) the allowlist key.
    private var directoryAllowLists: [String: Set<String>] {
        didSet { saveDirectoryAllowLists() }
    }

    /// Custom patterns beyond the defaults
    var patterns: [String] {
        FeatureSettings.shared.dangerousCommandPatterns
    }

    /// Result of checking a command
    enum CheckResult: Equatable {
        case safe // Not risky, proceed
        case allowed // Risky but in allow list
        case needsConfirmation(command: String, matchedPattern: String) // Needs user confirmation
        case blocked // In block list
    }

    private init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.object(forKey: "feature.dangerousCommandGuard") as? Bool ?? true
        self.allowList = Set(defaults.stringArray(forKey: "dangerousGuard.allowList") ?? [])
        self.blockList = Set(defaults.stringArray(forKey: "dangerousGuard.blockList") ?? [])
        // Load per-directory allowlists
        if let data = defaults.data(forKey: "dangerousGuard.directoryAllowLists"),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.directoryAllowLists = decoded.mapValues { Set($0) }
        } else {
            self.directoryAllowLists = [:]
        }
        Log.info("DangerousCommandGuard initialized: enabled=\(isEnabled) allow=\(allowList.count) block=\(blockList.count) dirAllow=\(directoryAllowLists.count)")
    }

    // Initializer for testing only — bypasses UserDefaults.
    // Use `@testable import` from test targets to access this.
    #if DEBUG
    init(enabled: Bool, allowList: Set<String>, blockList: Set<String>, testPatterns: [String]) {
        self.isEnabled = enabled
        self.allowList = allowList
        self.blockList = blockList
        self.directoryAllowLists = [:]
        self._testPatterns = testPatterns
    }
    #endif

    /// Override patterns for testing; nil means use FeatureSettings.shared.
    private var _testPatterns: [String]?

    /// Resolved patterns: test override or FeatureSettings.
    private var resolvedPatterns: [String] {
        _testPatterns ?? FeatureSettings.shared.dangerousCommandPatterns
    }

    // MARK: - Check

    /// Checks whether a command needs confirmation.
    /// - Parameters:
    ///   - commandLine: The command to check
    ///   - directory: Current working directory (for per-directory allowlist matching)
    func check(commandLine: String, directory: String? = nil) -> CheckResult {
        guard isEnabled else { return .safe }
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .safe }

        // Unicode homoglyph detection: flag commands containing non-ASCII lookalikes
        // of common shell characters (e.g. Cyrillic а/о/е that look like Latin a/o/e)
        if containsHomoglyphs(trimmed) {
            Log.warn("DangerousCommandGuard: homoglyph detected '\(trimmed.prefix(60))'")
            return .needsConfirmation(command: trimmed, matchedPattern: "Unicode homoglyph characters detected")
        }

        // Multiline paste protection: flag pasted commands spanning multiple lines
        if trimmed.contains("\n") {
            Log.warn("DangerousCommandGuard: multiline paste '\(trimmed.prefix(60))'")
            return .needsConfirmation(command: trimmed, matchedPattern: "Multiline paste detected")
        }

        // Check block list first
        if blockList.contains(trimmed) {
            Log.warn("DangerousCommandGuard: BLOCKED '\(trimmed)'")
            return .blocked
        }

        // Check per-directory allowlist
        if let dir = directory {
            for (allowedDir, commands) in directoryAllowLists {
                if dir == allowedDir || dir.hasPrefix(allowedDir + "/"), commands.contains(trimmed) {
                    Log.trace("DangerousCommandGuard: allowed (directory '\(allowedDir)') '\(trimmed)'")
                    return .allowed
                }
            }
        }

        // Check global allow list
        if allowList.contains(trimmed) {
            Log.trace("DangerousCommandGuard: allowed (allowlist) '\(trimmed)'")
            return .allowed
        }

        // Check risk patterns
        if CommandRiskDetection.isRisky(commandLine: trimmed, patterns: resolvedPatterns) {
            Log.warn("DangerousCommandGuard: needs confirmation '\(trimmed)'")
            let matched = findMatchedPattern(trimmed)
            return .needsConfirmation(command: trimmed, matchedPattern: matched)
        }

        return .safe
    }

    /// Detects Unicode homoglyphs — characters that visually resemble ASCII but are
    /// from different Unicode blocks (Cyrillic, Greek, etc.). Attackers use these to
    /// disguise malicious commands as safe-looking ones.
    private func containsHomoglyphs(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            // Skip ASCII range entirely
            if scalar.value < 0x80 { continue }
            // Common Cyrillic lookalikes: а(0x430) е(0x435) о(0x43E) р(0x440) с(0x441) х(0x445)
            // Common fullwidth: ！(FF01) ～(FF5E)
            let v = scalar.value
            if (v >= 0x0400 && v <= 0x04FF) || // Cyrillic block
                (v >= 0xFF01 && v <= 0xFF5E) { // Fullwidth forms
                return true
            }
        }
        return false
    }

    // MARK: - Confirmation

    /// Shows a confirmation alert for a dangerous command.
    /// Returns true if the user confirms execution.
    /// Must be called on the main actor (which this class is isolated to).
    func showConfirmation(command: String, matchedPattern: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("dangerousGuard.alert.title", "Dangerous Command Detected")
        alert.informativeText = L(
            "dangerousGuard.alert.body",
            "The command matches a risky pattern:\n\n%@\n\nMatched: %@\n\nAre you sure you want to execute this?",
            command,
            matchedPattern
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("dangerousGuard.alert.execute", "Execute"))
        alert.addButton(withTitle: L("dangerousGuard.alert.cancel", "Cancel"))
        alert.addButton(withTitle: L("dangerousGuard.alert.alwaysAllow", "Always Allow"))

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Log.info("DangerousCommandGuard: user confirmed '\(command)'")
            return true
        case .alertThirdButtonReturn:
            Log.info("DangerousCommandGuard: user always-allowed '\(command)'")
            allowList.insert(command)
            return true
        default:
            Log.info("DangerousCommandGuard: user cancelled '\(command)'")
            return false
        }
    }

    // MARK: - List Management

    /// Adds a command to the allow list.
    func addToAllowList(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        allowList.insert(trimmed)
        Log.info("DangerousCommandGuard: added to allow list '\(trimmed)'")
    }

    /// Removes a command from the allow list.
    func removeFromAllowList(_ command: String) {
        allowList.remove(command)
        Log.info("DangerousCommandGuard: removed from allow list '\(command)'")
    }

    /// Adds a command to the block list.
    func addToBlockList(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        blockList.insert(trimmed)
        Log.info("DangerousCommandGuard: added to block list '\(trimmed)'")
    }

    /// Removes a command from the block list.
    func removeFromBlockList(_ command: String) {
        blockList.remove(command)
        Log.info("DangerousCommandGuard: removed from block list '\(command)'")
    }

    /// Clears the allow list.
    func clearAllowList() {
        allowList.removeAll()
        Log.info("DangerousCommandGuard: cleared allow list")
    }

    /// Clears the block list.
    func clearBlockList() {
        blockList.removeAll()
        Log.info("DangerousCommandGuard: cleared block list")
    }

    // MARK: - Helpers

    private func findMatchedPattern(_ command: String) -> String {
        for pattern in resolvedPatterns {
            if CommandRiskDetection.isRisky(commandLine: command, patterns: [pattern]) {
                return pattern
            }
        }
        return "risky command pattern"
    }

    private func saveAllowList() {
        UserDefaults.standard.set(Array(allowList), forKey: "dangerousGuard.allowList")
    }

    private func saveBlockList() {
        UserDefaults.standard.set(Array(blockList), forKey: "dangerousGuard.blockList")
    }

    // MARK: - Per-Directory Allowlist

    func addToDirectoryAllowList(command: String, directory: String) {
        var commands = directoryAllowLists[directory] ?? []
        commands.insert(command)
        directoryAllowLists[directory] = commands
        Log.info("DangerousCommandGuard: added to directory allowlist '\(command)' for '\(directory)'")
    }

    func removeFromDirectoryAllowList(command: String, directory: String) {
        directoryAllowLists[directory]?.remove(command)
        if directoryAllowLists[directory]?.isEmpty == true {
            directoryAllowLists.removeValue(forKey: directory)
        }
    }

    private func saveDirectoryAllowLists() {
        let serializable = directoryAllowLists.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(serializable) {
            UserDefaults.standard.set(data, forKey: "dangerousGuard.directoryAllowLists")
        }
    }
}
