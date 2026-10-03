import XCTest
@testable import Chau7Core

final class FileRetentionBudgetTests: XCTestCase {
    func testPrunesByBytesCountAgeAndPerFileSizeWithoutDroppingNewValidArchive() {
        let entries: [FileRetentionBudget.Entry] = [
            .init(key: "huge", bytes: 100, modifiedAt: 10),
            .init(key: "new", bytes: 6, modifiedAt: 9),
            .init(key: "too-big-for-budget", bytes: 6, modifiedAt: 8),
            .init(key: "small", bytes: 3, modifiedAt: 7),
            .init(key: "over-count", bytes: 0, modifiedAt: 6),
            .init(key: "expired", bytes: 1, modifiedAt: 0)
        ]
        XCTAssertEqual(
            FileRetentionBudget.removals(
                newestFirst: entries,
                maximumCount: 2,
                maximumBytes: 10,
                maximumFileBytes: 10,
                cutoff: 1
            ),
            ["huge", "too-big-for-budget", "over-count", "expired"]
        )
    }

    func testZeroBudgetAndOverflowSizedFilesAreRejected() {
        let entry = FileRetentionBudget.Entry(key: "x", bytes: Int.max, modifiedAt: 1)
        XCTAssertEqual(FileRetentionBudget.removals(
            newestFirst: [entry],
            maximumCount: 1,
            maximumBytes: 0,
            maximumFileBytes: Int.max,
            cutoff: 0
        ), ["x"])
    }
}
