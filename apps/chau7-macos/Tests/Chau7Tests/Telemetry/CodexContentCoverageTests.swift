import XCTest
@testable import Chau7
@testable import Chau7Core

final class CodexContentCoverageTests: XCTestCase {
    func testTruncatedTranscriptCannotClaimCompleteMetricsOrHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coverage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = tokenLine(900)
        let tail = "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5\"}}\n" + tokenLine(100)
        try (first + tail).write(to: url, atomically: true, encoding: .utf8)
        let provider = CodexContentProvider()
        let start = Date(timeIntervalSince1970: 0)
        let complete = try XCTUnwrap(provider.extractFromJSONL(file: url, runID: "run", startedAt: start, endedAt: nil))
        let partial = try XCTUnwrap(provider.extractFromJSONL(file: url, runID: "run", startedAt: start, endedAt: nil, maxBytes: tail.utf8.count))
        XCTAssertEqual(complete.totalInputTokens, 1000)
        XCTAssertEqual(complete.tokenUsageState, .complete)
        XCTAssertFalse(complete.transcriptIsPartial)
        XCTAssertEqual(partial.totalInputTokens, 100)
        XCTAssertEqual(partial.tokenUsageState, .partial)
        XCTAssertEqual(partial.costState, .partial)
        XCTAssertTrue(partial.transcriptIsPartial)
        let sanitized = TelemetryMetricsSanitizer.sanitize(partial, provider: "codex").content
        XCTAssertEqual(sanitized.tokenUsageState, .partial)
        var run = TelemetryRun(id: "run", provider: "codex", cwd: "/tmp", startedAt: start)
        run.applyContent(sanitized, invalidMessage: "invalid", clearOnValid: true)
        XCTAssertEqual(run.metadata["transcript_content_state"], "partial")
        XCTAssertEqual(run.rawTranscriptRef, url.path)
        XCTAssertEqual(try String(contentsOf: url), first + tail, "extraction must never modify source history")
    }

    func testCostBackfillPreservesPartialCoverage() throws {
        let run = TelemetryRun(id: "partial", provider: "codex", model: "gpt-5", cwd: "/tmp", startedAt: Date(), totalInputTokens: 100, tokenUsageState: .partial)
        XCTAssertEqual(try XCTUnwrap(TelemetryHistoricalCostBackfill.repairedRun(run)).costState, .partial)
    }

    private func tokenLine(_ input: Int) -> String {
        "{\"timestamp\":\"2026-09-17T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(input),\"output_tokens\":10}}}}\n"
    }
}
