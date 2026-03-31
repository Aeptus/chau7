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
            type: "idle",
            tool: "Shell",
            message: "",
            ts: "2024-01-01T00:00:00Z"
        )
        let trigger = NotificationTriggerCatalog.trigger(for: event)
        XCTAssertEqual(trigger?.id, "terminal_session.idle")
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
        XCTAssertEqual(triggers.count, 2) // "finished" and "idle"
        let types = Set(triggers.map(\.type))
        XCTAssertTrue(types.contains("finished"))
        XCTAssertTrue(types.contains("idle"))
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
        // app.docker_event has displayContexts: [.activity] only (no event emitter yet)
        let settingsTriggers = NotificationTriggerCatalog.displayableTriggers(in: .settings)
        let hasDockerEvent = settingsTriggers.contains { $0.id == "app.docker_event" }
        XCTAssertFalse(hasDockerEvent, "app.docker_event should only appear in activity context")
        // Verify it does appear in activity
        let activityTriggers = NotificationTriggerCatalog.displayableTriggers(in: .activity)
        let hasDockerEventInActivity = activityTriggers.contains { $0.id == "app.docker_event" }
        XCTAssertTrue(hasDockerEventInActivity, "app.docker_event should appear in activity context")
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

    // MARK: - Group Catalog Tests

    func testAiCodingGroupContainsAllSources() {
        let group = NotificationTriggerCatalog.aiCodingGroup
        let expectedSources: [AIEventSource] = [.claudeCode, .codex, .cursor, .windsurf, .copilot, .aider, .cline, .continueAI, .runtime]
        XCTAssertEqual(group.sources.count, expectedSources.count)
        for source in expectedSources {
            XCTAssertTrue(group.contains(source: source), "Group should contain \(source.rawValue)")
        }
    }

    func testGroupTriggerIdFormat() {
        let group = NotificationTriggerCatalog.aiCodingGroup
        XCTAssertEqual(group.groupTriggerId(for: "finished"), "ai_coding.finished")
        XCTAssertEqual(group.groupTriggerId(for: "permission"), "ai_coding.permission")
    }

    func testGroupForAiSource() {
        let group = NotificationTriggerCatalog.group(for: .claudeCode)
        XCTAssertNotNil(group)
        XCTAssertEqual(group?.id, "ai_coding")
    }

    func testGroupForNonAiSourceIsNil() {
        XCTAssertNil(NotificationTriggerCatalog.group(for: .eventsLog))
        XCTAssertNil(NotificationTriggerCatalog.group(for: .shell))
        XCTAssertNil(NotificationTriggerCatalog.group(for: .app))
    }

    func testGroupTriggerInfosCount() {
        let group = NotificationTriggerCatalog.aiCodingGroup
        let infos = NotificationTriggerCatalog.groupTriggerInfos(for: group)
        XCTAssertEqual(infos.count, group.triggerTypes.count)
        // Each info should have a valid ID
        for info in infos {
            XCTAssertTrue(info.id.hasPrefix("ai_coding."))
            XCTAssertFalse(info.labelFallback.isEmpty)
        }
    }

    func testAllGroupTriggerIds() {
        let ids = NotificationTriggerCatalog.allGroupTriggerIds
        let group = NotificationTriggerCatalog.aiCodingGroup
        // Should have one ID per trigger type
        XCTAssertEqual(ids.count, group.triggerTypes.count)
        XCTAssertTrue(ids.contains("ai_coding.finished"))
        XCTAssertTrue(ids.contains("ai_coding.permission"))
    }

    // MARK: - 3-Tier Resolution Tests

    func testPerTriggerOverrideWinsOverGroup() {
        let trigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "finished")!
        // Group says enabled, per-trigger says disabled → disabled wins
        var state = NotificationTriggerState(
            overrides: [trigger.id: false],
            groupOverrides: ["ai_coding.finished": true]
        )
        XCTAssertFalse(state.isEnabled(for: trigger))

        // Flip: group says disabled, per-trigger says enabled → enabled wins
        state = NotificationTriggerState(
            overrides: [trigger.id: true],
            groupOverrides: ["ai_coding.finished": false]
        )
        XCTAssertTrue(state.isEnabled(for: trigger))
    }

    func testGroupOverrideWinsOverDefault() {
        let trigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "finished")!
        // Default is true for "finished", group says false → false
        let state = NotificationTriggerState(
            overrides: [:],
            groupOverrides: ["ai_coding.finished": false]
        )
        XCTAssertFalse(state.isEnabled(for: trigger))
    }

    func testDefaultUsedWhenNoOverrides() {
        let finishedTrigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "finished")!
        let failedTrigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "failed")!
        let idleTrigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "idle")!
        let state = NotificationTriggerState()
        // "finished" defaults to true
        XCTAssertTrue(state.isEnabled(for: finishedTrigger))
        // "failed" defaults to true
        XCTAssertTrue(state.isEnabled(for: failedTrigger))
        // "idle" defaults to false
        XCTAssertFalse(state.isEnabled(for: idleTrigger))
    }

    func testPerTriggerFalseOverridesGroupTrue() {
        // All AI sources: group=true but one specific source overridden to false
        let cursorFinished = NotificationTriggerCatalog.trigger(source: .cursor, type: "finished")!
        let claudeFinished = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "finished")!

        let state = NotificationTriggerState(
            overrides: [cursorFinished.id: false],
            groupOverrides: ["ai_coding.finished": true]
        )
        XCTAssertFalse(state.isEnabled(for: cursorFinished))
        XCTAssertTrue(state.isEnabled(for: claudeFinished))
    }

    // MARK: - Group Override Helpers

    func testHasPerTriggerOverride() {
        let trigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "finished")!
        var state = NotificationTriggerState()
        XCTAssertFalse(state.hasPerTriggerOverride(for: trigger))
        state.setEnabled(false, for: trigger)
        XCTAssertTrue(state.hasPerTriggerOverride(for: trigger))
    }

    func testIsGroupEnabled() {
        var state = NotificationTriggerState()
        // No override → uses default
        XCTAssertTrue(state.isGroupEnabled(groupId: "ai_coding", type: "finished", defaultEnabled: true))
        XCTAssertFalse(state.isGroupEnabled(groupId: "ai_coding", type: "idle", defaultEnabled: false))

        // With override
        state.setGroupEnabled(false, groupId: "ai_coding", type: "finished")
        XCTAssertFalse(state.isGroupEnabled(groupId: "ai_coding", type: "finished", defaultEnabled: true))
    }

    func testRemoveGroupOverride() {
        var state = NotificationTriggerState()
        state.setGroupEnabled(false, groupId: "ai_coding", type: "finished")
        XCTAssertFalse(state.isGroupEnabled(groupId: "ai_coding", type: "finished", defaultEnabled: true))
        state.removeGroupOverride(groupId: "ai_coding", type: "finished")
        XCTAssertTrue(state.isGroupEnabled(groupId: "ai_coding", type: "finished", defaultEnabled: true))
    }

    func testRemoveOverride() {
        let trigger = NotificationTriggerCatalog.trigger(source: .claudeCode, type: "finished")!
        var state = NotificationTriggerState()
        state.setEnabled(false, for: trigger)
        XCTAssertTrue(state.hasPerTriggerOverride(for: trigger))
        state.removeOverride(for: trigger)
        XCTAssertFalse(state.hasPerTriggerOverride(for: trigger))
    }

    // MARK: - Codable Backward Compat

    func testCodableRoundTripWithGroupOverrides() throws {
        let original = NotificationTriggerState(
            overrides: ["claude_code.finished": false],
            groupOverrides: ["ai_coding.finished": true, "ai_coding.idle": false]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationTriggerState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableBackwardCompat_NoGroupOverrides() throws {
        // Simulate old format without groupOverrides key
        let json = """
        {"overrides":{"claude_code.finished":false}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NotificationTriggerState.self, from: data)
        XCTAssertEqual(decoded.overrides, ["claude_code.finished": false])
        XCTAssertEqual(decoded.groupOverrides, [:])
    }

    // MARK: - Normalize

    func testNormalizeDropsOrphanedGroupOverrides() {
        var state = NotificationTriggerState(
            overrides: [:],
            groupOverrides: ["ai_coding.finished": true, "bogus_group.finished": false]
        )
        state.normalize()
        XCTAssertEqual(state.groupOverrides.count, 1)
        XCTAssertNotNil(state.groupOverrides["ai_coding.finished"])
        XCTAssertNil(state.groupOverrides["bogus_group.finished"])
    }

    func testNormalizeKeepsValidGroupOverrides() {
        var state = NotificationTriggerState(
            overrides: [:],
            groupOverrides: ["ai_coding.finished": true, "ai_coding.permission": false]
        )
        state.normalize()
        XCTAssertEqual(state.groupOverrides.count, 2)
    }

    // MARK: - Non-Group Triggers Unaffected by Group Overrides

    func testNonGroupTriggerIgnoresGroupOverrides() {
        // Shell triggers should not be affected by AI group overrides
        let shellTrigger = NotificationTriggerCatalog.trigger(source: .shell, type: "command_finished")!
        let state = NotificationTriggerState(
            overrides: [:],
            groupOverrides: ["ai_coding.command_finished": false]
        )
        // Should use catalog default (true for command_finished)
        XCTAssertEqual(state.isEnabled(for: shellTrigger), shellTrigger.defaultEnabled)
    }

    // MARK: - History Monitor Trigger Coverage

    func testHistoryMonitorFinishedTriggerExists() {
        let trigger = NotificationTriggerCatalog.trigger(source: .historyMonitor, type: "finished")
        XCTAssertNotNil(trigger, "historyMonitor.finished must exist so Codex/Cursor/Aider completions route through the pipeline")
    }

    func testHistoryMonitorFinishedIsEnabledByDefault() {
        let trigger = NotificationTriggerCatalog.trigger(source: .historyMonitor, type: "finished")!
        XCTAssertTrue(trigger.defaultEnabled, "historyMonitor.finished should be enabled by default for all AI tools")
    }

    func testAiFailedTriggerIsEnabledByDefault() {
        let trigger = NotificationTriggerCatalog.trigger(source: .runtime, type: "failed")!
        XCTAssertTrue(trigger.defaultEnabled, "AI failed triggers should be enabled by default")
    }

    func testEventsLogNoiseTriggersAreDisabledByDefault() {
        let needsValidation = NotificationTriggerCatalog.trigger(source: .eventsLog, type: "needs_validation")!
        let customNotification = NotificationTriggerCatalog.trigger(source: .eventsLog, type: "notification")!
        let wildcard = NotificationTriggerCatalog.trigger(source: .eventsLog, type: "*")!

        XCTAssertFalse(needsValidation.defaultEnabled)
        XCTAssertFalse(customNotification.defaultEnabled)
        XCTAssertFalse(wildcard.defaultEnabled)
    }
}
