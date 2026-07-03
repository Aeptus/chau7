import XCTest
@testable import Chau7

/// The extracted productivity feature store against an isolated UserDefaults
/// suite.
final class ProductivitySettingsStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ProductivitySettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshStoreUsesDefaults() {
        let store = ProductivitySettingsStore(defaults: defaults)
        XCTAssertTrue(store.isAutoTabThemeEnabled)
        XCTAssertTrue(store.isCopyOnSelectEnabled)
        XCTAssertFalse(store.isLineTimestampsEnabled)
        XCTAssertEqual(store.timestampFormat, "HH:mm:ss")
        XCTAssertTrue(store.isLastCommandBadgeEnabled)
        XCTAssertTrue(store.isCmdClickPathsEnabled)
        XCTAssertTrue(store.cmdClickOpensInternalEditor)
        XCTAssertTrue(store.isOptionClickCursorEnabled)
        XCTAssertEqual(store.defaultEditor, "")
        XCTAssertTrue(store.customAIDetectionRules.isEmpty)
        XCTAssertFalse(store.isBroadcastEnabled)
        XCTAssertTrue(store.isClipboardHistoryEnabled)
        XCTAssertEqual(store.clipboardHistoryMaxItems, 50)
        XCTAssertTrue(store.isBookmarksEnabled)
        XCTAssertEqual(store.maxBookmarksPerTab, 20)
        XCTAssertTrue(store.isSnippetsEnabled)
        XCTAssertTrue(store.isRepoSnippetsEnabled)
        XCTAssertEqual(store.repoSnippetPath, ".chau7/snippets")
        XCTAssertEqual(store.snippetInsertMode, "expand")
        XCTAssertTrue(store.snippetPlaceholdersEnabled)
    }

    func testMutationsPersistAndReload() {
        let store = ProductivitySettingsStore(defaults: defaults)
        store.isAutoTabThemeEnabled = false
        store.isCopyOnSelectEnabled = false
        store.isLineTimestampsEnabled = true
        store.timestampFormat = "HH:mm"
        store.isLastCommandBadgeEnabled = false
        store.isCmdClickPathsEnabled = false
        store.cmdClickOpensInternalEditor = false
        store.isOptionClickCursorEnabled = false
        store.defaultEditor = "vscode"
        store.customAIDetectionRules = [
            CustomAIDetectionRule(pattern: "my-agent", displayName: "My Agent", colorName: "blue")
        ]
        store.isBroadcastEnabled = true
        store.isClipboardHistoryEnabled = false
        store.clipboardHistoryMaxItems = 120
        store.isBookmarksEnabled = false
        store.maxBookmarksPerTab = 40
        store.isSnippetsEnabled = false
        store.isRepoSnippetsEnabled = false
        store.repoSnippetPath = ".snippets"
        store.snippetInsertMode = "paste"
        store.snippetPlaceholdersEnabled = false

        let reloaded = ProductivitySettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.isAutoTabThemeEnabled)
        XCTAssertFalse(reloaded.isCopyOnSelectEnabled)
        XCTAssertTrue(reloaded.isLineTimestampsEnabled)
        XCTAssertEqual(reloaded.timestampFormat, "HH:mm")
        XCTAssertFalse(reloaded.isLastCommandBadgeEnabled)
        XCTAssertFalse(reloaded.isCmdClickPathsEnabled)
        XCTAssertFalse(reloaded.cmdClickOpensInternalEditor)
        XCTAssertFalse(reloaded.isOptionClickCursorEnabled)
        XCTAssertEqual(reloaded.defaultEditor, "vscode")
        XCTAssertEqual(reloaded.customAIDetectionRules.count, 1)
        XCTAssertEqual(reloaded.customAIDetectionRules.first?.pattern, "my-agent")
        XCTAssertTrue(reloaded.isBroadcastEnabled)
        XCTAssertFalse(reloaded.isClipboardHistoryEnabled)
        XCTAssertEqual(reloaded.clipboardHistoryMaxItems, 120)
        XCTAssertFalse(reloaded.isBookmarksEnabled)
        XCTAssertEqual(reloaded.maxBookmarksPerTab, 40)
        XCTAssertFalse(reloaded.isSnippetsEnabled)
        XCTAssertFalse(reloaded.isRepoSnippetsEnabled)
        XCTAssertEqual(reloaded.repoSnippetPath, ".snippets")
        XCTAssertEqual(reloaded.snippetInsertMode, "paste")
        XCTAssertFalse(reloaded.snippetPlaceholdersEnabled)
    }

    func testClampingAndTrimming() {
        let store = ProductivitySettingsStore(defaults: defaults)
        store.clipboardHistoryMaxItems = 100_000
        XCTAssertEqual(store.clipboardHistoryMaxItems, 1000)
        store.clipboardHistoryMaxItems = 0
        XCTAssertEqual(store.clipboardHistoryMaxItems, 1)
        store.maxBookmarksPerTab = 5000
        XCTAssertEqual(store.maxBookmarksPerTab, 200)
        store.repoSnippetPath = "  .chau7/snips  "
        XCTAssertEqual(store.repoSnippetPath, ".chau7/snips")
    }

    func testResetToDefaultsMatchesFreshStore() {
        let store = ProductivitySettingsStore(defaults: defaults)
        store.isAutoTabThemeEnabled = false
        store.isCopyOnSelectEnabled = false
        store.isLineTimestampsEnabled = true
        store.timestampFormat = "ss"
        store.isLastCommandBadgeEnabled = false
        store.defaultEditor = "zed"
        store.customAIDetectionRules = [
            CustomAIDetectionRule(pattern: "x", displayName: "X", colorName: "red")
        ]
        store.isBroadcastEnabled = true
        store.clipboardHistoryMaxItems = 200
        store.maxBookmarksPerTab = 3
        store.isSnippetsEnabled = false
        store.repoSnippetPath = "elsewhere"
        store.snippetInsertMode = "paste"

        store.resetToDefaults()

        let fresh = ProductivitySettingsStore(defaults: defaults)
        XCTAssertEqual(store.isAutoTabThemeEnabled, fresh.isAutoTabThemeEnabled)
        XCTAssertEqual(store.isCopyOnSelectEnabled, fresh.isCopyOnSelectEnabled)
        XCTAssertEqual(store.isLineTimestampsEnabled, fresh.isLineTimestampsEnabled)
        XCTAssertEqual(store.timestampFormat, fresh.timestampFormat)
        XCTAssertEqual(store.isLastCommandBadgeEnabled, fresh.isLastCommandBadgeEnabled)
        XCTAssertEqual(store.isCmdClickPathsEnabled, fresh.isCmdClickPathsEnabled)
        XCTAssertEqual(store.cmdClickOpensInternalEditor, fresh.cmdClickOpensInternalEditor)
        XCTAssertEqual(store.isOptionClickCursorEnabled, fresh.isOptionClickCursorEnabled)
        XCTAssertEqual(store.defaultEditor, fresh.defaultEditor)
        XCTAssertEqual(store.customAIDetectionRules, fresh.customAIDetectionRules)
        XCTAssertEqual(store.isBroadcastEnabled, fresh.isBroadcastEnabled)
        XCTAssertEqual(store.isClipboardHistoryEnabled, fresh.isClipboardHistoryEnabled)
        XCTAssertEqual(store.clipboardHistoryMaxItems, fresh.clipboardHistoryMaxItems)
        XCTAssertEqual(store.isBookmarksEnabled, fresh.isBookmarksEnabled)
        XCTAssertEqual(store.maxBookmarksPerTab, fresh.maxBookmarksPerTab)
        XCTAssertEqual(store.isSnippetsEnabled, fresh.isSnippetsEnabled)
        XCTAssertEqual(store.isRepoSnippetsEnabled, fresh.isRepoSnippetsEnabled)
        XCTAssertEqual(store.repoSnippetPath, fresh.repoSnippetPath)
        XCTAssertEqual(store.snippetInsertMode, fresh.snippetInsertMode)
        XCTAssertEqual(store.snippetPlaceholdersEnabled, fresh.snippetPlaceholdersEnabled)
        // Regression guard: snippets return to enabled with the stock path.
        XCTAssertTrue(store.isSnippetsEnabled)
        XCTAssertEqual(store.repoSnippetPath, ".chau7/snippets")
    }
}
