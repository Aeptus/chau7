import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class GitDiffTrackerTests: XCTestCase {
    func testChangedPathReturnsDestinationForRename() {
        XCTAssertEqual(
            GitDiffTracker.changedPath(fromStatusPorcelainLine: "R  old/name.swift -> new/name.swift"),
            "new/name.swift"
        )
    }

    func testChangedPathReturnsDestinationForCopy() {
        XCTAssertEqual(
            GitDiffTracker.changedPath(fromStatusPorcelainLine: "C  src/template.swift -> src/template_copy.swift"),
            "src/template_copy.swift"
        )
    }

    func testFirstChangedPathUsesParsedDestination() {
        let porcelain = """
        R  old/name.swift -> new/name.swift
         M README.md
        """

        XCTAssertEqual(GitDiffTracker.firstChangedPath(inStatusPorcelain: porcelain), "new/name.swift")
    }
}
#endif
