import Foundation
import XCTest
@testable import Chau7Core

final class LogRetentionPolicyTests: XCTestCase {
    func testArchiveURLsAreBoundedAndOrderedNewestFirst() {
        let logURL = URL(fileURLWithPath: "/tmp/Chau7.log")

        XCTAssertEqual(
            LogRetentionPolicy.archiveURLs(for: logURL, count: 3).map(\.lastPathComponent),
            ["Chau7.log.1", "Chau7.log.2", "Chau7.log.3"]
        )
        XCTAssertTrue(LogRetentionPolicy.archiveURLs(for: logURL, count: 0).isEmpty)
    }

    func testTailStartsAtCompleteLineAndStaysWithinBudget() throws {
        let data = Data("alpha\nbeta\ngamma\ndelta\n".utf8)
        let retained = LogRetentionPolicy.lineAlignedTail(of: data, maximumBytes: 14)

        XCTAssertLessThanOrEqual(retained.count, 14)
        XCTAssertEqual(String(decoding: retained, as: UTF8.self), "gamma\ndelta\n")
    }

    func testTailDropsOversizedRecordWithNoBoundary() {
        let data = Data(String(repeating: "x", count: 100).utf8)
        XCTAssertTrue(LogRetentionPolicy.lineAlignedTail(of: data, maximumBytes: 10).isEmpty)
    }

    func testTailPreservesSmallFileVerbatim() {
        let data = Data("complete\n".utf8)
        XCTAssertEqual(LogRetentionPolicy.lineAlignedTail(of: data, maximumBytes: 100), data)
    }
}
