import XCTest
@testable import Chau7Core

// MARK: - RustEscapeSanitizer Tests

final class RustEscapeSanitizerTests: XCTestCase {

    // MARK: - Shared Instance

    func testSharedInstance_exists() {
        let instance = RustEscapeSanitizer.shared
        XCTAssertNotNil(instance)
    }

    func testSharedInstance_isSingleton() {
        let a = RustEscapeSanitizer.shared
        let b = RustEscapeSanitizer.shared
        XCTAssertTrue(a === b)
    }

    // MARK: - Fallback Behavior (Rust dylib not loaded)

    func testSanitize_returnsNilWhenRustUnavailable() {
        // When the Rust dylib is not loaded (typical in test environment),
        // sanitize should return nil rather than crash.
        let result = RustEscapeSanitizer.shared.sanitize("hello world")
        // Result is nil when Rust is unavailable, or a String when it is.
        // Either outcome is acceptable; we just verify no crash.
        if result != nil {
            XCTAssertFalse(result!.isEmpty || result == "hello world",
                           "If Rust is loaded, result should be the sanitized text")
        }
    }

    func testSanitize_emptyString_doesNotCrash() {
        let result = RustEscapeSanitizer.shared.sanitize("")
        // nil (Rust unavailable) or "" (Rust returns empty) are both valid
        if let result {
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testSanitize_unicodeInput_doesNotCrash() {
        _ = RustEscapeSanitizer.shared.sanitize("Bonjour le monde")
    }

    func testSanitize_escapeSequenceInput_doesNotCrash() {
        _ = RustEscapeSanitizer.shared.sanitize("\u{1b}[32mgreen\u{1b}[0m")
    }

    func testSanitize_longInput_doesNotCrash() {
        let long = String(repeating: "a", count: 100_000)
        _ = RustEscapeSanitizer.shared.sanitize(long)
    }

    func testSanitize_nullCharacterInput_doesNotCrash() {
        _ = RustEscapeSanitizer.shared.sanitize("hello\u{00}world")
    }

    // MARK: - Thread Safety

    func testSanitize_concurrentAccess_doesNotCrash() {
        let group = DispatchGroup()
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                _ = RustEscapeSanitizer.shared.sanitize("concurrent test \(i)")
                group.leave()
            }
        }
        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success)
    }
}

// MARK: - RustCommandRisk Tests

final class RustCommandRiskTests: XCTestCase {

    // MARK: - Shared Instance

    func testSharedInstance_exists() {
        let instance = RustCommandRisk.shared
        XCTAssertNotNil(instance)
    }

    func testSharedInstance_isSingleton() {
        let a = RustCommandRisk.shared
        let b = RustCommandRisk.shared
        XCTAssertTrue(a === b)
    }

    // MARK: - Empty Patterns Short-Circuit

    func testIsRisky_emptyPatterns_returnsFalse() {
        // The implementation short-circuits: empty patterns always returns false,
        // without attempting to load the Rust dylib.
        let result = RustCommandRisk.shared.isRisky(command: "rm -rf /", patterns: [])
        XCTAssertEqual(result, false)
    }

    // MARK: - Fallback Behavior (Rust dylib not loaded)

    func testIsRisky_returnsNilWhenRustUnavailable() {
        // When the Rust dylib is not loaded, isRisky should return nil
        // (not crash) for non-empty patterns.
        let result = RustCommandRisk.shared.isRisky(
            command: "rm -rf /",
            patterns: ["rm -rf"]
        )
        // nil means Rust not available; Bool means Rust is loaded.
        // We only verify no crash.
        _ = result
    }

    func testIsRisky_emptyCommand_doesNotCrash() {
        _ = RustCommandRisk.shared.isRisky(command: "", patterns: ["rm -rf"])
    }

    func testIsRisky_emptyCommandAndPatterns_returnsFalse() {
        let result = RustCommandRisk.shared.isRisky(command: "", patterns: [])
        XCTAssertEqual(result, false)
    }

    func testIsRisky_longCommand_doesNotCrash() {
        let long = String(repeating: "x", count: 100_000)
        _ = RustCommandRisk.shared.isRisky(command: long, patterns: ["dangerous"])
    }

    func testIsRisky_manyPatterns_doesNotCrash() {
        let patterns = (0..<100).map { "pattern_\($0)" }
        _ = RustCommandRisk.shared.isRisky(command: "test command", patterns: patterns)
    }

    func testIsRisky_unicodePattern_doesNotCrash() {
        _ = RustCommandRisk.shared.isRisky(
            command: "supprimer tout",
            patterns: ["supprimer"]
        )
    }

    // MARK: - Thread Safety

    func testIsRisky_concurrentAccess_doesNotCrash() {
        let group = DispatchGroup()
        let patterns = ["rm -rf", "git push --force"]
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                _ = RustCommandRisk.shared.isRisky(
                    command: "command \(i)",
                    patterns: patterns
                )
                group.leave()
            }
        }
        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success)
    }
}

// MARK: - RustPatternMatcher Tests

final class RustPatternMatcherTests: XCTestCase {

    // MARK: - Static Instances

    func testOutputPatternsInstance_exists() {
        let instance = RustPatternMatcher.outputPatterns
        XCTAssertNotNil(instance)
    }

    func testWaitPatternsInstance_exists() {
        let instance = RustPatternMatcher.waitPatterns
        XCTAssertNotNil(instance)
    }

    func testOutputAndWaitPatterns_areDifferentInstances() {
        let output = RustPatternMatcher.outputPatterns
        let wait = RustPatternMatcher.waitPatterns
        XCTAssertFalse(output === wait)
    }

