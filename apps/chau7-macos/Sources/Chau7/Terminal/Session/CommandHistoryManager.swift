import Foundation
import Chau7Core

/// Manages per-tab and global command history for arrow-key navigation.
/// - Arrow ↑/↓: per-tab history
/// - Option+Arrow ↑/↓: global (cross-tab) history
///
/// Security: Commands entered during password prompts (echo disabled) are
/// never recorded. Commands containing inline secrets are also filtered.
///
/// All access must be on the main queue (callers are UI event handlers
/// and terminal session callbacks which both run on main).
final class CommandHistoryManager {
    static let shared = CommandHistoryManager()

    private let maxPerTab = 500
    private let maxGlobal = 2000

    /// Per-tab history: tabID → [oldest … newest]
    private var tabHistory: [String: [String]] = [:]
    /// Global history: [oldest … newest]
    private var globalHistory: [String] = []

    // Navigation cursors (-1 = not navigating, 0 = most recent)
    private var tabCursors: [String: Int] = [:]
    private var globalCursor: Int = -1

    private init() {}

    // MARK: - Recording

    /// Records a command in history.
    /// - Parameters:
    ///   - command: The command text
    ///   - tabID: Tab identifier for per-tab history
    ///   - isSensitive: If true, the command was entered during a password prompt
    ///     or other echo-disabled context and should NOT be recorded.
    func recordCommand(_ command: String, tabID: String, isSensitive: Bool = false) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Security: never record commands entered during password prompts
        if isSensitive {
            Log.trace("CommandHistoryManager: Skipping sensitive command (echo disabled)")
            // Still reset cursors so navigation state is clean
            tabCursors[tabID] = -1
            globalCursor = -1
            return
        }

        // Security: filter commands containing inline secrets
        if SensitiveInputGuard.containsInlineSecrets(trimmed) {
            Log.trace("CommandHistoryManager: Skipping command with inline secrets")
            tabCursors[tabID] = -1
            globalCursor = -1
            return
        }

        // Per-tab: skip consecutive duplicates
        if tabHistory[tabID]?.last != trimmed {
            tabHistory[tabID, default: []].append(trimmed)
            if tabHistory[tabID]!.count > maxPerTab {
                tabHistory[tabID]!.removeFirst()
            }
        }

        // Global: skip consecutive duplicates
        if globalHistory.last != trimmed {
            globalHistory.append(trimmed)
            if globalHistory.count > maxGlobal {
                globalHistory.removeFirst()
            }
        }

        // Reset cursors on new command
        tabCursors[tabID] = -1
        globalCursor = -1
    }

    // MARK: - Per-Tab Navigation

    func previousInTab(_ tabID: String) -> String? {
        guard let history = tabHistory[tabID], !history.isEmpty else { return nil }
        let cursor = tabCursors[tabID] ?? -1
        let next = cursor + 1
        guard next < history.count else { return nil }
        tabCursors[tabID] = next
        return history[history.count - 1 - next]
    }

    func nextInTab(_ tabID: String) -> String? {
        let cursor = tabCursors[tabID] ?? -1
        guard cursor >= 0 else { return nil } // Not navigating — do nothing
        if cursor == 0 {
            tabCursors[tabID] = -1
            return "" // Back to fresh prompt
        }
        let newCursor = cursor - 1
        tabCursors[tabID] = newCursor
        guard let history = tabHistory[tabID] else { return nil }
        return history[history.count - 1 - newCursor]
    }

    // MARK: - Global Navigation

    func previousGlobal() -> String? {
        guard !globalHistory.isEmpty else { return nil }
        let next = globalCursor + 1
        guard next < globalHistory.count else { return nil }
        globalCursor = next
        return globalHistory[globalHistory.count - 1 - next]
    }

    func nextGlobal() -> String? {
        guard globalCursor >= 0 else { return nil } // Not navigating — do nothing
        if globalCursor == 0 {
            globalCursor = -1
            return "" // Back to fresh prompt
        }
        let newCursor = globalCursor - 1
        globalCursor = newCursor
        return globalHistory[globalHistory.count - 1 - newCursor]
    }

    // MARK: - Cursor Reset

    func resetCursor(tabID: String) {
        tabCursors[tabID] = -1
    }

    func resetGlobalCursor() {
        globalCursor = -1
    }

    func resetAllCursors(tabID: String) {
        tabCursors[tabID] = -1
        globalCursor = -1
    }

    func removeTab(_ tabID: String) {
        tabHistory.removeValue(forKey: tabID)
        tabCursors.removeValue(forKey: tabID)
    }
}
