import XCTest
@testable import Chau7
@testable import Chau7Core

/// The extracted terminal appearance store: defaults, clamping, persistence
/// round-trips, and scheme resolution against an isolated UserDefaults suite.
final class TerminalAppearanceStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TerminalAppearanceStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshStoreUsesDefaults() {
        let store = TerminalAppearanceStore(defaults: defaults)
        XCTAssertEqual(store.fontFamily, "SF Mono")
        XCTAssertEqual(store.fontWeight, 5)
        XCTAssertEqual(store.fontSize, 11)
        XCTAssertEqual(store.defaultZoomPercent, 100)
        XCTAssertEqual(store.colorSchemeName, "Default")
        XCTAssertNil(store.customColorScheme)
    }

    func testMutationsClampAndPersist() {
        let store = TerminalAppearanceStore(defaults: defaults)
        store.fontSize = 500
        XCTAssertEqual(store.fontSize, 72, "font size clamps to 72")
        store.defaultZoomPercent = 10
        XCTAssertEqual(store.defaultZoomPercent, 50, "zoom clamps to 50")
        store.fontFamily = "Menlo"

        let reloaded = TerminalAppearanceStore(defaults: defaults)
        XCTAssertEqual(reloaded.fontSize, 72)
        XCTAssertEqual(reloaded.defaultZoomPercent, 50)
        XCTAssertEqual(reloaded.fontFamily, "Menlo")
    }

    func testCurrentColorSchemeResolution() throws {
        let store = TerminalAppearanceStore(defaults: defaults)
        XCTAssertEqual(store.currentColorScheme.name, TerminalColorScheme.default.name)

        // "Custom" without a stored scheme falls back to default.
        store.colorSchemeName = "Custom"
        XCTAssertEqual(store.currentColorScheme.name, TerminalColorScheme.default.name)

        let scheme = TerminalColorScheme.allPresets.first { $0.name != TerminalColorScheme.default.name }
        let custom = try XCTUnwrap(scheme)
        store.customColorScheme = custom
        XCTAssertEqual(store.currentColorScheme, custom)

        // Custom scheme persists across reload.
        let reloaded = TerminalAppearanceStore(defaults: defaults)
        XCTAssertEqual(reloaded.customColorScheme, custom)
    }

    func testResetEqualsFreshInstall() {
        let store = TerminalAppearanceStore(defaults: defaults)
        store.fontFamily = "Menlo"
        store.fontSize = 40
        store.colorSchemeName = "Custom"

        store.resetToDefaults()

        XCTAssertEqual(store.fontFamily, "SF Mono")
        XCTAssertEqual(store.fontSize, 11)
        XCTAssertEqual(store.colorSchemeName, "Default")
        XCTAssertNil(store.customColorScheme)
    }

    func testFacadeForwardsToStore() {
        let before = FeatureSettings.shared.fontSize
        FeatureSettings.shared.fontSize = before == 20 ? 21 : 20
        XCTAssertNotEqual(FeatureSettings.shared.fontSize, before)
        FeatureSettings.shared.fontSize = before
        XCTAssertEqual(FeatureSettings.shared.fontSize, before)
    }
}
