import XCTest
@testable import Chau7Core

final class ProviderLatencyAnalyticsTests: XCTestCase {
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

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: comps) ?? .distantPast
    }
}
