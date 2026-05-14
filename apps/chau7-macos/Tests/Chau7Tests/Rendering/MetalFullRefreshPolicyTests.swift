import XCTest
@testable import Chau7Core

final class MetalFullRefreshPolicyTests: XCTestCase {
    func testPreservesExistingFullRefresh() {
        XCTAssertTrue(
            MetalFullRefreshPolicy.shouldForceFullRefresh(
                rowCount: 79,
                dirtyRowCount: 1,
                alreadyFullRefresh: true,
                inScrollStorm: false,
                isInteractive: true,
                allowsLivePresentation: true
            )
        )
    }

    func testForcesFullRefreshDuringScrollStorm() {
        XCTAssertTrue(
            MetalFullRefreshPolicy.shouldForceFullRefresh(
                rowCount: 79,
                dirtyRowCount: 10,
                alreadyFullRefresh: false,
                inScrollStorm: true,
                isInteractive: true,
                allowsLivePresentation: true
            )
        )
    }

    func testForcesFullRefreshForVisibleNoninteractiveView() {
        XCTAssertTrue(
            MetalFullRefreshPolicy.shouldForceFullRefresh(
                rowCount: 79,
                dirtyRowCount: 2,
                alreadyFullRefresh: false,
                inScrollStorm: false,
                isInteractive: false,
                allowsLivePresentation: true
            )
        )
    }

    func testForcesFullRefreshForNearFullDirtyRowBurst() {
        XCTAssertTrue(
            MetalFullRefreshPolicy.shouldForceFullRefresh(
                rowCount: 79,
                dirtyRowCount: 68,
                alreadyFullRefresh: false,
                inScrollStorm: false,
                isInteractive: true,
                allowsLivePresentation: true
            )
        )
    }

    func testKeepsIncrementalPathForOrdinaryInteractiveFrame() {
        XCTAssertFalse(
            MetalFullRefreshPolicy.shouldForceFullRefresh(
                rowCount: 79,
                dirtyRowCount: 6,
                alreadyFullRefresh: false,
                inScrollStorm: false,
                isInteractive: true,
                allowsLivePresentation: true
            )
        )
    }
}
