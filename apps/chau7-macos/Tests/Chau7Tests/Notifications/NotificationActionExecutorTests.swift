#if !SWIFT_PACKAGE
import XCTest
@testable import Chau7
import Chau7Core

@MainActor
final class NotificationActionExecutorTests: XCTestCase {
    private final class MockDelegate: NotificationActionDelegate {
        var focusResult = false
        var styleResult: UUID?
        var styleCallResults: [UUID?] = []
        var styledTabIDs: [UUID] = []
        var existingTabs: Set<UUID> = []
        var badgeResult = false
        var snippetResult = false
        var resolvedExactTabID: UUID?
        var resolveTarget: TabTarget?

        func focusTab(tabID: UUID) -> Bool {
            focusResult
        }

        func styleTab(tabID: UUID, preset: String, config: [String: String]) -> UUID? {
            styledTabIDs.append(tabID)
            if !styleCallResults.isEmpty {
                return styleCallResults.removeFirst()
            }
            styleResult
        }

        func tabExists(tabID: UUID) -> Bool {
            existingTabs.contains(tabID)
        }

        func badgeTab(tabID: UUID, text: String, color: String) -> Bool {
            badgeResult
        }

        func insertSnippet(id: String, tabID: UUID, autoExecute: Bool) -> Bool {
            snippetResult
        }

        func flashMenuBar(duration: Int, animate: Bool) {}

        func resolveExactTab(target: TabTarget) -> UUID? {
            resolveTarget = target
            return resolvedExactTabID
        }
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

    override func setUp() {
        super.setUp()
        NotificationActionExecutor.shared.resetForTesting()
    }

    override func tearDown() {
        NotificationActionExecutor.shared.resetForTesting()
        super.tearDown()
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

    func testStyleActionRecoversStaleExplicitTabViaExactSessionResolution() {
        let delegate = MockDelegate()
        let executor = NotificationActionExecutor.shared
        let staleTabID = UUID()
        let recoveredTabID = UUID()
        delegate.styleCallResults = [nil, recoveredTabID]
        delegate.resolvedExactTabID = recoveredTabID
        delegate.existingTabs = [recoveredTabID]
        executor.delegate = delegate

        let report = executor.execute(
            actions: [NotificationActionConfig(actionType: .styleTab, enabled: true)],
            for: AIEvent(
                source: .codex,
                type: "finished",
                tool: "Codex",
                message: "done",
                ts: "2026-04-02T12:00:00Z",
                directory: "/tmp/chau7",
                tabID: staleTabID,
                sessionID: "thread_123",
                reliability: .authoritative
            )
        )

        XCTAssertEqual(report.successfulActions, [NotificationActionType.styleTab.rawValue])
        XCTAssertTrue(report.didStyleTab)
        XCTAssertEqual(
            delegate.resolveTarget,
            TabTarget(tool: "Codex", directory: "/tmp/chau7", tabID: nil, sessionID: "thread_123")
        )
        XCTAssertEqual(delegate.styledTabIDs, [recoveredTabID])
    }

    func testResolveAutoClearTabIDRecoversMissingTabViaExactSessionLookup() {
        let staleTabID = UUID()
        let recoveredTabID = UUID()
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-04-03T09:00:00Z",
            directory: "/tmp/chau7",
            tabID: staleTabID,
            sessionID: "thread_999",
            reliability: .authoritative
        )

        let resolved = NotificationActionExecutor.resolveAutoClearTabID(
            originalTabID: staleTabID,
            event: event,
            tabExists: { $0 == recoveredTabID },
            resolveExactTab: { _ in recoveredTabID }
        )

        XCTAssertEqual(resolved, recoveredTabID)
    }

    func testResolveAutoClearTabIDReturnsNilWhenTabDisappearsAndCannotBeRecovered() {
        let staleTabID = UUID()
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-04-03T09:00:00Z",
            directory: "/tmp/chau7",
            tabID: staleTabID,
            sessionID: "thread_999",
            reliability: .authoritative
        )

        let resolved = NotificationActionExecutor.resolveAutoClearTabID(
            originalTabID: staleTabID,
            event: event,
            tabExists: { _ in false },
            resolveExactTab: { _ in nil }
        )

        XCTAssertNil(resolved)
    }

    func testStyleActionSchedulesDeferredRetryForRecoverableStaleTab() {
        let delegate = MockDelegate()
        let executor = NotificationActionExecutor.shared
        let staleTabID = UUID()
        let recoveredTabID = UUID()
        delegate.styleCallResults = [nil, recoveredTabID]
        delegate.resolvedExactTabID = recoveredTabID
        delegate.existingTabs = [recoveredTabID]
        executor.delegate = delegate

        let report = executor.execute(
            actions: [NotificationActionConfig(actionType: .styleTab, enabled: true)],
            for: AIEvent(
                source: .claudeCode,
                type: "waiting_input",
                tool: "Claude",
                message: "waiting",
                ts: "2026-04-04T08:00:00Z",
                directory: "/tmp/chau7",
                tabID: staleTabID,
                sessionID: "claude-session-1",
                reliability: .authoritative
            )
        )

        XCTAssertTrue(report.didStyleTab)
        XCTAssertTrue(report.notes.contains { $0.contains("deferred retry scheduled") })

        let expectation = expectation(description: "deferred style retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(delegate.styledTabIDs, [recoveredTabID, recoveredTabID])
    }

    func testStyleActionDoesNotScheduleDeferredRetryWhenStaleTabCannotBeRecovered() {
        let delegate = MockDelegate()
        let executor = NotificationActionExecutor.shared
        let staleTabID = UUID()
        delegate.styleResult = nil
        delegate.existingTabs = []
        delegate.resolvedExactTabID = staleTabID
        executor.delegate = delegate

        let report = executor.execute(
            actions: [NotificationActionConfig(actionType: .styleTab, enabled: true)],
            for: AIEvent(
                source: .claudeCode,
                type: "waiting_input",
                tool: "Claude",
                message: "waiting",
                ts: "2026-04-04T08:00:00Z",
                directory: "/tmp/chau7",
                tabID: staleTabID,
                sessionID: "claude-session-2",
                reliability: .authoritative
            )
        )

        XCTAssertTrue(report.successfulActions.isEmpty)
        XCTAssertFalse(report.didStyleTab)
        XCTAssertFalse(report.notes.contains { $0.contains("deferred retry scheduled") })
    }

    func testCancelPendingStyleWorkCancelsDeferredRetryForSession() {
        let delegate = MockDelegate()
        let executor = NotificationActionExecutor.shared
        let staleTabID = UUID()
        let recoveredTabID = UUID()
        delegate.styleCallResults = [nil, recoveredTabID]
        delegate.resolvedExactTabID = recoveredTabID
        delegate.existingTabs = [recoveredTabID]
        executor.delegate = delegate

        let report = executor.execute(
            actions: [NotificationActionConfig(actionType: .styleTab, enabled: true)],
            for: AIEvent(
                source: .claudeCode,
                type: "waiting_input",
                tool: "Claude",
                message: "waiting",
                ts: "2026-04-04T08:00:00Z",
                directory: "/tmp/chau7",
                tabID: staleTabID,
                sessionID: "claude-session-cancel",
                reliability: .authoritative
            )
        )

        XCTAssertTrue(report.notes.contains { $0.contains("deferred retry scheduled") })

        executor.cancelPendingStyleWork(tabID: staleTabID, sessionID: "claude-session-cancel")

        let expectation = expectation(description: "cancelled deferred retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(delegate.styledTabIDs, [recoveredTabID])
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
