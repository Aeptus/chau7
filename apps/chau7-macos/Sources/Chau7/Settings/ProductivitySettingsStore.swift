import Foundation

/// Owns the productivity feature cluster: broadcast input, clipboard history,
/// bookmarks, snippets, copy-on-select, line timestamps, last-command badge,
/// cmd-click paths, option-click cursor, auto tab themes, and custom AI
/// detection rules.
///
/// Extracted from `FeatureSettings` (which forwards) following the
/// store-behind-facade pattern of the other settings domains.
@Observable
final class ProductivitySettingsStore {

    enum Keys {
        /// F05
        static let autoTabTheme = "feature.autoTabTheme"
        /// F18
        static let copyOnSelect = "feature.copyOnSelect"
        // F19
        static let lineTimestamps = "feature.lineTimestamps"
        static let timestampFormat = "feature.timestampFormat"
        /// F20
        static let lastCommandBadge = "feature.lastCommandBadge"
        // F03
        static let cmdClickPaths = "feature.cmdClickPaths"
        static let cmdClickOpensInternalEditor = "feature.cmdClickOpensInternalEditor"
        static let optionClickCursor = "feature.optionClickCursor"
        static let defaultEditor = "feature.defaultEditor"
        /// Custom AI Detection
        static let customAIDetectionRules = "ai.customDetectionRules"
        /// F13
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
    }

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - F05: Auto Tab Themes by AI Model

    var isAutoTabThemeEnabled: Bool {
        didSet { defaults.set(isAutoTabThemeEnabled, forKey: Keys.autoTabTheme) }
    }

    // MARK: - F18: Copy-on-Select

    var isCopyOnSelectEnabled: Bool {
        didSet { defaults.set(isCopyOnSelectEnabled, forKey: Keys.copyOnSelect) }
    }

    // MARK: - F19: Line Timestamps

    var isLineTimestampsEnabled: Bool {
        didSet { defaults.set(isLineTimestampsEnabled, forKey: Keys.lineTimestamps) }
    }

    var timestampFormat: String {
        didSet { defaults.set(timestampFormat, forKey: Keys.timestampFormat) }
    }

    // MARK: - F20: Last Command Badge

    var isLastCommandBadgeEnabled: Bool {
        didSet { defaults.set(isLastCommandBadgeEnabled, forKey: Keys.lastCommandBadge) }
    }

    // MARK: - F03: Cmd+Click Paths

    var isCmdClickPathsEnabled: Bool {
        didSet { defaults.set(isCmdClickPathsEnabled, forKey: Keys.cmdClickPaths) }
    }

    /// Open Cmd+Click file paths in internal editor (right panel) instead of external editor
    var cmdClickOpensInternalEditor: Bool {
        didSet { defaults.set(cmdClickOpensInternalEditor, forKey: Keys.cmdClickOpensInternalEditor) }
    }

    /// Option+click to position cursor in the command line (like iTerm2)
    var isOptionClickCursorEnabled: Bool {
        didSet { defaults.set(isOptionClickCursorEnabled, forKey: Keys.optionClickCursor) }
    }

    var defaultEditor: String {
        didSet { defaults.set(defaultEditor, forKey: Keys.defaultEditor) }
    }

    // MARK: - Custom AI Detection

    var customAIDetectionRules: [CustomAIDetectionRule] {
        didSet {
            if let data = JSONOperations.encode(customAIDetectionRules, context: "customAIDetectionRules") {
                defaults.set(data, forKey: Keys.customAIDetectionRules)
            }
        }
    }

    // MARK: - F13: Broadcast Input

    var isBroadcastEnabled: Bool {
        didSet { defaults.set(isBroadcastEnabled, forKey: Keys.broadcastEnabled) }
    }

    // MARK: - F16: Clipboard History

    var isClipboardHistoryEnabled: Bool {
        didSet { defaults.set(isClipboardHistoryEnabled, forKey: Keys.clipboardHistory) }
    }

    var clipboardHistoryMaxItems: Int {
        didSet {
            let clamped = max(1, min(clipboardHistoryMaxItems, 1000))
            if clipboardHistoryMaxItems != clamped {
                clipboardHistoryMaxItems = clamped
                return
            }
            defaults.set(clipboardHistoryMaxItems, forKey: Keys.clipboardHistoryMax)
        }
    }

    // MARK: - F17: Bookmarks

    var isBookmarksEnabled: Bool {
        didSet { defaults.set(isBookmarksEnabled, forKey: Keys.bookmarksEnabled) }
    }

    var maxBookmarksPerTab: Int {
        didSet {
            let clamped = max(1, min(maxBookmarksPerTab, 200))
            if maxBookmarksPerTab != clamped {
                maxBookmarksPerTab = clamped
                return
            }
            defaults.set(maxBookmarksPerTab, forKey: Keys.maxBookmarks)
        }
    }

    // MARK: - F21: Snippets

    var isSnippetsEnabled: Bool {
        didSet { defaults.set(isSnippetsEnabled, forKey: Keys.snippetsEnabled) }
    }

    var isRepoSnippetsEnabled: Bool {
        didSet { defaults.set(isRepoSnippetsEnabled, forKey: Keys.repoSnippetsEnabled) }
    }

