import XCTest
@testable import Chau7Core

final class NotificationTriggerCatalogTests: XCTestCase {
    func testCatalogHasUniqueIds() {
        let ids = NotificationTriggerCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTriggerLookupMatchesExact() {
        let event = AIEvent(
            source: .terminalSession,
            type: "finished",
            tool: "Shell",
            message: "",
            ts: "2024-01-01T00:00:00Z"
        )
        let trigger = NotificationTriggerCatalog.trigger(for: event)
        XCTAssertEqual(trigger?.id, "terminal_session.finished")
    }

    func testTriggerLookupUsesWildcardForEventsLog() {
        let event = AIEvent(
            source: .eventsLog,
            type: "custom_type",
            tool: "CLI",
            message: "",
            ts: "2024-01-01T00:00:00Z"
        )
        let trigger = NotificationTriggerCatalog.trigger(for: event)
        XCTAssertEqual(trigger?.type, NotificationTriggerCatalog.wildcardType)
    }

    func testTriggerStateDefaultsUseCatalogValues() {
        let trigger = NotificationTriggerCatalog.all.first { $0.id == "events_log.finished" }
        XCTAssertNotNil(trigger)
        let state = NotificationTriggerState()
        XCTAssertEqual(state.isEnabled(for: trigger!), trigger!.defaultEnabled)
    }

    func testTriggerStateOverrideWins() {
        let trigger = NotificationTriggerCatalog.all.first { $0.id == "events_log.failed" }
        XCTAssertNotNil(trigger)
        var state = NotificationTriggerState()
        state.setEnabled(!(trigger!.defaultEnabled), for: trigger!)
        XCTAssertEqual(state.isEnabled(for: trigger!), !trigger!.defaultEnabled)
    }

    func testNormalizeDropsUnknownOverrides() {
        var state = NotificationTriggerState(overrides: ["unknown.trigger": false])
        state.normalize()
        XCTAssertTrue(state.overrides.isEmpty)
    }
}
