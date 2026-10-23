import XCTest
@testable import Chau7Core

final class AINotificationSettingsBridgeTests: XCTestCase {
    func testPreferenceUsesDefaultActionsWhenCurrentActionsAreEmpty() {
        let defaults = [
            NotificationActionConfig(actionType: .showNotification, enabled: true),
            NotificationActionConfig(actionType: .styleTab, enabled: true)
        ]

        let preference = AINotificationSettingsBridge.preference(
            for: .finished,
            currentActions: [],
            defaultActions: defaults
        )

        XCTAssertTrue(preference.showNotification)
        XCTAssertTrue(preference.styleTab)
        XCTAssertFalse(preference.playSound)
        XCTAssertFalse(preference.dockBounce)
        XCTAssertFalse(preference.hasAdditionalActions)
    }

    func testPreferenceDetectsAdditionalActions() {
        let current = [
            NotificationActionConfig(actionType: .showNotification, enabled: true),
            NotificationActionConfig(actionType: .runScript, enabled: true, config: ["path": "/tmp/a.sh"])
        ]

        let preference = AINotificationSettingsBridge.preference(
            for: .failed,
            currentActions: current,
            defaultActions: []
        )

        XCTAssertTrue(preference.showNotification)
        XCTAssertTrue(preference.hasAdditionalActions)
    }

    func testUpdatedActionsPreservesUnknownActionsAndManagedConfigs() {
        let customSound = NotificationActionConfig(
            actionType: .playSound,
            enabled: true,
            config: ["sound": "Purr", "volume": "60"]
        )
        let extraAction = NotificationActionConfig(
            actionType: .runScript,
            enabled: true,
            config: ["path": "/tmp/hook.sh"]
        )

        let updated = AINotificationSettingsBridge.updatedActions(
            for: .permission,
            preference: AINotificationPrimaryPreference(
                showNotification: true,
                styleTab: false,
                playSound: true,
                dockBounce: false,
                hasAdditionalActions: true
            ),
            currentActions: [customSound, extraAction],
            defaultActions: [NotificationActionConfig(actionType: .showNotification, enabled: true)]
        )

        XCTAssertEqual(updated.map(\.actionType), [.showNotification, .playSound, .dockBounce, .styleTab, .runScript])
        XCTAssertEqual(updated.first(where: { $0.actionType == .playSound })?.config["sound"], "Purr")
        XCTAssertEqual(updated.last?.actionType, .runScript)
        XCTAssertFalse(updated.first(where: { $0.actionType == .dockBounce })?.enabled ?? true)
        XCTAssertFalse(updated.first(where: { $0.actionType == .styleTab })?.enabled ?? true)
    }

    func testUpdatedActionsCanDisableManagedActionsWithoutRemovingExtras() {
        let extraAction = NotificationActionConfig(actionType: .webhook, enabled: true, config: ["url": "https://example.com"])

        let updated = AINotificationSettingsBridge.updatedActions(
            for: .finished,
            preference: AINotificationPrimaryPreference(
                showNotification: false,
                styleTab: false,
                playSound: false,
                dockBounce: false,
                hasAdditionalActions: true
            ),
            currentActions: [extraAction],
            defaultActions: [
                NotificationActionConfig(actionType: .showNotification, enabled: true),
                NotificationActionConfig(actionType: .styleTab, enabled: true)
            ]
        )

        XCTAssertEqual(updated.map(\.actionType), [.showNotification, .playSound, .dockBounce, .styleTab, .webhook])
        XCTAssertFalse(updated[0].enabled)
        XCTAssertFalse(updated[1].enabled)
        XCTAssertFalse(updated[2].enabled)
        XCTAssertFalse(updated[3].enabled)
        XCTAssertEqual(updated[4].actionType, .webhook)
    }

    func testIsEffectivelyEnabledUsesPerTriggerOverrides() {
        let trigger = NotificationTriggerCatalog.trigger(source: .codex, type: "finished")!
        var state = NotificationTriggerState()
        state.setGroupEnabled(false, groupId: NotificationTriggerCatalog.aiCodingGroup.id, type: "finished")
        state.setEnabled(true, for: trigger)

        XCTAssertTrue(
            AINotificationSettingsBridge.isEffectivelyEnabled(
                for: .finished,
                state: state
            )
        )
    }

    func testUpdatedStateForPrimaryToggleClearsPerSourceOverrides() {
        let trigger = NotificationTriggerCatalog.trigger(source: .codex, type: "finished")!
        var state = NotificationTriggerState()
        state.setEnabled(false, for: trigger)

        let updated = AINotificationSettingsBridge.updatedStateForPrimaryToggle(
            state,
            event: .finished,
            enabled: true
        )

        XCTAssertNil(updated.overrides[trigger.id])
        XCTAssertEqual(updated.groupOverrides["ai_coding.finished"], true)
    }

