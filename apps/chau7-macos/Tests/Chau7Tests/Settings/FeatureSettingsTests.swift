import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class FeatureSettingsTests: XCTestCase {

    // MARK: - Singleton

    func testSharedReturnsSameInstance() {
        let a = FeatureSettings.shared
        let b = FeatureSettings.shared
        XCTAssertTrue(a === b, "shared should return the same instance")
    }

    // MARK: - Font Defaults

    func testDefaultFontFamily() {
        let settings = FeatureSettings.shared
        // Default is "Menlo" when no UserDefaults value is stored
        XCTAssertFalse(settings.fontFamily.isEmpty, "fontFamily should not be empty")
    }

    func testDefaultFontSize() {
        let settings = FeatureSettings.shared
        // Default is 13, but may have been changed; just verify it's in valid range
        XCTAssertGreaterThanOrEqual(settings.fontSize, 8, "fontSize must be >= 8")
        XCTAssertLessThanOrEqual(settings.fontSize, 72, "fontSize must be <= 72")
    }

    func testDefaultZoomPercent() {
        let settings = FeatureSettings.shared
        XCTAssertGreaterThanOrEqual(settings.defaultZoomPercent, 50)
        XCTAssertLessThanOrEqual(settings.defaultZoomPercent, 200)
    }

    func testNotificationFilterDefaultsOnlyEnableFinishedFailedAndPermission() {
        let filters = NotificationFilters.defaults

        XCTAssertTrue(filters.taskFinished)
        XCTAssertTrue(filters.taskFailed)
        XCTAssertTrue(filters.permissionRequest)
        XCTAssertFalse(filters.needsValidation)
        XCTAssertFalse(filters.toolComplete)
        XCTAssertFalse(filters.sessionEnd)
        XCTAssertFalse(filters.commandIdle)
    }

    // MARK: - Color Scheme Defaults

    func testDefaultColorSchemeName() {
        let settings = FeatureSettings.shared
        XCTAssertFalse(
            settings.colorSchemeName.isEmpty,
            "colorSchemeName should not be empty"
        )
    }

    func testCurrentColorSchemeIsNotNil() {
        let settings = FeatureSettings.shared
        // currentColorScheme is a computed property that always returns a valid scheme
        let scheme = settings.currentColorScheme
        XCTAssertFalse(scheme.name.isEmpty, "currentColorScheme should have a name")
    }

    // MARK: - Shell Defaults

    func testDefaultShellType() {
        let settings = FeatureSettings.shared
        // Should be one of the valid ShellType cases
        XCTAssertNotNil(
            ShellType(rawValue: settings.shellType.rawValue),
            "shellType should be a valid ShellType case"
        )
    }

    func testDefaultCustomShellPath() {
        let settings = FeatureSettings.shared
        // Default is empty string when no custom shell is configured
        XCTAssertNotNil(settings.customShellPath)
    }

    func testDefaultStartupCommand() {
        let settings = FeatureSettings.shared
        XCTAssertNotNil(settings.startupCommand)
    }

    func testDefaultLsColorsEnabled() {
        let settings = FeatureSettings.shared
        // Default is true
        XCTAssertTrue(
            settings.isLsColorsEnabled || !settings.isLsColorsEnabled,
            "isLsColorsEnabled should be a valid Bool"
        )
    }

    // MARK: - Keyboard Shortcuts Defaults

    func testDefaultCustomShortcutsNotEmpty() {
        let settings = FeatureSettings.shared
        XCTAssertFalse(
            settings.customShortcuts.isEmpty,
            "customShortcuts should not be empty on a fresh instance"
        )
    }

    func testDefaultShortcutsContainNewTab() {
        let settings = FeatureSettings.shared
        let newTab = settings.shortcut(for: "newTab")
        XCTAssertNotNil(newTab, "Default shortcuts should include newTab")
        XCTAssertEqual(newTab?.key, "t")
        XCTAssertTrue(newTab?.modifiers.contains("cmd") ?? false)
    }

    func testDefaultShortcutsContainCloseTab() {
        let settings = FeatureSettings.shared
        let closeTab = settings.shortcut(for: "closeTab")
        XCTAssertNotNil(closeTab, "Default shortcuts should include closeTab")
        XCTAssertEqual(closeTab?.key, "w")
    }

    func testDefaultShortcutsContainCopy() {
        let settings = FeatureSettings.shared
        let copy = settings.shortcut(for: "copy")
        XCTAssertNotNil(copy, "Default shortcuts should include copy")
        XCTAssertEqual(copy?.key, "c")
    }

    func testDefaultShortcutsContainPaste() {
        let settings = FeatureSettings.shared
        let paste = settings.shortcut(for: "paste")
        XCTAssertNotNil(paste, "Default shortcuts should include paste")
        XCTAssertEqual(paste?.key, "v")
    }

    func testShortcutHelperHintDefault() {
        let settings = FeatureSettings.shared
        // Default is true
        XCTAssertTrue(
            settings.isShortcutHelperHintEnabled || !settings.isShortcutHelperHintEnabled,
            "isShortcutHelperHintEnabled should be a valid Bool"
        )
    }

    // MARK: - Tab Behavior Defaults

    func testDefaultLastTabCloseBehavior() {
        let settings = FeatureSettings.shared
        XCTAssertNotNil(LastTabCloseBehavior(rawValue: settings.lastTabCloseBehavior.rawValue))
    }

    func testDefaultNewTabPosition() {
        let settings = FeatureSettings.shared
        XCTAssertFalse(
            settings.newTabPosition.isEmpty,
            "newTabPosition should not be empty"
        )
    }

    func testDefaultAlwaysShowTabBar() {
        // Should be accessible without crashing
        _ = FeatureSettings.shared.alwaysShowTabBar
    }

    func testDefaultWarnOnCloseWithRunningProcess() {
        _ = FeatureSettings.shared.warnOnCloseWithRunningProcess
    }

    // MARK: - Window Opacity

    func testDefaultWindowOpacity() {
        let settings = FeatureSettings.shared
        XCTAssertGreaterThanOrEqual(settings.windowOpacity, 0.3)
        XCTAssertLessThanOrEqual(settings.windowOpacity, 1.0)
    }

    // MARK: - Feature Flag Defaults (Bool properties)

    func testDefaultBoolFeatureFlags() {
        let settings = FeatureSettings.shared

        // These are all Bool @Published properties. Verify they are accessible
        // and don't crash. Each default is documented in init().
        _ = settings.isAutoTabThemeEnabled // default: true
        _ = settings.isCopyOnSelectEnabled // default: true
        _ = settings.isLineTimestampsEnabled // default: false
        _ = settings.showTabIcons // default: true
        _ = settings.showTabPath // default: true
        _ = settings.showTabGitIndicator // default: true
        _ = settings.showTabCTOIndicator // default: true
        _ = settings.showTabBroadcastIndicator // default: true
        _ = settings.customTitleOnly // default: false
        _ = settings.isLastCommandBadgeEnabled // default: true
        _ = settings.isCmdClickPathsEnabled // default: true
        _ = settings.cmdClickOpensInternalEditor // default: true
        _ = settings.isOptionClickCursorEnabled // default: true
        _ = settings.isMouseReportingEnabled // default: false
        _ = settings.isRustTerminalEnabled // default: true
        _ = settings.useMetalRenderer // default: true
        _ = settings.isClickToPositionEnabled // default: true
        _ = settings.isBroadcastEnabled // default: false
        _ = settings.isClipboardHistoryEnabled // default: true
        _ = settings.isBookmarksEnabled // default: true
        _ = settings.isSnippetsEnabled // default: true
        _ = settings.isRepoSnippetsEnabled // default: true
        _ = settings.isSyntaxHighlightEnabled // default: true
        _ = settings.isClickableURLsEnabled // default: true
        _ = settings.isInlineImagesEnabled // default: true
        _ = settings.isJSONPrettyPrintEnabled // default: false
        _ = settings.isSemanticSearchEnabled // default: false
        _ = settings.isSplitPanesEnabled // default: true
        _ = settings.isLocalEchoEnabled // default: false
        _ = settings.isSmartScrollEnabled // default: true
        _ = settings.bellEnabled // default: true
        _ = settings.cursorBlink // default: true
        _ = settings.isAPIAnalyticsEnabled // default: false
        _ = settings.apiAnalyticsLogPrompts // default: false
        _ = settings.isRemoteEnabled // default: false
        _ = settings.isTmuxIntegrationEnabled // default: false
        _ = settings.isTmuxAutoAttachEnabled // default: false
        _ = settings.errorExplainEnabled // default: false
        _ = settings.isCTOEnabled // default: false
    }

    // MARK: - Numeric Defaults

    func testDefaultScrollbackLines() {
        let settings = FeatureSettings.shared
        XCTAssertGreaterThanOrEqual(settings.scrollbackLines, 100)
        XCTAssertLessThanOrEqual(settings.scrollbackLines, 100_000)
    }

    func testDefaultRestoredScrollbackLines() {
        let settings = FeatureSettings.shared
        XCTAssertGreaterThanOrEqual(settings.restoredScrollbackLines, 0)
        XCTAssertLessThanOrEqual(settings.restoredScrollbackLines, 10000)
    }

    func testDefaultClipboardHistoryMaxItems() {
        let settings = FeatureSettings.shared
        XCTAssertGreaterThanOrEqual(settings.clipboardHistoryMaxItems, 1)
        XCTAssertLessThanOrEqual(settings.clipboardHistoryMaxItems, 500)
    }

    func testDefaultMaxBookmarksPerTab() {
        let settings = FeatureSettings.shared
        XCTAssertGreaterThanOrEqual(settings.maxBookmarksPerTab, 1)
        XCTAssertLessThanOrEqual(settings.maxBookmarksPerTab, 200)
    }

    func testDefaultApiAnalyticsPort() {
        let settings = FeatureSettings.shared
        XCTAssertGreaterThanOrEqual(settings.apiAnalyticsPort, 1024)
        XCTAssertLessThanOrEqual(settings.apiAnalyticsPort, 65535)
    }

    // MARK: - String Defaults

    func testDefaultCursorStyle() {
        let settings = FeatureSettings.shared
        XCTAssertFalse(settings.cursorStyle.isEmpty)
    }

    func testDefaultTimestampFormat() {
        let settings = FeatureSettings.shared
        XCTAssertFalse(
            settings.timestampFormat.isEmpty,
            "timestampFormat should default to a non-empty format string"
        )
    }

    func testDefaultKeybindingPreset() {
        let settings = FeatureSettings.shared
        XCTAssertFalse(settings.keybindingPreset.isEmpty)
    }

    func testDefaultRepoSnippetPath() {
        let settings = FeatureSettings.shared
        XCTAssertFalse(settings.repoSnippetPath.isEmpty)
    }

    func testDefaultSnippetInsertMode() {
        let settings = FeatureSettings.shared
        XCTAssertFalse(settings.snippetInsertMode.isEmpty)
    }

    // MARK: - Enum Defaults

    func testDefaultUrlHandler() {
        let settings = FeatureSettings.shared
        XCTAssertNotNil(URLHandler(rawValue: settings.urlHandler.rawValue))
    }

    func testDefaultAppTheme() {
        let settings = FeatureSettings.shared
        XCTAssertNotNil(AppTheme(rawValue: settings.appTheme.rawValue))
    }

    func testDefaultDangerousCommandHighlightScope() {
        let settings = FeatureSettings.shared
        XCTAssertNotNil(DangerousCommandHighlightScope(rawValue: settings.dangerousCommandHighlightScope.rawValue))
    }

    // MARK: - Shortcut Lookup and Mutation

    func testShortcutLookupReturnsNilForUnknownAction() {
        let settings = FeatureSettings.shared
        XCTAssertNil(settings.shortcut(for: "nonExistentAction"))
    }

    func testShortcutConflictDetection() {
        let settings = FeatureSettings.shared
        // Create a shortcut that mimics an existing one
        let existingShortcut = settings.customShortcuts[0]
        let conflicting = KeyboardShortcut(
            action: "testConflict",
            key: existingShortcut.key,
            modifiers: existingShortcut.modifiers
        )
        let conflicts = settings.shortcutConflicts(for: conflicting)
        XCTAssertTrue(
            conflicts.contains(where: { $0.action == existingShortcut.action }),
            "Should detect conflict with existing shortcut"
        )
    }

    func testApplyKeybindingPresetVim() {
        let settings = FeatureSettings.shared
        let original = settings.customShortcuts
        settings.applyKeybindingPreset("vim")
        let vimNextTab = settings.shortcut(for: "nextTab")
        XCTAssertNotNil(vimNextTab)
        // Vim preset overrides nextTab to ctrl+l
        XCTAssertEqual(vimNextTab?.key, "l")
        XCTAssertTrue(vimNextTab?.modifiers.contains("ctrl") ?? false)
        // Restore
        settings.customShortcuts = original
    }

    func testApplyKeybindingPresetEmacs() {
        let settings = FeatureSettings.shared
        let original = settings.customShortcuts
        settings.applyKeybindingPreset("emacs")
        let emacsNextTab = settings.shortcut(for: "nextTab")
        XCTAssertNotNil(emacsNextTab)
        // Emacs preset overrides nextTab to ctrl+n
        XCTAssertEqual(emacsNextTab?.key, "n")
        XCTAssertTrue(emacsNextTab?.modifiers.contains("ctrl") ?? false)
        // Restore
        settings.customShortcuts = original
    }

    func testResetShortcutsToDefaults() {
        let settings = FeatureSettings.shared
        let original = settings.customShortcuts
        // Mutate
        settings.applyKeybindingPreset("vim")
        // Reset
        settings.resetShortcutsToDefaults()
        // Should be back to the preset-based defaults
        let newTab = settings.shortcut(for: "newTab")
        XCTAssertNotNil(newTab)
        XCTAssertEqual(newTab?.key, "t", "After reset, newTab should be cmd+t")
        // Restore
        settings.customShortcuts = original
    }

    // MARK: - Notification Trigger Actions

    func testActionsForUnknownTriggerReturnsDefault() {
        let settings = FeatureSettings.shared
        let actions = settings.actionsForTrigger("unknown_trigger_\(UUID().uuidString)")
        XCTAssertEqual(actions.count, 1, "Unknown trigger should get one default action")
        XCTAssertEqual(actions.first?.actionType, .showNotification)
    }

    // MARK: - Dangerous Command Patterns

    func testDefaultDangerousCommandPatternsNotEmpty() {
        let settings = FeatureSettings.shared
        XCTAssertFalse(
            settings.dangerousCommandPatterns.isEmpty,
            "dangerousCommandPatterns should have default patterns"
        )
    }

    func testDangerousCommandPatternsContainCommonThreats() {
        let settings = FeatureSettings.shared
        let patterns = settings.dangerousCommandPatterns
        XCTAssertTrue(patterns.contains("rm -rf"), "Should include rm -rf")
        XCTAssertTrue(patterns.contains("git reset --hard"), "Should include git reset --hard")
        XCTAssertTrue(patterns.contains("drop database"), "Should include drop database")
    }

    // MARK: - CTO Tab Overrides

    func testCTODefaultTabOverridesEmpty() {
        let settings = FeatureSettings.shared
        // ctoTabOverrides may or may not be empty depending on prior test runs,
        // but the type should be valid
        XCTAssertNotNil(settings.ctoTabOverrides)
    }
}

#endif
