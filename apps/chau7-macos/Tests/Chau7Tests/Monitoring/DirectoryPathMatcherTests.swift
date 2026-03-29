import XCTest
@testable import Chau7Core

final class DirectoryPathMatcherTests: XCTestCase {
    func testBidirectionalPrefixRankMatchesExactDirectory() {
        XCTAssertEqual(
            DirectoryPathMatcher.bidirectionalPrefixRank(
                targetPath: "/tmp/chau7",
                candidatePath: "/tmp/chau7"
            ),
            0
        )
    }

    func testBidirectionalPrefixRankMatchesNestedDirectoriesInEitherDirection() {
        XCTAssertEqual(
            DirectoryPathMatcher.bidirectionalPrefixRank(
                targetPath: "/tmp/chau7",
                candidatePath: "/tmp/chau7/apps/chau7-macos"
            ),
            1
        )
        XCTAssertEqual(
            DirectoryPathMatcher.bidirectionalPrefixRank(
                targetPath: "/tmp/chau7/apps/chau7-macos",
                candidatePath: "/tmp/chau7"
            ),
            1
        )
    }

    func testBidirectionalPrefixRankStandardizesPathsBeforeComparing() {
        XCTAssertEqual(
            DirectoryPathMatcher.bidirectionalPrefixRank(
                targetPath: "/tmp/chau7/../chau7",
                candidatePath: "/tmp/chau7"
            ),
            0
        )
    }

    func testBidirectionalPrefixRankRejectsUnrelatedDirectories() {
        XCTAssertNil(
            DirectoryPathMatcher.bidirectionalPrefixRank(
                targetPath: "/tmp/chau7",
                candidatePath: "/tmp/mockup"
            )
        )
    }
}
