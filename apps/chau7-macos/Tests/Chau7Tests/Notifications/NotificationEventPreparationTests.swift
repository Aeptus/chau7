import XCTest
@testable import Chau7Core

final class NotificationEventPreparationTests: XCTestCase {
    func testPrepareResolvesTabEvenWhenTriggerIsDisabled() {
        let expectedTabID = UUID()
        let event = AIEvent(
            source: .historyMonitor,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            directory: "/tmp/chau7",
            sessionID: "session-1",
            reliability: .fallback
        )
        var triggerState = NotificationTriggerState()
        let trigger = NotificationTriggerCatalog.trigger(for: event)
        XCTAssertNotNil(trigger)
        triggerState.setEnabled(false, for: trigger!)

        var resolverCallCount = 0
        let decision = NotificationEventPreparation.prepare(event, triggerState: triggerState) { target in
            resolverCallCount += 1
            XCTAssertEqual(
                target,
                TabTarget(
                    tool: "Claude",
                    directory: "/tmp/chau7",
                    tabID: nil,
                    sessionID: "session-1"
                )
            )
            return expectedTabID
        }

        XCTAssertEqual(resolverCallCount, 1)
        if case .proceed(let prepared) = decision {
            XCTAssertEqual(prepared.event.tabID, expectedTabID)
            XCTAssertEqual(prepared.resolutionMethod, "resolved_via_tab_resolver")
        } else {
            XCTFail("Expected disabled trigger to proceed through routing")
        }
    }

    func testPrepareResolvesTabForEnabledFallbackTrigger() {
        let expectedTabID = UUID()
        let event = AIEvent(
            source: .historyMonitor,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            directory: "/tmp/chau7",
            sessionID: "session-1",
            reliability: .fallback
        )

        let decision = NotificationEventPreparation.prepare(event, triggerState: NotificationTriggerState()) { target in
            XCTAssertEqual(
                target,
                TabTarget(
                    tool: "Codex",
                    directory: "/tmp/chau7",
                    tabID: nil,
                    sessionID: "session-1"
                )
            )
            return expectedTabID
        }

        if case .proceed(let prepared) = decision {
            XCTAssertEqual(prepared.event.tabID, expectedTabID)
            XCTAssertEqual(prepared.resolutionMethod, "resolved_via_tab_resolver")
        } else {
            XCTFail("Expected enabled event to proceed")
        }
    }

    func testPrepareLeavesAuthoritativeClaudeEventUnresolvedUntilExactBindingExists() {
        let event = AIEvent(
            source: .claudeCode,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            directory: "/tmp/chau7",
            sessionID: "claude-session-1",
            reliability: .authoritative
        )

        var resolverCallCount = 0
        let decision = NotificationEventPreparation.prepare(event, triggerState: NotificationTriggerState()) { _ in
            resolverCallCount += 1
            return UUID()
        }

        XCTAssertEqual(resolverCallCount, 0)
        if case .proceed(let prepared) = decision {
            XCTAssertNil(prepared.event.tabID)
            XCTAssertEqual(prepared.resolutionMethod, "awaiting_authoritative_resolution")
        } else {
            XCTFail("Expected authoritative Claude event to proceed unresolved")
        }
    }

    func testPrepareKeepsExplicitTabIDWithoutResolvingAgain() {
        let explicitTabID = UUID()
        let event = AIEvent(
            source: .claudeCode,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            tabID: explicitTabID
        )

        var resolverCallCount = 0
        let decision = NotificationEventPreparation.prepare(event, triggerState: NotificationTriggerState()) { _ in
            resolverCallCount += 1
            return UUID()
        }

        XCTAssertEqual(resolverCallCount, 0)
        if case .proceed(let prepared) = decision {
            XCTAssertEqual(prepared.event.tabID, explicitTabID)
            XCTAssertEqual(prepared.resolutionMethod, "explicit_tab")
        } else {
            XCTFail("Expected explicit-tab event to proceed")
        }
    }

    func testPrepareCorrectsAuthoritativeExplicitTabUsingSessionResolution() {
        let staleTabID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let liveTabID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let event = AIEvent(
            source: .codex,
            type: "finished",
            rawType: "agent-turn-complete",
            tool: "Codex",
            message: "done",
            ts: "2026-04-02T00:00:00Z",
            directory: "/tmp/chau7",
            tabID: staleTabID,
            sessionID: "thread_123",
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        let decision = NotificationEventPreparation.prepare(event, triggerState: NotificationTriggerState()) { target in
            XCTAssertEqual(
                target,
                TabTarget(tool: "Codex", directory: "/tmp/chau7", tabID: nil, sessionID: "thread_123")
            )
            return liveTabID
        }

        if case .proceed(let prepared) = decision {
            XCTAssertEqual(prepared.event.tabID, liveTabID)
            XCTAssertEqual(prepared.resolutionMethod, "explicit_tab_corrected_via_session")
        } else {
            XCTFail("Expected authoritative explicit-tab event to be corrected")
        }
    }

    func testPrepareDoesNotCorrectFallbackExplicitTab() {
        let explicitTabID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let otherTabID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let event = AIEvent(
            source: .historyMonitor,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-04-02T00:00:00Z",
            tabID: explicitTabID,
            sessionID: "thread_123",
            producer: "history_idle_monitor",
            reliability: .fallback
        )

        var resolverCalls = 0
        let decision = NotificationEventPreparation.prepare(event, triggerState: NotificationTriggerState()) { _ in
            resolverCalls += 1
            return otherTabID
        }

        XCTAssertEqual(resolverCalls, 0)
        if case .proceed(let prepared) = decision {
            XCTAssertEqual(prepared.event.tabID, explicitTabID)
            XCTAssertEqual(prepared.resolutionMethod, "explicit_tab")
        } else {
            XCTFail("Expected fallback explicit-tab event to keep explicit tab")
        }
    }

    func testPrepareRebindingAuthoritativeExplicitTabPreservesRepoPath() {
        // Regression: the prior hand-rolled AIEvent reconstruction inside
        // rebindAuthoritativeExplicitTabIfNeeded was silently dropping
        // repoPath. Now that rebind routes through event.replacingTabID,
        // repoPath round-trips. Per-repo event filtering downstream
        // depends on this.
        let staleExplicitTabID = UUID()
        let correctedTabID = UUID()
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "done",
            ts: "2026-06-10T00:00:00Z",
            directory: "/Users/me/projects/Chau7/apps/chau7-macos",
            repoPath: "/Users/me/projects/Chau7",
            tabID: staleExplicitTabID,
            sessionID: "thread_42",
            reliability: .authoritative
        )

        let decision = NotificationEventPreparation.prepare(event, triggerState: NotificationTriggerState()) { _ in
            correctedTabID
        }

        guard case .proceed(let prepared) = decision else {
            XCTFail("Expected proceed for authoritative explicit-tab rebind")
            return
        }
        XCTAssertEqual(prepared.event.tabID, correctedTabID, "tab must be rebound")
        XCTAssertEqual(prepared.event.repoPath, "/Users/me/projects/Chau7", "repoPath must survive rebind")
        XCTAssertEqual(prepared.resolutionMethod, "explicit_tab_corrected_via_session")
    }
}
