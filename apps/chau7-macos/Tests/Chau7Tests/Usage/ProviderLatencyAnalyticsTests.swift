import XCTest
@testable import Chau7Core

final class ProviderLatencyAnalyticsTests: XCTestCase {
    func testMetricExplanationsDescribeLatencySemantics() {
        XCTAssertEqual(ProviderLatencyMetricKind.apiRequest.displayName, "API Response")
        XCTAssertTrue(ProviderLatencyMetricKind.apiRequest.detailedExplanation.contains("time to first token"))
        XCTAssertTrue(ProviderLatencyMetricKind.firstResponse.detailedExplanation.contains("first human prompt"))
    }

    func testPreferredAPILatencyPrefersTimeToFirstToken() {
        XCTAssertEqual(
            ProviderLatencyAnalytics.preferredAPILatencyMs(roundTripMs: 52_000, timeToFirstTokenMs: 1_450),
            1_450
        )
        XCTAssertEqual(
            ProviderLatencyAnalytics.preferredAPILatencyMs(roundTripMs: 980, timeToFirstTokenMs: nil),
            980
        )
        XCTAssertNil(
            ProviderLatencyAnalytics.preferredAPILatencyMs(roundTripMs: 0, timeToFirstTokenMs: 0)
        )
    }

    func testLatencyRelevantAPIEndpointsExcludeNonInferenceTraffic() {
        XCTAssertTrue(
            ProviderLatencyAnalytics.isLatencyRelevantAPIEndpoint(provider: "openai", endpoint: "/v1/responses")
        )
        XCTAssertFalse(
            ProviderLatencyAnalytics.isLatencyRelevantAPIEndpoint(provider: "openai", endpoint: "/v1/models")
        )
        XCTAssertFalse(
            ProviderLatencyAnalytics.isLatencyRelevantAPIEndpoint(provider: "openai", endpoint: "/v1/responses/compact")
        )
        XCTAssertTrue(
            ProviderLatencyAnalytics.isLatencyRelevantAPIEndpoint(provider: "anthropic", endpoint: "/v1/messages")
        )
        XCTAssertTrue(
            ProviderLatencyAnalytics.isLatencyRelevantAPIEndpoint(
                provider: "gemini",
                endpoint: "/v1beta/models/gemini-2.5-pro:streamGenerateContent"
            )
        )
    }

    func testAggregateComputesAverageAndPercentiles() {
        let samples = [
            ProviderLatencySample(provider: "codex", metricKind: .firstResponse, latencyMs: 100, timestamp: Date(timeIntervalSince1970: 1), sourceKind: "test"),
            ProviderLatencySample(provider: "codex", metricKind: .firstResponse, latencyMs: 200, timestamp: Date(timeIntervalSince1970: 2), sourceKind: "test"),
            ProviderLatencySample(provider: "codex", metricKind: .firstResponse, latencyMs: 300, timestamp: Date(timeIntervalSince1970: 3), sourceKind: "test"),
            ProviderLatencySample(provider: "codex", metricKind: .firstResponse, latencyMs: 500, timestamp: Date(timeIntervalSince1970: 4), sourceKind: "test")
        ]

        let aggregate = ProviderLatencyAnalytics.aggregate(samples: samples)

        XCTAssertEqual(aggregate?.count, 4)
        XCTAssertEqual(aggregate?.averageLatencyMs ?? 0, 275, accuracy: 0.01)
        XCTAssertEqual(aggregate?.p50LatencyMs, 300)
        XCTAssertEqual(aggregate?.p95LatencyMs, 500)
        XCTAssertEqual(aggregate?.minLatencyMs, 100)
        XCTAssertEqual(aggregate?.maxLatencyMs, 500)
    }

    func testBucketedWeekdayUsesCalendarOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let samples = [
            ProviderLatencySample(provider: "claude", metricKind: .firstResponse, latencyMs: 120, timestamp: date(2026, 4, 13, 9), sourceKind: "test"),
            ProviderLatencySample(provider: "claude", metricKind: .firstResponse, latencyMs: 180, timestamp: date(2026, 4, 15, 9), sourceKind: "test")
        ]

        let buckets = ProviderLatencyAnalytics.bucketed(samples: samples, by: .weekday, calendar: calendar)

