import XCTest
@testable import Chau7
@testable import Chau7Core

/// Pins the APICallEvent→AIEvent mapping to the format that shipped in
/// AppModel.handleAPICallEvent before the conversion was unified onto
/// `toAIEvent()`. Downstream consumers (notification adapters, MCP
/// observability, per-repo buffers) rely on these exact strings.
final class APICallEventConversionTests: XCTestCase {

    private func makeEvent(
        statusCode: Int = 200,
        errorMessage: String? = nil
    ) -> APICallEvent {
        APICallEvent(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            sessionId: "session-1",
            provider: .anthropic,
            model: "claude-sonnet-5",
            endpoint: "/v1/messages",
            inputTokens: 1200,
            outputTokens: 340,
            latencyMs: 900,
            statusCode: statusCode,
            costUSD: 0.0123,
            timestamp: Date(timeIntervalSince1970: 1_736_856_000),
            errorMessage: errorMessage
        )
    }

    func testToAIEventPreservesShippingMessageFormat() {
        let event = makeEvent()
        let aiEvent = event.toAIEvent()
        XCTAssertEqual(
            aiEvent.message,
            "\(event.provider.displayName) \(event.model): in:\(event.inputTokens) out:\(event.outputTokens) \(event.formattedCost)"
        )
    }

    func testToAIEventSuccessType() {
        XCTAssertEqual(makeEvent().toAIEvent().type, "api_call")
    }

    func testToAIEventErrorTypeMatchesShippingString() {
        // The shipping inline conversion used "error" (keyed on hasError),
        // not "api_error"; the adapter registry accepts both, but the wire
        // string must stay stable.
        let aiEvent = makeEvent(statusCode: 500, errorMessage: "boom").toAIEvent()
        XCTAssertEqual(aiEvent.type, "error")
    }

    func testToAIEventStatusFailureWithoutErrorMessageIsNotError() {
        // hasError is driven by errorMessage presence, matching the shipping
        // inline conversion (not isSuccess/statusCode).
        let aiEvent = makeEvent(statusCode: 500).toAIEvent()
        XCTAssertEqual(aiEvent.type, "api_call")
    }

    func testToAIEventUsesSharedFractionalTimestampFormat() {
        let event = makeEvent()
        let aiEvent = event.toAIEvent()
        XCTAssertEqual(aiEvent.ts, DateFormatters.iso8601.string(from: event.timestamp))
        XCTAssertEqual(DateFormatters.parseISO8601(aiEvent.ts), event.timestamp)
    }

    func testToAIEventPreservesIdentityAndSource() {
        let event = makeEvent()
        let aiEvent = event.toAIEvent()
        XCTAssertEqual(aiEvent.id, event.id)
        XCTAssertEqual(aiEvent.source, .apiProxy)
        XCTAssertEqual(aiEvent.tool, event.provider.displayName)
    }
}
