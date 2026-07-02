import XCTest
@testable import Chau7Core

final class EventTopicCatalogTests: XCTestCase {

    // MARK: - Contract alignment

    func testTopicConstantsMatchObserverContract() {
        let catalogTopics: Set<String> = [
            EventTopic.approvalState,
            EventTopic.repoEvents,
            EventTopic.runtimeEvents,
            EventTopic.sessionState,
            EventTopic.tabState,
            EventTopic.telemetryRuns,
            EventTopic.timerInventory
        ]
        XCTAssertEqual(catalogTopics, Set(Chau7MCPObserverContract.supportedTopics))
    }

    func testDeclaredTopicsOnlyUseSupportedTopics() {
        let supported = Set(Chau7MCPObserverContract.supportedTopics)
        for (type, topics) in EventTopicCatalog.declaredTopics {
            XCTAssertTrue(
                topics.isSubset(of: supported),
                "type \(type) declares unsupported topics: \(topics.subtracting(supported))"
            )
        }
    }

    // MARK: - Completeness: every known event type has an explicit entry

    func testEveryRuntimeEventTypeIsDeclared() {
        let runtimeTypes = [
            RuntimeEventType.sessionStarting, .sessionReady, .sessionStopped, .sessionError,
            .stateChanged, .turnStarted, .turnCompleted, .turnFailed, .turnReconciled,
            .turnResult, .userInput, .agentResponding, .notification, .toolUse, .toolResult,
            .outputChunk, .approvalNeeded, .approvalResolved, .stallDetected,
            .tokenThreshold, .costThreshold, .exitClassified, .policyBlocked
        ]
        for type in runtimeTypes {
            XCTAssertNotNil(
                EventTopicCatalog.declaredTopics[type.rawValue],
                "RuntimeEventType \(type.rawValue) has no declared topic entry"
            )
        }
    }

    func testKnownStructuralTypesAreDeclared() {
        // Types recorded by direct observability callers today.
        let structuralTypes = [
            "ai_event", "app_launched", "approval_resolved", "approval_waiting",
            "build_activated", "file_conflict", "finished", "tab_closed",
            "tab_created", "tab_opened", "telemetry_run_completed",
            "telemetry_run_started", "telemetry_run_updated", "waiting_input",
            "window_focused", "window_unfocused"
        ]
        for type in structuralTypes {
            XCTAssertNotNil(
                EventTopicCatalog.declaredTopics[type],
                "structural type \(type) has no declared topic entry"
            )
        }
    }

    // MARK: - Parity with the legacy string-prefix heuristic

    /// Reimplementation of the observability service's `topicsForEvent`
    /// heuristic, used to prove the declarative catalog assigns identical
    /// topics for every known input before the heuristic is deleted (stage A4).
    private func legacyHeuristicTopics(
        type: String,
        subsystem: String,
        tabID: String?,
        sessionID: String?,
        runID: String?,
        repoPath: String?
    ) -> [String] {
        var topics = Set<String>(["runtime-events"])
        if tabID != nil || type.hasPrefix("tab_") || subsystem == "tabs" {
            topics.insert("tab-state")
        }
        if subsystem == "mcp_approvals" || type.hasPrefix("approval_") {
            topics.insert("approval-state")
        }
        if runID != nil || type.hasPrefix("telemetry_run_") {
            topics.insert("telemetry-runs")
        }
        if repoPath != nil || type == "ai_event" {
            topics.insert("repo-events")
        }
        if sessionID != nil {
            topics.insert("session-state")
        }
        return Array(topics).sorted()
    }

    func testCatalogMatchesLegacyHeuristicForKnownTypes() {
        let subsystemsByType: [String: String] = [
            "ai_event": "claude-code",
            "tab_created": "tabs", "tab_closed": "tabs", "tab_opened": "tabs", "tab_switched": "tabs",
            "approval_waiting": "mcp_approvals", "approval_resolved": "mcp_approvals",
            "approval_needed": "mcp_approvals",
            "telemetry_run_started": "telemetry", "telemetry_run_updated": "telemetry",
            "telemetry_run_completed": "telemetry",
            "app_launched": "app", "build_activated": "app",
            "window_focused": "app", "window_unfocused": "app",
            "file_conflict": "app", "finished": "terminal", "waiting_input": "terminal"
        ]

        let contexts: [(tab: String?, session: String?, run: String?, repo: String?)] = [
            (nil, nil, nil, nil),
            ("tab_1", nil, nil, nil),
            (nil, "sess-1", nil, nil),
            (nil, nil, "run-1", nil),
            (nil, nil, nil, "/repo"),
            ("tab_1", "sess-1", "run-1", "/repo")
        ]

        for (type, subsystem) in subsystemsByType {
            for context in contexts {
                let expected = legacyHeuristicTopics(
                    type: type, subsystem: subsystem,
                    tabID: context.tab, sessionID: context.session,
                    runID: context.run, repoPath: context.repo
                )
                let actual = EventTopicCatalog.topics(for: EventTopicContext(
                    type: type, subsystem: subsystem,
                    hasTab: context.tab != nil, hasSession: context.session != nil,
                    hasRun: context.run != nil, hasRepo: context.repo != nil
                ))
                XCTAssertEqual(
                    actual, expected,
                    "topic mismatch for type=\(type) subsystem=\(subsystem) context=\(context)"
                )
            }
        }
    }

    // MARK: - Unknown types get the declared fallback

    func testUnknownTypeGetsBasePlusContextTopics() {
        let bare = EventTopicCatalog.topics(for: EventTopicContext(type: "future_event", subsystem: "future"))
        XCTAssertEqual(bare, [EventTopic.runtimeEvents])

        let withContext = EventTopicCatalog.topics(for: EventTopicContext(
            type: "future_event", subsystem: "future",
            hasTab: true, hasSession: true, hasRun: true, hasRepo: true
        ))
        XCTAssertEqual(withContext, [
            EventTopic.repoEvents, EventTopic.runtimeEvents, EventTopic.sessionState,
            EventTopic.tabState, EventTopic.telemetryRuns
        ])
    }

    // MARK: - Determinism

    func testTopicAssignmentIsDeterministicAndSorted() {
        let context = EventTopicContext(
            type: "approval_waiting", subsystem: "mcp_approvals",
            hasTab: true, hasSession: true
        )
        let first = EventTopicCatalog.topics(for: context)
        for _ in 0 ..< 50 {
            XCTAssertEqual(EventTopicCatalog.topics(for: context), first)
        }
        XCTAssertEqual(first, first.sorted())
    }

    // MARK: - AIEvent context mapping

    func testAIEventContextMatchesObservabilityRecording() {
        let event = AIEvent(
            source: .claudeCode, type: "finished", tool: "Claude Code",
            message: "done", ts: DateFormatters.nowISO8601(),
            repoPath: "/repo", sessionID: "sess-1"
        )
        let context = EventTopicCatalog.context(for: event)
        XCTAssertEqual(context.type, "ai_event")
        XCTAssertEqual(context.subsystem, event.source.rawValue)
        XCTAssertTrue(context.hasSession)
        XCTAssertTrue(context.hasRepo)
        XCTAssertFalse(context.hasTab)
        XCTAssertFalse(context.hasRun)
    }
}
