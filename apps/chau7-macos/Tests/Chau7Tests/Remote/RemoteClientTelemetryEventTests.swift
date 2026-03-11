import XCTest
import Chau7Core

final class RemoteClientTelemetryEventTests: XCTestCase {
    func testCodableRoundTripPreservesTelemetryFields() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 794_770_102.125)
        let event = RemoteClientTelemetryEvent(
            id: "event-123",
            source: "ios",
            deviceID: "device-abc",
            deviceName: "Christophe's iPhone",
            appVersion: "1.1.0",
            sessionID: "session-xyz",
            eventType: .tabSwitched,
            status: "ok",
            tabID: 7,
            tabTitle: "Claude",
            message: "Switched tabs",
            metadata: [
                "from_tab": "5",
                "gesture": "tap"
            ],
            timestamp: timestamp
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RemoteClientTelemetryEvent.self, from: data)

        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.source, event.source)
        XCTAssertEqual(decoded.deviceID, event.deviceID)
        XCTAssertEqual(decoded.deviceName, event.deviceName)
        XCTAssertEqual(decoded.appVersion, event.appVersion)
        XCTAssertEqual(decoded.sessionID, event.sessionID)
        XCTAssertEqual(decoded.eventType, event.eventType)
        XCTAssertEqual(decoded.status, event.status)
        XCTAssertEqual(decoded.tabID, event.tabID)
        XCTAssertEqual(decoded.tabTitle, event.tabTitle)
        XCTAssertEqual(decoded.message, event.message)
        XCTAssertEqual(decoded.metadata, event.metadata)
        XCTAssertEqual(decoded.timestamp, event.timestamp)
    }
}
