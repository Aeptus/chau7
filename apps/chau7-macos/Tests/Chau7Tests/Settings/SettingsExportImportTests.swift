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
