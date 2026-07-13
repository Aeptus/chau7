import XCTest
@testable import Chau7

/// Pins the settings export/import contract that the iCloud freshness guard
/// depends on: exports are timestamped, and newer-format blobs are refused
/// outright instead of partially decoded.
final class SettingsExportImportTests: XCTestCase {
    func testExportStampsExportedAt() throws {
        let before = Date()
        let data = try XCTUnwrap(FeatureSettings.shared.exportSettings())
        let decoded = try XCTUnwrap(
            JSONOperations.decode(FeatureSettings.ExportableSettings.self, from: data, context: "test")
        )

        let exportedAt = try XCTUnwrap(decoded.exportedAt)
        XCTAssertGreaterThanOrEqual(exportedAt.timeIntervalSince1970, before.timeIntervalSince1970 - 1)
        XCTAssertEqual(decoded.exportVersion, FeatureSettings.maxSupportedSettingsExportVersion)
    }

    func testExportIncludesAppChromeVisibilitySettings() throws {
        let settings = FeatureSettings.shared
        let originalMenuBarOnlyMode = settings.menuBarOnlyMode
        let originalWindowFloating = settings.windowFloating
        let originalEnableLigatures = settings.enableLigatures
        defer {
            settings.menuBarOnlyMode = originalMenuBarOnlyMode
            settings.windowFloating = originalWindowFloating
            settings.enableLigatures = originalEnableLigatures
        }

        settings.menuBarOnlyMode = true
        settings.windowFloating = true
        settings.enableLigatures = true

        let data = try XCTUnwrap(settings.exportSettings())
        let decoded = try XCTUnwrap(
            JSONOperations.decode(FeatureSettings.ExportableSettings.self, from: data, context: "test")
        )

        XCTAssertEqual(decoded.menuBarOnlyMode, true)
        XCTAssertEqual(decoded.windowFloating, true)
        XCTAssertEqual(decoded.enableLigatures, true)
    }

    func testImportRefusesNewerExportVersion() throws {
        // A real export with only the version bumped: a future format must be
        // refused outright, not partially decoded-and-resaved.
        let data = try XCTUnwrap(FeatureSettings.shared.exportSettings())
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["exportVersion"] = FeatureSettings.maxSupportedSettingsExportVersion + 1
        let modified = try JSONSerialization.data(withJSONObject: json)

        XCTAssertFalse(FeatureSettings.shared.importSettings(from: modified))
    }
}
