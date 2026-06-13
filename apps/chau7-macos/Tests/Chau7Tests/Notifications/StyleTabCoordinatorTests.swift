import XCTest
@testable import Chau7
import Chau7Core

/// Focused tests for the extracted StyleTabCoordinator. Exercises the
/// pure static resolveAutoClearTabID, the redundant-style-re-apply
/// suppression, and the failure-attribution path on missing tabID.
/// The full retry/recovery integration path is covered by
/// `NotificationActionExecutorTests` (Xcode-only, #if !SWIFT_PACKAGE).
@MainActor
final class StyleTabCoordinatorTests: XCTestCase {

    private func makeEvent(tabID: UUID? = UUID(), sessionID: String? = "session-1") -> AIEvent {
        AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-04-03T09:00:00Z",
            directory: "/tmp/chau7",
            tabID: tabID,
            sessionID: sessionID,
            reliability: .authoritative
        )
    }

    // MARK: - Static helper

    func testResolveAutoClearTabIDReturnsOriginalWhenStillAlive() {
        let original = UUID()
        let event = makeEvent(tabID: original)
        let resolved = StyleTabCoordinator.resolveAutoClearTabID(
            originalTabID: original,
            event: event,
            tabExists: { $0 == original },
            resolveExactTab: { _ in nil }
        )
        XCTAssertEqual(resolved, original)
    }

    func testResolveAutoClearTabIDRecoversViaSessionWhenOriginalDisappears() {
        let stale = UUID()
        let recovered = UUID()
        let event = makeEvent(tabID: stale)
        let resolved = StyleTabCoordinator.resolveAutoClearTabID(
            originalTabID: stale,
            event: event,
            tabExists: { $0 == recovered },
            resolveExactTab: { _ in recovered }
        )
        XCTAssertEqual(resolved, recovered)
    }

    func testResolveAutoClearTabIDReturnsNilWhenOriginalGoneAndNoSession() {
        let stale = UUID()
        let event = makeEvent(tabID: stale, sessionID: nil)
        let resolved = StyleTabCoordinator.resolveAutoClearTabID(
            originalTabID: stale,
            event: event,
            tabExists: { _ in false },
            resolveExactTab: { _ in UUID() }
        )
        XCTAssertNil(resolved, "Cannot recover without session ID")
    }

    func testResolveAutoClearTabIDReturnsNilWhenSessionRecoveryAlsoFails() {
        let stale = UUID()
        let event = makeEvent(tabID: stale)
        let resolved = StyleTabCoordinator.resolveAutoClearTabID(
            originalTabID: stale,
            event: event,
            tabExists: { _ in false },
            resolveExactTab: { _ in nil }
        )
        XCTAssertNil(resolved)
    }

    // MARK: - apply()

    func testApplyRecordsFailureWhenEventMissingTabID() {
        let coordinator = StyleTabCoordinator()
        let delegate = FakeDelegate()
        coordinator.delegate = delegate
        let event = makeEvent(tabID: nil)

        let report = coordinator.apply(
            event: event,
            config: NotificationActionConfig(actionType: .styleTab, enabled: true, config: ["style": "waiting"])
        )

        XCTAssertTrue(report.successfulActions.isEmpty)
        XCTAssertEqual(report.notes, ["styleTab missing explicit tabID"])
        XCTAssertFalse(report.didStyleTab)
    }

    func testApplyDelegatesToLiveStyleAndRecordsSuccess() {
        let coordinator = StyleTabCoordinator()
        let delegate = FakeDelegate()
        delegate.tabExistsResult = true
        coordinator.delegate = delegate

        let tabID = UUID()
        delegate.styleTabResult = tabID
        let event = makeEvent(tabID: tabID)

        let report = coordinator.apply(
            event: event,
            config: NotificationActionConfig(
                actionType: .styleTab,
                enabled: true,
                config: ["style": "waiting"]
            )
        )

        XCTAssertEqual(report.successfulActions, [NotificationActionType.styleTab.rawValue])
        XCTAssertTrue(report.didStyleTab)
        XCTAssertEqual(delegate.styleTabCallCount, 1)
        XCTAssertEqual(delegate.lastStyleTabPreset, "waiting")
    }

    func testApplySuppressesRedundantReApplyWhenAutoClearTimerActive() {
        let coordinator = StyleTabCoordinator()
        let delegate = FakeDelegate()
        delegate.tabExistsResult = true
        coordinator.delegate = delegate

        let tabID = UUID()
        delegate.styleTabResult = tabID
        let event = makeEvent(tabID: tabID)
        let config = NotificationActionConfig(
            actionType: .styleTab,
            enabled: true,
            config: ["style": "waiting", "autoClearSeconds": "30"]
        )

        _ = coordinator.apply(event: event, config: config)
        XCTAssertEqual(delegate.styleTabCallCount, 1)

        // Second identical apply must short-circuit — the auto-clear timer
        // already running on the tab means re-styling would reset the
        // 30s countdown, which is exactly what idle-re-notifications must
        // not do.
        let secondReport = coordinator.apply(event: event, config: config)
        XCTAssertEqual(delegate.styleTabCallCount, 1, "Redundant re-apply must skip delegate")
        XCTAssertTrue(secondReport.didStyleTab, "Suppressed apply still records success")
    }
}

// MARK: - Fake delegate

@MainActor
private final class FakeDelegate: NotificationActionDelegate {
    var tabExistsResult = true
    var styleTabResult: UUID?
    var resolveExactTabResult: UUID?

    private(set) var styleTabCallCount = 0
    private(set) var lastStyleTabPreset: String?

    func focusTab(tabID: UUID) -> Bool {
        true
    }

    func styleTab(tabID: UUID, preset: String, config: [String: String]) -> UUID? {
        styleTabCallCount += 1
        lastStyleTabPreset = preset
        return styleTabResult
    }

    func tabExists(tabID: UUID) -> Bool {
        tabExistsResult
    }

    func badgeTab(tabID: UUID, text: String, color: String) -> Bool {
        true
    }

    func insertSnippet(id: String, tabID: UUID, autoExecute: Bool) -> Bool {
        true
    }

    func flashMenuBar(duration: Int, animate: Bool) {}

    func resolveExactTab(target: TabTarget) -> UUID? {
        resolveExactTabResult
    }
}
