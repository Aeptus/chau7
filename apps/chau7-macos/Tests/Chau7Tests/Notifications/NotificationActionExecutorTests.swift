#if !SWIFT_PACKAGE
import XCTest
@testable import Chau7
import Chau7Core

@MainActor
final class NotificationActionExecutorTests: XCTestCase {
    private final class MockDelegate: NotificationActionDelegate {
        var focusResult = false
        var styleResult: UUID?
        var badgeResult = false
        var snippetResult = false

        func focusTab(tabID: UUID) -> Bool {
            focusResult
        }

        func styleTab(tabID: UUID, preset: String, config: [String: String]) -> UUID? {
            styleResult
        }

        func badgeTab(tabID: UUID, text: String, color: String) -> Bool {
            badgeResult
        }

        func insertSnippet(id: String, tabID: UUID, autoExecute: Bool) -> Bool {
            snippetResult
        }

        func flashMenuBar(duration: Int, animate: Bool) {}
    }

    private func makeEvent(tabID: UUID? = UUID()) -> AIEvent {
        AIEvent(
            source: .codex,
            type: "waiting_input",
            tool: "Codex",
            message: "Codex is waiting",
            ts: "2026-04-01T20:00:00Z",
            tabID: tabID
        )
    }

    func testStyleActionReportsFailureWhenDelegateCannotResolveExplicitTab() {
        let delegate = MockDelegate()
        let executor = NotificationActionExecutor.shared
        executor.delegate = delegate

        let report = executor.execute(
            actions: [NotificationActionConfig(actionType: .styleTab, enabled: true)],
            for: makeEvent()
        )

        XCTAssertTrue(report.successfulActions.isEmpty)
        XCTAssertFalse(report.didStyleTab)
        XCTAssertTrue(report.notes.contains { $0.contains("styleTab failed") })
    }

    func testStyleActionReportsSuccessWhenDelegateStylesExplicitTab() {
        let delegate = MockDelegate()
        let executor = NotificationActionExecutor.shared
        let tabID = UUID()
        delegate.styleResult = tabID
        executor.delegate = delegate

        let report = executor.execute(
            actions: [NotificationActionConfig(actionType: .styleTab, enabled: true)],
            for: makeEvent(tabID: tabID)
        )

        XCTAssertEqual(report.successfulActions, [NotificationActionType.styleTab.rawValue])
        XCTAssertTrue(report.didStyleTab)
        XCTAssertTrue(report.notes.isEmpty)
    }

    func testBadgeActionReportsFailureWhenDelegateCannotResolveExplicitTab() {
        let delegate = MockDelegate()
        let executor = NotificationActionExecutor.shared
        executor.delegate = delegate

        let report = executor.execute(
            actions: [NotificationActionConfig(actionType: .badgeTab, enabled: true)],
            for: makeEvent()
        )

        XCTAssertTrue(report.successfulActions.isEmpty)
        XCTAssertTrue(report.notes.contains { $0.contains("badgeTab failed") })
    }
}
#endif
