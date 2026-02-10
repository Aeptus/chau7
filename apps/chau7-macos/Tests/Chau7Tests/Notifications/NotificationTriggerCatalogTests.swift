import XCTest
@testable import Chau7Core

final class NotificationTriggerCatalogTests: XCTestCase {

    // MARK: - Catalog Integrity

    func testCatalogHasUniqueIds() {
        let ids = NotificationTriggerCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testCatalogIsNonEmpty() {
        XCTAssertGreaterThan(NotificationTriggerCatalog.all.count, 0)
    }

    func testAllTriggersHaveLabels() {
        for trigger in NotificationTriggerCatalog.all {
            XCTAssertFalse(trigger.labelFallback.isEmpty, "\(trigger.id) missing label")
            XCTAssertFalse(trigger.labelKey.isEmpty, "\(trigger.id) missing label key")
        }
    }

    func testAllTriggersHaveDescriptions() {
        for trigger in NotificationTriggerCatalog.all {
            XCTAssertFalse(trigger.descriptionFallback.isEmpty, "\(trigger.id) missing description")
            XCTAssertFalse(trigger.descriptionKey.isEmpty, "\(trigger.id) missing description key")
        }
    }

    // MARK: - triggerId Format

    func testTriggerIdFormat() {
        let id = NotificationTriggerCatalog.triggerId(source: .claudeCode, type: "finished")
        XCTAssertEqual(id, "claude_code.finished")
    }

    func testTriggerIdNormalizesType() {
        let id = NotificationTriggerCatalog.triggerId(source: .claudeCode, type: "  FINISHED  ")
        XCTAssertEqual(id, "claude_code.finished")
    }

    // MARK: - trigger(for:) via AIEvent

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

    // MARK: - trigger(source:type:) Direct Lookup

    func testTriggerDirectLookupExact() {
        let trigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "finished")
        XCTAssertNotNil(trigger)
        XCTAssertEqual(trigger?.source, .claudeCode)
        XCTAssertEqual(trigger?.type, "finished")
    }

