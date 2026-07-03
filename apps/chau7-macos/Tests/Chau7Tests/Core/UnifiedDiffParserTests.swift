import XCTest
@testable import Chau7Core

/// Direct tests for the pure unified-diff parser extracted from
/// `DiffViewerModel` (Stage 3 of the SOLID/DRY plan). Summary detection
/// (binary / rename) stays covered via the model shim in
/// `DiffParserSummaryTests`.
final class UnifiedDiffParserTests: XCTestCase {

    // MARK: - Hunk Header Parsing

    func testParseHunkHeaderWithExplicitCounts() {
        let numbers = UnifiedDiffParser.parseHunkHeader("@@ -3,7 +12,9 @@ func body() {")
        XCTAssertEqual(numbers.oldStart, 3)
        XCTAssertEqual(numbers.oldCount, 7)
        XCTAssertEqual(numbers.newStart, 12)
        XCTAssertEqual(numbers.newCount, 9)
    }

    func testParseHunkHeaderOmittedCountsDefaultToOne() {
        // Single-line hunks omit the count: "@@ -5 +5 @@"
        let numbers = UnifiedDiffParser.parseHunkHeader("@@ -5 +5 @@")
        XCTAssertEqual(numbers.oldStart, 5)
        XCTAssertEqual(numbers.oldCount, 1)
        XCTAssertEqual(numbers.newStart, 5)
        XCTAssertEqual(numbers.newCount, 1)
    }

    // MARK: - Line Classification

    func testParseUnifiedDiffClassifiesAddRemoveAndContextLines() {
        let raw = """
        diff --git a/foo.swift b/foo.swift
        index abc..def 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,3 +1,3 @@
         unchanged
        -removed line
        +added line
        \\ No newline at end of file
        """
        let parsed = UnifiedDiffParser.parseUnifiedDiff(raw)
        XCTAssertEqual(parsed.hunks.count, 1)
        XCTAssertEqual(parsed.additions, 1)
        XCTAssertEqual(parsed.deletions, 1)
        XCTAssertEqual(parsed.summary, .content)
        XCTAssertEqual(parsed.hunks[0].lines, [
            .hunkHeader("@@ -1,3 +1,3 @@"),
            .context("unchanged"),
            .deletion("removed line"),
            .addition("added line")
        ])
    }

    func testParseUnifiedDiffSplitsMultipleHunks() {
        let raw = """
        @@ -1,2 +1,2 @@
        -a
        +b
        @@ -10,2 +10,2 @@
        -c
        +d
        """
        let parsed = UnifiedDiffParser.parseUnifiedDiff(raw)
        XCTAssertEqual(parsed.hunks.count, 2)
        XCTAssertEqual(parsed.hunks[0].oldStart, 1)
        XCTAssertEqual(parsed.hunks[1].oldStart, 10)
        XCTAssertEqual(parsed.additions, 2)
        XCTAssertEqual(parsed.deletions, 2)
    }

    // MARK: - Malformed Input

    func testParseUnifiedDiffMalformedInputProducesNoHunks() {
        let parsed = UnifiedDiffParser.parseUnifiedDiff("not a diff at all\njust random text\n+++ stray marker")
        XCTAssertTrue(parsed.hunks.isEmpty)
        XCTAssertEqual(parsed.additions, 0)
        XCTAssertEqual(parsed.deletions, 0)
        XCTAssertEqual(parsed.summary, .content)
    }

    func testParseUnifiedDiffEmptyInput() {
        let parsed = UnifiedDiffParser.parseUnifiedDiff("")
        XCTAssertTrue(parsed.hunks.isEmpty)
        XCTAssertEqual(parsed.summary, .content)
    }
}