        XCTAssertEqual(buckets.map(\.label), ["Mon", "Wed"])
    }

    func testBucketedPeriodOfDayGroupsByExpectedWindows() {
        let samples = [
            ProviderLatencySample(provider: "openai", metricKind: .apiRequest, latencyMs: 90, timestamp: date(2026, 4, 14, 2), sourceKind: "test"),
            ProviderLatencySample(provider: "openai", metricKind: .apiRequest, latencyMs: 110, timestamp: date(2026, 4, 14, 8), sourceKind: "test"),
            ProviderLatencySample(provider: "openai", metricKind: .apiRequest, latencyMs: 130, timestamp: date(2026, 4, 14, 14), sourceKind: "test"),
            ProviderLatencySample(provider: "openai", metricKind: .apiRequest, latencyMs: 150, timestamp: date(2026, 4, 14, 20), sourceKind: "test")
        ]

        let buckets = ProviderLatencyAnalytics.bucketed(samples: samples, by: .periodOfDay)

        XCTAssertEqual(buckets.map(\.label), ["Night", "Morning", "Afternoon", "Evening"])
    }

    func testCompletedRunFirstResponseSampleUsesFirstAssistantTurnWithinRunWindow() {
        let run = TelemetryRun(
            id: "run-1",
            sessionID: "session-1",
            provider: "codex",
            model: "gpt-5",
            cwd: "/tmp/project",
            repoPath: "/tmp/project",
            startedAt: date(2026, 4, 14, 9, 0, 0),
            endedAt: date(2026, 4, 14, 9, 1, 0),
            rawTranscriptRef: "/tmp/rollout.jsonl"
        )
        let turns = [
            TelemetryTurn(runID: run.id, turnIndex: 0, role: .human, timestamp: date(2026, 4, 14, 9, 0, 5)),
            TelemetryTurn(runID: run.id, turnIndex: 1, role: .assistant, timestamp: date(2026, 4, 14, 9, 0, 8)),
            TelemetryTurn(runID: run.id, turnIndex: 2, role: .assistant, timestamp: date(2026, 4, 14, 9, 2, 0))
        ]

        let sample = ProviderLatencyAnalytics.completedRunFirstResponseSample(run: run, turns: turns)

        XCTAssertEqual(sample?.provider, "codex")
        XCTAssertEqual(sample?.metricKind, .firstResponse)
        XCTAssertEqual(sample?.latencyMs, 3_000)
        XCTAssertEqual(sample?.timestamp, date(2026, 4, 14, 9, 0, 8))
    }

    func testCompletedRunFirstResponseSampleReturnsNilWithoutAssistantTurnInWindow() {
        let run = TelemetryRun(
            id: "run-2",
            provider: "claude",
            cwd: "/tmp/project",
            startedAt: date(2026, 4, 14, 9, 0, 0),
            endedAt: date(2026, 4, 14, 9, 1, 0),
            rawTranscriptRef: "/tmp/transcript.jsonl"
        )
        let turns = [
            TelemetryTurn(runID: run.id, turnIndex: 0, role: .human, timestamp: date(2026, 4, 14, 9, 0, 10)),
            TelemetryTurn(runID: run.id, turnIndex: 1, role: .assistant, timestamp: date(2026, 4, 14, 9, 1, 5))
        ]

        XCTAssertNil(ProviderLatencyAnalytics.completedRunFirstResponseSample(run: run, turns: turns))
    }

    func testCompletedRunFirstResponseSampleReturnsNilForFallbackTranscriptSource() {
        let run = TelemetryRun(
            id: "run-3",
            provider: "claude",
            cwd: "/tmp/project",
            startedAt: date(2026, 4, 14, 9, 0, 0),
            endedAt: date(2026, 4, 14, 9, 1, 0),
            rawTranscriptRef: "pty_log"
        )
        let turns = [
            TelemetryTurn(runID: run.id, turnIndex: 0, role: .human, timestamp: date(2026, 4, 14, 9, 0, 10)),
            TelemetryTurn(runID: run.id, turnIndex: 1, role: .assistant, timestamp: date(2026, 4, 14, 9, 0, 12))
        ]

        XCTAssertNil(ProviderLatencyAnalytics.completedRunFirstResponseSample(run: run, turns: turns))
    }

    func testCompletedRunFirstResponseSampleFallsBackToRunStartWhenHumanTurnMissing() {
        let run = TelemetryRun(
            id: "run-4",
            provider: "claude",
            cwd: "/tmp/project",
            startedAt: date(2026, 4, 14, 20, 0, 0),
            endedAt: date(2026, 4, 14, 20, 3, 0),
            rawTranscriptRef: "/tmp/transcript.jsonl"
        )
        let turns = [
            TelemetryTurn(runID: run.id, turnIndex: 0, role: .assistant, timestamp: date(2026, 4, 14, 20, 0, 12)),
            TelemetryTurn(runID: run.id, turnIndex: 1, role: .assistant, timestamp: date(2026, 4, 14, 20, 0, 20))
        ]

        let sample = ProviderLatencyAnalytics.completedRunFirstResponseSample(run: run, turns: turns)

        XCTAssertEqual(sample?.latencyMs, 12_000)
        XCTAssertEqual(sample?.timestamp, date(2026, 4, 14, 20, 0, 12))
    }

    func testCanonicalLatencySamplesPrefersCompletedRunTurnsOverTerminalFallback() {
        let terminalSample = ProviderLatencySample(
            id: "terminal",
            provider: "claude",
            metricKind: .firstResponse,
            latencyMs: 9_000,
            timestamp: date(2026, 4, 14, 20, 0, 9),
            runID: "run-5",
            sourceKind: "terminal_first_output"
        )
        let completedSample = ProviderLatencySample(
            id: "completed",
            provider: "claude",
            metricKind: .firstResponse,
            latencyMs: 11_000,
            timestamp: date(2026, 4, 14, 20, 0, 11),
            runID: "run-5",
            sourceKind: "completed_run_turns"
        )

        let canonical = ProviderLatencyAnalytics.canonicalLatencySamples([terminalSample, completedSample])

        XCTAssertEqual(canonical.count, 1)
        XCTAssertEqual(canonical.first?.id, "completed")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        date(year, month, day, hour, 0, 0)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: comps) ?? .distantPast
    }
}
