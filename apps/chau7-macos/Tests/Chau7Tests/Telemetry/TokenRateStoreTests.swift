import XCTest
@testable import Chau7

@MainActor
final class TokenRateStoreTests: XCTestCase {
    func testRecordCalculatesAndFormatsProviderUsageRate() throws {
        let store = TokenRateStore()
        let updatedAt = Date(timeIntervalSince1970: 100)

        store.record(
            tabID: "tab-1",
            provider: "Anthropic / claude-sonnet",
            outputTokens: 120,
            durationMs: 3000,
            source: .proxyUsage,
            updatedAt: updatedAt
        )

        let reading = try XCTUnwrap(store.reading(for: "tab-1"))
        XCTAssertEqual(reading.tokensPerSecond, 40, accuracy: 0.001)
        XCTAssertEqual(reading.formattedRate, "40 t/s")
        XCTAssertFalse(reading.source.isEstimated)
        XCTAssertTrue(reading.detail.contains("120 output tokens in 3.0s"))
    }

    func testTranscriptEstimateDoesNotImmediatelyReplaceRecentProxyUsage() throws {
        let store = TokenRateStore()
        let base = Date(timeIntervalSince1970: 100)

        store.record(
            tabID: "tab-1",
            provider: "Anthropic",
            outputTokens: 80,
            durationMs: 2000,
            source: .proxyUsage,
            updatedAt: base
        )
        store.record(
            tabID: "tab-1",
            provider: "Claude",
            outputTokens: 50,
            durationMs: 2500,
            source: .claudeTranscript,
            updatedAt: base.addingTimeInterval(3)
        )

        XCTAssertEqual(try XCTUnwrap(store.reading(for: "tab-1")).source, .proxyUsage)

        store.record(
            tabID: "tab-1",
            provider: "Claude",
            outputTokens: 50,
            durationMs: 2500,
            source: .claudeTranscript,
            updatedAt: base.addingTimeInterval(6)
        )
        XCTAssertEqual(try XCTUnwrap(store.reading(for: "tab-1")).source, .claudeTranscript)
    }

    func testStreamEstimatesAreMarkedAndRetainedReadingsStayBounded() throws {
        let store = TokenRateStore()
        let base = Date(timeIntervalSince1970: 100)

        for index in 0 ..< 513 {
            store.recordStreamEstimate(
                tabID: "tab-\(index)",
                provider: "OpenAI",
                outputTokens: 4,
                tokensPerSecond: 2,
                durationMs: 2000,
                updatedAt: base.addingTimeInterval(Double(index))
            )
        }

        XCTAssertLessThanOrEqual(store.readingsByTabID.count, 512)
        XCTAssertNil(store.reading(for: "tab-0"))

        let latest = try XCTUnwrap(store.reading(for: "tab-512"))
        XCTAssertEqual(latest.formattedRate, "~2 t/s")
        XCTAssertTrue(latest.source.isEstimated)
    }
}
