import Foundation
import AppKit

// MARK: - Feature Settings (Centralized configuration for all features)

/// Centralized feature flags and settings for Chau7
/// All features can be toggled in Settings and values are persisted in UserDefaults
final class FeatureSettings: ObservableObject {
    static let shared = FeatureSettings()

    // MARK: - F05: Auto Tab Themes by AI Model

    @Published var isAutoTabThemeEnabled: Bool {
        didSet { UserDefaults.standard.set(isAutoTabThemeEnabled, forKey: Keys.autoTabTheme) }
    }

    /// AI model to tab color mapping
    static let aiModelColors: [String: TabColor] = [
        "claude": .purple,
        "claude-code": .purple,
        "claude-cli": .purple,
        "codex": .green,
        "openai": .green,
        "gpt": .green,
        "gemini": .blue,
        "bard": .blue,
        "copilot": .orange,
        "cursor": .teal,
        "aider": .pink,
        "continue": .yellow
    ]

    // MARK: - F18: Copy-on-Select

    @Published var isCopyOnSelectEnabled: Bool {
        didSet { UserDefaults.standard.set(isCopyOnSelectEnabled, forKey: Keys.copyOnSelect) }
    }

    // MARK: - F19: Line Timestamps

    @Published var isLineTimestampsEnabled: Bool {
        didSet { UserDefaults.standard.set(isLineTimestampsEnabled, forKey: Keys.lineTimestamps) }
    }

    @Published var timestampFormat: String {
        didSet { UserDefaults.standard.set(timestampFormat, forKey: Keys.timestampFormat) }
    }

    // MARK: - F20: Last Command Badge

    @Published var isLastCommandBadgeEnabled: Bool {
        didSet { UserDefaults.standard.set(isLastCommandBadgeEnabled, forKey: Keys.lastCommandBadge) }
    }

    // MARK: - F03: Cmd+Click Paths

    @Published var isCmdClickPathsEnabled: Bool {
        didSet { UserDefaults.standard.set(isCmdClickPathsEnabled, forKey: Keys.cmdClickPaths) }
    }

    @Published var defaultEditor: String {
        didSet { UserDefaults.standard.set(defaultEditor, forKey: Keys.defaultEditor) }
    }

    // MARK: - F04: Quick Dropdown Terminal

    @Published var isDropdownEnabled: Bool {
        didSet { UserDefaults.standard.set(isDropdownEnabled, forKey: Keys.dropdownEnabled) }
    }

    @Published var dropdownHotkey: String {
        didSet { UserDefaults.standard.set(dropdownHotkey, forKey: Keys.dropdownHotkey) }
    }

    @Published var dropdownHeight: Double {
        didSet {
            let clamped = max(0.1, min(dropdownHeight, 1.0))
            if dropdownHeight != clamped {
                dropdownHeight = clamped
                return
            }
            UserDefaults.standard.set(dropdownHeight, forKey: Keys.dropdownHeight)
        }
    }

    // MARK: - F13: Broadcast Input

    @Published var isBroadcastEnabled: Bool {
        didSet { UserDefaults.standard.set(isBroadcastEnabled, forKey: Keys.broadcastEnabled) }
    }

    // MARK: - F16: Clipboard History

    @Published var isClipboardHistoryEnabled: Bool {
        didSet { UserDefaults.standard.set(isClipboardHistoryEnabled, forKey: Keys.clipboardHistory) }
    }

    @Published var clipboardHistoryMaxItems: Int {
        didSet {
            let clamped = max(1, min(clipboardHistoryMaxItems, 500))
            if clipboardHistoryMaxItems != clamped {
                clipboardHistoryMaxItems = clamped
                return
            }
            UserDefaults.standard.set(clipboardHistoryMaxItems, forKey: Keys.clipboardHistoryMax)
        }
    }

    // MARK: - F17: Bookmarks

    @Published var isBookmarksEnabled: Bool {
        didSet { UserDefaults.standard.set(isBookmarksEnabled, forKey: Keys.bookmarksEnabled) }
    }

    @Published var maxBookmarksPerTab: Int {
        didSet {
            let clamped = max(1, min(maxBookmarksPerTab, 200))
            if maxBookmarksPerTab != clamped {
                maxBookmarksPerTab = clamped
                return
            }
            UserDefaults.standard.set(maxBookmarksPerTab, forKey: Keys.maxBookmarks)
        }
    }

