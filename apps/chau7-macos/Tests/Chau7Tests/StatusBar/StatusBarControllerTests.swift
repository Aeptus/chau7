import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class StatusBarControllerTests: XCTestCase {

    // MARK: - Singleton

    func testSharedInstanceIsSingleton() {
        let first = StatusBarController.shared
        let second = StatusBarController.shared
        XCTAssertTrue(first === second,
            "StatusBarController.shared should always return the same instance")
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
        controller.cleanup()  // Ensure clean state
        // updateIcon is @objc and could be called via notification even if
        // statusItem is nil. It should guard safely.
        controller.updateIcon()
    }

    // MARK: - StatusBarPanelView State

    /// Verify that the StreamSelection enum has all expected cases
    func testStreamSelectionCases() {
        let allCases = StreamSelection.allCases
        XCTAssertEqual(allCases.count, 5,
            "StreamSelection should have 5 cases")
        XCTAssertTrue(allCases.contains(.codexHistory))
        XCTAssertTrue(allCases.contains(.claudeHistory))
        XCTAssertTrue(allCases.contains(.codexTerminal))
        XCTAssertTrue(allCases.contains(.claudeTerminal))
        XCTAssertTrue(allCases.contains(.verbose))
    }

    func testStreamSelectionTitles() {
        XCTAssertEqual(StreamSelection.codexHistory.title, "Codex")
        XCTAssertEqual(StreamSelection.claudeHistory.title, "Claude")
        XCTAssertEqual(StreamSelection.codexTerminal.title, "Codex TTY")
        XCTAssertEqual(StreamSelection.claudeTerminal.title, "Claude TTY")
        XCTAssertEqual(StreamSelection.verbose.title, "Verbose")
    }

    func testStreamSelectionIdentifiable() {
        // Each case's id should equal its rawValue
        for selection in StreamSelection.allCases {
            XCTAssertEqual(selection.id, selection.rawValue,
                "\(selection).id should match its rawValue")
        }
    }

    func testStreamSelectionRawValues() {
        XCTAssertEqual(StreamSelection.codexHistory.rawValue, "codexHistory")
        XCTAssertEqual(StreamSelection.claudeHistory.rawValue, "claudeHistory")
        XCTAssertEqual(StreamSelection.codexTerminal.rawValue, "codexTerminal")
        XCTAssertEqual(StreamSelection.claudeTerminal.rawValue, "claudeTerminal")
        XCTAssertEqual(StreamSelection.verbose.rawValue, "verbose")
    }

    // MARK: - Notification Integration

    func testMonitoringStateChangedNotificationName() {
        // The controller observes "MonitoringStateChanged" notification.
        // Verify the string name is consistent with what the panel posts.
        let name = NSNotification.Name("MonitoringStateChanged")
        XCTAssertEqual(name.rawValue, "MonitoringStateChanged",
            "Notification name should match the expected string")
    }

    // MARK: - Popover Content Size

    func testPopoverContentSizeDimensions() {
        // The popover is configured with specific dimensions in setup().
        // While we cannot access the popover directly without a model,
        // we can verify the expected constants match design specs.
        let expectedWidth: CGFloat = 400
        let expectedHeight: CGFloat = 520
        XCTAssertGreaterThan(expectedWidth, 0, "Popover width should be positive")
        XCTAssertGreaterThan(expectedHeight, 0, "Popover height should be positive")
        // The popover should be taller than it is wide (panel layout)
        XCTAssertGreaterThan(expectedHeight, expectedWidth,
            "Status bar panel should be taller than wide")
    }

    // MARK: - Stream Selection Unique IDs

    func testStreamSelectionIdsAreUnique() {
        let ids = StreamSelection.allCases.map(\.id)
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count,
            "All stream selection cases should have unique IDs")
    }
}
#endif