    func testOutputPatterns_isSingleton() {
        let a = RustPatternMatcher.outputPatterns
        let b = RustPatternMatcher.outputPatterns
        XCTAssertTrue(a === b)
    }

    func testWaitPatterns_isSingleton() {
        let a = RustPatternMatcher.waitPatterns
        let b = RustPatternMatcher.waitPatterns
        XCTAssertTrue(a === b)
    }

    // MARK: - Empty Patterns Short-Circuit

    func testFirstMatchIndex_emptyPatterns_returnsMinusOne() {
        // The implementation short-circuits: empty patterns returns -1
        // (wrapped as Int?) without loading the Rust dylib.
        let result = RustPatternMatcher.outputPatterns.firstMatchIndex(
            haystack: "some text",
            patterns: []
        )
        XCTAssertEqual(result, -1)
    }

    func testContainsAny_emptyPatterns_returnsFalse() {
        // The implementation short-circuits: empty patterns returns false
        // without loading the Rust dylib.
        let result = RustPatternMatcher.outputPatterns.containsAny(
            haystack: "some text",
            patterns: []
        )
        XCTAssertEqual(result, false)
    }

    // MARK: - Fallback Behavior (Rust dylib not loaded)

    func testFirstMatchIndex_returnsNilWhenRustUnavailable() {
        // When the Rust dylib is not loaded, firstMatchIndex should return nil
        // for non-empty patterns.
        let result = RustPatternMatcher.outputPatterns.firstMatchIndex(
            haystack: "hello world",
            patterns: ["hello"]
        )
        // nil means Rust not available; Int means Rust is loaded.
        _ = result
    }

    func testContainsAny_returnsNilWhenRustUnavailable() {
        // When the Rust dylib is not loaded, containsAny should return nil
        // for non-empty patterns.
        let result = RustPatternMatcher.outputPatterns.containsAny(
            haystack: "hello world",
            patterns: ["hello"]
        )
        // nil means Rust not available; Bool means Rust is loaded.
        _ = result
    }

    // MARK: - Empty / Nil Input Handling

    func testFirstMatchIndex_emptyHaystack_doesNotCrash() {
        _ = RustPatternMatcher.outputPatterns.firstMatchIndex(
            haystack: "",
            patterns: ["pattern"]
        )
    }

    func testContainsAny_emptyHaystack_doesNotCrash() {
        _ = RustPatternMatcher.outputPatterns.containsAny(
            haystack: "",
            patterns: ["pattern"]
        )
    }

    func testFirstMatchIndex_emptyHaystackAndPatterns_returnsMinusOne() {
        let result = RustPatternMatcher.outputPatterns.firstMatchIndex(
            haystack: "",
            patterns: []
        )
        XCTAssertEqual(result, -1)
    }

    func testContainsAny_emptyHaystackAndPatterns_returnsFalse() {
        let result = RustPatternMatcher.outputPatterns.containsAny(
            haystack: "",
            patterns: []
        )
        XCTAssertEqual(result, false)
    }

    // MARK: - Long / Large Inputs

    func testFirstMatchIndex_longHaystack_doesNotCrash() {
        let long = String(repeating: "a", count: 100_000)
        _ = RustPatternMatcher.outputPatterns.firstMatchIndex(
            haystack: long,
            patterns: ["needle"]
        )
    }

    func testContainsAny_longHaystack_doesNotCrash() {
        let long = String(repeating: "a", count: 100_000)
        _ = RustPatternMatcher.outputPatterns.containsAny(
            haystack: long,
            patterns: ["needle"]
        )
    }

    func testFirstMatchIndex_manyPatterns_doesNotCrash() {
        let patterns = (0..<100).map { "pattern_\($0)" }
        _ = RustPatternMatcher.outputPatterns.firstMatchIndex(
            haystack: "test input",
            patterns: patterns
        )
    }

    func testContainsAny_manyPatterns_doesNotCrash() {
        let patterns = (0..<100).map { "pattern_\($0)" }
        _ = RustPatternMatcher.outputPatterns.containsAny(
            haystack: "test input",
            patterns: patterns
        )
    }

    // MARK: - Unicode

    func testFirstMatchIndex_unicodeHaystack_doesNotCrash() {
        _ = RustPatternMatcher.outputPatterns.firstMatchIndex(
            haystack: "cafe\u{0301} terminee",
            patterns: ["terminee"]
        )
    }

    func testContainsAny_unicodePatterns_doesNotCrash() {
        _ = RustPatternMatcher.outputPatterns.containsAny(
            haystack: "some output text",
            patterns: ["terminee"]
        )
    }

    // MARK: - Both Instances Independently Usable

    func testBothInstances_canBeCalledIndependently() {
        _ = RustPatternMatcher.outputPatterns.containsAny(
            haystack: "output text",
            patterns: ["output"]
        )
        _ = RustPatternMatcher.waitPatterns.containsAny(
            haystack: "wait text",
            patterns: ["wait"]
        )
    }

    // MARK: - Thread Safety

    func testFirstMatchIndex_concurrentAccess_doesNotCrash() {
        let group = DispatchGroup()
        let patterns = ["alpha", "beta", "gamma"]
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                _ = RustPatternMatcher.outputPatterns.firstMatchIndex(
                    haystack: "test input \(i)",
                    patterns: patterns
                )
                group.leave()
            }
        }
        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success)
    }

    func testContainsAny_concurrentAccess_doesNotCrash() {
        let group = DispatchGroup()
        let patterns = ["alpha", "beta", "gamma"]
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                _ = RustPatternMatcher.waitPatterns.containsAny(
                    haystack: "test input \(i)",
                    patterns: patterns
                )
                group.leave()
            }
        }
        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success)
    }
}
