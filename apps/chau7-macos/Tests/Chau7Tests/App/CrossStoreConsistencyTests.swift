import XCTest
import AppKit
import Chau7Core
@testable import Chau7

/// A5 contract: one Claude hook delivery produces linked records — the
/// `claudeCodeEvents` entry and the spine envelope share the hook event's
/// UUID as the correlation key (the runtime journal's tool entries carry
/// their own tool-scoped correlation, covered by RuntimeToolEventMetadata
/// tests).
@MainActor
final class CrossStoreConsistencyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("CHAU7_ISOLATED_TEST_MODE", "1", 1)
        _ = NSApplication.shared
    }

    private func waitUntil(timeout: TimeInterval = 5.0, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func testHookEventLinksClaudeBufferAndSpineEnvelope() {
        let model = AppModel(notifications: NotificationServices())

        let hookEvent = ClaudeCodeEvent(
            type: .permissionRequest,
            hook: "PermissionRequest",
            sessionId: "claude-sess-1",
            transcriptPath: "",
            toolName: "Bash",
            title: "Permission needed",
            message: "Wants to run swift test",
            cwd: "/tmp/mockup",
            timestamp: Date()
        )

        model.handleClaudeCodeMonitorEvent(hookEvent)

        XCTAssertTrue(
            waitUntil { model.eventSpine.journal.latestCursor >= 1 },
            "hook event must reach the spine"
        )

        // The claudeCodeEvents buffer holds the raw hook event…
        XCTAssertTrue(model.claudeCodeEvents.contains(where: { $0.id == hookEvent.id }))

        // …and the spine envelope carries the hook UUID as correlation.
        let (envelopes, _, _) = model.eventSpine.journal.envelopes(after: 0, limit: 10)
        let linked = envelopes.first(where: { $0.correlationID == hookEvent.id.uuidString })
        XCTAssertNotNil(linked, "spine envelope must be correlated to the hook event UUID")
        XCTAssertEqual(linked?.aiEvent?.producer, "claude_code_monitor")
        XCTAssertEqual(linked?.aiEvent?.sessionID, "claude-sess-1")
    }
}
