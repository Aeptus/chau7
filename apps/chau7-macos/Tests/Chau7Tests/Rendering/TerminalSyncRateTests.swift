import XCTest
@testable import Chau7

@MainActor
final class TerminalSyncRateTests: XCTestCase {
    private let epsilon = 1e-9

    func testFocusedViewFollowsActiveCapDisplayNative() {
        // displayNative (capHz == nil) → up to 120fps, regardless of inactive cap.
        let interval = RustTerminalView.minSyncInterval(
            isInteractive: true, activeCapHz: nil, inactiveMaxFPS: 42
        )
        XCTAssertEqual(interval, 1.0 / 120.0, accuracy: epsilon)
    }

    func testFocusedViewHonorsActiveCapHz() {
        // The previously-dead activePollingRateCap now actually caps the focused view.
        XCTAssertEqual(
            RustTerminalView.minSyncInterval(isInteractive: true, activeCapHz: 60, inactiveMaxFPS: 42),
            1.0 / 60.0, accuracy: epsilon
        )
        XCTAssertEqual(
            RustTerminalView.minSyncInterval(isInteractive: true, activeCapHz: 30, inactiveMaxFPS: 42),
            1.0 / 30.0, accuracy: epsilon
        )
    }

    func testInactiveViewUsesInactiveCapNotActiveCap() {
        // A visible non-focused view throttles to the inactive fps even when the
        // active cap is display-native.
        let interval = RustTerminalView.minSyncInterval(
            isInteractive: false, activeCapHz: nil, inactiveMaxFPS: 42
        )
        XCTAssertEqual(interval, 1.0 / 42.0, accuracy: epsilon)
    }

    func testFpsValuesAreClampedToSaneBounds() {
        // 0 / negative → at least 1fps; absurdly high → capped at 120fps.
        XCTAssertEqual(
            RustTerminalView.minSyncInterval(isInteractive: false, activeCapHz: nil, inactiveMaxFPS: 0),
            1.0 / 1.0, accuracy: epsilon
        )
        XCTAssertEqual(
            RustTerminalView.minSyncInterval(isInteractive: false, activeCapHz: nil, inactiveMaxFPS: 10000),
            1.0 / 120.0, accuracy: epsilon
        )
    }
}
