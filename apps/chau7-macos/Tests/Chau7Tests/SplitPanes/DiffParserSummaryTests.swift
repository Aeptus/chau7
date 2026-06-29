import XCTest
@testable import Chau7

/// `parseUnifiedDiff` now reports a `DiffSummary` so the empty-state UI
/// can explain *why* there are no hunks. Previously a rename-only diff
/// and a binary-file change both rendered as "no changes", which made
/// the viewer feel broken for those cases.
final class DiffParserSummaryTests: XCTestCase {

    func testPlainContentDiffHasContentSummary() {
        let raw = """
        diff --git a/foo.swift b/foo.swift
        index abc..def 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,2 +1,2 @@
         line1
        -line2
        +line2_modified
        """
        let parsed = DiffViewerModel.parseUnifiedDiff(raw)
        XCTAssertEqual(parsed.summary, .content)
        XCTAssertEqual(parsed.hunks.count, 1)
        XCTAssertEqual(parsed.additions, 1)
        XCTAssertEqual(parsed.deletions, 1)
    }

    func testBinaryDiffIsRecognised() {
        let raw = """
        diff --git a/logo.png b/logo.png
        index abc..def 100644
        Binary files a/logo.png and b/logo.png differ
        """
        let parsed = DiffViewerModel.parseUnifiedDiff(raw)
        XCTAssertEqual(parsed.summary, .binary)
        XCTAssertTrue(parsed.hunks.isEmpty)
    }

    func testRenameOnlyIsRecognised() {
        let raw = """
        diff --git a/old.swift b/new.swift
        similarity index 100%
        rename from old.swift
        rename to new.swift
        """
        let parsed = DiffViewerModel.parseUnifiedDiff(raw)
        XCTAssertEqual(parsed.summary, .renamed(from: "old.swift", to: "new.swift"))
        XCTAssertTrue(parsed.hunks.isEmpty)
    }

    func testRenameWithEditKeepsHunksAndPlainSummary() {
        // Rename + edit: the textual hunks must still parse. The summary
        // becomes `.renamed` because both rename markers are present, but
        // hunks remain available — the UI shows them, not the empty state.
        let raw = """
        diff --git a/old.swift b/new.swift
        similarity index 80%
        rename from old.swift
        rename to new.swift
        --- a/old.swift
        +++ b/new.swift
        @@ -1,2 +1,2 @@
         line1
        -line2
        +line2_updated
        """
        let parsed = DiffViewerModel.parseUnifiedDiff(raw)
        XCTAssertEqual(parsed.summary, .renamed(from: "old.swift", to: "new.swift"))
        XCTAssertEqual(parsed.hunks.count, 1)
        XCTAssertEqual(parsed.additions, 1)
        XCTAssertEqual(parsed.deletions, 1)
    }

    func testEmptyDiffIsContentSummary() {
        let parsed = DiffViewerModel.parseUnifiedDiff("")
        XCTAssertEqual(parsed.summary, .content)
        XCTAssertTrue(parsed.hunks.isEmpty)
    }
}
