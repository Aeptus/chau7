import XCTest
@testable import Chau7
@testable import Chau7Core

/// The extracted shell settings store against an isolated UserDefaults suite.
final class ShellSettingsStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ShellSettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshStoreUsesDefaults() {
        let store = ShellSettingsStore(defaults: defaults)
        XCTAssertEqual(store.shellType, .system)
        XCTAssertEqual(store.customShellPath, "")
        XCTAssertEqual(store.startupCommand, "")
        XCTAssertTrue(store.isLsColorsEnabled)
    }

    func testMutationsPersistAndReload() {
        let store = ShellSettingsStore(defaults: defaults)
        store.shellType = .zsh
        store.customShellPath = "/opt/homebrew/bin/fish"
        store.startupCommand = "echo hi"
        store.isLsColorsEnabled = false

        let reloaded = ShellSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.shellType, .zsh)
        XCTAssertEqual(reloaded.customShellPath, "/opt/homebrew/bin/fish")
        XCTAssertEqual(reloaded.startupCommand, "echo hi")
        XCTAssertFalse(reloaded.isLsColorsEnabled)
    }

    func testUnknownPersistedShellFallsBackToSystem() {
        defaults.set("not-a-shell", forKey: ShellSettingsStore.Keys.shellType)
        let store = ShellSettingsStore(defaults: defaults)
        XCTAssertEqual(store.shellType, .system)
    }
}
