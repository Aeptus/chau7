import AppKit
import XCTest
@testable import Chau7

/// SPM-runnable tests for `OverlayWindowFraming.clampedFrame`.
///
/// The clamp is the fix for bug #92 ("input line clipped at bottom of
/// screen"). The user-visible symptom was the bottom row of the terminal
/// being half-clipped because the overlay window extended below
/// `visibleFrame.minY` (under the dock). The static-analysis path
/// established that the terminal's rendering math is correct; the only
/// remaining cause is window position. These tests pin the clamp so
/// future refactors can't silently re-open the bug.
final class OverlayWindowFramingTests: XCTestCase {

    /// 14" MBP-ish visible frame (after menu bar + dock).
    private let visibleFrame = NSRect(x: 0, y: 80, width: 1440, height: 850)

    // MARK: - No-op when already inside

    func testFramingFullyInsideReturnsUnchanged() {
        let frame = NSRect(x: 100, y: 200, width: 800, height: 600)
        let clamped = OverlayWindowFraming.clampedFrame(proposed: frame, in: visibleFrame)
        XCTAssertEqual(clamped, frame)
    }

    // MARK: - Bottom clip (the actual bug #92)

    func testFrameExtendingBelowVisibleBottomIsShiftedUp() {
        // Window's bottom (origin.y=20) is below visibleFrame.minY=80.
        // Expect origin.y to be clamped to 80; size unchanged.
        let frame = NSRect(x: 100, y: 20, width: 800, height: 600)
        let clamped = OverlayWindowFraming.clampedFrame(proposed: frame, in: visibleFrame)
        XCTAssertEqual(
            clamped.origin.y,
            visibleFrame.minY,
            "Bottom edge must be at visibleFrame.minY when proposed is below"
        )
        XCTAssertEqual(
            clamped.size,
            frame.size,
            "Size must not be reduced just to lift the bottom edge"
        )
    }

    // MARK: - Top clip

    func testFrameExtendingAboveVisibleTopIsShiftedDown() {
        // Window's top (maxY=1100) is above visibleFrame.maxY=930.
        let frame = NSRect(x: 100, y: 500, width: 800, height: 600)
        let clamped = OverlayWindowFraming.clampedFrame(proposed: frame, in: visibleFrame)
        XCTAssertEqual(clamped.maxY, visibleFrame.maxY)
        XCTAssertEqual(clamped.size, frame.size)
    }

    // MARK: - Width/height larger than screen → cap at visible size

    func testHeightLargerThanVisibleFrameIsCapped() {
        let frame = NSRect(x: 100, y: 80, width: 800, height: 2000)
        let clamped = OverlayWindowFraming.clampedFrame(proposed: frame, in: visibleFrame)
        XCTAssertEqual(
            clamped.size.height,
            visibleFrame.height,
            "Height must be capped at visibleFrame.height when proposed exceeds it"
        )
        XCTAssertEqual(
            clamped.origin.y,
            visibleFrame.minY,
            "After height cap, window must sit at visibleFrame.minY"
        )
    }

    func testWidthLargerThanVisibleFrameIsCapped() {
        let frame = NSRect(x: 0, y: 80, width: 2500, height: 600)
        let clamped = OverlayWindowFraming.clampedFrame(proposed: frame, in: visibleFrame)
        XCTAssertEqual(clamped.size.width, visibleFrame.width)
    }

    // MARK: - Horizontal clipping

    func testFrameExtendingLeftIsShiftedRight() {
        // visibleFrame.minX=0; proposed origin.x=-50 means window extends past left.
        let frame = NSRect(x: -50, y: 200, width: 800, height: 600)
        let clamped = OverlayWindowFraming.clampedFrame(proposed: frame, in: visibleFrame)
        XCTAssertEqual(clamped.origin.x, visibleFrame.minX)
    }

    func testFrameExtendingRightIsShiftedLeft() {
        let frame = NSRect(x: 1000, y: 200, width: 800, height: 600)
        let clamped = OverlayWindowFraming.clampedFrame(proposed: frame, in: visibleFrame)
        XCTAssertEqual(clamped.maxX, visibleFrame.maxX)
    }

    // MARK: - Idempotence

    func testClampIsIdempotent() {
        let frame = NSRect(x: -50, y: -100, width: 2000, height: 2000)
        let once = OverlayWindowFraming.clampedFrame(proposed: frame, in: visibleFrame)
        let twice = OverlayWindowFraming.clampedFrame(proposed: once, in: visibleFrame)
        XCTAssertEqual(
            once,
            twice,
            "Clamping a clamped frame must produce no further change"
        )
    }

    // MARK: - Multi-monitor: secondary screen with non-zero origin

    func testClampUsesScreenVisibleFrameOriginNotZero() {
        // Secondary monitor at x=1440, y=0 with its own dock.
        let secondaryVisible = NSRect(x: 1440, y: 50, width: 1920, height: 1030)
        // Window placed correctly on secondary.
        let frame = NSRect(x: 1500, y: 100, width: 800, height: 600)
        let clamped = OverlayWindowFraming.clampedFrame(proposed: frame, in: secondaryVisible)
        XCTAssertEqual(clamped, frame, "Frame already inside secondary screen must not move")

        // Frame extending below secondary's visibleFrame.minY=50.
        let dropped = NSRect(x: 1500, y: 10, width: 800, height: 600)
        let clampedDropped = OverlayWindowFraming.clampedFrame(proposed: dropped, in: secondaryVisible)
        XCTAssertEqual(clampedDropped.origin.y, secondaryVisible.minY)
    }
}
