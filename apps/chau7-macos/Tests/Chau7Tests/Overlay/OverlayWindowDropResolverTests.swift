import XCTest
import CoreGraphics
@testable import Chau7Core

final class OverlayWindowDropResolverTests: XCTestCase {
    func testTargetIndexPrefersPrimaryTabBarFrame() {
        let candidates = [
            OverlayWindowDropCandidate(
                index: 0,
                primaryFrame: CGRect(x: 0, y: 0, width: 100, height: 20),
                fallbackFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
            ),
            OverlayWindowDropCandidate(
                index: 1,
                primaryFrame: CGRect(x: 500, y: 0, width: 100, height: 20),
                fallbackFrame: CGRect(x: 500, y: 0, width: 400, height: 300)
            )
        ]

        XCTAssertEqual(
            OverlayWindowDropResolver.targetIndex(at: CGPoint(x: 550, y: 10), candidates: candidates),
            1
        )
    }

    func testTargetIndexFallsBackToWindowFrameWhenPrimaryFrameMissing() {
        let candidates = [
            OverlayWindowDropCandidate(
                index: 1,
                primaryFrame: .zero,
                fallbackFrame: CGRect(x: 500, y: 0, width: 400, height: 300)
            )
        ]

        XCTAssertEqual(
            OverlayWindowDropResolver.targetIndex(at: CGPoint(x: 650, y: 120), candidates: candidates),
            1
        )
    }

    func testTargetIndexExcludesSourceWindow() {
        let candidates = [
            OverlayWindowDropCandidate(
                index: 0,
                primaryFrame: CGRect(x: 0, y: 0, width: 100, height: 20),
                fallbackFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
            ),
            OverlayWindowDropCandidate(
                index: 1,
                primaryFrame: CGRect(x: 500, y: 0, width: 100, height: 20),
                fallbackFrame: CGRect(x: 500, y: 0, width: 400, height: 300)
            )
        ]

        XCTAssertNil(
            OverlayWindowDropResolver.targetIndex(
                at: CGPoint(x: 50, y: 10),
                candidates: candidates,
                excluding: 0
            )
        )
    }

    // Regression: two overlay windows stacked at the same frame. Drop happens
    // inside the source window's content area (not on any tab bar). Before the
    // fix, the source was excluded and the other window's fallbackFrame matched
    // the same point, silently re-homing the tab to the wrong window.
    // Frame/point values captured from a real session log on 2026-05-19.
    func testTargetIndexDoesNotJumpWhenWindowsOverlapAndDropIsBelowTabBar() {
        let candidates = [
            OverlayWindowDropCandidate(
                index: 0,
                primaryFrame: CGRect(x: 10, y: 5, width: 1902, height: 28),
                fallbackFrame: CGRect(x: 1512, y: -87, width: 1920, height: 1080)
            ),
            OverlayWindowDropCandidate(
                index: 1,
                primaryFrame: CGRect(x: 80, y: 5, width: 1832, height: 28),
                fallbackFrame: CGRect(x: 1512, y: -87, width: 1920, height: 1080)
            )
        ]

        XCTAssertNil(
            OverlayWindowDropResolver.targetIndex(
                at: CGPoint(x: 3231, y: 943),
                candidates: candidates,
                excluding: 1
            ),
            "Drop in source window's content area must not be routed to another overlapping window"
        )
    }
}
