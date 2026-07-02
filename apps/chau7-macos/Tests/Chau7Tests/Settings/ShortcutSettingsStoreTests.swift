import XCTest
@testable import Chau7
@testable import Chau7Core

/// The extracted shortcut store: preset fallback, generation bumps,
/// conflict detection, import/export round-trips, and the legacy conflict
/// migrations — against an isolated UserDefaults suite.
final class ShortcutSettingsStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutSettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshStoreLoadsDefaultPresetWithMigrations() {
        let store = ShortcutSettingsStore(defaults: defaults)
        XCTAssertFalse(store.customShortcuts.isEmpty)
        XCTAssertNotNil(
            store.shortcut(for: "openTextEditor"),
            "the openTextEditor backfill migration must apply to preset loads too"
        )
        XCTAssertTrue(store.isShortcutHelperHintEnabled)
    }

    func testMutationBumpsGenerationAndPersists() {
        let store = ShortcutSettingsStore(defaults: defaults)
        let generation = store.customShortcutsGeneration
        guard var shortcut = store.customShortcuts.first else {
            return XCTFail("preset must provide shortcuts")
        }
        shortcut = KeyboardShortcut(action: shortcut.action, key: "9", modifiers: ["cmd", "opt", "shift"])
        store.updateShortcut(shortcut)
        XCTAssertEqual(store.customShortcutsGeneration, generation + 1)

        let reloaded = ShortcutSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.shortcut(for: shortcut.action)?.key, "9")
    }

    func testConflictDetectionIgnoresSameAction() {
        let store = ShortcutSettingsStore(defaults: defaults)
        guard let existing = store.customShortcuts.first else {
            return XCTFail("preset must provide shortcuts")
        }
        let probe = KeyboardShortcut(action: "some-new-action", key: existing.key, modifiers: existing.modifiers)
        XCTAssertTrue(store.shortcutConflicts(for: probe).contains { $0.action == existing.action })
        XCTAssertFalse(store.shortcutConflicts(for: existing).contains { $0.action == existing.action })
    }

    func testExportImportRoundTrip() throws {
        let store = ShortcutSettingsStore(defaults: defaults)
        let data = try XCTUnwrap(store.exportKeybindings())
        store.applyPreset("default")
        XCTAssertTrue(store.importKeybindings(from: data))
        XCTAssertFalse(store.importKeybindings(from: Data("junk".utf8)))
    }

    func testLegacyDebugConsoleConflictMigration() {
        let legacy = [
            KeyboardShortcut(action: "debugConsole", key: "d", modifiers: ["cmd", "shift"]),
            KeyboardShortcut(action: "splitVertical", key: "d", modifiers: ["cmd", "shift"])
        ]
        let migrated = ShortcutSettingsStore.migratedShortcutsIfNeeded(legacy)
        XCTAssertEqual(migrated.first { $0.action == "debugConsole" }?.key, "l")
        XCTAssertEqual(migrated.first { $0.action == "splitVertical" }?.key, "d")
    }
}
