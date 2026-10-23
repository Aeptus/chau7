import XCTest
@testable import Chau7Core

final class RepoGroupInheritanceTests: XCTestCase {
    func testInheritsGroupForDirectoryInsideRepo() {
        XCTAssertEqual(
            RepoGroupInheritance.inheritedGroupID(
                selectedRepoGroupID: "/tmp/Chau7",
                startDirectory: "/tmp/Chau7/apps/chau7-macos"
            ),
            "/tmp/Chau7"
        )
    }

    func testDoesNotInheritGroupForDifferentRepo() {
        XCTAssertNil(
            RepoGroupInheritance.inheritedGroupID(
                selectedRepoGroupID: "/tmp/Chau7",
                startDirectory: "/tmp/chau7-website"
            )
        )
    }

    func testDoesNotInheritGroupWithoutStartDirectory() {
        XCTAssertNil(
            RepoGroupInheritance.inheritedGroupID(
                selectedRepoGroupID: "/tmp/Chau7",
                startDirectory: nil
            )
        )
    }
}
