import XCTest
@testable import Chau7Core

final class NotificationActionRequirementsTests: XCTestCase {
    func testStyleActionRequiresResolvedTabTarget() {
        let config = NotificationActionConfig(actionType: .styleTab, enabled: true)
        XCTAssertTrue(NotificationActionRequirements.requiresResolvedTabTarget(config))
    }

    func testFocusWindowWithoutFocusTabDoesNotRequireResolvedTabTarget() {
        let config = NotificationActionConfig(
            actionType: .focusWindow,
            enabled: true,
            config: ["focusTab": "false"]
        )
        XCTAssertFalse(NotificationActionRequirements.requiresResolvedTabTarget(config))
    }

    func testPartitionSeparatesTabScopedActions() {
        let actions = [
            NotificationActionConfig(actionType: .showNotification, enabled: true),
            NotificationActionConfig(actionType: .styleTab, enabled: true),
            NotificationActionConfig(actionType: .focusWindow, enabled: true, config: ["focusTab": "false"]),
            NotificationActionConfig(actionType: .badgeTab, enabled: true)
        ]

        let partition = NotificationActionRequirements.partitionByResolvedTabRequirement(actions)

        XCTAssertEqual(partition.tabScoped.map(\.actionType), [.styleTab, .badgeTab])
        XCTAssertEqual(partition.nonTabScoped.map(\.actionType), [.showNotification, .focusWindow])
    }
}
