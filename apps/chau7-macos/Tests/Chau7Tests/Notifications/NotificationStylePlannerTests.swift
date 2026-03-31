import XCTest
@testable import Chau7Core

final class NotificationStylePlannerTests: XCTestCase {
    func testStyleOnlyActionsPreferExplicitEnabledStyle() {
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-03-31T00:00:00Z"
        )
        let explicit = NotificationActionConfig(
            actionType: .styleTab,
            enabled: true,
            config: ["style": "attention"]
        )

        let actions = NotificationStylePlanner.styleOnlyActions(for: event, from: [explicit])

        XCTAssertEqual(actions, [explicit])
    }

    func testStyleOnlyActionsFallBackToDefaultStyleWhenNoStyleActionExists() {
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-03-31T00:00:00Z"
        )

        let actions = NotificationStylePlanner.styleOnlyActions(
            for: event,
            from: [NotificationActionConfig(actionType: .showNotification, enabled: true)]
        )

        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.actionType, .styleTab)
        XCTAssertEqual(actions.first?.config["style"], "waiting")
    }

    func testStyleOnlyActionsRespectExplicitDisabledStyleAction() {
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-03-31T00:00:00Z"
        )
        let disabledStyle = NotificationActionConfig(
            actionType: .styleTab,
            enabled: false,
            config: ["style": "attention"]
        )

        let actions = NotificationStylePlanner.styleOnlyActions(for: event, from: [disabledStyle])

        XCTAssertTrue(actions.isEmpty)
    }

    func testSupplementalStyleActionOnlyAppearsWhenNoStyleActionExists() {
        let event = AIEvent(
            source: .codex,
            type: "permission",
            tool: "Codex",
            message: "needs input",
            ts: "2026-03-31T00:00:00Z"
        )

        let fallback = NotificationStylePlanner.supplementalStyleAction(
            for: event,
            from: [NotificationActionConfig(actionType: .dockBounce, enabled: true)]
        )
        XCTAssertEqual(fallback?.actionType, .styleTab)
        XCTAssertEqual(fallback?.config["style"], "attention")

        let explicitStyle = NotificationActionConfig(actionType: .styleTab, enabled: false)
        XCTAssertNil(
            NotificationStylePlanner.supplementalStyleAction(for: event, from: [explicitStyle])
        )
    }
}