    // MARK: - F21: Snippets

    @Published var isSnippetsEnabled: Bool {
        didSet { UserDefaults.standard.set(isSnippetsEnabled, forKey: Keys.snippetsEnabled) }
    }

    @Published var isRepoSnippetsEnabled: Bool {
        didSet { UserDefaults.standard.set(isRepoSnippetsEnabled, forKey: Keys.repoSnippetsEnabled) }
    }

    @Published var repoSnippetPath: String {
        didSet {
            let trimmed = repoSnippetPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if repoSnippetPath != trimmed {
                repoSnippetPath = trimmed
                return
            }
            UserDefaults.standard.set(repoSnippetPath, forKey: Keys.repoSnippetPath)
        }
    }

    @Published var snippetInsertMode: String {
        didSet { UserDefaults.standard.set(snippetInsertMode, forKey: Keys.snippetInsertMode) }
    }

    @Published var snippetPlaceholdersEnabled: Bool {
        didSet { UserDefaults.standard.set(snippetPlaceholdersEnabled, forKey: Keys.snippetPlaceholders) }
    }

    // MARK: - F08: Smart Syntax Highlighting

    @Published var isSyntaxHighlightEnabled: Bool {
        didSet { UserDefaults.standard.set(isSyntaxHighlightEnabled, forKey: Keys.syntaxHighlight) }
    }

    @Published var isClickableURLsEnabled: Bool {
        didSet { UserDefaults.standard.set(isClickableURLsEnabled, forKey: Keys.clickableURLs) }
    }

    @Published var isJSONPrettyPrintEnabled: Bool {
        didSet { UserDefaults.standard.set(isJSONPrettyPrintEnabled, forKey: Keys.jsonPrettyPrint) }
    }

    // MARK: - F07: Semantic Scrollback Search

