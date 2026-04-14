import XCTest
@testable import Chau7Core

final class ClaudeTranscriptParserTests: XCTestCase {
    func testIngest_deduplicatesRepeatedAssistantUsageByRequestIdentity() {
        let startedAt = ClaudeTranscriptUsageParser.parseDate("2026-04-01T09:00:00.000Z")!
        let jsonl = [
            #"{"timestamp":"2026-04-01T08:59:59.000Z","message":{"role":"assistant","model":"claude-sonnet","usage":{"input_tokens":999,"cache_creation_input_tokens":1,"cache_read_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":4},"content":["#
                + #"{"type":"text","text":"old"}]},"requestId":"req-old"}"#,
            #"{"timestamp":"2026-04-01T09:00:01.000Z","message":{"id":"msg-1","role":"assistant","model":"claude-sonnet","usage":{"input_tokens":100,"cache_creation_input_tokens":10,"cache_read_input_tokens":5,"output_tokens":20,"reasoning_output_tokens":7},"content":["#
                + #"{"type":"text","text":"answer"}]},"requestId":"req-1"}"#,
            #"{"timestamp":"2026-04-01T09:00:02.000Z","message":{"id":"msg-1","role":"assistant","model":"claude-sonnet","usage":{"input_tokens":100,"cache_creation_input_tokens":10,"cache_read_input_tokens":5,"output_tokens":20,"reasoning_output_tokens":7},"content":["#
                + #"{"type":"tool_use","id":"tool-1","name":"Read","input":{"path":"README.md"}}]},"requestId":"req-1"}"#,
            #"{"timestamp":"2026-04-01T09:00:03.000Z","message":{"role":"user","content":"thanks"}}"#
        ].joined(separator: "\n")

        var state = ClaudeTranscriptUsageParser.State()
        ClaudeTranscriptUsageParser.ingest(jsonl: jsonl, runID: "run-1", startedAt: startedAt, state: &state)

        XCTAssertEqual(state.model, "claude-sonnet")
        XCTAssertEqual(state.turns.count, 3)
        XCTAssertEqual(state.toolCalls.count, 1)
        XCTAssertEqual(state.tokenUsage.inputTokens, 100)
        XCTAssertEqual(state.tokenUsage.cacheCreationInputTokens, 10)
        XCTAssertEqual(state.tokenUsage.cacheReadInputTokens, 5)
        XCTAssertEqual(state.tokenUsage.cachedInputTokens, 15)
        XCTAssertEqual(state.tokenUsage.outputTokens, 20)
        XCTAssertEqual(state.tokenUsage.reasoningOutputTokens, 7)
        XCTAssertEqual(state.turns[0].inputTokens, 100)
        XCTAssertEqual(state.turns[0].cacheCreationInputTokens, 10)
        XCTAssertEqual(state.turns[0].cacheReadInputTokens, 5)
        XCTAssertNil(state.turns[1].inputTokens, "duplicate assistant fragment should not count usage twice")
    }

    func testIngest_excludesMessagesAfterRunEnd() {
        let startedAt = ClaudeTranscriptUsageParser.parseDate("2026-04-01T09:00:00.000Z")!
        let endedAt = ClaudeTranscriptUsageParser.parseDate("2026-04-01T09:00:02.500Z")!
        // swiftlint:disable line_length
        let jsonl = [
            #"{"timestamp":"2026-04-01T09:00:01.000Z","message":{"role":"assistant","model":"claude-sonnet","usage":{"input_tokens":100,"cache_creation_input_tokens":10,"cache_read_input_tokens":5,"output_tokens":20,"reasoning_output_tokens":7},"content":[{"type":"text","text":"answer"}]},"requestId":"req-1"}"#,
            #"{"timestamp":"2026-04-01T09:00:03.000Z","message":{"role":"assistant","model":"claude-sonnet","usage":{"input_tokens":900,"cache_creation_input_tokens":90,"cache_read_input_tokens":45,"output_tokens":200,"reasoning_output_tokens":70},"content":[{"type":"text","text":"late"}]},"requestId":"req-2"}"#
        ].joined(separator: "\n")
        // swiftlint:enable line_length

        var state = ClaudeTranscriptUsageParser.State()
        ClaudeTranscriptUsageParser.ingest(
            jsonl: jsonl,
            runID: "run-2",
            startedAt: startedAt,
            endedAt: endedAt,
            state: &state
        )

        XCTAssertEqual(state.turns.count, 1)
        XCTAssertEqual(state.tokenUsage.inputTokens, 100)
        XCTAssertEqual(state.tokenUsage.cacheCreationInputTokens, 10)
        XCTAssertEqual(state.tokenUsage.cacheReadInputTokens, 5)
        XCTAssertEqual(state.tokenUsage.outputTokens, 20)
        XCTAssertEqual(state.tokenUsage.reasoningOutputTokens, 7)
    }
}
