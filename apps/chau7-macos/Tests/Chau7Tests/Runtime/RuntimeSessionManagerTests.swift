import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7
import Chau7Core

final class RuntimeSessionManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RuntimeSessionManager.shared.resetForTesting()
    }

    override func tearDown() {
        RuntimeSessionManager.shared.resetForTesting()
        super.tearDown()
    }

    func testClaudeSessionBindingSurvivesSecondSessionInSameDirectory() {
        let manager = RuntimeSessionManager.shared
        let cwd = "/tmp/runtime-shared-\(UUID().uuidString)"

        let first = manager.createSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: cwd, provider: "claude")
        )
        XCTAssertNotNil(first.startTurn(prompt: "first prompt"))

        manager.handleClaudeEvent(
            ClaudeCodeEvent(
                type: .toolStart,
                hook: "PreToolUse",
                sessionId: "claude-session-1",
                transcriptPath: "",
                toolName: "Read",
                message: "/tmp/one.swift",
                cwd: cwd,
                timestamp: Date()
            )
        )

        let second = manager.createSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: cwd, provider: "claude")
        )
        XCTAssertNotNil(second.startTurn(prompt: "second prompt"))

        manager.handleClaudeEvent(
            ClaudeCodeEvent(
                type: .toolStart,
                hook: "PreToolUse",
                sessionId: "claude-session-1",
                transcriptPath: "",
                toolName: "Edit",
                message: "/tmp/two.swift",
                cwd: cwd,
                timestamp: Date().addingTimeInterval(1)
            )
        )

        XCTAssertEqual(toolUseEvents(in: first).count, 2)
        XCTAssertEqual(toolUseEvents(in: second).count, 0)
    }

    func testStoppingSessionClearsClaudeSessionBinding() {
        let manager = RuntimeSessionManager.shared
        let cwd = "/tmp/runtime-stop-\(UUID().uuidString)"

        let first = manager.createSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: cwd, provider: "claude")
        )
        XCTAssertNotNil(first.startTurn(prompt: "first prompt"))

        manager.handleClaudeEvent(
            ClaudeCodeEvent(
                type: .toolStart,
                hook: "PreToolUse",
                sessionId: "claude-session-2",
                transcriptPath: "",
                toolName: "Read",
                message: "/tmp/one.swift",
                cwd: cwd,
                timestamp: Date()
            )
        )

        XCTAssertTrue(manager.stopSession(id: first.id))

        let second = manager.createSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: cwd, provider: "claude")
        )
        XCTAssertNotNil(second.startTurn(prompt: "second prompt"))

        manager.handleClaudeEvent(
            ClaudeCodeEvent(
                type: .toolStart,
                hook: "PreToolUse",
                sessionId: "claude-session-2",
                transcriptPath: "",
                toolName: "Edit",
                message: "/tmp/two.swift",
                cwd: cwd,
                timestamp: Date().addingTimeInterval(1)
            )
        )

        XCTAssertEqual(toolUseEvents(in: first).count, 1)
        XCTAssertEqual(toolUseEvents(in: second).count, 1)
    }

    func testNotificationEventsBindClaudeSessionAndJournalNotification() {
        let manager = RuntimeSessionManager.shared
        let cwd = "/tmp/runtime-notification-\(UUID().uuidString)"
        let tabID = UUID()

        let session = manager.createSession(
            tabID: tabID,
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: cwd, provider: "claude")
        )

        manager.handleClaudeEvent(
            ClaudeCodeEvent(
                type: .notification,
                hook: "Notification",
                sessionId: "claude-session-notify",
                transcriptPath: "",
                toolName: "",
                message: "Heads up",
                cwd: cwd,
                timestamp: Date()
            )
        )

        XCTAssertEqual(manager.sessionForClaudeSessionID("claude-session-notify")?.id, session.id)
        let notificationEvents = session.journal
            .events(after: 0, limit: 100)
            .events
            .filter { $0.type == RuntimeEventType.notification.rawValue }
        XCTAssertEqual(notificationEvents.count, 1)
        XCTAssertEqual(notificationEvents.first?.data?["message"], "Heads up")
    }

    func testToolLifecycleJournalsCorrelationDurationAndResultMetadata() throws {
        let manager = RuntimeSessionManager.shared
        let cwd = "/tmp/runtime-tool-metadata-\(UUID().uuidString)"
        let session = manager.createSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: cwd, provider: "claude")
        )

        manager.handleClaudeEvent(
            ClaudeCodeEvent(
                type: .toolStart,
                hook: "PreToolUse",
                sessionId: "claude-session-tool-metadata",
                transcriptPath: "",
                toolName: "Bash",
                message: "rg -n EventJournal apps/chau7-macos/Sources/Chau7Core/Runtime/EventJournal.swift",
                cwd: cwd,
                timestamp: Date()
            )
        )

        manager.handleClaudeEvent(
            ClaudeCodeEvent(
                type: .toolComplete,
                hook: "PostToolUse",
                sessionId: "claude-session-tool-metadata",
                transcriptPath: "",
                toolName: "Bash",
                message: "Command failed with exit code 2: rg: file not found",
                cwd: cwd,
                timestamp: Date().addingTimeInterval(1)
            )
        )

        let events = session.journal.events(after: 0, limit: 100).events
        let toolUse = try XCTUnwrap(events.first { $0.type == RuntimeEventType.toolUse.rawValue })
        let toolResult = try XCTUnwrap(events.first { $0.type == RuntimeEventType.toolResult.rawValue })

        XCTAssertEqual(toolUse.data["tool"], "Bash")
        XCTAssertEqual(toolUse.data["args_summary"], "rg -n EventJournal apps/chau7-macos/Sources/Chau7Core/Runtime/EventJournal.swift")
        XCTAssertEqual(toolUse.data["file"], "\(cwd)/apps/chau7-macos/Sources/Chau7Core/Runtime/EventJournal.swift")
        XCTAssertEqual(toolUse.correlationID, toolResult.correlationID)
        XCTAssertEqual(toolResult.data["success"], "false")
        XCTAssertEqual(toolResult.data["exit_code"], "2")
        XCTAssertNotNil(toolResult.data["duration_ms"])
        XCTAssertNotNil(toolResult.data["error"])
        XCTAssertNotNil(toolResult.data["output_preview"])
        XCTAssertEqual(toolResult.data["file"], "\(cwd)/apps/chau7-macos/Sources/Chau7Core/Runtime/EventJournal.swift")
    }

    func testAmbiguousClaudeSessionsInSameDirectoryDoNotBindNewSessionByGuessing() {
        let manager = RuntimeSessionManager.shared
        let cwd = "/tmp/runtime-ambiguous-\(UUID().uuidString)"

        let first = manager.createSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: cwd, provider: "claude")
        )
        XCTAssertNotNil(first.startTurn(prompt: "first prompt"))

        let second = manager.createSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: cwd, provider: "claude")
        )
        XCTAssertNotNil(second.startTurn(prompt: "second prompt"))

        manager.handleClaudeEvent(
            ClaudeCodeEvent(
                type: .notification,
                hook: "Notification",
                sessionId: "claude-session-ambiguous",
                transcriptPath: "",
                toolName: "",
                message: "Needs attention",
                cwd: cwd,
                timestamp: Date()
            )
        )

        XCTAssertNil(manager.sessionForClaudeSessionID("claude-session-ambiguous"))
        XCTAssertTrue(notificationEvents(in: first).isEmpty)
        XCTAssertTrue(notificationEvents(in: second).isEmpty)
    }

    func testResolveClaudeTabIDAllowsNestedDirectoryMatch() {
        let sessionID = "claude-session-nested"
        let exactTabID = UUID()
        let unrelatedTabID = UUID()

        let resolved = RuntimeSessionManager.resolveClaudeTabID(
            sessionID: sessionID,
            cwd: "/tmp/project/subdir",
            tabs: [
                RuntimeSessionManager.AITabSummary(
                    tabID: exactTabID,
                    cwd: "/tmp/project",
                    provider: "claude",
                    sessionID: sessionID
                ),
                RuntimeSessionManager.AITabSummary(
                    tabID: unrelatedTabID,
                    cwd: "/tmp/other",
                    provider: "claude",
                    sessionID: "someone-else"
                )
            ]
        )

        XCTAssertEqual(resolved, exactTabID)
    }

    func testResolveClaudeTabIDFallsBackToUniqueSessionWhenProviderMetadataMissing() {
        let sessionID = "claude-session-providerless"
        let providerlessTabID = UUID()

        let resolved = RuntimeSessionManager.resolveClaudeTabID(
            sessionID: sessionID,
            cwd: "/tmp/project",
            tabs: [
                RuntimeSessionManager.AITabSummary(
                    tabID: providerlessTabID,
                    cwd: "/tmp/project",
                    provider: nil,
                    sessionID: sessionID
                )
            ]
        )

        XCTAssertEqual(resolved, providerlessTabID)
    }

    func testResolveClaudeTabIDFallsBackToStrictSessionMatchWhenTabSummaryMissesSession() {
        let sessionID = "claude-session-strict"
        let resolvedTabID = UUID()

        let resolved = RuntimeSessionManager.resolveAuthoritativeClaudeTabID(
            sessionID: sessionID,
            cwd: "/tmp/project/subdir",
            boundSession: nil,
            tabs: [],
            strictResolver: { incomingSessionID, incomingCwd in
                XCTAssertEqual(incomingSessionID, sessionID)
                XCTAssertEqual(incomingCwd, "/tmp/project/subdir")
                return resolvedTabID
            }
        )

        XCTAssertEqual(resolved, resolvedTabID)
    }

    func testResolveAuthoritativeClaudeTabIDIgnoresBoundSessionWhoseTabIsNoLongerLive() {
        let session = RuntimeSession(
            tabID: UUID(),
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: "/tmp/project", provider: "claude")
        )
        let liveTabID = UUID()

        let resolved = RuntimeSessionManager.resolveAuthoritativeClaudeTabID(
            sessionID: "claude-session-live",
            cwd: "/tmp/project",
            boundSession: session,
            tabs: [
                RuntimeSessionManager.AITabSummary(
                    tabID: liveTabID,
                    cwd: "/tmp/project",
                    provider: "claude",
                    sessionID: "claude-session-live"
                )
            ],
            strictResolver: { _, _ in
                XCTFail("strict resolver should not be needed when a live tab summary exists")
                return nil
            }
        )

        XCTAssertEqual(resolved, liveTabID)
    }

    func testUserPromptStartsTurnForAdoptedClaudeSession() {
        let manager = RuntimeSessionManager.shared
        let cwd = "/tmp/runtime-adopted-turn-\(UUID().uuidString)"
        let tabID = UUID()

        let session = manager.createSession(
            tabID: tabID,
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: cwd, provider: "claude")
        )

        manager.handleClaudeEvent(
            ClaudeCodeEvent(
                type: .userPrompt,
                hook: "UserPrompt",
                sessionId: "claude-session-turn",
                transcriptPath: "",
                toolName: "",
                message: "Please continue",
                cwd: cwd,
                timestamp: Date()
            )
        )

        XCTAssertEqual(manager.sessionForClaudeSessionID("claude-session-turn")?.id, session.id)
        XCTAssertEqual(session.state, .busy)
        XCTAssertNotNil(session.currentTurnID)
    }

    func testNotificationEventWithExactSessionDoesNotCreateDuplicateRuntimeSession() {
        let manager = RuntimeSessionManager.shared
        let cwd = "/tmp/runtime-existing-\(UUID().uuidString)"
        let tabID = UUID()

        let session = manager.createSession(
            tabID: tabID,
            backend: ClaudeCodeBackend(),
            config: SessionConfig(directory: cwd, provider: "claude")
        )

        manager.handleClaudeEvent(
            ClaudeCodeEvent(
                type: .notification,
                hook: "Notification",
                sessionId: "claude-existing-session",
                transcriptPath: "",
                toolName: "",
                message: "Needs attention",
                cwd: cwd,
                timestamp: Date()
            )
        )

        XCTAssertEqual(manager.allSessions().count, 1)
        XCTAssertEqual(manager.sessionForClaudeSessionID("claude-existing-session")?.id, session.id)
    }

    private func toolUseEvents(in session: RuntimeSession) -> [RuntimeEvent] {
        session.journal
            .events(after: 0, limit: 100)
            .events
            .filter { $0.type == RuntimeEventType.toolUse.rawValue }
    }

    private func notificationEvents(in session: RuntimeSession) -> [RuntimeEvent] {
        session.journal
            .events(after: 0, limit: 100)
            .events
            .filter { $0.type == RuntimeEventType.notification.rawValue }
    }
}
#endif
