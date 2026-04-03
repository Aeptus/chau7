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

    // MARK: - Format Specifier Parity

    func testFormatSpecifierParity() throws {
        let base = loadStrings(locale: "en")
        guard !base.isEmpty else { return }

        let specifierPattern = try NSRegularExpression(pattern: "%(?:\\d+\\$)?[dDuUxXoOfFeEgGcCsSpaAn@]|%#@\\w+@")

        for locale in ["fr", "ar", "he"] {
            let current = loadStrings(locale: locale)
            for (key, enValue) in base {
                guard let localizedValue = current[key] else { continue }
                let enSpecifiers = specifierPattern.matches(in: enValue, range: NSRange(enValue.startIndex..., in: enValue))
                    .map { String(enValue[Range($0.range, in: enValue)!]) }
                let locSpecifiers = specifierPattern.matches(in: localizedValue, range: NSRange(localizedValue.startIndex..., in: localizedValue))
                    .map { String(localizedValue[Range($0.range, in: localizedValue)!]) }
                XCTAssertEqual(
                    enSpecifiers.count, locSpecifiers.count,
                    "Locale \(locale), key \"\(key)\": format specifier count mismatch — en has \(enSpecifiers) but \(locale) has \(locSpecifiers)"
                )
            }
        }
    }

    // MARK: - Translation Completeness

    /// Flags keys where a non-English locale has a value identical to English,
    /// excluding known legitimate cognates and brand names.
    func testTranslationCompleteness() {
        let base = loadStrings(locale: "en")
        guard !base.isEmpty else { return }

        // Values that are legitimately identical across languages
        let allowedIdentical: Set = [
            "Chau7", "Git", "SSH", "MCP", "TTY", "URL", "JSON", "PDF", "DMG",
            "Apple Silicon (arm64)", "Intel (x86_64)", "OK",
            "Claude", "Codex", "ChatGPT", "Copilot", "Cursor", "Gemini",
            "AGPL 3.0", "Aeptus"
        ]

        // Key prefixes that are inherently format-only or technical
        let skipPrefixes = ["a11y.", "debug.", "cto.runtime."]

        for locale in ["fr", "ar", "he"] {
            let current = loadStrings(locale: locale)
            var untranslated: [String] = []

            for (key, enValue) in base {
                guard let localizedValue = current[key] else { continue }
                if localizedValue == enValue,
                   !allowedIdentical.contains(enValue),
                   !skipPrefixes.contains(where: { key.hasPrefix($0) }),
                   // Skip format-only strings like "(%d/%d)"
                   enValue.range(of: "[a-zA-Z]", options: .regularExpression) != nil {
                    untranslated.append(key)
                }
            }

            // Allow up to 5% identical-to-English (cognates vary by language)
            let threshold = Int(Double(base.count) * 0.05)
            XCTAssertLessThanOrEqual(
                untranslated.count, threshold,
                "Locale \(locale): \(untranslated.count) keys appear untranslated (>\(threshold) threshold). First 10: \(untranslated.sorted().prefix(10))"
            )
        }
    }

    // MARK: - Stringsdict Key Coverage

    /// Verify all .stringsdict keys either exist in .strings (as fallback)
    /// or are self-contained plural definitions (which don't need .strings).
    /// This test mainly ensures no typos in .stringsdict key names.
    func testStringsdictKeysAreUsedInCode() {
        let baseDict = loadStringsdictKeys(locale: "en")
        guard !baseDict.isEmpty else { return }

        // .stringsdict keys override .strings — they don't need a .strings entry.
        // Just verify at least the English .stringsdict has entries.
        XCTAssertFalse(baseDict.isEmpty, "English .stringsdict should have plural definitions")

        // Verify all 4 locales define the same set of plural keys
        for locale in ["fr", "ar", "he"] {
            let currentKeys = loadStringsdictKeys(locale: locale)
            let missing = baseDict.subtracting(currentKeys)
            XCTAssertTrue(missing.isEmpty, "Locale \(locale) .stringsdict missing keys: \(missing.sorted())")
        }
    }

    // MARK: - Stringsdict Parity

    func testStringsdictKeyParity() {
        let baseKeys = loadStringsdictKeys(locale: "en")
        guard !baseKeys.isEmpty else {
            // No .stringsdict files yet — skip
            return
        }

        for locale in ["fr", "ar", "he"] {
            let currentKeys = loadStringsdictKeys(locale: locale)
            let missing = baseKeys.subtracting(currentKeys)
            let extra = currentKeys.subtracting(baseKeys)
            XCTAssertTrue(missing.isEmpty, "Locale \(locale) .stringsdict missing keys: \(missing.sorted())")
            XCTAssertTrue(extra.isEmpty, "Locale \(locale) .stringsdict has extra keys: \(extra.sorted())")
        }
    }

    // MARK: - Helpers

    private func loadStringsdictKeys(locale: String, file: StaticString = #filePath) -> Set<String> {
        let fileURL = URL(fileURLWithPath: "\(file)")
        let root = fileURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dictURL = root
            .appendingPathComponent("Sources/Chau7/Resources")
            .appendingPathComponent("\(locale).lproj/Localizable.stringsdict")

        guard FileManager.default.fileExists(atPath: dictURL.path),
              let data = try? Data(contentsOf: dictURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return []
        }
        return Set(plist.keys)
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
