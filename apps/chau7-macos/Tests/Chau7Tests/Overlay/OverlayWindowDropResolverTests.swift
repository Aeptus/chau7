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
}
