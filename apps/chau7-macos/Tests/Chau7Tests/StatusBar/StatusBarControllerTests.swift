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

    // MARK: - StatusBarPanelView State

    /// Verify that the default StreamSelection picker entries cover the known tools
    func testStreamSelectionDefaultSelections() {
        let selections = StreamSelection.defaultSelections
        XCTAssertEqual(
            selections.count,
            5,
            "StreamSelection should offer 5 default selections"
        )
        XCTAssertTrue(selections.contains(.history(providerKey: "codex")))
        XCTAssertTrue(selections.contains(.history(providerKey: "claude")))
        XCTAssertTrue(selections.contains(.terminal(providerKey: "codex")))
        XCTAssertTrue(selections.contains(.terminal(providerKey: "claude")))
        XCTAssertTrue(selections.contains(.verbose))
    }

    func testStreamSelectionTitles() {
        XCTAssertEqual(StreamSelection.history(providerKey: "codex").title, "Codex")
        XCTAssertEqual(StreamSelection.history(providerKey: "claude").title, "Claude")
        XCTAssertEqual(StreamSelection.terminal(providerKey: "codex").title, "Codex TTY")
        XCTAssertEqual(StreamSelection.terminal(providerKey: "claude").title, "Claude TTY")
        XCTAssertEqual(StreamSelection.verbose.title, "Verbose")
    }

    func testStreamSelectionIdentifiable() {
        XCTAssertEqual(StreamSelection.history(providerKey: "codex").id, "history-codex")
        XCTAssertEqual(StreamSelection.history(providerKey: "claude").id, "history-claude")
        XCTAssertEqual(StreamSelection.terminal(providerKey: "codex").id, "terminal-codex")
        XCTAssertEqual(StreamSelection.terminal(providerKey: "claude").id, "terminal-claude")
        XCTAssertEqual(StreamSelection.verbose.id, "verbose")
    }

    // MARK: - Notification Integration

    func testMonitoringStateChangedNotificationName() {
        // The controller observes `.monitoringStateChanged`; the panel posts the same
        // production constant. Verify the underlying string stays stable.
        XCTAssertEqual(
            Notification.Name.monitoringStateChanged.rawValue,
            "MonitoringStateChanged",
            "Notification name should match the expected string"
        )
    }

    // MARK: - Stream Selection Unique IDs

    func testStreamSelectionIdsAreUnique() {
        let ids = StreamSelection.defaultSelections.map(\.id)
        let uniqueIds = Set(ids)
        XCTAssertEqual(
            ids.count,
            uniqueIds.count,
            "All stream selection cases should have unique IDs"
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
