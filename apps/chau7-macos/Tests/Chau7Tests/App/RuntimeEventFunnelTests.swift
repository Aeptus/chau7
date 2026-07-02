import XCTest
import AppKit
import Chau7Core
@testable import Chau7

/// A3 completeness contract: runtime session events publish through the
/// spine funnel (via the injected AIEventPublishing seam), so they reach
/// recentEvents and the spine journal — not just the notification manager,
/// as the old direct notify(for:) bypass did.
@MainActor
final class RuntimeEventFunnelTests: XCTestCase {

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

    func testPreparedRuntimeEventReachesJournalAndRecentEvents() {
        let model = AppModel(notifications: NotificationServices())

        let event = AIEvent(
            source: .runtime,
            type: "permission",
            tool: "Claude Code",
            message: "Needs approval to run tests",
            ts: DateFormatters.nowISO8601(),
            directory: "/tmp/mockup",
            sessionID: "rs_test_1",
            producer: "runtime_session_manager",
            reliability: .authoritative
        )
        (model as AIEventPublishing).publishPreparedEvent(event, notify: true)

        // The raw envelope is always journaled (pre-acceptance audit record)…
        XCTAssertTrue(waitUntil { model.eventSpine.journal.latestCursor == 1 })
        let (envelopes, _, _) = model.eventSpine.journal.envelopes(after: 0, limit: 1)
        XCTAssertEqual(envelopes.first?.eventID, event.id)
        XCTAssertEqual(envelopes.first?.aiEvent?.producer, "runtime_session_manager")

        // …and the accepted event lands in recentEvents (the completeness fix:
        // the old notify(for:) bypass never populated this surface).
        XCTAssertTrue(
            waitUntil { model.recentEvents.contains(where: { $0.type == "permission" && $0.sessionID == "rs_test_1" }) },
            "runtime event should reach recentEvents through the funnel"
        )
    }

    // Note: sendTestNotification also routes through publishUnifiedEvent now,
    // but it guards on Bundle.main.bundleIdentifier and cannot run in a
    // bundle-less swiftpm test process.
}
