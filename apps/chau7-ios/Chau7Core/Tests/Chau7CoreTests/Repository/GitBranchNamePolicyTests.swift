import XCTest
@testable import Chau7Core

final class GitBranchNamePolicyTests: XCTestCase {
    func testDisplayNameTrimsNormalBranchNames() {
        XCTAssertEqual(GitBranchNamePolicy.displayName(from: "  feature/perf  \n"), "feature/perf")
    }

    func testDisplayNameSuppressesDetachedHeadSentinel() {
        XCTAssertNil(GitBranchNamePolicy.displayName(from: "HEAD\n"))
    }

    func testDisplayNameSuppressesEmptyInput() {
        XCTAssertNil(GitBranchNamePolicy.displayName(from: "  "))
        XCTAssertNil(GitBranchNamePolicy.displayName(from: nil))
    }

    func testDetachedHeadDetectionIsExactAfterTrimming() {
        XCTAssertTrue(GitBranchNamePolicy.isDetachedHead(" HEAD\n"))
        XCTAssertFalse(GitBranchNamePolicy.isDetachedHead("feature/HEAD-fix"))
    }
}
