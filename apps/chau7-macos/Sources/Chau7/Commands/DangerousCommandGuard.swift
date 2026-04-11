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
@Observable
@MainActor
final class DangerousCommandGuard {
    static let shared = DangerousCommandGuard()

    /// Whether the guard is currently active
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "feature.dangerousCommandGuard")
            Log.info("DangerousCommandGuard: \(isEnabled ? "enabled" : "disabled")")
        }
    }

    /// Commands that are always allowed (user has confirmed "always allow")
    var allowList: Set<String> {
        didSet { saveAllowList() }
    }

    /// Commands that are always blocked
    var blockList: Set<String> {
        didSet { saveBlockList() }
    }

    /// Per-directory allowlists: directory path → set of allowed commands.
    /// Commands in a directory allowlist are only allowed when the terminal's
    /// working directory matches (or is a child of) the allowlist key.
    @ObservationIgnored
    private var directoryAllowLists: [String: Set<String>] {
        didSet { saveDirectoryAllowLists() }
    }

    /// Custom patterns beyond the defaults
    var patterns: [String] {
        FeatureSettings.shared.dangerousCommandPatterns
    }

    /// Categorises why a command needs confirmation. Drives the explanation
    /// string shown to the user so they understand *why* a warning fired, not
    /// just *what* rule matched.
    enum ConfirmationReason: Equatable {
        /// Text contained an embedded newline, i.e. multiple commands.
        case multilinePaste
        /// Text contained non-ASCII lookalikes of shell characters.
        case unicodeHomoglyph
        /// Self-protection policy matched (Chau7's own files/processes).
        case selfProtection(detail: String)
        /// A user- or default-configured risky-pattern regex matched.
        case riskyPattern(pattern: String)

        /// Short one-liner shown next to the "Matched:" label.
        var shortLabel: String {
            switch self {
            case .multilinePaste:
                return L("dangerousGuard.reason.multiline.short", "Multiline paste")
            case .unicodeHomoglyph:
                return L("dangerousGuard.reason.homoglyph.short", "Unicode lookalike characters")
            case .selfProtection(let detail):
                return L("dangerousGuard.reason.selfProtect.short", "Protects Chau7: %@", detail)
            case .riskyPattern(let pattern):
                return pattern
            }
        }

        /// One-paragraph explanation of *why* this is risky, shown as the
        /// alert's informative text so the user understands the threat model.
        var explanation: String {
            switch self {
            case .multilinePaste:
                return L(
                    "dangerousGuard.reason.multiline.explanation",
                    "The pasted text contains a newline, which means it will run more than one command as soon as you press Enter. Unexpected newlines are a common way malicious snippets slip past a quick visual review."
                )
            case .unicodeHomoglyph:
                return L(
                    "dangerousGuard.reason.homoglyph.explanation",
                    "The text contains Unicode characters that visually resemble ASCII letters (for example, Cyrillic \u{0430} or \u{043E}). Attackers use these lookalikes to disguise malicious commands as safe ones. Compare each character carefully before executing."
                )
            case .selfProtection(let detail):
                return L(
                    "dangerousGuard.reason.selfProtect.explanation",
                    "This command targets Chau7 itself or its managed runtime: %@. Running it could corrupt the app's state, disable running agents, or delete data Chau7 is actively using.",
                    detail
                )
            case .riskyPattern(let pattern):
                return L(
                    "dangerousGuard.reason.risky.explanation",
                    "The command matches the risky-pattern rule \u{201C}%@\u{201D}. Matching commands typically remove files, modify permissions, or write to the network in ways that are hard to undo. Make sure this is what you intended.",
                    pattern
                )
            }
        }
    }

    /// Result of checking a command
    enum CheckResult: Equatable {
        case safe // Not risky, proceed
        case allowed // Risky but in allow list
        case needsConfirmation(command: String, matchedPattern: String, reason: ConfirmationReason) // Needs user confirmation
        case blocked(reason: String) // Hard blocked by policy
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
        self.testPatternsOverride = testPatterns
    }
    #endif

    /// Override patterns for testing; nil means use FeatureSettings.shared.
    @ObservationIgnored
    private var testPatternsOverride: [String]?

    /// Resolved patterns: test override or FeatureSettings.
    private var resolvedPatterns: [String] {
        testPatternsOverride ?? FeatureSettings.shared.dangerousCommandPatterns
    }

    // MARK: - Check

    /// Checks whether a command needs confirmation.
    /// - Parameters:
    ///   - commandLine: The command to check
    ///   - directory: Current working directory (for per-directory allowlist matching)
    func check(
        commandLine: String,
        directory: String? = nil,
        selfProtectionContext: SelfProtectiveCommandContext? = nil
    ) -> CheckResult {
        guard isEnabled else { return .safe }
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .safe }

        // Unicode homoglyph detection: flag commands containing non-ASCII lookalikes
        // of common shell characters (e.g. Cyrillic а/о/е that look like Latin a/o/e)
        if containsHomoglyphs(trimmed) {
            Log.warn("DangerousCommandGuard: homoglyph detected '\(trimmed.prefix(60))'")
            let reason = ConfirmationReason.unicodeHomoglyph
            return .needsConfirmation(command: trimmed, matchedPattern: reason.shortLabel, reason: reason)
        }

        // Multiline paste protection: flag pasted commands spanning multiple lines
        if trimmed.contains("\n") {
            Log.warn("DangerousCommandGuard: multiline paste '\(trimmed.prefix(60))'")
            let reason = ConfirmationReason.multilinePaste
            return .needsConfirmation(command: trimmed, matchedPattern: reason.shortLabel, reason: reason)
        }

        let effectiveSelfProtectionContext = selfProtectionContext ?? FeatureSettings.shared.dangerousCommandSelfProtectionContext()
        if FeatureSettings.shared.dangerousCommandProtectChau7Enabled,
           let match = SelfProtectiveCommandDetection.detect(commandLine: trimmed, context: effectiveSelfProtectionContext) {
            switch FeatureSettings.shared.dangerousCommandProtectChau7Level {
            case .verboseLogging:
                Log.warn("DangerousCommandGuard: self-protection log '\(trimmed)' (\(match.reason))")
                return .safe
            case .warning:
                Log.warn("DangerousCommandGuard: self-protection warn '\(trimmed)' (\(match.reason))")
                let reason = ConfirmationReason.selfProtection(detail: match.reason)
                return .needsConfirmation(command: trimmed, matchedPattern: reason.shortLabel, reason: reason)
            case .blocking:
                Log.warn("DangerousCommandGuard: self-protection blocked '\(trimmed)' (\(match.reason))")
                return .blocked(reason: match.reason)
            }
        }

        // Check block list first
        if blockList.contains(trimmed) {
            Log.warn("DangerousCommandGuard: BLOCKED '\(trimmed)'")
            return .blocked(reason: "blocked by dangerous command guard block list")
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
            let reason = ConfirmationReason.riskyPattern(pattern: matched)
            return .needsConfirmation(command: trimmed, matchedPattern: matched, reason: reason)
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
    ///
    /// The command text is rendered inside a bounded scrollable accessoryView
    /// rather than the alert's informativeText so that very long or multi-line
    /// commands don't stretch the alert past the screen edge and push the
    /// Execute/Cancel/Always Allow buttons out of view.
    ///
    /// If a `ConfirmationReason` is supplied, its `explanation` replaces the
    /// generic alert body with category-specific text telling the user *why*
    /// this input was flagged (not just which pattern matched).
    func showConfirmation(command: String, matchedPattern: String, reason: ConfirmationReason? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("dangerousGuard.alert.title", "Dangerous Command Detected")
        let explanation = reason?.explanation ?? L(
            "dangerousGuard.alert.body.generic",
            "This input matches a risky pattern. Review the command below and confirm whether to execute it."
        )
        alert.informativeText = L(
            "dangerousGuard.alert.body",
            "%@\n\nMatched: %@",
            explanation,
            matchedPattern
        )
        alert.alertStyle = .warning
        alert.accessoryView = Self.makeCommandAccessoryView(command: command)
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

    /// Shows a blocking alert when a command is denied by policy.
    /// Must be called on the main actor (which this class is isolated to).
    func showBlockedAlert(command: String, reason: String) {
        let alert = NSAlert()
        alert.messageText = L("dangerousGuard.blocked.title", "Command Blocked")
        alert.informativeText = L(
            "dangerousGuard.blocked.body",
            "Chau7 blocked this command because it would harm the app or its managed runtime.\n\n%@\n\nReason: %@",
            command,
            reason
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("dangerousGuard.blocked.dismiss", "OK"))
        _ = alert.runModal()
        Log.warn("DangerousCommandGuard: blocked alert shown '\(command)' (\(reason))")
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

    /// Builds a bounded scrollable NSView that displays the command inside the
    /// confirmation NSAlert. Using an accessoryView instead of stuffing the full
    /// text into `informativeText` caps the dialog height so that very long or
    /// multi-line commands scroll inside the box rather than pushing the
    /// Execute/Cancel/Always Allow buttons off-screen.
    ///
    /// Width: 480pt (comfortable for an NSAlert).
    /// Height: clamped to the screen so there's always room for header + buttons.
    @MainActor
    static func makeCommandAccessoryView(command: String) -> NSView {
        let width: CGFloat = 480
        // Reserve 220pt for alert header, informative text, and button row so
        // the whole alert fits comfortably on the smallest likely screen.
        let screenBudget = NSScreen.main?.visibleFrame.height ?? 800
        let maxHeight: CGFloat = max(120, min(320, screenBudget - 220))

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: maxHeight))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = command
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width - 16, height: .greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: maxHeight))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = true

        return scroll
    }

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
