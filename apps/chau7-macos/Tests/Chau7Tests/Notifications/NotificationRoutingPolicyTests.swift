import XCTest
import AppKit
@testable import Chau7
@testable import Chau7Core

final class NotificationRoutingPolicyTests: XCTestCase {

    // MARK: - Table

    func testAttentionKindsTargetEverySurface() {
        for kind: NotificationSemanticKind in [.permissionRequired, .waitingForInput, .attentionRequired] {
            XCTAssertEqual(
                NotificationRoutingPolicy.surfaces(kind: kind),
                Set(NotificationSurface.allCases),
                "\(kind.rawValue) must reach every surface"
            )
        }
    }

    func testTaskCompletionPushIsSettingsGated() {
        let off = NotificationRoutingPolicy.surfaces(kind: .taskFinished)
        XCTAssertFalse(off.contains(.iosPush), "default off")
        XCTAssertTrue(off.isSuperset(of: [.macLocal, .tabStyle, .liveActivity, .mcpSubscribers]))

        let on = NotificationRoutingPolicy.surfaces(
            kind: .taskFailed,
            settings: NotificationSurfaceSettings(pushTaskCompletions: true)
        )
        XCTAssertTrue(on.contains(.iosPush))
    }

    func testInformationalIncludesMCP() {
        // The audit-flagged asymmetry: .app informational events reached local
        // notifications but were silently dropped from MCP observability.
        // Routing now declares them MCP-visible.
        let surfaces = NotificationRoutingPolicy.surfaces(kind: .informational)
        XCTAssertTrue(surfaces.contains(.mcpSubscribers))
        XCTAssertFalse(surfaces.contains(.iosPush))
        XCTAssertFalse(surfaces.contains(.liveActivity))
    }

    func testUnknownKindTargetsNothing() {
        XCTAssertTrue(NotificationRoutingPolicy.surfaces(kind: .unknown).isEmpty)
    }

    // MARK: - The .app → MCP fix end to end

    @MainActor
    func testAppInformationalEventReachesObservability() {
        setenv("CHAU7_ISOLATED_TEST_MODE", "1", 1)
        _ = NSApplication.shared
        Chau7ObservabilityService.shared.resetForTests()
        defer { Chau7ObservabilityService.shared.resetForTests() }

        let model = AppModel(notifications: NotificationServices())
        model.recordEvent(
            source: .app, type: "update_available", tool: "Chau7",
            message: "informational", notify: false, sessionID: "app-1"
        )

        let deadline = Date().addingTimeInterval(5)
        var found = false
        while Date() < deadline, !found {
            let json = Chau7ObservabilityService.shared.runtimeEventsJSON(sinceMillis: nil, limit: 100)
            found = json.contains("\"subsystem\":\"app\"") || json.contains("update_available")
            if !found { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        XCTAssertTrue(found, ".app informational events must now be MCP-visible by declared policy")
    }
}
