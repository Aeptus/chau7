import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class APICallEventDisplayTests: XCTestCase {
    func testProjectNameUsesLastPathComponent() {
        let event = APICallEvent(
            sessionId: "session-1",
            provider: .openai,
            model: "gpt-5",
            endpoint: "/v1/responses",
            inputTokens: 10,
            outputTokens: 20,
            latencyMs: 420,
            statusCode: 200,
            costUSD: 0.12,
            timestamp: Date(timeIntervalSince1970: 1_760_000_000),
            projectPath: "/Users/test/dev/chau7-website"
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        XCTAssertEqual(event.projectName, "chau7-website")
        XCTAssertEqual(event.formattedHour, formatter.string(from: event.timestamp))
    }
}
#endif
