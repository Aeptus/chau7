import XCTest
@testable import Chau7Core

final class SnippetParsingTests: XCTestCase {

    // MARK: - Placeholder Expansion Tests

    func testExpandSimplePlaceholder() {
        let result = SnippetParsing.expandPlaceholders(in: "Hello ${1}")
        XCTAssertEqual(result.text, "Hello ")
        XCTAssertEqual(result.placeholders.count, 1)
        XCTAssertEqual(result.placeholders[0].index, 1)
        XCTAssertEqual(result.placeholders[0].start, 6)
        XCTAssertEqual(result.placeholders[0].length, 0)
    }

    func testExpandPlaceholderWithDefault() {
        let result = SnippetParsing.expandPlaceholders(in: "Hello ${1:World}")
        XCTAssertEqual(result.text, "Hello World")
        XCTAssertEqual(result.placeholders.count, 1)
        XCTAssertEqual(result.placeholders[0].index, 1)
        XCTAssertEqual(result.placeholders[0].start, 6)
        XCTAssertEqual(result.placeholders[0].length, 5)
    }

    func testExpandMultiplePlaceholders() {
        let result = SnippetParsing.expandPlaceholders(in: "${1:first} and ${2:second}")
        XCTAssertEqual(result.text, "first and second")
        XCTAssertEqual(result.placeholders.count, 2)
        XCTAssertEqual(result.placeholders[0].index, 1)
        XCTAssertEqual(result.placeholders[1].index, 2)
    }

    func testExpandFinalCursorPosition() {
        let result = SnippetParsing.expandPlaceholders(in: "Hello ${1:name}!${0}")
        XCTAssertEqual(result.text, "Hello name!")
        XCTAssertEqual(result.finalCursorOffset, 11) // After "Hello name!"
    }

    func testExpandNoPlaceholders() {
        let result = SnippetParsing.expandPlaceholders(in: "Hello World")
        XCTAssertEqual(result.text, "Hello World")
        XCTAssertEqual(result.placeholders.count, 0)
        XCTAssertNil(result.finalCursorOffset)
    }

    func testExpandPlaceholdersSorted() {
        let result = SnippetParsing.expandPlaceholders(in: "${3:c} ${1:a} ${2:b}")
        XCTAssertEqual(result.placeholders[0].index, 1)
        XCTAssertEqual(result.placeholders[1].index, 2)
        XCTAssertEqual(result.placeholders[2].index, 3)
    }

    func testExpandEmptyDefault() {
        let result = SnippetParsing.expandPlaceholders(in: "prefix${1}suffix")
        XCTAssertEqual(result.text, "prefixsuffix")
        XCTAssertEqual(result.placeholders[0].start, 6)
        XCTAssertEqual(result.placeholders[0].length, 0)
    }

    // MARK: - Environment Token Tests

    func testReplaceEnvTokens() {
        let result = SnippetParsing.replaceEnvTokens(in: "User: ${env:USER}", provider: { key in
            key == "USER" ? "testuser" : ""
        })
        XCTAssertEqual(result, "User: testuser")
    }

    func testReplaceMultipleEnvTokens() {
        let result = SnippetParsing.replaceEnvTokens(in: "${env:HOME}/${env:USER}", provider: { key in
            switch key {
            case "HOME": return "/home/test"
            case "USER": return "testuser"
            default: return ""
            }
        })
        XCTAssertEqual(result, "/home/test/testuser")
    }

    func testReplaceMissingEnvToken() {
        let result = SnippetParsing.replaceEnvTokens(in: "Value: ${env:MISSING}", provider: { _ in "" })
        XCTAssertEqual(result, "Value: ")
    }

    func testNoEnvTokens() {
        let result = SnippetParsing.replaceEnvTokens(in: "No tokens here", provider: { _ in "FAIL" })
        XCTAssertEqual(result, "No tokens here")
    }

    // MARK: - CSV Parsing Tests

    func testParseCSVBasic() {
        let result = SnippetParsing.parseCSV("a, b, c")
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testParseCSVWithSpaces() {
        let result = SnippetParsing.parseCSV("  hello  ,  world  ")
        XCTAssertEqual(result, ["hello", "world"])
    }

    func testParseCSVEmpty() {
        XCTAssertEqual(SnippetParsing.parseCSV(""), [])
        XCTAssertEqual(SnippetParsing.parseCSV("  "), [])
    }

    func testParseCSVEmptyValues() {
        let result = SnippetParsing.parseCSV("a,,b,  ,c")
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testParseCSVSingleValue() {
        XCTAssertEqual(SnippetParsing.parseCSV("single"), ["single"])
    }

    // MARK: - Token Detection Tests

    func testContainsTokens() {
        XCTAssertTrue(SnippetParsing.containsTokens("cd ${cwd}"))
        XCTAssertTrue(SnippetParsing.containsTokens("Home: ${home}"))
        XCTAssertTrue(SnippetParsing.containsTokens("Date: ${date}"))
        XCTAssertTrue(SnippetParsing.containsTokens("Time: ${time}"))
        XCTAssertTrue(SnippetParsing.containsTokens("Paste: ${clip}"))
        XCTAssertFalse(SnippetParsing.containsTokens("No tokens"))
    }

    func testContainsEnvTokens() {
        XCTAssertTrue(SnippetParsing.containsEnvTokens("${env:PATH}"))
        XCTAssertTrue(SnippetParsing.containsEnvTokens("User is ${env:USER}"))
        XCTAssertFalse(SnippetParsing.containsEnvTokens("$PATH"))
        XCTAssertFalse(SnippetParsing.containsEnvTokens("${PATH}"))
    }

    func testContainsPlaceholders() {
        XCTAssertTrue(SnippetParsing.containsPlaceholders("${1}"))
        XCTAssertTrue(SnippetParsing.containsPlaceholders("${0}"))
        XCTAssertTrue(SnippetParsing.containsPlaceholders("Hello ${1:name}"))
        XCTAssertFalse(SnippetParsing.containsPlaceholders("${env:VAR}"))
        XCTAssertFalse(SnippetParsing.containsPlaceholders("${cwd}"))
        XCTAssertFalse(SnippetParsing.containsPlaceholders("No placeholders"))
    }

    // MARK: - Complex Snippet Tests

    func testComplexSnippetExpansion() {
        let snippet = """
        function ${1:name}(${2:params}) {
            ${0}
        }
        """
        let result = SnippetParsing.expandPlaceholders(in: snippet)
        // Note: Indentation before ${0} is preserved when placeholder is removed
        XCTAssertEqual(result.text, "function name(params) {\n    \n}")
        XCTAssertEqual(result.placeholders.count, 2)
        XCTAssertNotNil(result.finalCursorOffset)
    }

    func testMixedTokensAndPlaceholders() {
        // Note: This only tests placeholder expansion, not token replacement
        let result = SnippetParsing.expandPlaceholders(in: "${cwd}/${1:filename}")
        XCTAssertEqual(result.text, "${cwd}/filename")
        XCTAssertEqual(result.placeholders.count, 1)
    }
}
