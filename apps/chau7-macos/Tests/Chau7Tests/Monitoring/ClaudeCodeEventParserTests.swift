import XCTest
@testable import Chau7

final class ClaudeCodeEventParserTests: XCTestCase {
    func testParsesToolInputAndToolUseID() throws {
        // swiftlint:disable line_length
        let line = """
        {"type":"tool_start","hook":"PreToolUse","sessionId":"s1","transcriptPath":"/x","toolName":"AskUserQuestion","toolUseID":"toolu_9","message":"","cwd":"/repo","tabID":"tab","timestamp":"2026-07-17T10:00:00Z","toolInput":{"questions":[{"question":"Q?","options":[{"label":"A"},{"label":"B"}]}]}}
        """
        // swiftlint:enable line_length

        let event = try ClaudeCodeEventParser.parse(line: line)
        XCTAssertEqual(event.type, .toolStart)
        XCTAssertEqual(event.toolUseID, "toolu_9")

        let json = try XCTUnwrap(event.toolInputJSON)
        let roundTrip = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let questions = try XCTUnwrap(roundTrip["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.first?["question"] as? String, "Q?")
    }

    func testOldJSONLLinesWithoutNewFieldsStillParse() throws {
        // Lines written by an older helper script carry neither toolUseID nor
        // toolInput — they must keep decoding with defaults.
        let line = """
        {"type":"tool_complete","hook":"PostToolUse","sessionId":"s1","transcriptPath":"/x","toolName":"Bash","message":"","cwd":"/repo","tabID":"tab","timestamp":"2026-07-17T10:00:00Z"}
        """

        let event = try ClaudeCodeEventParser.parse(line: line)
        XCTAssertEqual(event.toolUseID, "")
        XCTAssertNil(event.toolInputJSON)
    }

    func testNonObjectToolInputReadsAsAbsent() throws {
        let line = """
        {"type":"tool_start","hook":"PreToolUse","sessionId":"s1","transcriptPath":"/x","toolName":"AskUserQuestion","message":"","cwd":"/repo","tabID":"tab","timestamp":"2026-07-17T10:00:00Z","toolInput":"just a string"}
        """

        let event = try ClaudeCodeEventParser.parse(line: line)
        XCTAssertNil(event.toolInputJSON)
    }
}
