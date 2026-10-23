import XCTest
@testable import Chau7Core

final class NotificationDropLogPolicyTests: XCTestCase {
    func testExpectedRawLifecycleDropIsTraceOnly() {
        XCTAssertEqual(
            NotificationDropLogPolicy.level(
                for: "Claude raw event tool_start is not user-facing"
            ),
            .trace
        )
    }

    func testStateOnlyDeliveryDropIsTraceOnly() {
        XCTAssertEqual(
            NotificationDropLogPolicy.level(
                for: "Claude response_complete is state-only; Notification hook owns user-facing delivery"
            ),
            .trace
        )
    }

    func testUnsupportedPayloadRemainsInfo() {
        XCTAssertEqual(
            NotificationDropLogPolicy.level(
                for: "Unsupported Claude notification payload"
            ),
            .info
        )
    }
}
