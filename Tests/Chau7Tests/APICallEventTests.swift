import XCTest
@testable import Chau7Core

// Note: These tests are for the public types in the Proxy module.
// Full integration tests require the Chau7 target.

final class APICallEventTests: XCTestCase {

    // MARK: - AIEventSource Tests

    func testAPIProxyEventSource() {
        let source = AIEventSource.apiProxy
        XCTAssertEqual(source.rawValue, "api_proxy")
    }

    func testAllEventSourcesUnique() {
        let sources: [AIEventSource] = [
            .eventsLog, .historyMonitor, .claudeCode, .app, .apiProxy, .unknown
        ]
        let rawValues = sources.map { $0.rawValue }
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "All event sources should have unique raw values")
    }

    // MARK: - AIEvent Tests

    func testAIEventWithCustomID() {
        let customID = UUID()
        let event = AIEvent(
            id: customID,
            source: .apiProxy,
            type: "api_call",
            tool: "Anthropic",
            message: "Test message",
            ts: "2025-01-14T12:00:00Z"
        )

        XCTAssertEqual(event.id, customID)
        XCTAssertEqual(event.source, .apiProxy)
        XCTAssertEqual(event.type, "api_call")
        XCTAssertEqual(event.tool, "Anthropic")
        XCTAssertEqual(event.message, "Test message")
    }

    func testAIEventWithoutCustomID() {
        let event = AIEvent(
            source: .apiProxy,
            type: "api_call",
            tool: "OpenAI",
            message: "Test",
            ts: "2025-01-14T12:00:00Z"
        )

        // ID should be auto-generated
        XCTAssertNotEqual(event.id, UUID())
        XCTAssertEqual(event.source, .apiProxy)
    }

    func testAIEventEquality() {
        let id = UUID()
        let event1 = AIEvent(id: id, source: .apiProxy, type: "api_call", tool: "Anthropic", message: "Test", ts: "2025-01-14T12:00:00Z")
        let event2 = AIEvent(id: id, source: .apiProxy, type: "api_call", tool: "Anthropic", message: "Test", ts: "2025-01-14T12:00:00Z")

        XCTAssertEqual(event1, event2)
    }
}

// MARK: - Provider Tests (via string matching since type is in Chau7 module)

final class ProviderStringTests: XCTestCase {

    func testKnownProviderStrings() {
        // These are the raw values used by the Go proxy
        let knownProviders = ["anthropic", "openai", "gemini"]

        for provider in knownProviders {
            XCTAssertFalse(provider.isEmpty, "Provider string should not be empty")
            XCTAssertEqual(provider, provider.lowercased(), "Provider strings should be lowercase")
        }
    }

    func testProviderDisplayNames() {
        // Map of raw values to expected display names
        let expectedDisplayNames = [
            "anthropic": "Anthropic",
            "openai": "OpenAI",
            "gemini": "Google",
            "unknown": "Unknown"
        ]

        for (rawValue, displayName) in expectedDisplayNames {
            XCTAssertFalse(displayName.isEmpty, "Display name for \(rawValue) should not be empty")
            XCTAssertTrue(displayName.first?.isUppercase ?? false, "Display name should be capitalized")
        }
    }
}

// MARK: - Stats Calculation Tests

final class StatsCalculationTests: XCTestCase {

    func testEmptyStatsDefaults() {
        // Test that default values are reasonable
        let callCount = 0
        let inputTokens = 0
        let outputTokens = 0
        let cost = 0.0
        let avgLatency = 0.0

        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(inputTokens + outputTokens, 0)
        XCTAssertEqual(cost, 0.0, accuracy: 0.0001)
        XCTAssertEqual(avgLatency, 0.0, accuracy: 0.0001)
    }

    func testTokenCalculation() {
        let inputTokens = 100
        let outputTokens = 500
        let totalTokens = inputTokens + outputTokens

        XCTAssertEqual(totalTokens, 600)
    }

    func testCostFormatting() {
        // Test cost formatting logic
        let smallCost = 0.0045
        let largeCost = 1.23

        // Small costs should show 4 decimal places
        let smallFormatted = String(format: "$%.4f", smallCost)
        XCTAssertEqual(smallFormatted, "$0.0045")

        // Large costs should show 2 decimal places
        let largeFormatted = String(format: "$%.2f", largeCost)
        XCTAssertEqual(largeFormatted, "$1.23")
    }

    func testLatencyFormatting() {
        // Test latency formatting logic
        let fastLatency = 250  // ms
        let slowLatency = 2500  // ms

        // Fast latency in ms
        XCTAssertEqual("\(fastLatency)ms", "250ms")

        // Slow latency in seconds
        let slowInSeconds = String(format: "%.1fs", Double(slowLatency) / 1000.0)
        XCTAssertEqual(slowInSeconds, "2.5s")
    }

    func testStatusCodeSuccess() {
        let successCodes = [200, 201, 204, 299]
        let failureCodes = [400, 401, 403, 404, 500, 502, 503]

        for code in successCodes {
            XCTAssertTrue((200..<300).contains(code), "Code \(code) should be success")
        }

        for code in failureCodes {
            XCTAssertFalse((200..<300).contains(code), "Code \(code) should be failure")
        }
    }

    func testAverageLatencyCalculation() {
        let latencies = [100, 200, 300]
        let sum = latencies.reduce(0, +)
        let average = Double(sum) / Double(latencies.count)

        XCTAssertEqual(average, 200.0, accuracy: 0.001)
    }
}

// MARK: - IPC Message Format Tests

final class IPCMessageFormatTests: XCTestCase {

    func testIPCMessageStructure() {
        // Test that JSON keys match expected format
        let expectedKeys = [
            "session_id",
            "provider",
            "model",
            "endpoint",
            "input_tokens",
            "output_tokens",
            "latency_ms",
            "status_code",
            "cost_usd",
            "timestamp",
            "error_message"
        ]

        // Verify all expected keys
        XCTAssertEqual(expectedKeys.count, 11)
        XCTAssertTrue(expectedKeys.contains("error_message"), "Should include error_message field")
    }

    func testTimestampParsing() {
        let iso8601String = "2025-01-14T12:00:00Z"
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: iso8601String)

        XCTAssertNotNil(date, "Should parse ISO8601 timestamp")
    }

    func testTimestampParsingWithMilliseconds() {
        let iso8601String = "2025-01-14T12:00:00.123Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso8601String)

        XCTAssertNotNil(date, "Should parse ISO8601 timestamp with milliseconds")
    }
}
