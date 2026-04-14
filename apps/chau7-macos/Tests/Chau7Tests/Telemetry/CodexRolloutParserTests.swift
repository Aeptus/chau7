import XCTest
@testable import Chau7Core

final class CodexRolloutParserTests: XCTestCase {
    func testParse_countsOnlyRunLocalTokenDeltas() {
        let startedAt = CodexRolloutParser.parseDate("2026-04-01T10:00:00.000Z")!
        let jsonl = """
        {"timestamp":"2026-04-01T09:59:58.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":10},"total_token_usage":{"input_tokens":500,"output_tokens":200}}}}
        {"timestamp":"2026-04-01T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-04-01T10:00:02.000Z","type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"commit"}]}}
        {"timestamp":"2026-04-01T10:00:03.000Z","type":"response_item","payload":{"role":"assistant","content":[{"type":"output_text","text":"done"},{"type":"function_call","call_id":"call-1","name":"apply_patch","arguments":"{}"}]}}
        {"timestamp":"2026-04-01T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":8,"output_tokens":20,"reasoning_output_tokens":3},"total_token_usage":{"input_tokens":550,"output_tokens":220}}}}
        {"timestamp":"2026-04-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"cached_input_tokens":2,"output_tokens":10,"reasoning_output_tokens":1},"total_token_usage":{"input_tokens":580,"output_tokens":230}}}}
        """

        let parsed = CodexRolloutParser.parse(jsonl: jsonl, runID: "run-1", startedAt: startedAt)

        XCTAssertEqual(parsed.model, "gpt-5-codex")
        XCTAssertEqual(parsed.turns.count, 2)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(parsed.tokenUsage.inputTokens, 80)
        XCTAssertEqual(parsed.tokenUsage.cachedInputTokens, 10)
        XCTAssertEqual(parsed.tokenUsage.outputTokens, 30)
        XCTAssertEqual(parsed.tokenUsage.reasoningOutputTokens, 4)
    }

    func testParse_excludesEventsAfterRunEnd() {
        let startedAt = CodexRolloutParser.parseDate("2026-04-01T10:00:00.000Z")!
        let endedAt = CodexRolloutParser.parseDate("2026-04-01T10:00:04.500Z")!
        // swiftlint:disable line_length
        let jsonl = """
        {"timestamp":"2026-04-01T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"2026-04-01T10:00:02.000Z","type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"fix"}]}}
        {"timestamp":"2026-04-01T10:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":4,"output_tokens":10,"reasoning_output_tokens":1},"total_token_usage":{"input_tokens":40,"cached_input_tokens":4,"output_tokens":10,"reasoning_output_tokens":1}}}}
        {"timestamp":"2026-04-01T10:00:05.000Z","type":"response_item","payload":{"role":"assistant","content":[{"type":"output_text","text":"late"}]}}
        {"timestamp":"2026-04-01T10:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":4000,"cached_input_tokens":400,"output_tokens":1000,"reasoning_output_tokens":100},"total_token_usage":{"input_tokens":4040,"cached_input_tokens":404,"output_tokens":1010,"reasoning_output_tokens":101}}}}
        """
        // swiftlint:enable line_length

        let parsed = CodexRolloutParser.parse(jsonl: jsonl, runID: "run-2", startedAt: startedAt, endedAt: endedAt)

        XCTAssertEqual(parsed.turns.count, 1)
        XCTAssertEqual(parsed.tokenUsage.inputTokens, 40)
        XCTAssertEqual(parsed.tokenUsage.cachedInputTokens, 4)
        XCTAssertEqual(parsed.tokenUsage.outputTokens, 10)
        XCTAssertEqual(parsed.tokenUsage.reasoningOutputTokens, 1)
    }
}
