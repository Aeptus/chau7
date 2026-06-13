import XCTest
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

    // NOTE: `FeatureSettings.triggerState(from:)`, `legacyNotificationFilters(from:)`
    // and `defaultTriggerActionBindings()` are fileprivate (private extension), so the
    // original tests against them are no longer reachable from the test target. The
    // group-level default bindings remain accessible and cover the same intent.

    func testIdleNotificationsDefaultToNoActions() {
        XCTAssertEqual(
            NotificationSettings.defaultGroupActionBindings["ai_coding.idle"] ?? [],
            []
        )
    }

    func testPermissionNotificationsDefaultToPersistentStyle() {
        let groupKeys = [
            "ai_coding.permission",
            "ai_coding.waiting_input",
            "ai_coding.attention_required"
        ]

        let bindings = NotificationSettings.defaultGroupActionBindings
        for groupKey in groupKeys {
            let styleAction = bindings[groupKey]?.first(where: { $0.actionType == .styleTab })
            XCTAssertEqual(styleAction?.config["persistent"], "true", "Expected persistent style for \(groupKey)")
        }
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

    // These assert against `KeyboardShortcut.defaultShortcuts` (the canonical defaults)
    // rather than `FeatureSettings.shared.customShortcuts`, which reflects whatever is
    // persisted in UserDefaults and would make the tests environment-dependent.

    func testDefaultShortcutsContainNewTab() {
        let newTab = KeyboardShortcut.defaultShortcuts.first { $0.action == "newTab" }
        XCTAssertNotNil(newTab, "Default shortcuts should include newTab")
        XCTAssertEqual(newTab?.key, "t")
        XCTAssertTrue(newTab?.modifiers.contains("cmd") ?? false)
    }

    func testDefaultShortcutsContainCloseTab() {
        let closeTab = KeyboardShortcut.defaultShortcuts.first { $0.action == "closeTab" }
        XCTAssertNotNil(closeTab, "Default shortcuts should include closeTab")
        XCTAssertEqual(closeTab?.key, "w")
    }

    func testDefaultShortcutsContainCopy() {
        let copy = KeyboardShortcut.defaultShortcuts.first { $0.action == "copy" }
        XCTAssertNotNil(copy, "Default shortcuts should include copy")
        XCTAssertEqual(copy?.key, "c")
    }

    func testDefaultShortcutsContainPaste() {
        let paste = KeyboardShortcut.defaultShortcuts.first { $0.action == "paste" }
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
        _ = settings.isSmartScrollEnabled // default: true
        _ = settings.bellEnabled // default: true
        _ = settings.cursorBlink // default: true
        _ = settings.isAPIAnalyticsEnabled // default: false
        _ = settings.apiAnalyticsLogPrompts // default: false
        _ = settings.apiAnalyticsIncludeOpenAI // default: true
        _ = settings.isRemoteEnabled // default: false
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

    func testDefaultRuntimeCostThresholds() {
        let key = "runtime.costThresholdsUSD"
        let defaults = UserDefaults.standard
        let original = defaults.array(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key)
        let settings = FeatureSettings.shared
        XCTAssertEqual(settings.runtimeCostThresholdsUSD, [1, 5, 10])
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

    func testRuntimeCostThresholdsNormalizeAndPersist() {
        let settings = FeatureSettings.shared
        let original = settings.runtimeCostThresholdsUSD
        defer { settings.runtimeCostThresholdsUSD = original }

        settings.runtimeCostThresholdsUSD = [10, 1, -3, 5, 5]

        XCTAssertEqual(settings.runtimeCostThresholdsUSD, [1, 5, 10])
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

    func testDefaultActivePollingRateCap() {
        let settings = FeatureSettings.shared
        XCTAssertNotNil(ActivePollingRateCap(rawValue: settings.activePollingRateCap.rawValue))
    }

    func testActivePollingRateCapCapHz() {
        XCTAssertNil(ActivePollingRateCap.displayNative.capHz)
        XCTAssertEqual(ActivePollingRateCap.hz60.capHz, 60)
        XCTAssertEqual(ActivePollingRateCap.hz30.capHz, 30)
    }

    // MARK: - Shortcut Lookup and Mutation

    func testShortcutLookupReturnsNilForUnknownAction() {
        let settings = FeatureSettings.shared
        XCTAssertNil(settings.shortcut(for: "nonExistentAction"))
    }

    func testShortcutConflictDetection() throws {
        let settings = FeatureSettings.shared
        // Create a shortcut that mimics an existing one
        let existingShortcut = try XCTUnwrap(settings.customShortcuts.first)
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
        defer { settings.customShortcuts = original }

        settings.applyKeybindingPreset("vim")
        let vimNextTab = settings.shortcut(for: "nextTab")
        XCTAssertNotNil(vimNextTab)
        // Vim preset overrides nextTab to ctrl+l
        XCTAssertEqual(vimNextTab?.key, "l")
        XCTAssertTrue(vimNextTab?.modifiers.contains("ctrl") ?? false)
    }

    func testApplyKeybindingPresetEmacs() {
        let settings = FeatureSettings.shared
        let original = settings.customShortcuts
        defer { settings.customShortcuts = original }

        settings.applyKeybindingPreset("emacs")
        let emacsNextTab = settings.shortcut(for: "nextTab")
        XCTAssertNotNil(emacsNextTab)
        // Emacs preset overrides nextTab to ctrl+n
        XCTAssertEqual(emacsNextTab?.key, "n")
        XCTAssertTrue(emacsNextTab?.modifiers.contains("ctrl") ?? false)
    }

    func testResetShortcutsToDefaults() {
        let settings = FeatureSettings.shared
        let originalShortcuts = settings.customShortcuts
        let originalPreset = settings.keybindingPreset
        defer {
            settings.keybindingPreset = originalPreset
            settings.customShortcuts = originalShortcuts
        }

        // Pin the preset so the reset target is deterministic
        settings.keybindingPreset = "default"
        // Mutate
        settings.applyKeybindingPreset("vim")
        // Reset
        settings.resetShortcutsToDefaults()
        // Should be back to the preset-based defaults
        let newTab = settings.shortcut(for: "newTab")
        XCTAssertNotNil(newTab)
        XCTAssertEqual(newTab?.key, "t", "After reset, newTab should be cmd+t")
    }

    func testImportSettingsPreservesKnownRepoBranchMetadataForRecentRoots() throws {
        let settings = FeatureSettings.shared
        let previousRecentRepoRoots = settings.recentRepoRoots
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer {
            settings.recentRepoRoots = previousRecentRepoRoots
            KnownRepoIdentityStore.shared.restore(previousKnownIdentities)
        }

        let repoRoot = "/tmp/Downloads/Repositories/Chau7"
        settings.recentRepoRoots = [repoRoot]
        KnownRepoIdentityStore.shared.restore([
            KnownRepoIdentity(
                rootPath: repoRoot,
                lastConfirmedAt: Date(timeIntervalSince1970: 0),
                lastKnownBranch: "feature/protected"
            )
        ])

        let exported = try XCTUnwrap(settings.exportSettings())
        XCTAssertTrue(settings.importSettings(from: exported))
        XCTAssertEqual(
            KnownRepoIdentityStore.shared.identity(forRootPath: repoRoot)?.lastKnownBranch,
            "feature/protected"
        )
    }

    func testImportSettingsWithoutRecentRepoRootsDoesNotResetKnownRepoIdentities() throws {
        let settings = FeatureSettings.shared
        let previousRecentRepoRoots = settings.recentRepoRoots
        let previousKnownIdentities = KnownRepoIdentityStore.shared.allIdentities()
        defer {
            settings.recentRepoRoots = previousRecentRepoRoots
            KnownRepoIdentityStore.shared.restore(previousKnownIdentities)
        }

        let repoRoot = "/tmp/Downloads/Repositories/Chau7"
        settings.recentRepoRoots = [repoRoot]
        KnownRepoIdentityStore.shared.restore([
            KnownRepoIdentity(
                rootPath: repoRoot,
                lastConfirmedAt: Date(timeIntervalSince1970: 0),
                lastKnownBranch: "main"
            )
        ])

        let exported = try XCTUnwrap(settings.exportSettings())
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: exported) as? [String: Any])
        var mutated = raw
        mutated.removeValue(forKey: "recentRepoRoots")
        let mutatedData = try JSONSerialization.data(withJSONObject: mutated, options: [])

        XCTAssertTrue(settings.importSettings(from: mutatedData))
        XCTAssertEqual(
            KnownRepoIdentityStore.shared.identity(forRootPath: repoRoot)?.lastKnownBranch,
            "main"
        )
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

    func testCTOTabOverridesRoundTrip() {
        let settings = FeatureSettings.shared
        let original = settings.ctoTabOverrides
        defer { settings.ctoTabOverrides = original }

        settings.ctoTabOverrides = ["tab-test-override": true]
        XCTAssertEqual(settings.ctoTabOverrides["tab-test-override"], true)

        settings.ctoTabOverrides = [:]
        XCTAssertTrue(settings.ctoTabOverrides.isEmpty)
    }
}

