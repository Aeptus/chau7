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

        XCTAssertEqual(updated.map(\.actionType), [.showNotification, .playSound, .runScript])
        XCTAssertEqual(updated.first(where: { $0.actionType == .playSound })?.config["sound"], "Purr")
        XCTAssertEqual(updated.last?.actionType, .runScript)
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

        XCTAssertEqual(updated.map(\.actionType), [.webhook])
    }
}