    func testTriggerDirectLookupCaseInsensitive() {
        let trigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "FINISHED")
        XCTAssertNotNil(trigger)
        XCTAssertEqual(trigger?.type, "finished")
    }

    func testTriggerDirectLookupTrimsWhitespace() {
        let trigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "  finished  ")
        XCTAssertNotNil(trigger)
        XCTAssertEqual(trigger?.type, "finished")
    }

    func testTriggerDirectLookupFallsBackToWildcard() {
        let trigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "unknown_type")
        XCTAssertNotNil(trigger)
        XCTAssertTrue(trigger!.isWildcard)
    }

    func testTriggerDirectLookupNoWildcardForUnknownSource() {
        // historyMonitor only has "idle" — unknown type with no wildcard
        let trigger = NotificationTriggerCatalog.trigger(source: .historyMonitor, type: "nonexistent")
        XCTAssertNil(trigger, "historyMonitor has no wildcard trigger")
    }

    // MARK: - triggers(for:) Source Filtering

    func testTriggersForSource() {
        let shellTriggers = NotificationTriggerCatalog.triggers(for: .shell)
        XCTAssertGreaterThan(shellTriggers.count, 0)
        for trigger in shellTriggers {
            XCTAssertEqual(trigger.source, .shell)
        }
    }

    func testTriggersForSourceHistoryMonitor() {
        let triggers = NotificationTriggerCatalog.triggers(for: .historyMonitor)
        XCTAssertEqual(triggers.count, 1) // Only "idle"
        XCTAssertEqual(triggers.first?.type, "idle")
    }

    func testTriggersForSourceEventsLog() {
        let triggers = NotificationTriggerCatalog.triggers(for: .eventsLog)
        let types = triggers.map(\.type)
        XCTAssertTrue(types.contains("finished"))
        XCTAssertTrue(types.contains("failed"))
        XCTAssertTrue(types.contains("needs_validation"))
        XCTAssertTrue(types.contains("*"))
    }

    // MARK: - displayableTriggers(in:)

    func testDisplayableTriggersInSettings() {
        let settingsTriggers = NotificationTriggerCatalog.displayableTriggers(in: .settings)
        XCTAssertGreaterThan(settingsTriggers.count, 0)
        for trigger in settingsTriggers {
            XCTAssertTrue(trigger.displayContexts.contains(.settings))
        }
    }

    func testDisplayableTriggersInActivity() {
        let activityTriggers = NotificationTriggerCatalog.displayableTriggers(in: .activity)
        XCTAssertGreaterThan(activityTriggers.count, 0)
        for trigger in activityTriggers {
            XCTAssertTrue(trigger.displayContexts.contains(.activity))
        }
    }

    func testDisplayableTriggersInDebug() {
        let debugTriggers = NotificationTriggerCatalog.displayableTriggers(in: .debug)
        // No triggers use .debug context in the current catalog
        XCTAssertEqual(debugTriggers.count, 0)
    }

    func testActivityOnlyTriggerNotInSettings() {
        // app.info has displayContexts: [.activity] only
        let settingsTriggers = NotificationTriggerCatalog.displayableTriggers(in: .settings)
        let hasAppInfo = settingsTriggers.contains { $0.id == "app.info" }
        XCTAssertFalse(hasAppInfo, "app.info should only appear in activity context")
    }

    // MARK: - NotificationTrigger Properties

    func testWildcardTriggerIsWildcard() {
        let wildcard = NotificationTriggerCatalog.all.first { $0.source == .eventsLog && $0.type == "*" }
        XCTAssertNotNil(wildcard)
        XCTAssertTrue(wildcard!.isWildcard)
    }

    func testNonWildcardTriggerIsNotWildcard() {
        let trigger = NotificationTriggerCatalog.all.first { $0.source == .eventsLog && $0.type == "finished" }
        XCTAssertNotNil(trigger)
        XCTAssertFalse(trigger!.isWildcard)
    }

    func testTriggerEquality() {
        let a = NotificationTriggerCatalog.all.first { $0.id == "events_log.finished" }!
        let b = NotificationTriggerCatalog.all.first { $0.id == "events_log.finished" }!
        XCTAssertEqual(a, b)
    }

    // MARK: - NotificationTriggerState

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

    func testTriggerStateDisabledOverride() {
        let trigger = NotificationTriggerCatalog.all.first { $0.defaultEnabled }!
        var state = NotificationTriggerState()
        state.setEnabled(false, for: trigger)
        XCTAssertFalse(state.isEnabled(for: trigger))
    }

    func testTriggerStateEnabledOverride() {
        let trigger = NotificationTriggerCatalog.all.first { !$0.defaultEnabled }!
        var state = NotificationTriggerState()
        state.setEnabled(true, for: trigger)
        XCTAssertTrue(state.isEnabled(for: trigger))
    }

    func testNormalizeDropsUnknownOverrides() {
        var state = NotificationTriggerState(overrides: ["unknown.trigger": false])
        state.normalize()
        XCTAssertTrue(state.overrides.isEmpty)
    }

    func testNormalizeKeepsKnownOverrides() {
        let knownId = NotificationTriggerCatalog.all.first!.id
        var state = NotificationTriggerState(overrides: [knownId: false, "bogus.id": true])
        state.normalize()
        XCTAssertEqual(state.overrides.count, 1)
        XCTAssertNotNil(state.overrides[knownId])
    }

    func testStateCodableRoundTrip() throws {
        let original = NotificationTriggerState(overrides: [
            "events_log.finished": false,
            "claude_code.permission": true
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationTriggerState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - NotificationTriggerDisplay OptionSet

    func testDisplayOptionSetSettings() {
        let display: NotificationTriggerDisplay = .settings
        XCTAssertTrue(display.contains(.settings))
        XCTAssertFalse(display.contains(.activity))
    }

    func testDisplayOptionSetCombined() {
        let display: NotificationTriggerDisplay = [.settings, .activity]
        XCTAssertTrue(display.contains(.settings))
        XCTAssertTrue(display.contains(.activity))
        XCTAssertFalse(display.contains(.debug))
    }

    func testDisplayOptionSetEmpty() {
        let display = NotificationTriggerDisplay()
        XCTAssertFalse(display.contains(.settings))
        XCTAssertFalse(display.contains(.activity))
        XCTAssertFalse(display.contains(.debug))
    }

    // MARK: - NotificationTriggerSourceInfo

    func testSourcesCoverExpectedSources() {
        let sourceIds = NotificationTriggerCatalog.sources.map(\.id)
        XCTAssertTrue(sourceIds.contains(.eventsLog))
        XCTAssertTrue(sourceIds.contains(.terminalSession))
        XCTAssertTrue(sourceIds.contains(.claudeCode))
        XCTAssertTrue(sourceIds.contains(.shell))
        XCTAssertTrue(sourceIds.contains(.app))
    }

    func testSourcesSortedBySortOrder() {
        let orders = NotificationTriggerCatalog.sources.map(\.sortOrder)
        XCTAssertEqual(orders, orders.sorted())
    }

    func testSourcesHaveLabels() {
        for source in NotificationTriggerCatalog.sources {
            XCTAssertFalse(source.labelFallback.isEmpty)
            XCTAssertFalse(source.labelKey.isEmpty)
        }
    }

    func testSourcesIdentifiable() {
        let source = NotificationTriggerCatalog.sources.first!
        XCTAssertEqual(source.id, source.id) // Identifiable via AIEventSource
    }
}
