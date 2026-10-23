import XCTest
@testable import Chau7Core

// MARK: - AIEventParser Tests

final class AIEventParserTests: XCTestCase {

    // MARK: - Valid Parsing

    func testParseValidJSONAllFields() throws {
        let json = """
        {"source":"app","type":"finished","tool":"Claude","message":"All done","ts":"2025-01-14T12:00:00Z"}
        """

        let event = try AIEventParser.parse(line: json)

        XCTAssertEqual(event.source, .app)
        XCTAssertEqual(event.type, "finished")
        XCTAssertEqual(event.tool, "Claude")
        XCTAssertEqual(event.message, "All done")
        XCTAssertEqual(event.ts, "2025-01-14T12:00:00Z")
    }

    func testParseMinimalJSON() throws {
        // Only the required "type" field
        let json = """
        {"type":"idle"}
        """

        let event = try AIEventParser.parse(line: json)

        XCTAssertEqual(event.type, "idle")
        XCTAssertEqual(event.source, .eventsLog, "Should default to eventsLog")
        XCTAssertEqual(event.tool, "CLI", "Should default to CLI")
        XCTAssertEqual(event.message, "", "Should default to empty string")
        XCTAssertFalse(event.ts.isEmpty, "Should have a default timestamp")
    }

    func testParseDifferentSources() throws {
        let sources = ["app", "terminal_session", "api_proxy", "claude_code", "shell"]

        for source in sources {
            let json = """
            {"source":"\(source)","type":"update"}
            """
            let event = try AIEventParser.parse(line: json)
            XCTAssertEqual(event.source.rawValue, source)
        }
    }

    func testParseUnknownSourcePreserved() throws {
        let json = """
        {"source":"custom_integration","type":"update"}
        """

        let event = try AIEventParser.parse(line: json)

        XCTAssertEqual(event.source.rawValue, "custom_integration")
    }

    // MARK: - Error Cases

    func testParseMissingRequiredType() {
        let json = """
        {"source":"app","tool":"Claude"}
        """

        XCTAssertThrowsError(try AIEventParser.parse(line: json)) { error in
            guard let parseError = error as? AIEventParseError else {
                XCTFail("Expected AIEventParseError, got \(type(of: error))")
                return
            }
            if case .missingField(let field) = parseError {
                XCTAssertEqual(field, "type")
            } else {
                XCTFail("Expected .missingField(\"type\"), got \(parseError)")
            }
        }
    }

    func testParseInvalidFieldType() {
        // "type" is an integer instead of a string
        let json = """
        {"type": 123}
        """

        XCTAssertThrowsError(try AIEventParser.parse(line: json)) { error in
            guard let parseError = error as? AIEventParseError else {
                XCTFail("Expected AIEventParseError, got \(type(of: error))")
                return
            }
            if case .invalidFieldType(let field) = parseError {
                XCTAssertEqual(field, "type")
            } else {
                XCTFail("Expected .invalidFieldType(\"type\"), got \(parseError)")
            }
        }
    }

    func testParseJSONArrayThrowsNotJSONObject() {
        let json = "[1, 2, 3]"

        XCTAssertThrowsError(try AIEventParser.parse(line: json)) { error in
            XCTAssertTrue(error is AIEventParseError, "Expected AIEventParseError for JSON array")
        }
    }

    func testParseNonJSONStringThrows() {
        let invalid = "this is not json"

        XCTAssertThrowsError(try AIEventParser.parse(line: invalid))
    }

    func testParseEmptyStringThrows() {
        XCTAssertThrowsError(try AIEventParser.parse(line: ""))
    }

    func testParseInvalidSourceFieldType() {
        // "source" is a number instead of string
        let json = """
        {"source": 42, "type": "update"}
        """

        XCTAssertThrowsError(try AIEventParser.parse(line: json)) { error in
            guard let parseError = error as? AIEventParseError else {
                XCTFail("Expected AIEventParseError")
                return
            }
            if case .invalidFieldType(let field) = parseError {
                XCTAssertEqual(field, "source")
            } else {
                XCTFail("Expected .invalidFieldType(\"source\"), got \(parseError)")
            }
        }
    }

    // MARK: - Edge Cases

    func testParseUnicodeContent() throws {
        let json = """
        {"type":"update","message":"Tâche terminée 🎉","tool":"Claude"}
        """

        let event = try AIEventParser.parse(line: json)

        XCTAssertEqual(event.message, "Tâche terminée 🎉")
    }

    func testParseEmptyTypeString() throws {
        // Empty string is a valid string value — parser doesn't reject it
        let json = """
        {"type":""}
        """

        let event = try AIEventParser.parse(line: json)
        XCTAssertEqual(event.type, "")
    }

    func testParseExtraFieldsIgnored() throws {
        let json = """
        {"type":"idle","extra_field":"ignored","nested":{"a":1}}
        """

        let event = try AIEventParser.parse(line: json)
        XCTAssertEqual(event.type, "idle")
    }
}
