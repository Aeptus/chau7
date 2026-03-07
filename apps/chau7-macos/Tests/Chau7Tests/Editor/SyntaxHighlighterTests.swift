import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

// MARK: - EditorLanguage Tests

final class EditorLanguageTests: XCTestCase {

    // MARK: - Language Detection from File Extension

    func testDetectSwift() {
        let lang = EditorLanguage.detect(from: "main.swift")
        XCTAssertEqual(lang.id, "swift")
        XCTAssertEqual(lang.displayName, "Swift")
    }

    func testDetectPython() {
        let lang = EditorLanguage.detect(from: "script.py")
        XCTAssertEqual(lang.id, "python")
        XCTAssertEqual(lang.displayName, "Python")
    }

    func testDetectJavaScript() {
        let lang = EditorLanguage.detect(from: "app.js")
        XCTAssertEqual(lang.id, "javascript")
    }

    func testDetectJSX() {
        let lang = EditorLanguage.detect(from: "Component.jsx")
        XCTAssertEqual(lang.id, "javascript")
    }

    func testDetectTypeScript() {
        let lang = EditorLanguage.detect(from: "index.ts")
        XCTAssertEqual(lang.id, "javascript")
    }

    func testDetectTSX() {
        let lang = EditorLanguage.detect(from: "Component.tsx")
        XCTAssertEqual(lang.id, "javascript")
    }

    func testDetectShell() {
        XCTAssertEqual(EditorLanguage.detect(from: "setup.sh").id, "shell")
        XCTAssertEqual(EditorLanguage.detect(from: "init.bash").id, "shell")
        XCTAssertEqual(EditorLanguage.detect(from: "config.zsh").id, "shell")
        XCTAssertEqual(EditorLanguage.detect(from: "setup.fish").id, "shell")
    }

    func testDetectJSON() {
        let lang = EditorLanguage.detect(from: "package.json")
        XCTAssertEqual(lang.id, "json")
    }

    func testDetectYAML() {
        XCTAssertEqual(EditorLanguage.detect(from: "config.yml").id, "yaml")
        XCTAssertEqual(EditorLanguage.detect(from: "config.yaml").id, "yaml")
    }

    func testDetectTOML() {
        let lang = EditorLanguage.detect(from: "Cargo.toml")
        XCTAssertEqual(lang.id, "toml")
    }

    func testDetectMarkdown() {
        XCTAssertEqual(EditorLanguage.detect(from: "README.md").id, "markdown")
        XCTAssertEqual(EditorLanguage.detect(from: "docs.markdown").id, "markdown")
    }

    func testDetectGo() {
        let lang = EditorLanguage.detect(from: "main.go")
        XCTAssertEqual(lang.id, "go")
    }

    func testDetectRust() {
        let lang = EditorLanguage.detect(from: "lib.rs")
        XCTAssertEqual(lang.id, "rust")
    }

    func testDetectRuby() {
        let lang = EditorLanguage.detect(from: "Gemfile.rb")
        XCTAssertEqual(lang.id, "ruby")
    }

    func testDetectPlainText() {
        XCTAssertEqual(EditorLanguage.detect(from: "notes.txt").id, "text")
        XCTAssertEqual(EditorLanguage.detect(from: "output.log").id, "text")
    }

    func testUnknownExtensionFallsBackToPlainText() {
        let lang = EditorLanguage.detect(from: "data.csv")
        XCTAssertEqual(lang.id, "text")
        XCTAssertEqual(lang.displayName, "Plain Text")
    }

    func testNoExtensionFallsBackToPlainText() {
        let lang = EditorLanguage.detect(from: "Makefile")
        XCTAssertEqual(lang.id, "text")
    }

    func testDetectionIsCaseInsensitive() {
        // pathExtension.lowercased() should handle uppercase extensions
        XCTAssertEqual(EditorLanguage.detect(from: "App.SWIFT").id, "swift")
        XCTAssertEqual(EditorLanguage.detect(from: "module.JS").id, "javascript")
        XCTAssertEqual(EditorLanguage.detect(from: "Config.YML").id, "yaml")
    }

