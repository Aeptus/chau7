import XCTest
@testable import Chau7Core

final class HistoryEntryParserTests: XCTestCase {

    // MARK: - Valid Parsing

    func testParseAllFields() throws {
        let json = """
        {"session_id":"abc123","ts":1700000000,"text":"hello world","display":"Hello World"}
        """
        let entry = try HistoryEntryParser.parse(line: json)

        XCTAssertEqual(entry.sessionId, "abc123")
        XCTAssertEqual(entry.timestamp, 1_700_000_000)
        XCTAssertEqual(entry.summary, "hello world")
        XCTAssertFalse(entry.isExit)
        XCTAssertEqual(entry.activityKind, .prompt)
    }

    func testParseUsesTextOverDisplay() throws {
        let json = """
        {"session_id":"s1","ts":100,"text":"from text","display":"from display"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.summary, "from text")
    }

    func testParseFallsBackToDisplayWhenTextEmpty() throws {
        let json = """
        {"session_id":"s1","ts":100,"text":"","display":"from display"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.summary, "from display")
    }

    func testParseFallsBackToDisplayWhenTextMissing() throws {
        let json = """
        {"session_id":"s1","ts":100,"display":"fallback"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.summary, "fallback")
    }

    func testParseMissingTextAndDisplay() throws {
        let json = """
        {"session_id":"s1","ts":100}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.summary, "")
    }

    // MARK: - Alternative Key Names

    func testParseSessionIdAlternativeKey() throws {
        let json = """
        {"sessionId":"alt-id","ts":100}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.sessionId, "alt-id")
    }

    func testParseTimestampAlternativeKey() throws {
        let json = """
        {"session_id":"s1","timestamp":1700000000}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.timestamp, 1_700_000_000)
    }

    // MARK: - Timestamp Normalization

    func testParseNormalizesMillisecondTimestamp() throws {
        // > 1_000_000_000_000 → divide by 1000
        let json = """
        {"session_id":"s1","ts":1700000000000}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.timestamp, 1_700_000_000, accuracy: 0.001)
    }

    func testParseKeepsSecondTimestampAsIs() throws {
        let json = """
        {"session_id":"s1","ts":1700000000}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.timestamp, 1_700_000_000)
    }

    func testParseBoundaryTimestampNotNormalized() throws {
        // Exactly 1_000_000_000_000 is NOT > threshold, so NOT normalized
        let json = """
        {"session_id":"s1","ts":1000000000000}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.timestamp, 1_000_000_000_000, accuracy: 0.001)
    }

    func testParseBelowBoundaryNotNormalized() throws {
        // 999_999_999_999 is NOT > 1_000_000_000_000
        let json = """
        {"session_id":"s1","ts":999999999999}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.timestamp, 999_999_999_999)
    }

    // MARK: - Exit Marker Detection

    func testParseExitMarkerFromDisplay() throws {
        let json = """
        {"session_id":"s1","ts":100,"text":"","display":"exit"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertTrue(entry.isExit)
    }

    func testParseExitMarkerFromText() throws {
        let json = """
        {"session_id":"s1","ts":100,"text":"exit","display":""}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertTrue(entry.isExit)
    }

    func testParseExitMarkerSlashExit() throws {
        let json = """
        {"session_id":"s1","ts":100,"display":"/exit"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertTrue(entry.isExit)
    }

    func testParseExitMarkerQuit() throws {
        let json = """
        {"session_id":"s1","ts":100,"display":"quit"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertTrue(entry.isExit)
    }

    func testParseExitMarkerSlashQuit() throws {
        let json = """
        {"session_id":"s1","ts":100,"display":"/quit"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertTrue(entry.isExit)
    }

    func testParseExitMarkerCaseInsensitive() throws {
        let json = """
        {"session_id":"s1","ts":100,"display":"EXIT"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertTrue(entry.isExit)
    }

    func testParseExitMarkerTrimmed() throws {
        let json = """
        {"session_id":"s1","ts":100,"display":"  exit  "}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertTrue(entry.isExit)
    }

    func testParseNonExitText() throws {
        let json = """
        {"session_id":"s1","ts":100,"text":"ls -la"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertFalse(entry.isExit)
        XCTAssertEqual(entry.activityKind, .prompt)
    }

    func testParseAssistantRoleMarksResponseActivity() throws {
        let json = """
        {"session_id":"s1","ts":100,"text":"Done","role":"assistant"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.activityKind, .response)
    }

    func testParseNestedAssistantRoleMarksResponseActivity() throws {
        let json = """
        {"session_id":"s1","ts":100,"message":{"role":"assistant"},"display":"Done"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.activityKind, .response)
    }

    func testParseExitMarkerPrefersDisplayOverText() throws {
        // When display is non-empty, exit check uses display
        let json = """
        {"session_id":"s1","ts":100,"text":"exit","display":"not exit"}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertFalse(entry.isExit)
    }

    // MARK: - Numeric Field Coercion

    func testParseTimestampAsInt() throws {
        let json = """
        {"session_id":"s1","ts":100}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.timestamp, 100)
    }

    func testParseTimestampAsDouble() throws {
        let json = """
        {"session_id":"s1","ts":100.5}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.timestamp, 100.5)
    }

    func testParseSessionIdFromNonStringCoerced() throws {
        // getString coerces non-string values via String(describing:)
        let json = """
        {"session_id":42,"ts":100}
        """
        let entry = try HistoryEntryParser.parse(line: json)
        XCTAssertEqual(entry.sessionId, "42")
    }

    // MARK: - Error Cases

    func testParseMissingSessionIdThrows() {
        let json = """
        {"ts":100}
        """
        XCTAssertThrowsError(try HistoryEntryParser.parse(line: json)) { error in
            guard let parseError = error as? HistoryEntryParseError else {
                XCTFail("Expected HistoryEntryParseError")
                return
            }
            if case .missingField(let field) = parseError {
                XCTAssertEqual(field, "session_id")
            } else {
                XCTFail("Expected .missingField")
            }
        }
    }

    func testParseMissingTimestampThrows() {
        let json = """
        {"session_id":"s1"}
        """
        XCTAssertThrowsError(try HistoryEntryParser.parse(line: json)) { error in
            guard let parseError = error as? HistoryEntryParseError else {
                XCTFail("Expected HistoryEntryParseError")
                return
            }
            if case .missingField(let field) = parseError {
                XCTAssertEqual(field, "ts")
            } else {
                XCTFail("Expected .missingField")
            }
        }
    }

    func testParseInvalidJSONThrows() {
        XCTAssertThrowsError(try HistoryEntryParser.parse(line: "not json"))
    }

    func testParseEmptyStringThrows() {
        XCTAssertThrowsError(try HistoryEntryParser.parse(line: ""))
    }

    func testParseJSONArrayThrows() {
        XCTAssertThrowsError(try HistoryEntryParser.parse(line: "[1,2,3]")) { error in
            XCTAssertTrue(error is HistoryEntryParseError)
        }
    }

    // MARK: - HistoryEntry Equatable

    func testHistoryEntryEquality() {
        let a = HistoryEntry(sessionId: "s1", timestamp: 100, summary: "hello", isExit: false)
        let b = HistoryEntry(sessionId: "s1", timestamp: 100, summary: "hello", isExit: false)
        XCTAssertEqual(a, b)
    }

    func testHistoryEntryInequality() {
        let a = HistoryEntry(sessionId: "s1", timestamp: 100, summary: "hello", isExit: false)
        let b = HistoryEntry(sessionId: "s2", timestamp: 100, summary: "hello", isExit: false)
        XCTAssertNotEqual(a, b)
    }
}
