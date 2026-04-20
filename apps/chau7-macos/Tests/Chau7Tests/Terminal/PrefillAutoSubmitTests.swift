import XCTest
@testable import Chau7
import Chau7Core

@MainActor
final class PrefillAutoSubmitTests: XCTestCase {
    private var originalAutoSubmit: Bool = true

    override func setUp() async throws {
        try await super.setUp()
        originalAutoSubmit = FeatureSettings.shared.autoSubmitRestorePrefill
    }

    override func tearDown() async throws {
        FeatureSettings.shared.autoSubmitRestorePrefill = originalAutoSubmit
        try await super.tearDown()
    }

    func testFeatureFlagDefaultIsOn() {
        // Default true means the original "insert and wait for Enter" behavior is
        // replaced by auto-submit for most users — which is the intended UX after
        // the regression where restored tabs stayed half-restored.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "restore.autoSubmitPrefill")
        let fresh = defaults.object(forKey: "restore.autoSubmitPrefill") as? Bool ?? true
        XCTAssertTrue(fresh, "autoSubmitRestorePrefill must default to true")
    }

    func testFeatureFlagCanBeToggledOff() {
        FeatureSettings.shared.autoSubmitRestorePrefill = false
        XCTAssertFalse(FeatureSettings.shared.autoSubmitRestorePrefill)

        FeatureSettings.shared.autoSubmitRestorePrefill = true
        XCTAssertTrue(FeatureSettings.shared.autoSubmitRestorePrefill)
    }

    func testFeatureFlagPersistsAcrossReads() {
        FeatureSettings.shared.autoSubmitRestorePrefill = false
        let value = UserDefaults.standard.object(forKey: "restore.autoSubmitPrefill") as? Bool
        XCTAssertEqual(value, false, "toggling must persist via UserDefaults")
    }
}
