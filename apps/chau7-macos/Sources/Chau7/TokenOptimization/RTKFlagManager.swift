import Foundation

// MARK: - Token Optimization Mode

/// Global mode controlling when RTK (Reduced Token Kit) is active across tabs.
enum TokenOptimizationMode: String, CaseIterable, Codable {
    /// RTK disabled entirely — no PATH injection, no flag files.
    case off

    /// Every tab, every command — flag files always created.
    case allTabs

    /// Only when an AI CLI is detected via `activeAppName`.
    case aiOnly

    /// Per-tab manual control — default off, user opts in.
    case manual

    var displayName: String {
        switch self {
        case .off: return L("rtk.mode.off", "Off")
        case .allTabs: return L("rtk.mode.allTabs", "All Commands")
        case .aiOnly: return L("rtk.mode.aiOnly", "AI Commands Only")
        case .manual: return L("rtk.mode.manual", "Manual (Per-Tab)")
        }
    }

    var description: String {
        switch self {
        case .off: return L("rtk.mode.off.desc", "Token optimization is disabled")
        case .allTabs: return L("rtk.mode.allTabs.desc", "Active in every tab for all commands")
        case .aiOnly: return L("rtk.mode.aiOnly.desc", "Activates when an AI CLI is detected")
        case .manual: return L("rtk.mode.manual.desc", "Manually enable per tab")
        }
    }
}

// MARK: - Per-Tab Override

/// Per-tab override for token optimization, allowing users to force-on or
/// force-off regardless of the global mode.
enum TabTokenOptOverride: String, Codable, CaseIterable {
    /// Follow the global mode's default behavior.
    case `default`

    /// Always active, regardless of global mode.
    case forceOn

    /// Never active, regardless of global mode.
    case forceOff
}

// MARK: - RTK Flag Manager

/// Manages per-session flag files that tell RTK wrapper scripts whether to
/// intercept commands. Flag files live in `~/.chau7/rtk_active/` and are
/// named by session ID.
///
/// The wrapper script checks: `if [ -f ~/.chau7/rtk_active/$CHAU7_RTK_SESSION ]; then ...`
enum RTKFlagManager {

    /// Base directory for RTK flag files.
    private static let flagDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".chau7/rtk_active", isDirectory: true)
    }()

    // MARK: - Decision Logic

    /// Determines whether RTK should be active for a given tab's state.
    ///
    /// This is the single source of truth for the entire decision matrix:
    /// - `.off` mode: never active
    /// - `.forceOff` override: never active
    /// - `.forceOn` override: always active
    /// - `.allTabs` + `.default`: active
    /// - `.aiOnly` + `.default`: active only when AI is detected
    /// - `.manual` + `.default`: inactive
    static func shouldBeActive(
        mode: TokenOptimizationMode,
        override: TabTokenOptOverride,
        isAIActive: Bool
    ) -> Bool {
        switch (mode, override) {
        case (.off, _):               return false
        case (_, .forceOff):           return false
        case (_, .forceOn):            return true
        case (.allTabs, .default):     return true
        case (.aiOnly, .default):      return isAIActive
        case (.manual, .default):      return false
        }
    }

    // MARK: - Flag File CRUD

    /// Ensures the flag directory exists. Called once during app startup.
    static func ensureFlagDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: flagDirectory.path) {
            do {
                try fm.createDirectory(at: flagDirectory, withIntermediateDirectories: true)
                Log.info("RTKFlagManager: created flag directory at \(flagDirectory.path)")
            } catch {
                Log.error("RTKFlagManager: failed to create flag directory: \(error)")
            }
        }
    }

    /// Creates a flag file for the given session, signaling RTK is active.
    static func createFlag(sessionID: String) {
        let path = flagDirectory.appendingPathComponent(sessionID)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            fm.createFile(atPath: path.path, contents: nil)
            Log.trace("RTKFlagManager: created flag for session \(sessionID)")
        }
    }

    /// Removes the flag file for the given session, signaling RTK is inactive.
    static func removeFlag(sessionID: String) {
        let path = flagDirectory.appendingPathComponent(sessionID)
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) {
            do {
                try fm.removeItem(at: path)
                Log.trace("RTKFlagManager: removed flag for session \(sessionID)")
            } catch {
                Log.error("RTKFlagManager: failed to remove flag for \(sessionID): \(error)")
            }
        }
    }

    /// Removes all flag files. Called on app quit and mode changes.
    static func removeAllFlags() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: flagDirectory.path) else { return }
        guard let contents = try? fm.contentsOfDirectory(atPath: flagDirectory.path) else {
            Log.error("RTKFlagManager: failed to list flag directory")
            return
        }
        var removed = 0
        for file in contents {
            do {
                try fm.removeItem(atPath: flagDirectory.appendingPathComponent(file).path)
                removed += 1
            } catch {
                Log.error("RTKFlagManager: failed to remove flag \(file): \(error)")
            }
        }
        if removed > 0 {
            Log.info("RTKFlagManager: cleared \(removed) flag file(s)")
        }
    }

    /// Returns whether a flag file exists for the given session.
    static func isFlagActive(sessionID: String) -> Bool {
        let path = flagDirectory.appendingPathComponent(sessionID)
        return FileManager.default.fileExists(atPath: path.path)
    }

    // MARK: - Recalculation

    /// Recalculates the flag file state for a single session based on current
    /// mode, override, and AI detection state. Creates or removes the flag
    /// file as appropriate.
    static func recalculate(
        sessionID: String,
        mode: TokenOptimizationMode,
        override: TabTokenOptOverride,
        isAIActive: Bool
    ) {
        let active = shouldBeActive(mode: mode, override: override, isAIActive: isAIActive)
        if active {
            createFlag(sessionID: sessionID)
        } else {
            removeFlag(sessionID: sessionID)
        }
    }
}
