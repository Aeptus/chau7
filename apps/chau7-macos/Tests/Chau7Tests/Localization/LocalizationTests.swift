import XCTest
@testable import Chau7Core

// MARK: - Localization Tests

/// Tests for the localization infrastructure
final class LocalizationTests: XCTestCase {

    // MARK: - Localization Key Parity Tests

    func testLocalizationKeyParity() {
        let base = loadStrings(locale: "en")
        guard !base.isEmpty else {
            XCTFail("English .strings file is missing or empty — parity check is meaningless")
            return
        }

        for locale in ["fr", "ar", "he"] {
            let current = loadStrings(locale: locale)
            guard !current.isEmpty else {
                XCTFail("Locale \(locale) .strings file is missing or empty")
                continue
            }
            let missing = Set(base.keys).subtracting(current.keys)
            let extra = Set(current.keys).subtracting(base.keys)
            XCTAssertTrue(missing.isEmpty, "Locale \(locale) missing keys: \(missing.sorted())")
            XCTAssertTrue(extra.isEmpty, "Locale \(locale) has extra keys: \(extra.sorted())")
        }
    }

    private func loadStrings(locale: String, file: StaticString = #filePath) -> [String: String] {
        let fileURL = URL(fileURLWithPath: "\(file)")
        let root = fileURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stringsURL = root
            .appendingPathComponent("Sources/Chau7/Resources")
            .appendingPathComponent("\(locale).lproj/Localizable.strings")

        guard FileManager.default.fileExists(atPath: stringsURL.path) else {
            XCTFail("Missing Localizable.strings for locale: \(locale)")
            return [:]
        }
        guard let dict = NSDictionary(contentsOf: stringsURL) as? [String: String] else {
            XCTFail("Failed to load Localizable.strings for locale: \(locale)")
            return [:]
        }
        return dict
    }
}