    @Published var isSemanticSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(isSemanticSearchEnabled, forKey: Keys.semanticSearch) }
    }

    // MARK: - F02: Split Panes

    @Published var isSplitPanesEnabled: Bool {
        didSet { UserDefaults.standard.set(isSplitPanesEnabled, forKey: Keys.splitPanes) }
    }

    // MARK: - F11: Keybindings

    @Published var keybindingPreset: String {
        didSet { UserDefaults.standard.set(keybindingPreset, forKey: Keys.keybindingPreset) }
    }

    // MARK: - Overlay Positions

    @Published var overlayPositionsVersion: Int = 0

    // MARK: - General Terminal Settings

    @Published var cursorStyle: String {
        didSet { UserDefaults.standard.set(cursorStyle, forKey: Keys.cursorStyle) }
    }

    @Published var cursorBlink: Bool {
        didSet { UserDefaults.standard.set(cursorBlink, forKey: Keys.cursorBlink) }
    }

    @Published var scrollbackLines: Int {
        didSet {
            let clamped = max(100, min(scrollbackLines, 100_000))
            if scrollbackLines != clamped {
                scrollbackLines = clamped
                return
            }
            UserDefaults.standard.set(scrollbackLines, forKey: Keys.scrollbackLines)
        }
    }

    @Published var bellEnabled: Bool {
        didSet { UserDefaults.standard.set(bellEnabled, forKey: Keys.bellEnabled) }
    }

    @Published var bellSound: String {
        didSet { UserDefaults.standard.set(bellSound, forKey: Keys.bellSound) }
    }

    @Published var defaultStartDirectory: String {
        didSet {
            let trimmed = defaultStartDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.path
                : trimmed
            if defaultStartDirectory != normalized {
                defaultStartDirectory = normalized
                return
            }
            UserDefaults.standard.set(defaultStartDirectory, forKey: Keys.defaultStartDirectory)
        }
    }

    // MARK: - Keys

    private enum Keys {
        // F05
        static let autoTabTheme = "feature.autoTabTheme"
        // F18
        static let copyOnSelect = "feature.copyOnSelect"
        // F19
        static let lineTimestamps = "feature.lineTimestamps"
        static let timestampFormat = "feature.timestampFormat"
        // F20
        static let lastCommandBadge = "feature.lastCommandBadge"
        // F03
        static let cmdClickPaths = "feature.cmdClickPaths"
        static let defaultEditor = "feature.defaultEditor"
        // F04
        static let dropdownEnabled = "feature.dropdownEnabled"
        static let dropdownHotkey = "feature.dropdownHotkey"
        static let dropdownHeight = "feature.dropdownHeight"
        // F13
        static let broadcastEnabled = "feature.broadcastEnabled"
        // F16
        static let clipboardHistory = "feature.clipboardHistory"
        static let clipboardHistoryMax = "feature.clipboardHistoryMax"
        // F17
        static let bookmarksEnabled = "feature.bookmarksEnabled"
        static let maxBookmarks = "feature.maxBookmarks"
        // F21
        static let snippetsEnabled = "feature.snippetsEnabled"
        static let repoSnippetsEnabled = "feature.repoSnippetsEnabled"
        static let repoSnippetPath = "feature.repoSnippetPath"
        static let snippetInsertMode = "feature.snippetInsertMode"
        static let snippetPlaceholders = "feature.snippetPlaceholders"
        // F08
        static let syntaxHighlight = "feature.syntaxHighlight"
        static let clickableURLs = "feature.clickableURLs"
        static let jsonPrettyPrint = "feature.jsonPrettyPrint"
        // F07
        static let semanticSearch = "feature.semanticSearch"
        // F02
        static let splitPanes = "feature.splitPanes"
        // F11
        static let keybindingPreset = "feature.keybindingPreset"
        // General
        static let cursorStyle = "terminal.cursorStyle"
        static let cursorBlink = "terminal.cursorBlink"
        static let scrollbackLines = "terminal.scrollbackLines"
        static let bellEnabled = "terminal.bellEnabled"
        static let bellSound = "terminal.bellSound"
        static let defaultStartDirectory = "terminal.defaultStartDirectory"
        static let overlayPositionsMap = "overlay.positions.map"
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // F05: Auto Tab Theme (default: enabled)
        self.isAutoTabThemeEnabled = defaults.object(forKey: Keys.autoTabTheme) as? Bool ?? true

        // F18: Copy on Select (default: disabled)
        self.isCopyOnSelectEnabled = defaults.object(forKey: Keys.copyOnSelect) as? Bool ?? false

        // F19: Line Timestamps (default: disabled)
        self.isLineTimestampsEnabled = defaults.object(forKey: Keys.lineTimestamps) as? Bool ?? false
        self.timestampFormat = defaults.string(forKey: Keys.timestampFormat) ?? "HH:mm:ss"

        // F20: Last Command Badge (default: enabled)
        self.isLastCommandBadgeEnabled = defaults.object(forKey: Keys.lastCommandBadge) as? Bool ?? true

        // F03: Cmd+Click Paths (default: enabled)
        self.isCmdClickPathsEnabled = defaults.object(forKey: Keys.cmdClickPaths) as? Bool ?? true
        self.defaultEditor = defaults.string(forKey: Keys.defaultEditor) ?? ""  // Empty = use $EDITOR or system default

        // F04: Dropdown (default: disabled)
        self.isDropdownEnabled = defaults.object(forKey: Keys.dropdownEnabled) as? Bool ?? false
        self.dropdownHotkey = defaults.string(forKey: Keys.dropdownHotkey) ?? "ctrl+`"
        self.dropdownHeight = defaults.object(forKey: Keys.dropdownHeight) as? Double ?? 0.4  // 40% of screen

        // F13: Broadcast (default: disabled)
        self.isBroadcastEnabled = defaults.object(forKey: Keys.broadcastEnabled) as? Bool ?? false

        // F16: Clipboard History (default: enabled)
        self.isClipboardHistoryEnabled = defaults.object(forKey: Keys.clipboardHistory) as? Bool ?? true
        self.clipboardHistoryMaxItems = defaults.object(forKey: Keys.clipboardHistoryMax) as? Int ?? 50

        // F17: Bookmarks (default: enabled)
        self.isBookmarksEnabled = defaults.object(forKey: Keys.bookmarksEnabled) as? Bool ?? true
        self.maxBookmarksPerTab = defaults.object(forKey: Keys.maxBookmarks) as? Int ?? 20

        // F21: Snippets (default: enabled)
        self.isSnippetsEnabled = defaults.object(forKey: Keys.snippetsEnabled) as? Bool ?? true
        self.isRepoSnippetsEnabled = defaults.object(forKey: Keys.repoSnippetsEnabled) as? Bool ?? true
        self.repoSnippetPath = defaults.string(forKey: Keys.repoSnippetPath) ?? ".chau7/snippets.json"
        self.snippetInsertMode = defaults.string(forKey: Keys.snippetInsertMode) ?? "expand"
        self.snippetPlaceholdersEnabled = defaults.object(forKey: Keys.snippetPlaceholders) as? Bool ?? true

        // F08: Syntax Highlighting (default: enabled)
        self.isSyntaxHighlightEnabled = defaults.object(forKey: Keys.syntaxHighlight) as? Bool ?? true
        self.isClickableURLsEnabled = defaults.object(forKey: Keys.clickableURLs) as? Bool ?? true
        self.isJSONPrettyPrintEnabled = defaults.object(forKey: Keys.jsonPrettyPrint) as? Bool ?? false

        // F07: Semantic Search (default: disabled - requires shell integration)
        self.isSemanticSearchEnabled = defaults.object(forKey: Keys.semanticSearch) as? Bool ?? false

        // F02: Split Panes (default: enabled)
        self.isSplitPanesEnabled = defaults.object(forKey: Keys.splitPanes) as? Bool ?? true

        // F11: Keybindings (default: "default")
        self.keybindingPreset = defaults.string(forKey: Keys.keybindingPreset) ?? "default"

        // General Terminal Settings
        self.cursorStyle = defaults.string(forKey: Keys.cursorStyle) ?? "block"
        self.cursorBlink = defaults.object(forKey: Keys.cursorBlink) as? Bool ?? true
        self.scrollbackLines = defaults.object(forKey: Keys.scrollbackLines) as? Int ?? 10000
        self.bellEnabled = defaults.object(forKey: Keys.bellEnabled) as? Bool ?? true
        self.bellSound = defaults.string(forKey: Keys.bellSound) ?? "default"
        self.defaultStartDirectory = defaults.string(forKey: Keys.defaultStartDirectory) ?? home
    }

    func overlayOffset(for id: String, workspace: String?) -> CGSize {
        let key = overlayWorkspaceKey(workspace)
        let store = overlayPositionsStore()
        guard let workspaceStore = store[key],
              let entry = workspaceStore[id],
              let x = entry["x"],
              let y = entry["y"] else {
            return .zero
        }
        return CGSize(width: x, height: y)
    }

    func setOverlayOffset(_ offset: CGSize, for id: String, workspace: String?) {
        let key = overlayWorkspaceKey(workspace)
        var store = overlayPositionsStore()
        var workspaceStore = store[key] ?? [:]
        workspaceStore[id] = ["x": offset.width, "y": offset.height]
        store[key] = workspaceStore
        saveOverlayPositionsStore(store)
    }

    func resetOverlayOffsets(workspace: String? = nil) {
        var store = overlayPositionsStore()
        if let workspace {
            store.removeValue(forKey: overlayWorkspaceKey(workspace))
        } else {
            store.removeAll()
        }
        saveOverlayPositionsStore(store)
    }

    private func overlayPositionsStore() -> [String: [String: [String: Double]]] {
        let defaults = UserDefaults.standard
        guard let stored = defaults.dictionary(forKey: Keys.overlayPositionsMap) else { return [:] }
        var result: [String: [String: [String: Double]]] = [:]
        for (workspaceKey, value) in stored {
            guard let overlayDict = value as? [String: Any] else { continue }
            var overlayStore: [String: [String: Double]] = [:]
            for (overlayID, coordsValue) in overlayDict {
                if let coords = coordsValue as? [String: Double] {
                    overlayStore[overlayID] = coords
                }
            }
            result[workspaceKey] = overlayStore
        }
        return result
    }

    private func saveOverlayPositionsStore(_ store: [String: [String: [String: Double]]]) {
        UserDefaults.standard.set(store, forKey: Keys.overlayPositionsMap)
        overlayPositionsVersion += 1
    }

    private func overlayWorkspaceKey(_ workspace: String?) -> String {
        let base = workspace?.trimmingCharacters(in: .whitespacesAndNewlines)
        return base?.isEmpty == false ? base! : "global"
    }
}