    func testDetectionWithPath() {
        // NSString.pathExtension works with full paths
        let lang = EditorLanguage.detect(from: "/Users/dev/project/src/main.swift")
        XCTAssertEqual(lang.id, "swift")
    }

    // MARK: - Highlight Rule Structure

    func testSwiftHasHighlightRules() {
        XCTAssertFalse(EditorLanguage.swift.highlightingRules.isEmpty)
    }

    func testPlainTextHasNoRules() {
        XCTAssertTrue(EditorLanguage.plainText.highlightingRules.isEmpty)
    }

    func testAllLanguagesHaveUniqueIDs() {
        let ids = EditorLanguage.allLanguages.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Language IDs must be unique")
    }

    func testAllLanguagesHaveDisplayNames() {
        for lang in EditorLanguage.allLanguages {
            XCTAssertFalse(lang.displayName.isEmpty, "\(lang.id) should have a display name")
        }
    }

    func testAllLanguagesHaveExtensions() {
        for lang in EditorLanguage.allLanguages {
            XCTAssertFalse(lang.extensions.isEmpty, "\(lang.id) should have at least one extension")
        }
    }

    func testHighlightRulePatternsAreValidRegex() {
        for lang in EditorLanguage.allLanguages {
            for (index, rule) in lang.highlightingRules.enumerated() {
                XCTAssertNoThrow(
                    try NSRegularExpression(pattern: rule.pattern, options: rule.options),
                    "\(lang.id) rule[\(index)] has invalid regex: \(rule.pattern)"
                )
            }
        }
    }

    // MARK: - Highlight Rule Matching

    func testSwiftKeywordRuleMatchesFunc() throws {
        let lang = EditorLanguage.swift
        guard let keywordRule = lang.highlightingRules.first else {
            XCTFail("Swift should have keyword rule")
            return
        }

        let regex = try NSRegularExpression(pattern: keywordRule.pattern, options: keywordRule.options)
        let input = "func hello() { return }"
        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.matches(in: input, options: [], range: range)

        // Should match "func" and "return"
        XCTAssertEqual(matches.count, 2, "Should match 'func' and 'return'")
    }

    func testPythonCommentRuleMatches() throws {
        let lang = EditorLanguage.python
        // The comment rule is the last single-line one before numbers: "#.*$"
        guard let commentRule = lang.highlightingRules.first(where: { $0.pattern == "#.*$" }) else {
            XCTFail("Python should have a comment rule")
            return
        }

        let regex = try NSRegularExpression(pattern: commentRule.pattern, options: commentRule.options)
        let input = "x = 1  # this is a comment"
        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.matches(in: input, options: [], range: range)

        XCTAssertEqual(matches.count, 1)
    }

    func testJSONStringRuleMatchesQuotedValues() throws {
        let lang = EditorLanguage.json
        guard let stringRule = lang.highlightingRules.first(where: {
            $0.pattern.contains("\"") && !$0.pattern.contains(":")
        }) else {
            XCTFail("JSON should have a string rule")
            return
        }

        let regex = try NSRegularExpression(pattern: stringRule.pattern, options: stringRule.options)
        let input = #""hello""#
        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.matches(in: input, options: [], range: range)

        XCTAssertEqual(matches.count, 1)
    }

    func testRustKeywordRuleMatchesMut() throws {
        let lang = EditorLanguage.rust
        guard let keywordRule = lang.highlightingRules.first else {
            XCTFail("Rust should have keyword rule")
            return
        }

        let regex = try NSRegularExpression(pattern: keywordRule.pattern, options: keywordRule.options)
        let input = "let mut x = 5;"
        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.matches(in: input, options: [], range: range)

        // Should match "let", "mut"
        XCTAssertEqual(matches.count, 2)
    }

    // MARK: - allLanguages Completeness

    func testAllLanguagesListContainsExpectedLanguages() {
        let ids = Set(EditorLanguage.allLanguages.map(\.id))
        let expected: Set = [
            "swift", "python", "javascript", "shell", "json", "yaml",
            "toml", "markdown", "go", "rust", "ruby", "text"
        ]
        XCTAssertEqual(ids, expected)
    }
}

