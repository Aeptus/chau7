import XCTest
@testable import Chau7

@MainActor
final class StatusBarControllerTests: XCTestCase {

    // MARK: - Singleton

    func testSharedInstanceIsSingleton() {
        let first = StatusBarController.shared
        let second = StatusBarController.shared
        XCTAssertTrue(
            first === second,
            "StatusBarController.shared should always return the same instance"
        )
    }

    // MARK: - Initial State

    func testInitialStateHasNoStatusItem() {
        // Before setup(model:), the controller should have no status item or popover.
        // We verify this indirectly by calling cleanup without setup -- it should not crash.
        let controller = StatusBarController.shared
        // cleanup() is safe to call even when not set up
        controller.cleanup()
    }

    // MARK: - Cleanup Idempotency

    func testCleanupIsIdempotent() {
        let controller = StatusBarController.shared
        // Calling cleanup multiple times should not crash
        controller.cleanup()
        controller.cleanup()
        controller.cleanup()
    }

    // MARK: - Update Icon Without Setup

    func testUpdateIconWithoutSetupDoesNotCrash() {
        let controller = StatusBarController.shared
        controller.cleanup() // Ensure clean state
        // updateIcon is @objc and could be called via notification even if
        // statusItem is nil. It should guard safely.
        controller.updateIcon()
    }

    // MARK: - Notification Integration

    func testMonitoringStateChangedNotificationName() {
        // The controller observes `.monitoringStateChanged`; the panel posts the same
        // production constant. The raw value moved to the com.chau7. namespace when
        // the AppSignals registry centralized every internal Notification.Name
        // (process-internal only, so the rename is safe).
        XCTAssertEqual(
            Notification.Name.monitoringStateChanged.rawValue,
            "com.chau7.monitoringStateChanged",
            "Notification name should match the registry constant"
        )
    }

    func testCommandCenterViewModelLiveSessionsUseAgnosticSourceAndLimitToFive() {
        let model = AppModel()
        let sessions = [
            makeSummary(id: "6", state: .running, lastActivityOffset: 5),
            makeSummary(id: "5", state: .waitingInput, lastActivityOffset: 10),
            makeSummary(id: "4", state: .stuck, lastActivityOffset: 20),
            makeSummary(id: "3", state: .running, lastActivityOffset: 30),
            makeSummary(id: "2", state: .running, lastActivityOffset: 40),
            makeSummary(id: "1", state: .running, lastActivityOffset: 50)
        ]

        let viewModel = CommandCenterViewModel(
            model: model,
            onClose: {},
            sessionSource: { sessions },
            autoRefresh: false
        )

        XCTAssertEqual(
            viewModel.liveSessions.map(\.id),
            ["6", "5", "4", "3", "2"],
            "Live sessions should come from the AI-agnostic source, newest first, and cap at five"
        )
        XCTAssertEqual(viewModel.totalLiveSessionCount, 6)
    }

    func testCommandCenterViewModelAttentionSessionsOnlyIncludeWaitingInput() {
        let model = AppModel()
        let sessions = [
            makeSummary(id: "input", state: .waitingInput, lastActivityOffset: 10),
            makeSummary(id: "stuck", state: .stuck, lastActivityOffset: 20),
            makeSummary(id: "running", state: .running, lastActivityOffset: 5)
        ]

        let viewModel = CommandCenterViewModel(
            model: model,
            onClose: {},
            sessionSource: { sessions },
            autoRefresh: false
        )

        XCTAssertEqual(
            viewModel.attentionSessions.map(\.id),
            ["input"],
            "Attention sessions should only include live sessions currently waiting for user input"
        )
        XCTAssertEqual(viewModel.attentionCount, 1)
    }

    func testCommandCenterViewModelTabTargetUsesExactTabIDAndDirectory() {
        let model = AppModel()
        let session = makeSummary(id: "target", state: .running, lastActivityOffset: 5)
        let viewModel = CommandCenterViewModel(
            model: model,
            onClose: {},
            sessionSource: { [session] },
            autoRefresh: false
        )

        let target = viewModel.tabTarget(for: session)

        XCTAssertEqual(target.tool, "Codex")
        XCTAssertEqual(target.directory, "/tmp/target")
        XCTAssertEqual(target.tabID, UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }

    private func makeSummary(
        id: String,
        state: CommandCenterSessionSummary.State,
        lastActivityOffset: TimeInterval
    ) -> CommandCenterSessionSummary {
        CommandCenterSessionSummary(
            id: id,
            tabID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            paneID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Project \(id)",
            appName: "Codex",
            directory: "/tmp/\(id)",
            lastActivity: Date().addingTimeInterval(-lastActivityOffset),
            state: state
        )
    }
}
