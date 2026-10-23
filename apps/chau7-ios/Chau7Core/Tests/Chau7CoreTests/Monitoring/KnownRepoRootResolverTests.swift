import XCTest
@testable import Chau7Core

final class KnownRepoRootResolverTests: XCTestCase {
    func testResolvePrefersCurrentRepoGroupWhenDirectoryStillMatches() {
        XCTAssertEqual(
            KnownRepoRootResolver.resolve(
                currentDirectory: "/tmp/Chau7/apps/chau7-macos",
                preferredRepoRoot: "/tmp/Chau7",
                recentRepoRoots: ["/tmp/chau7-website", "/tmp/Chau7"]
            ),
            "/tmp/Chau7"
        )
    }

    func testResolveFallsBackToLongestMatchingRecentRepoRoot() {
        XCTAssertEqual(
            KnownRepoRootResolver.resolve(
                currentDirectory: "/tmp/Downloads/Repositories/Chau7/apps/chau7-macos",
                preferredRepoRoot: nil,
                recentRepoRoots: [
                    "/tmp/Downloads/Repositories",
                    "/tmp/Downloads/Repositories/Chau7"
                ]
            ),
            "/tmp/Downloads/Repositories/Chau7"
        )
    }

    func testResolveReturnsNilWhenNoKnownRepoMatches() {
        XCTAssertNil(
            KnownRepoRootResolver.resolve(
                currentDirectory: "/tmp/website",
                preferredRepoRoot: "/tmp/Chau7",
                recentRepoRoots: ["/tmp/Aethyme", "/tmp/Mockup"]
            )
        )
    }
}