// MARK: - SyntaxHighlighter Tests

@MainActor
final class SyntaxHighlighterTests: XCTestCase {

    private var highlighter: SyntaxHighlighter!

    override func setUp() {
        super.setUp()
        highlighter = SyntaxHighlighter.shared
        // Ensure syntax highlighting is enabled for tests
        FeatureSettings.shared.isSyntaxHighlightEnabled = true
        FeatureSettings.shared.isClickableURLsEnabled = true
        highlighter.clearCache()
        // Allow cache clear to complete
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    override func tearDown() {
        highlighter.clearCache()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        super.tearDown()
    }

    // MARK: - Empty Input Handling

    func testEmptyString() {
        let result = highlighter.highlight("")
        XCTAssertEqual(result.string, "")
    }

    func testWhitespaceOnly() {
        let result = highlighter.highlight("   ")
        XCTAssertEqual(result.string, "   ")
    }

    func testPlainTextNoPatterns() {
        let result = highlighter.highlight("hello world")
        XCTAssertEqual(result.string, "hello world")
    }

    // MARK: - Error Pattern Matching

    func testErrorKeywordHighlighted() {
        let result = highlighter.highlight("error: something went wrong")
        XCTAssertEqual(result.string, "error: something went wrong")

        // Check that the "error" portion has foreground color applied
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 0, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "Error keyword should have a foreground color")
    }

