import XCTest
@testable import Chau7Core

final class ParsingTests: XCTestCase {

    func testAIEventParserDefaults() throws {
        let line = #"{"type":"finished","tool":"Codex","message":"Done"}"#
        let event = try AIEventParser.parse(line: line)
        XCTAssertEqual(event.source, .eventsLog)
        XCTAssertEqual(event.type, "finished")
        XCTAssertEqual(event.tool, "Codex")
        XCTAssertEqual(event.message, "Done")
        XCTAssertFalse(event.ts.isEmpty)
    }

    func testHistoryEntryParserTimestampMilliseconds() throws {
        let line = #"{"session_id":"abc","ts":1700000000000,"text":"ok"}"#
        let entry = try HistoryEntryParser.parse(line: line)
        XCTAssertEqual(entry.sessionId, "abc")
        XCTAssertEqual(entry.summary, "ok")
        XCTAssertEqual(entry.timestamp, 1700000000, accuracy: 0.5)
    }

    func testPrettyPrintJSON() {
        let input = #"{"b":1,"a":2}"#
        let output = JSONPrettyPrinter.prettyPrint(input)
        XCTAssertNotNil(output)
        XCTAssertTrue(output?.contains("\n") ?? false)
        XCTAssertTrue(output?.contains("\"a\"") ?? false)
    }

    func testPrettyPrintJSONInvalid() {
        XCTAssertNil(JSONPrettyPrinter.prettyPrint("not-json"))
    }
}
