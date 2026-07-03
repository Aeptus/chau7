import XCTest
@testable import Chau7

/// The extracted app chrome store (theme, language, window mode/opacity,
/// launch at login, ligatures) against an isolated UserDefaults suite.
final class AppChromeSettingsStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var savedLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        // Launch-at-login side effects must stay inert under test.
        setenv("CHAU7_ISOLATED_TEST_MODE", "1", 1)
        suiteName = "AppChromeSettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // The appLanguage didSet forwards to the LocalizationManager
        // singleton; snapshot it so mutations here can't leak.
        savedLanguage = LocalizationManager.shared.currentLanguage
    }

    override func tearDown() {
        LocalizationManager.shared.currentLanguage = savedLanguage
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshStoreUsesDefaults() {
        let store = AppChromeSettingsStore(defaults: defaults)
        XCTAssertEqual(store.appTheme, .system)
        XCTAssertEqual(store.appLanguage, .system)
        XCTAssertFalse(store.menuBarOnlyMode)
        XCTAssertFalse(store.windowFloating)
        XCTAssertEqual(store.windowOpacity, 1.0)
        // Isolated test mode reports no installed login item.
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertFalse(store.enableLigatures)
    }

    func testMutationsPersistAndReload() {
        let store = AppChromeSettingsStore(defaults: defaults)
        store.appTheme = .dark
        store.menuBarOnlyMode = true
        store.windowFloating = true
        store.windowOpacity = 0.8
        store.launchAtLogin = true
        store.enableLigatures = true

        let reloaded = AppChromeSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.appTheme, .dark)
        XCTAssertTrue(reloaded.menuBarOnlyMode)
        XCTAssertTrue(reloaded.windowFloating)
        XCTAssertEqual(reloaded.windowOpacity, 0.8)
        XCTAssertTrue(reloaded.launchAtLogin)
        XCTAssertTrue(reloaded.enableLigatures)
        // Untouched members keep their loader defaults.
        XCTAssertEqual(reloaded.appLanguage, .system)
    }

    func testWindowOpacityClamps() {
        let store = AppChromeSettingsStore(defaults: defaults)
        store.windowOpacity = 0.05
        XCTAssertEqual(store.windowOpacity, 0.3)
        store.windowOpacity = 2.0
        XCTAssertEqual(store.windowOpacity, 1.0)
    }

    func testResetToDefaultsMatchesFreshStore() {
        let store = AppChromeSettingsStore(defaults: defaults)
        store.appTheme = .light
        store.menuBarOnlyMode = true
        store.windowFloating = true
        store.windowOpacity = 0.5
        store.launchAtLogin = true
        store.enableLigatures = true

        store.resetToDefaults()

        let fresh = AppChromeSettingsStore(defaults: defaults)
        XCTAssertEqual(store.appTheme, fresh.appTheme)
        XCTAssertEqual(store.appLanguage, fresh.appLanguage)
        XCTAssertEqual(store.menuBarOnlyMode, fresh.menuBarOnlyMode)
        XCTAssertEqual(store.windowFloating, fresh.windowFloating)
        XCTAssertEqual(store.windowOpacity, fresh.windowOpacity)
        XCTAssertEqual(store.launchAtLogin, fresh.launchAtLogin)
        XCTAssertEqual(store.enableLigatures, fresh.enableLigatures)
        // Regression guard: the theme returns to system with full opacity.
        XCTAssertEqual(store.appTheme, .system)
        XCTAssertEqual(store.windowOpacity, 1.0)
    }
}
