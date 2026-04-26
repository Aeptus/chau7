import Foundation
import Chau7Core

/// Manages per-tab and global command history for arrow-key navigation.
/// - Arrow ↑/↓: per-tab history
/// - Option+Arrow ↑/↓: global (cross-tab) history
///
/// In-memory caches drive the navigation cursor. When a `PersistentHistoryStore`
/// is wired in (the production singleton wires `PersistentHistoryStore.shared`),
/// recordCommand also writes through to disk so history survives app restart.
///
/// Security: Commands entered during password prompts (echo disabled) are
/// never recorded. Commands containing inline secrets are also filtered.
/// Sensitive commands are dropped at the start of recordCommand and never
/// reach the persistent store.
///
/// All access must be on the main queue (callers are UI event handlers
/// and terminal session callbacks which both run on main).
final class CommandHistoryManager {
    static let shared = CommandHistoryManager(persistentStore: PersistentHistoryStore.shared)

    private let maxPerTab = 500
    private let maxGlobal = 2000

    /// Per-tab history: tabID → [oldest … newest]
    private var tabHistory: [String: [String]] = [:]
    /// Global history: [oldest … newest]
    private var globalHistory: [String] = []

    // Navigation cursors (-1 = not navigating, 0 = most recent)
    private var tabCursors: [String: Int] = [:]
    private var globalCursor: Int = -1

    /// Optional persistent backing store. When non-nil and the
    /// `feature.persistentHistory` user default is enabled, recordCommand
    /// writes through to it. Tests inject `nil` (or an in-memory store via
    /// `PersistentHistoryStore(path: ":memory:")`) for isolation from the
    /// shared on-disk database.
    private let persistentStore: PersistentHistoryStore?

    init(persistentStore: PersistentHistoryStore?) {
        self.persistentStore = persistentStore
    }

    // MARK: - Recording

    /// Records a command in history.
    /// - Parameters:
    ///   - command: The command text
    ///   - tabID: Tab identifier for per-tab history (preferably the
    ///     persistent OverlayTab.id so entries survive restoration)
    ///   - isSensitive: If true, the command was entered during a password prompt
    ///     or other echo-disabled context and is dropped from BOTH the in-
    ///     memory caches and the persistent store.
    ///   - directory: Working directory at the time of execution; persisted
    ///     to the store for repo-scoped queries. Optional — pure in-memory
    ///     callers (tests, edge cases) can omit it.
    ///   - shell: Shell that ran the command (e.g. "zsh", "bash"). Same
    ///     optionality semantics as `directory`.
    func recordCommand(
        _ command: String,
        tabID: String,
        isSensitive: Bool = false,
        directory: String? = nil,
        shell: String? = nil
    ) {
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

        // Persistent write-through. Gated by the `feature.persistentHistory`
        // user default (default true; the Settings UI exposes this toggle as
        // "Enable Persistent History"). Sensitive + secret commands are
        // already filtered above and never reach this point.
        if let store = persistentStore, persistentHistoryEnabled() {
            store.insert(HistoryRecord(
                command: trimmed,
                directory: directory,
                shell: shell,
                tabID: tabID
            ))
        }
    }

    private func persistentHistoryEnabled() -> Bool {
        // UserDefaults stores `nil` when the user hasn't toggled the setting;
        // treat that as enabled (matches HistorySettingsView's default).
        UserDefaults.standard.object(forKey: "feature.persistentHistory") as? Bool ?? true
    }

    // MARK: - Per-Tab Navigation

    func previousInTab(_ tabID: String) -> String? {
        bootstrapTabIfNeeded(tabID)
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
        bootstrapGlobalIfNeeded()
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

    // MARK: - Bootstrap from PersistentHistoryStore

    /// Tabs we've already attempted to bootstrap from disk this launch.
    /// Tracks the attempt rather than the outcome — a tab with a genuinely
    /// empty persisted history (zero rows) shouldn't re-query the DB on
    /// every Up arrow press.
    private var bootstrappedTabs: Set<String> = []
    private var bootstrappedGlobal = false

    private func bootstrapTabIfNeeded(_ tabID: String) {
        guard let store = persistentStore, persistentHistoryEnabled() else { return }
        guard !bootstrappedTabs.contains(tabID) else { return }
        bootstrappedTabs.insert(tabID)

        // Only seed when the in-memory cache is empty for this tab. Once
        // recordCommand has populated the cache during the current launch,
        // we've already filtered for sensitivity and dedup — replacing it
        // with a raw DB read would be a regression.
        guard tabHistory[tabID]?.isEmpty ?? true else { return }

        let rows = store.recentForTab(tabID, limit: maxPerTab)
        guard !rows.isEmpty else { return }

        let commands = Self.normalizeForArrowNavigation(rows)
        guard !commands.isEmpty else { return }
        tabHistory[tabID] = commands
        Log.info("CommandHistoryManager: bootstrapped tab \(tabID) with \(commands.count) entries from persistent store")
    }

    private func bootstrapGlobalIfNeeded() {
        guard let store = persistentStore, persistentHistoryEnabled() else { return }
        guard !bootstrappedGlobal else { return }
        bootstrappedGlobal = true

        guard globalHistory.isEmpty else { return }

        let rows = store.recent(limit: maxGlobal)
        guard !rows.isEmpty else { return }

        let commands = Self.normalizeForArrowNavigation(rows)
        guard !commands.isEmpty else { return }
        globalHistory = commands
        Log.info("CommandHistoryManager: bootstrapped global history with \(commands.count) entries from persistent store")
    }

    /// Convert newest-first persisted rows into the oldest-first, dedup'd
    /// shape the in-memory arrow-key cache expects.
    ///
    /// The persistent store keeps every recorded command (audit trail +
    /// frequency analytics expect it), but recordCommand's in-memory cache
    /// drops consecutive duplicates so Up arrow doesn't yield "ls, ls, ls"
    /// when the user ran the same command three times. Bootstrap must
    /// apply the same dedup; otherwise after restart the user would see
    /// every duplicate the live session would have hidden.
    ///
    /// Also defensively re-filters inline secrets in case the persistence
    /// guard ever drifts from the recordCommand guard.
    static func normalizeForArrowNavigation(_ rows: [HistoryRecord]) -> [String] {
        // rows are newest-first; reverse to oldest-first so the dedup walk
        // matches the order recordCommand would have appended them.
        var result: [String] = []
        for record in rows.reversed() {
            let trimmed = record.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !SensitiveInputGuard.containsInlineSecrets(trimmed) else { continue }
            // Drop consecutive duplicates — same rule as the in-memory path.
            if result.last == trimmed { continue }
            result.append(trimmed)
        }
        return result
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
        // Allow a re-opened tab with the same OverlayTab.id (e.g., reopen-
        // closed-tab) to re-bootstrap from the persistent store next time
        // arrow-key navigation is invoked.
        bootstrappedTabs.remove(tabID)
    }
}