    func testFinishedPrimaryEventNoLongerCoversWaitingInput() {
        let waitingTrigger = NotificationTriggerCatalog.trigger(source: .codex, type: "waiting_input")!
        var state = NotificationTriggerState()
        let finishedTrigger = NotificationTriggerCatalog.trigger(source: .codex, type: "finished")!
        state.setEnabled(false, for: finishedTrigger)
        state.setEnabled(true, for: waitingTrigger)

        let updated = AINotificationSettingsBridge.updatedStateForPrimaryToggle(
            state,
            event: .finished,
            enabled: false
        )

        XCTAssertEqual(updated.overrides[waitingTrigger.id], true)
        XCTAssertEqual(updated.groupOverrides["ai_coding.finished"], false)
        XCTAssertNil(updated.groupOverrides["ai_coding.waiting_input"])
    }

    func testPermissionPrimaryEventCoversWaitingInput() {
        let waitingTrigger = NotificationTriggerCatalog.trigger(source: .codex, type: "waiting_input")!
        var state = NotificationTriggerState()
        state.setEnabled(true, for: waitingTrigger)

        XCTAssertTrue(
            AINotificationSettingsBridge.isEffectivelyEnabled(
                for: .permission,
                state: state
            )
        )
    }

    func testPermissionPrimaryToggleAlsoControlsAttentionRequired() {
        let attentionTrigger = NotificationTriggerCatalog.trigger(source: .codex, type: "attention_required")!
        var state = NotificationTriggerState()
        state.setEnabled(true, for: attentionTrigger)

        let updated = AINotificationSettingsBridge.updatedStateForPrimaryToggle(
            state,
            event: .permission,
            enabled: false
        )

        XCTAssertNil(updated.overrides[attentionTrigger.id])
        XCTAssertEqual(updated.groupOverrides["ai_coding.permission"], false)
        XCTAssertEqual(updated.groupOverrides["ai_coding.waiting_input"], false)
        XCTAssertEqual(updated.groupOverrides["ai_coding.attention_required"], false)
    }

    // MARK: - Merge regression (W3.5)

    func testUpdatedActionsOverridesDefaultConfigWithCurrentConfig() {
        // When both current and default have an entry for the same
        // actionType, the current (user-customized) config wins. Pre-W3.5
        // this was encoded as an `existing` closure on
        // `Dictionary(_:uniquingKeysWith:)` paired with `resolved +
        // defaults` ordering — two layers of indirection for what
        // should read as "defaults then overrides".
        let currentStyleTab = NotificationActionConfig(
            actionType: .styleTab,
            enabled: true,
            config: ["color": "#ff0000"]
        )
        let defaultStyleTab = NotificationActionConfig(
            actionType: .styleTab,
            enabled: true,
            config: ["color": "#0000ff"]
        )
        let result = AINotificationSettingsBridge.updatedActions(
            for: .finished,
            preference: AINotificationPrimaryPreference(
                showNotification: false,
                styleTab: true,
                playSound: false,
                dockBounce: false,
                hasAdditionalActions: false
            ),
            currentActions: [currentStyleTab],
            defaultActions: [defaultStyleTab]
        )
        let styleTab = result.first(where: { $0.actionType == .styleTab })
        XCTAssertEqual(styleTab?.config["color"], "#ff0000", "current (user) config must override default")
    }

    func testUpdatedActionsFallsBackToDefaultsForMissingCurrent() {
        // When current has no entry for an actionType, the template for
        // the managed action is taken from defaults.
        let currentStyleOnly = NotificationActionConfig(
            actionType: .styleTab,
            enabled: true,
            config: ["color": "#ff0000"]
        )
        let defaultPlaySound = NotificationActionConfig(
            actionType: .playSound,
            enabled: false,
            config: ["sound": "Glass"]
        )
        let result = AINotificationSettingsBridge.updatedActions(
            for: .finished,
            preference: AINotificationPrimaryPreference(
                showNotification: false,
                styleTab: true,
                playSound: true,
                dockBounce: false,
                hasAdditionalActions: false
            ),
            currentActions: [currentStyleOnly],
            defaultActions: [currentStyleOnly, defaultPlaySound]
        )
        let playSound = result.first(where: { $0.actionType == .playSound })
        XCTAssertEqual(playSound?.config["sound"], "Glass", "default-only action keeps its default config")
        XCTAssertEqual(playSound?.enabled, true, "preference flag flips enabled regardless of source template")
    }
}
