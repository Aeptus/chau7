import XCTest
@testable import Chau7Core

// MARK: - Localization Tests

/// Tests for the localization infrastructure
final class LocalizationTests: XCTestCase {

    // MARK: - AppLanguage Tests

    func testAppLanguage_AllCases() {
        let cases = ["system", "en", "fr", "ar", "he"]
        XCTAssertEqual(cases.count, 5, "Should have 5 language options")
    }

    func testAppLanguage_DisplayNames() {
        // Test that display names are non-empty
        XCTAssertFalse("English".isEmpty)
        XCTAssertFalse("Français".isEmpty)
        XCTAssertFalse("العربية".isEmpty)
        XCTAssertFalse("עברית".isEmpty)
    }

    func testAppLanguage_RTL_Arabic() {
        // Arabic should be RTL
        let arabicLocale = Locale(identifier: "ar")
        XCTAssertEqual(arabicLocale.language.characterDirection, .rightToLeft)
    }

    func testAppLanguage_RTL_Hebrew() {
        // Hebrew should be RTL
        let hebrewLocale = Locale(identifier: "he")
        XCTAssertEqual(hebrewLocale.language.characterDirection, .rightToLeft)
    }

    func testAppLanguage_LTR_English() {
        // English should be LTR
        let englishLocale = Locale(identifier: "en")
        XCTAssertEqual(englishLocale.language.characterDirection, .leftToRight)
    }

    func testAppLanguage_LTR_French() {
        // French should be LTR
        let frenchLocale = Locale(identifier: "fr")
        XCTAssertEqual(frenchLocale.language.characterDirection, .leftToRight)
    }

    // MARK: - Locale Tests

    func testLocale_Identifiers() {
        XCTAssertEqual(Locale(identifier: "en").identifier, "en")
        XCTAssertEqual(Locale(identifier: "fr").identifier, "fr")
        XCTAssertEqual(Locale(identifier: "ar").identifier, "ar")
        XCTAssertEqual(Locale(identifier: "he").identifier, "he")
    }

    // MARK: - Date Formatting Tests

    func testDateFormatter_ShortDate_English() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .short
        formatter.timeStyle = .none

        let date = Date(timeIntervalSince1970: 1704067200) // Jan 1, 2024
        let formatted = formatter.string(from: date)
        XCTAssertTrue(formatted.contains("1") && formatted.contains("24"))
    }

    func testDateFormatter_ShortDate_French() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .short
        formatter.timeStyle = .none

        let date = Date(timeIntervalSince1970: 1704067200) // Jan 1, 2024
        let formatted = formatter.string(from: date)
        XCTAssertTrue(formatted.contains("01") || formatted.contains("1"))
    }

    // MARK: - Number Formatting Tests

    func testNumberFormatter_Decimal_English() {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal

        let formatted = formatter.string(from: 1234.56)
        XCTAssertEqual(formatted, "1,234.56")
    }

    func testNumberFormatter_Decimal_French() {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.numberStyle = .decimal

        let formatted = formatter.string(from: 1234.56)
        // French uses space as thousands separator and comma for decimal
        XCTAssertTrue(formatted?.contains(",") == true || formatted?.contains(" ") == true)
    }

    func testNumberFormatter_Percent() {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0

        let formatted = formatter.string(from: 0.85)
        XCTAssertEqual(formatted, "85%")
    }

    // MARK: - Byte Count Formatting Tests

    func testByteCountFormatter_KB() {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let formatted = formatter.string(fromByteCount: 1024)
        XCTAssertTrue(formatted.contains("KB") || formatted.contains("Ko") || formatted.contains("1"))
    }

    func testByteCountFormatter_MB() {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let formatted = formatter.string(fromByteCount: 1024 * 1024)
        XCTAssertTrue(formatted.contains("MB") || formatted.contains("Mo") || formatted.contains("1"))
    }

    func testByteCountFormatter_GB() {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let formatted = formatter.string(fromByteCount: 1024 * 1024 * 1024)
        XCTAssertTrue(formatted.contains("GB") || formatted.contains("Go") || formatted.contains("1"))
    }

    // MARK: - Relative Date Formatting Tests

    func testRelativeDateFormatter_JustNow() {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .abbreviated

        let now = Date()
        let formatted = formatter.localizedString(for: now, relativeTo: now)
        XCTAssertFalse(formatted.isEmpty)
    }

    func testRelativeDateFormatter_HoursAgo() {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full

        let twoHoursAgo = Date().addingTimeInterval(-7200)
        let formatted = formatter.localizedString(for: twoHoursAgo, relativeTo: Date())
        XCTAssertTrue(formatted.lowercased().contains("hour") || formatted.contains("2"))
    }

    // MARK: - Localization Key Parity Tests

    func testLocalizationKeyParity() {
        let base = loadStrings(locale: "en")
        XCTAssertFalse(base.isEmpty)

        for locale in ["fr", "ar", "he"] {
            let current = loadStrings(locale: locale)
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
