import XCTest
@testable import Chau7Core

final class TransitionSnapshotRetentionTests: XCTestCase {
    func testRetainsNearbyCachedSnapshots() {
        XCTAssertTrue(
            TransitionSnapshotRetention.shouldRetainCachedSnapshot(
                tabIndex: 1,
                currentIndex: 3,
                hasRestorePreview: false
            )
        )
        XCTAssertTrue(
            TransitionSnapshotRetention.shouldRetainCachedSnapshot(
                tabIndex: 5,
                currentIndex: 3,
                hasRestorePreview: false
            )
        )
    }

    func testEvictsDistantCachedSnapshots() {
        XCTAssertFalse(
            TransitionSnapshotRetention.shouldRetainCachedSnapshot(
                tabIndex: 0,
                currentIndex: 3,
                hasRestorePreview: false
            )
        )
        XCTAssertFalse(
            TransitionSnapshotRetention.shouldRetainCachedSnapshot(
                tabIndex: 6,
                currentIndex: 3,
                hasRestorePreview: false
            )
        )
    }

    func testAlwaysRetainsRestorePreviewSnapshots() {
        XCTAssertTrue(
            TransitionSnapshotRetention.shouldRetainCachedSnapshot(
                tabIndex: 0,
                currentIndex: 3,
                hasRestorePreview: true
            )
        )
    }
}