    func testFatalKeywordHighlighted() {
        let result = highlighter.highlight("fatal error encountered")
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 0, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "'fatal' should be highlighted")
    }

    func testErrorKeywordCaseInsensitive() {
        let result = highlighter.highlight("ERROR: build failed")
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 0, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "Uppercase ERROR should match")
    }

    // MARK: - Warning Pattern Matching

    func testWarningKeywordHighlighted() {
        let result = highlighter.highlight("warning: unused variable")
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 0, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "'warning' should be highlighted")
    }

    func testDeprecatedKeywordHighlighted() {
        let result = highlighter.highlight("deprecated: use newMethod instead")
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 0, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "'deprecated' should be highlighted")
    }

    // MARK: - Success Pattern Matching

    func testSuccessKeywordHighlighted() {
        let result = highlighter.highlight("Build success")
        // "success" starts at index 6
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 6, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "'success' should be highlighted")
    }

    // MARK: - URL Pattern Matching

    func testURLHighlighted() {
        let input = "Visit https://example.com for more info"
        let result = highlighter.highlight(input)

        // "https://example.com" starts at index 6
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 6, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.link], "URL should have a link attribute")
        XCTAssertNotNil(attrs[.underlineStyle], "URL should be underlined")
    }

    func testURLWithoutClickableURLsDisabled() {
        FeatureSettings.shared.isClickableURLsEnabled = false
        highlighter.clearCache()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        let input = "Visit https://example.com for more info"
        let result = highlighter.highlight(input)

        // URL should NOT have a link attribute when clickable URLs are disabled
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 6, effectiveRange: &effectiveRange)
        XCTAssertNil(attrs[.link], "URL should not be a link when clickable URLs are disabled")
    }

    // MARK: - Number Pattern Matching

    func testIntegerHighlighted() {
        let input = "count: 42"
        let result = highlighter.highlight(input)

        // "42" starts at index 7
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 7, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "Number should have a foreground color")
    }

    func testHexNumberHighlighted() {
        let input = "address: 0xFF00"
        let result = highlighter.highlight(input)

        // "0xFF00" starts at index 9
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 9, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "Hex number should have a foreground color")
    }

    // MARK: - String Pattern Matching

    func testQuotedStringHighlighted() {
        let input = #"key = "hello world""#
        let result = highlighter.highlight(input)

        // The opening quote starts at index 6
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 6, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "Quoted string should have a foreground color")
    }

    // MARK: - JSON Key Pattern Matching

    func testJSONKeyHighlighted() {
        let input = #""name": "value""#
        let result = highlighter.highlight(input)

        // "name": pattern should match from index 0
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 1, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "JSON key should have foreground color")
    }

    // MARK: - Prompt Pattern Matching

    func testPromptHighlighted() {
        let input = "user@host:$ ls -la"
        let result = highlighter.highlight(input)

        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 0, effectiveRange: &effectiveRange)
        XCTAssertNotNil(attrs[.foregroundColor], "Prompt should have a foreground color")
    }

    // MARK: - Syntax Highlighting Disabled

    func testHighlightDisabledReturnsPlainString() {
        FeatureSettings.shared.isSyntaxHighlightEnabled = false

        let input = "error: this should not be highlighted"
        let result = highlighter.highlight(input)
        XCTAssertEqual(result.string, input)

        // No foreground color should be applied
        var effectiveRange = NSRange()
        let attrs = result.attributes(at: 0, effectiveRange: &effectiveRange)
        XCTAssertNil(attrs[.foregroundColor], "No highlighting when feature is disabled")

        // Restore for other tests
        FeatureSettings.shared.isSyntaxHighlightEnabled = true
    }

    // MARK: - highlightLines

    func testHighlightLines() {
        let lines = ["error: bad", "warning: check", "all ok"]
        let results = highlighter.highlightLines(lines)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].string, "error: bad")
        XCTAssertEqual(results[1].string, "warning: check")
        XCTAssertEqual(results[2].string, "all ok")
    }

    func testHighlightLinesDisabled() {
        FeatureSettings.shared.isSyntaxHighlightEnabled = false

        let lines = ["error: bad", "hello"]
        let results = highlighter.highlightLines(lines)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].string, "error: bad")
        XCTAssertEqual(results[1].string, "hello")

        // No colors when disabled
        var effectiveRange = NSRange()
        let attrs = results[0].attributes(at: 0, effectiveRange: &effectiveRange)
        XCTAssertNil(attrs[.foregroundColor])

        FeatureSettings.shared.isSyntaxHighlightEnabled = true
    }

    // MARK: - highlightLinesAsync

    func testHighlightLinesAsync() {
        let expectation = expectation(description: "async highlight")
        let lines = ["error: bad", "success"]

        highlighter.highlightLinesAsync(lines) { results in
            XCTAssertEqual(results.count, 2)
            XCTAssertEqual(results[0].string, "error: bad")
            XCTAssertEqual(results[1].string, "success")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testHighlightLinesAsyncDisabled() {
        FeatureSettings.shared.isSyntaxHighlightEnabled = false
        let expectation = expectation(description: "async highlight disabled")

        highlighter.highlightLinesAsync(["error"]) { results in
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results[0].string, "error")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        FeatureSettings.shared.isSyntaxHighlightEnabled = true
    }

    // MARK: - Cache Behavior

    func testCacheReturnsSameResult() {
        let input = "error: cache test"
        let first = highlighter.highlight(input)
        // Allow async cache write to complete
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        let second = highlighter.highlight(input)

        // Both should produce identical attributed strings
        XCTAssertEqual(first, second, "Cached result should equal the original")
    }

    func testClearCacheAllowsReHighlight() {
        let input = "error: clear test"
        _ = highlighter.highlight(input)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        highlighter.clearCache()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        // After clearing, it should still produce a valid result
        let result = highlighter.highlight(input)
        XCTAssertEqual(result.string, input)
    }

    func testCacheEvictionDoesNotCrash() {
        // Fill cache beyond maxCacheSize (500) to trigger eviction
        for i in 0 ..< 550 {
            _ = highlighter.highlight("line \(i) with error marker")
        }
        // Allow all async cache writes to complete
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        // Should still work after eviction
        let result = highlighter.highlight("post-eviction test error")
        XCTAssertEqual(result.string, "post-eviction test error")
    }

    // MARK: - String Content Preservation

    func testOutputStringMatchesInput() {
        let inputs = [
            "simple text",
            "error: build failed with code 1",
            "https://example.com/path?q=1&r=2",
            #"{"key": "value", "count": 42}"#,
            "user@server:~/project$ git status",
            ""
        ]

        for input in inputs {
            let result = highlighter.highlight(input)
            XCTAssertEqual(result.string, input, "Highlighting should preserve the original text")
        }
    }
}
#endif