    var repoSnippetPath: String {
        didSet {
            let trimmed = repoSnippetPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if repoSnippetPath != trimmed {
                repoSnippetPath = trimmed
                return
            }
            defaults.set(repoSnippetPath, forKey: Keys.repoSnippetPath)
        }
    }

    var snippetInsertMode: String {
        didSet { defaults.set(snippetInsertMode, forKey: Keys.snippetInsertMode) }
    }

    var snippetPlaceholdersEnabled: Bool {
        didSet { defaults.set(snippetPlaceholdersEnabled, forKey: Keys.snippetPlaceholders) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // F05: Auto Tab Theme (default: enabled)
        self.isAutoTabThemeEnabled = defaults.object(forKey: Keys.autoTabTheme) as? Bool ?? true

        // F18: Copy on Select (default: enabled)
        self.isCopyOnSelectEnabled = defaults.object(forKey: Keys.copyOnSelect) as? Bool ?? true

        // F19: Line Timestamps (default: disabled)
        self.isLineTimestampsEnabled = defaults.object(forKey: Keys.lineTimestamps) as? Bool ?? false
        self.timestampFormat = defaults.string(forKey: Keys.timestampFormat) ?? "HH:mm:ss"

        // F20: Last Command Badge (default: enabled)
        self.isLastCommandBadgeEnabled = defaults.object(forKey: Keys.lastCommandBadge) as? Bool ?? true

        // F03: Cmd+Click Paths (default: enabled)
        self.isCmdClickPathsEnabled = defaults.object(forKey: Keys.cmdClickPaths) as? Bool ?? true
        self.cmdClickOpensInternalEditor = defaults.object(forKey: Keys.cmdClickOpensInternalEditor) as? Bool ?? true
        self.isOptionClickCursorEnabled = defaults.object(forKey: Keys.optionClickCursor) as? Bool ?? true
        self.defaultEditor = defaults.string(forKey: Keys.defaultEditor) ?? "" // Empty = use $EDITOR or system default

        // Custom AI Detection
        if let data = defaults.data(forKey: Keys.customAIDetectionRules),
           let rules = JSONOperations.decode([CustomAIDetectionRule].self, from: data, context: "customAIDetectionRules") {
            self.customAIDetectionRules = rules
        } else {
            self.customAIDetectionRules = []
        }

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
        self.repoSnippetPath = defaults.string(forKey: Keys.repoSnippetPath) ?? ".chau7/snippets"
        self.snippetInsertMode = defaults.string(forKey: Keys.snippetInsertMode) ?? "expand"
        self.snippetPlaceholdersEnabled = defaults.object(forKey: Keys.snippetPlaceholders) as? Bool ?? true
    }

    /// Reset by deriving from the loader (single source of defaults).
    func resetToDefaults() {
        for key in [
            Keys.autoTabTheme, Keys.copyOnSelect, Keys.lineTimestamps,
            Keys.timestampFormat, Keys.lastCommandBadge, Keys.cmdClickPaths,
            Keys.cmdClickOpensInternalEditor, Keys.optionClickCursor,
            Keys.defaultEditor, Keys.customAIDetectionRules,
            Keys.broadcastEnabled, Keys.clipboardHistory,
            Keys.clipboardHistoryMax, Keys.bookmarksEnabled, Keys.maxBookmarks,
            Keys.snippetsEnabled, Keys.repoSnippetsEnabled,
            Keys.repoSnippetPath, Keys.snippetInsertMode,
            Keys.snippetPlaceholders
        ] {
            defaults.removeObject(forKey: key)
        }
        let fresh = ProductivitySettingsStore(defaults: defaults)
        isAutoTabThemeEnabled = fresh.isAutoTabThemeEnabled
        isCopyOnSelectEnabled = fresh.isCopyOnSelectEnabled
        isLineTimestampsEnabled = fresh.isLineTimestampsEnabled
        timestampFormat = fresh.timestampFormat
        isLastCommandBadgeEnabled = fresh.isLastCommandBadgeEnabled
        isCmdClickPathsEnabled = fresh.isCmdClickPathsEnabled
        cmdClickOpensInternalEditor = fresh.cmdClickOpensInternalEditor
        isOptionClickCursorEnabled = fresh.isOptionClickCursorEnabled
        defaultEditor = fresh.defaultEditor
        customAIDetectionRules = fresh.customAIDetectionRules
        isBroadcastEnabled = fresh.isBroadcastEnabled
        isClipboardHistoryEnabled = fresh.isClipboardHistoryEnabled
        clipboardHistoryMaxItems = fresh.clipboardHistoryMaxItems
        isBookmarksEnabled = fresh.isBookmarksEnabled
        maxBookmarksPerTab = fresh.maxBookmarksPerTab
        isSnippetsEnabled = fresh.isSnippetsEnabled
        isRepoSnippetsEnabled = fresh.isRepoSnippetsEnabled
        repoSnippetPath = fresh.repoSnippetPath
        snippetInsertMode = fresh.snippetInsertMode
        snippetPlaceholdersEnabled = fresh.snippetPlaceholdersEnabled
    }
}
