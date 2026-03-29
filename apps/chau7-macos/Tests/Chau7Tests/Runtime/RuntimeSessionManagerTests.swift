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

    private func toolUseEvents(in session: RuntimeSession) -> [RuntimeEvent] {
        session.journal
            .events(after: 0, limit: 100)
            .events
            .filter { $0.type == RuntimeEventType.toolUse.rawValue }
    }
}
#endif
