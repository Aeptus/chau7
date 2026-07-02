import XCTest
@testable import Chau7Core

final class NotificationProviderAdapterRegistryTests: XCTestCase {
    func testGeminiProviderCanonicalizesThroughGenericAdapter() {
        let event = AIEvent(
            source: .gemini,
            type: "finished",
            rawType: "finished",
            tool: "Gemini",
            message: "Done",
            ts: "2026-04-02T00:00:00Z",
            sessionID: "gemini-session-1",
            producer: "gemini_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Gemini event to canonicalize")
        }

        XCTAssertEqual(enriched.event.type, "finished")
        XCTAssertEqual(enriched.kind, .taskFinished)
    }

    func testChatGPTProviderCanonicalizesThroughGenericAdapter() {
        let event = AIEvent(
            source: .chatgpt,
            type: "finished",
            rawType: "finished",
            tool: "ChatGPT",
            message: "Done",
            ts: "2026-04-02T00:00:00Z",
            sessionID: "chatgpt-session-1",
            producer: "chatgpt_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected ChatGPT event to canonicalize")
        }

        XCTAssertEqual(enriched.event.type, "finished")
        XCTAssertEqual(enriched.kind, .taskFinished)
    }

    func testCodyProviderCanonicalizesThroughGenericAdapter() {
        let event = AIEvent(
            source: .cody,
            type: "finished",
            rawType: "finished",
            tool: "Cody",
            message: "Done",
            ts: "2026-04-02T00:00:00Z",
            sessionID: "cody-session-1",
            producer: "cody_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Cody event to canonicalize")
        }

        XCTAssertEqual(enriched.event.type, "finished")
        XCTAssertEqual(enriched.kind, .taskFinished)
    }

    func testAmazonQProviderCanonicalizesThroughGenericAdapter() {
        let event = AIEvent(
            source: .amazonQ,
            type: "finished",
            rawType: "finished",
            tool: "Amazon Q",
            message: "Done",
            ts: "2026-04-02T00:00:00Z",
            sessionID: "amazon-q-session-1",
            producer: "amazon_q_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Amazon Q event to canonicalize")
        }

        XCTAssertEqual(enriched.event.type, "finished")
        XCTAssertEqual(enriched.kind, .taskFinished)
    }

    func testDevinProviderCanonicalizesThroughGenericAdapter() {
        let event = AIEvent(
            source: .devin,
            type: "finished",
            rawType: "finished",
            tool: "Devin",
            message: "Done",
            ts: "2026-04-02T00:00:00Z",
            sessionID: "devin-session-1",
            producer: "devin_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Devin event to canonicalize")
        }

        XCTAssertEqual(enriched.event.type, "finished")
        XCTAssertEqual(enriched.kind, .taskFinished)
    }

    func testGooseProviderCanonicalizesThroughGenericAdapter() {
        let event = AIEvent(
            source: .goose,
            type: "finished",
            rawType: "finished",
            tool: "Goose",
            message: "Done",
            ts: "2026-04-02T00:00:00Z",
            sessionID: "goose-session-1",
            producer: "goose_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Goose event to canonicalize")
        }

        XCTAssertEqual(enriched.event.type, "finished")
        XCTAssertEqual(enriched.kind, .taskFinished)
    }

    func testMentatProviderCanonicalizesThroughGenericAdapter() {
        let event = AIEvent(
            source: .mentat,
            type: "finished",
            rawType: "finished",
            tool: "Mentat",
            message: "Done",
            ts: "2026-04-02T00:00:00Z",
            sessionID: "mentat-session-1",
            producer: "mentat_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Mentat event to canonicalize")
        }

        XCTAssertEqual(enriched.event.type, "finished")
        XCTAssertEqual(enriched.kind, .taskFinished)
    }

    func testAmpProviderCanonicalizesThroughGenericAdapter() {
        let event = AIEvent(
            source: .amp,
            type: "finished",
            rawType: "finished",
            tool: "Amp",
            message: "Done",
            ts: "2026-04-02T00:00:00Z",
            sessionID: "amp-session-1",
            producer: "amp_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Amp event to canonicalize")
        }

        XCTAssertEqual(enriched.event.type, "finished")
        XCTAssertEqual(enriched.kind, .taskFinished)
    }

    func testClaudeNotificationEventMapsToWaitingInput() {
        let event = AIEvent(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            source: .claudeCode,
            type: "notification",
            rawType: "notification",
            tool: "Claude",
            title: "Claude needs your input",
            message: "Claude is waiting for your input",
            notificationType: "idle_prompt",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "claude-session-1",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected canonical Claude notification")
        }

        XCTAssertEqual(enriched.kind, .waitingForInput)
        XCTAssertEqual(enriched.event.type, "waiting_input")
        XCTAssertEqual(enriched.event.rawType, "notification")
        XCTAssertEqual(enriched.event.notificationType, "idle_prompt")
        XCTAssertEqual(enriched.event.tool, "Claude")
    }

    func testClaudeResponseCompleteIsDroppedAsStateOnly() {
        let event = AIEvent(
            source: .claudeCode,
            type: "response_complete",
            rawType: "response_complete",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "claude-session-1",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .drop(reason) = decision else {
            return XCTFail("Expected Claude response_complete to be dropped")
        }

        XCTAssertTrue(reason.contains("state-only"))
    }

    func testClaudeIdlePromptTextMapsToWaitingInput() {
        let event = AIEvent(
            source: .claudeCode,
            type: "idle",
            tool: "Claude",
            message: "Waiting for input in Chau7",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "claude-session-1",
            producer: "claude_code_idle",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Claude idle prompt to canonicalize")
        }

        XCTAssertEqual(enriched.kind, .waitingForInput)
        XCTAssertEqual(enriched.event.type, "waiting_input")
        XCTAssertEqual(enriched.event.reliability, .authoritative)
    }

    func testClaudeRawWaitingInputPreservesHeuristicReliability() {
        let event = AIEvent(
            source: .claudeCode,
            type: "waiting_input",
            tool: "Claude",
            message: "Claude is waiting for your input",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "claude-session-1",
            producer: "terminal_wait_pattern_attention",
            reliability: .heuristic
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Claude waiting_input to canonicalize")
        }

        XCTAssertEqual(enriched.kind, .waitingForInput)
        XCTAssertEqual(enriched.event.type, "waiting_input")
        XCTAssertEqual(enriched.event.reliability, .heuristic)
    }

    func testClaudeNotificationEventMapsToAttentionRequired() {
        let event = AIEvent(
            source: .claudeCode,
            type: "notification",
            rawType: "notification",
            tool: "Claude",
            title: "Claude needs your attention",
            message: "Claude Code needs your attention",
            notificationType: "elicitation_dialog",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "claude-session-2",
            producer: "claude_code_monitor",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected canonical Claude attention event")
        }

        XCTAssertEqual(enriched.kind, .attentionRequired)
        XCTAssertEqual(enriched.event.type, "attention_required")
        XCTAssertEqual(enriched.event.notificationType, "elicitation_dialog")
    }

    func testRuntimeWaitingInputCanonicalizesWithoutChangingBehavior() {
        let event = AIEvent(
            source: .runtime,
            type: "waiting_input",
            tool: "Codex",
            message: "Codex is waiting",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            producer: "runtime_session_manager",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected runtime canonical event to emit canonical form")
        }

        XCTAssertEqual(enriched.event.type, "waiting_input")
        XCTAssertEqual(enriched.event.tool, "Codex")
        XCTAssertEqual(enriched.kind, .waitingForInput)
    }

    func testGenericAdapterPreservesProviderRawTypeSpellingWhenRawTypeIsMissing() {
        let event = AIEvent(
            source: .runtime,
            type: "agent-turn-complete",
            tool: "Codex",
            message: "Turn complete",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            producer: "runtime_session_manager",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected runtime event to canonicalize")
        }

        XCTAssertEqual(enriched.event.rawType, "agent-turn-complete")
        XCTAssertEqual(enriched.kind, .taskFinished)
    }

    func testCodexAgentTurnCompleteCanonicalizesToFinished() {
        let event = AIEvent(
            source: .codex,
            type: "agent-turn-complete",
            rawType: "agent-turn-complete",
            tool: "Codex",
            title: "Codex finished",
            message: "Turn complete",
            ts: "2026-04-02T00:00:00Z",
            tabID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Codex turn complete to emit canonical finished")
        }

        XCTAssertEqual(enriched.event.type, "finished")
        XCTAssertEqual(enriched.event.rawType, "agent-turn-complete")
        XCTAssertEqual(enriched.kind, .taskFinished)
        XCTAssertEqual(enriched.event.reliability, .authoritative)
    }

    func testCodexApprovalRequestedCanonicalizesToPermission() {
        let event = AIEvent(
            source: .codex,
            type: "approval-requested",
            rawType: "approval-requested",
            tool: "Codex",
            message: "Needs approval",
            ts: "2026-04-02T00:00:00Z",
            tabID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
            producer: "codex_notify_hook",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Codex approval event to emit canonical permission")
        }

        XCTAssertEqual(enriched.event.type, "permission")
        XCTAssertEqual(enriched.kind, .permissionRequired)
    }

    func testCodexFallbackIdlePreservesFallbackReliability() {
        let event = AIEvent(
            source: .codex,
            type: "idle",
            tool: "Codex",
            message: "Idle",
            ts: "2026-04-02T00:00:00Z",
            sessionID: "thread_123",
            producer: "history_idle_monitor",
            reliability: .fallback
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected Codex idle event to canonicalize")
        }

        XCTAssertEqual(enriched.event.type, "idle")
        XCTAssertEqual(enriched.event.reliability, .fallback)
        XCTAssertEqual(enriched.kind, .idle)
        XCTAssertEqual(enriched.event.reliability, .fallback)
    }

    func testUnsupportedGenericAIEventIsDropped() {
        let event = AIEvent(
            source: .runtime,
            type: "provider_internal_state",
            rawType: "provider_internal_state",
            tool: "Codex",
            message: "internal state",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            producer: "runtime_session_manager",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .drop(reason) = decision else {
            return XCTFail("Expected unsupported generic AI raw event to be dropped")
        }

        XCTAssertTrue(reason.contains("Unsupported generic AI raw event"))
    }

    func testHistoryMonitorFinishedCanonicalizesAsFallback() {
        let event = AIEvent(
            source: .historyMonitor,
            type: "finished",
            tool: "Codex",
            message: "Codex finished",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            producer: "history_idle_monitor",
            reliability: .fallback
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected canonical history monitor event")
        }

        XCTAssertEqual(enriched.kind, .taskFinished)
        XCTAssertEqual(enriched.event.type, "finished")
        XCTAssertEqual(enriched.event.reliability, .fallback)
    }

    func testEventsLogWaitingInputDropsWithoutIdentity() {
        let event = AIEvent(
            source: .eventsLog,
            type: "waiting_input",
            tool: "Codex",
            message: "Codex needs input",
            ts: "2026-04-01T00:00:00Z",
            producer: "external_events_log",
            reliability: .fallback
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .drop(reason) = decision else {
            return XCTFail("Expected events log event without identity to drop")
        }

        XCTAssertTrue(reason.contains("missing routing identity"))
    }

    func testEventsLogWaitingInputCanRouteWithDirectoryOnly() {
        let event = AIEvent(
            source: .eventsLog,
            type: "waiting_input",
            tool: "Codex",
            message: "Codex needs input",
            ts: "2026-04-01T00:00:00Z",
            directory: "/tmp/chau7",
            producer: "external_events_log",
            reliability: .fallback
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected events log event with directory identity to emit")
        }

        XCTAssertEqual(enriched.event.type, "waiting_input")
        XCTAssertEqual(enriched.event.directory, "/tmp/chau7")
        XCTAssertEqual(enriched.event.reliability, .fallback)
        XCTAssertEqual(enriched.kind, .waitingForInput)
    }

    func testTerminalSessionWaitingInputDropsWithoutExactIdentity() {
        let event = AIEvent(
            source: .terminalSession,
            type: "waiting_input",
            tool: "Codex",
            message: "Codex needs input",
            ts: "2026-04-01T00:00:00Z",
            producer: "terminal_session",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .drop(reason) = decision else {
            return XCTFail("Expected terminal session event without exact identity to drop")
        }

        XCTAssertTrue(reason.contains("missing exact routing identity"))
    }

    func testShellCommandFailedPreservesTriggerTypeAndCanonicalizes() {
        let event = AIEvent(
            source: .shell,
            type: "command_failed",
            tool: "Shell",
            message: "Exit 1",
            ts: "2026-04-01T00:00:00Z",
            directory: "/tmp/test",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected canonical shell event")
        }

        XCTAssertEqual(enriched.event.type, "command_failed")
        XCTAssertEqual(enriched.event.rawType, "command_failed")
        XCTAssertEqual(enriched.kind, .taskFailed)
    }

    func testAppUpdateAvailablePreservesTriggerTypeAndCanonicalizes() {
        let event = AIEvent(
            source: .app,
            type: "update_available",
            tool: "Chau7",
            message: "A new version is available.",
            ts: "2026-04-01T00:00:00Z",
            reliability: .authoritative
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected canonical app event")
        }

        XCTAssertEqual(enriched.event.type, "update_available")
        XCTAssertEqual(enriched.kind, .informational)
    }

    func testAPIProxyErrorCanonicalizesAsFailure() {
        let event = AIEvent(
            source: .apiProxy,
            type: "api_error",
            tool: "OpenAI",
            message: "500",
            ts: "2026-04-01T00:00:00Z",
            reliability: .heuristic
        )

        let decision = NotificationProviderAdapterRegistry.adapt(event)
        guard case let .emit(enriched) = decision else {
            return XCTFail("Expected canonical API proxy event")
        }

        XCTAssertEqual(enriched.event.type, "api_error")
        XCTAssertEqual(enriched.kind, .taskFailed)
    }

    // MARK: - Routing regression

    func testEveryGenericAIAdapterSourceRoutesThroughGenericAdapter() {
        // Regression cover for W2.3: the 15 generic-AI sources declared on
        // `AIEventSource.genericAIAdapterSources` must all reach the generic
        // adapter, not fall through to the unknown-adapter default. Locked
        // in as a single test so adding a 16th tool-level source to the set
        // automatically gains coverage without editing this file.
        for source in AIEventSource.genericAIAdapterSources {
            let event = AIEvent(
                source: source,
                type: "finished",
                rawType: "finished",
                tool: "Test \(source.rawValue)",
                message: "ok",
                ts: "2026-04-02T00:00:00Z",
                reliability: .authoritative
            )
            let decision = NotificationProviderAdapterRegistry.adapt(event)
            guard case .emit = decision else {
                XCTFail("Generic AI source \(source.rawValue) did not emit — unexpected drop or adapter fall-through")
                continue
            }
        }
    }

    func testUndeclaredToolSourceDoesNotCrashAdapterDispatch() {
        // A source created from a raw value that isn't in any of the
        // known sets must still produce a decision (not crash). The
        // unknown adapter tries semantic mapping first; if the rawType
        // is meaningful it canonicalizes, otherwise drops with a reason.
        let event = AIEvent(
            source: AIEventSource(rawValue: "brand_new_tool_2030"),
            type: "finished",
            rawType: "finished",
            tool: "NewTool",
            message: "ok",
            ts: "2026-04-02T00:00:00Z",
            reliability: .fallback
        )
        let decision = NotificationProviderAdapterRegistry.adapt(event)
        switch decision {
        case .emit, .drop:
            break
        }
    }
}
