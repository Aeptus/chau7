import XCTest
@testable import Chau7Core

final class ForeignCwdPolicyTests: XCTestCase {
    func testNoAnchorAllowsWriteToSeedFirstCwd() {
        XCTAssertFalse(
            ForeignCwdPolicy.shouldRefuse(
                newDirectory: "/tmp/first-bind",
                tabCurrentDirectory: "",
                tabGitRoot: nil
            )
        )
    }

    func testExactCwdMatchIsRelated() {
        XCTAssertFalse(
            ForeignCwdPolicy.shouldRefuse(
                newDirectory: "/tmp/repo",
                tabCurrentDirectory: "/tmp/repo",
                tabGitRoot: "/tmp/repo"
            )
        )
    }

    func testSubdirectoryOfCwdIsRelated() {
        XCTAssertFalse(
            ForeignCwdPolicy.shouldRefuse(
                newDirectory: "/tmp/repo/subdir",
                tabCurrentDirectory: "/tmp/repo",
                tabGitRoot: nil
            )
        )
    }

    func testParentOfCwdIsRelated() {
        XCTAssertFalse(
            ForeignCwdPolicy.shouldRefuse(
                newDirectory: "/tmp/repo",
                tabCurrentDirectory: "/tmp/repo/subdir",
                tabGitRoot: nil
            )
        )
    }

    func testRelatedToGitRootEvenIfCwdDiverges() {
        // The tab has cd'd inside Claude's TUI to a sibling repo path that
        // shares the git root anchor — should still be accepted.
        XCTAssertFalse(
            ForeignCwdPolicy.shouldRefuse(
                newDirectory: "/tmp/repo/packages/x",
                tabCurrentDirectory: "/tmp/repo/some-other-dir",
                tabGitRoot: "/tmp/repo"
            )
        )
    }

    func testTotallyUnrelatedPathIsForeign() {
        XCTAssertTrue(
            ForeignCwdPolicy.shouldRefuse(
                newDirectory: "/tmp/other-repo",
                tabCurrentDirectory: "/tmp/aethyme",
                tabGitRoot: "/tmp/aethyme"
            )
        )
    }

    func testEmptyAnchorsIgnored() {
        XCTAssertFalse(
            ForeignCwdPolicy.shouldRefuse(
                newDirectory: "/tmp/whatever",
                tabCurrentDirectory: "   ",
                tabGitRoot: nil
            )
        )
    }

    func testNormalizesPathsBeforeComparison() {
        XCTAssertFalse(
            ForeignCwdPolicy.shouldRefuse(
                newDirectory: "/tmp/repo/../repo/subdir",
                tabCurrentDirectory: "/tmp/repo",
                tabGitRoot: nil
            )
        )
    }
}
