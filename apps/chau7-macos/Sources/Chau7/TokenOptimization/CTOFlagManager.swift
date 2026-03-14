import Foundation
import Chau7Core

// MARK: - Token Optimization Mode (App-Target Extensions)

extension TokenOptimizationMode {
    var displayName: String {
        switch self {
        case .off: return L("cto.mode.off", "Off")
        case .allTabs: return L("cto.mode.allTabs", "All Commands")
        case .aiOnly: return L("cto.mode.aiOnly", "AI Commands Only")
        case .manual: return L("cto.mode.manual", "Manual (Per-Tab)")
        }
    }

    var description: String {
        switch self {
        case .off: return L("cto.mode.off.desc", "Token optimization is disabled")
        case .allTabs: return L("cto.mode.allTabs.desc", "Active in every tab for all commands")
        case .aiOnly: return L("cto.mode.aiOnly.desc", "Activates when an AI CLI is detected")
        case .manual: return L("cto.mode.manual.desc", "Manually enable per tab")
        }
    }
}

// MARK: - CTO Flag Manager

/// Manages per-session flag files that tell CTO wrapper scripts whether to
/// intercept commands. Flag files live in `~/.chau7/cto_active/` and are
/// named by session ID.
///
/// The wrapper script checks: `if [ -f ~/.chau7/cto_active/$CHAU7_CTO_SESSION ]; then ...`
enum CTOFlagManager {

    /// Base directory for CTO flag files.
    private static let flagDirectory: URL = {
        RuntimeIsolation.chau7Directory()
            .appendingPathComponent("cto_active", isDirectory: true)
    }()

    // MARK: - Flag File CRUD

    /// Ensures the flag directory exists. Called once during app startup.
    static func ensureFlagDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: flagDirectory.path) {
            do {
                try fm.createDirectory(at: flagDirectory, withIntermediateDirectories: true)
                Log.info("CTOFlagManager: created flag directory at \(flagDirectory.path)")
            } catch {
                Log.error("CTOFlagManager: failed to create flag directory: \(error)")
            }
        }
    }

    /// Creates a flag file for the given session, signaling CTO is active.
    @discardableResult
    static func createFlag(sessionID: String) -> Bool {
        let path = flagDirectory.appendingPathComponent(sessionID)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            fm.createFile(atPath: path.path, contents: nil)
            Log.trace("CTOFlagManager: created flag for session \(sessionID)")
            return true
        }
        return false
    }

    /// Removes the flag file for the given session, signaling CTO is inactive.
    @discardableResult
    static func removeFlag(sessionID: String) -> Bool {
        let path = flagDirectory.appendingPathComponent(sessionID)
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) {
            do {
                try fm.removeItem(at: path)
                Log.trace("CTOFlagManager: removed flag for session \(sessionID)")
                return true
            } catch {
                Log.error("CTOFlagManager: failed to remove flag for \(sessionID): \(error)")
                return false
            }
        }
        return false
    }

    /// Removes all flag files. Called on app quit and mode changes.
    @discardableResult
    static func removeAllFlags() -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: flagDirectory.path) else { return 0 }
        guard let contents = try? fm.contentsOfDirectory(atPath: flagDirectory.path) else {
            Log.error("CTOFlagManager: failed to list flag directory")
            return 0
        }
        var removed = 0
        for file in contents {
            do {
                try fm.removeItem(atPath: flagDirectory.appendingPathComponent(file).path)
                removed += 1
            } catch {
                Log.error("CTOFlagManager: failed to remove flag \(file): \(error)")
            }
        }
        if removed > 0 {
            Log.info("CTOFlagManager: cleared \(removed) flag file(s)")
        }
        return removed
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
    ) -> CTOFlagDecision {
        let active = shouldBeActive(mode: mode, override: override, isAIActive: isAIActive)
        let previous = isFlagActive(sessionID: sessionID)
        if active {
            return CTOFlagDecision(
                previousState: previous,
                nextState: active,
                changed: createFlag(sessionID: sessionID)
            )
        } else {
            return CTOFlagDecision(
                previousState: previous,
                nextState: active,
                changed: removeFlag(sessionID: sessionID)
            )
        }
    }
}
