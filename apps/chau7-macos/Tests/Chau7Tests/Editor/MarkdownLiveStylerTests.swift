import AppKit
import XCTest
@testable import Chau7

/// Covers the pure markdown span parser behind the editor's live "light" rendering.
/// Asserts on (kind, matched-substring) pairs so the structure is verified without
/// any AppKit fonts/colors.
final class MarkdownLiveStylerTests: XCTestCase {
    private func runs(_ markdown: String) -> [(MarkdownLiveStyler.Kind, String)] {
        let ns = markdown as NSString
        return MarkdownLiveStyler.styleRuns(in: ns).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func assertContains(
        _ markdown: String,
        _ expected: (MarkdownLiveStyler.Kind, String),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let found = runs(markdown)
        XCTAssertTrue(
            found.contains(where: { $0.0 == expected.0 && $0.1 == expected.1 }),
            "expected \(expected) in \(found)", file: file, line: line
        )
    }

    func testHeadingMarkerAndContent() {
        assertContains("# Title", (.marker, "#"))
        assertContains("# Title", (.heading(1), "Title"))
        assertContains("### Sub", (.marker, "###"))
        assertContains("### Sub", (.heading(3), "Sub"))
    }

    func testBoldItalicCode() {
        assertContains("a **bold** b", (.bold, "**bold**"))
        assertContains("a *it* b", (.italic, "*it*"))
        assertContains("a _it_ b", (.italic, "_it_"))
        assertContains("a `code` b", (.codeSpan, "`code`"))
        assertContains("a ~~gone~~ b", (.strikethrough, "~~gone~~"))
    }

    func testBoldNotMisreadAsItalic() {
        // The italic rule must not fire on the inner markers of bold.
        let found = runs("**bold**")
        XCTAssertTrue(found.contains(where: { $0.0 == .bold && $0.1 == "**bold**" }))
        XCTAssertFalse(found.contains(where: { $0.0 == .italic }), "bold should not also match italic")
    }

    func testLinkStylesTextAndDimsPunctuation() {
        assertContains("see [docs](https://x.y)", (.linkText, "docs"))
        assertContains("see [docs](https://x.y)", (.marker, "[docs](https://x.y)"))
    }

    func testBlockquoteAndList() {
        assertContains("> quoted", (.marker, ">"))
        assertContains("> quoted", (.blockquote, "quoted"))
        assertContains("- item", (.listMarker, "-"))
        assertContains("* item", (.listMarker, "*"))
        assertContains("1. item", (.listMarker, "1."))
    }

    func testHorizontalRule() {
        assertContains("---", (.horizontalRule, "---"))
        assertContains("***", (.horizontalRule, "***"))
    }

    func testFencedCodeBlockSuppressesInline() {
        let md = "```\n**not bold** `not code`\n```"
        let found = runs(md)
        XCTAssertTrue(found.contains(where: { $0.0 == .codeFence }), "fence lines styled as code")
        XCTAssertFalse(found.contains(where: { $0.0 == .bold }), "inline not parsed inside a fence")
        XCTAssertFalse(found.contains(where: { $0.0 == .codeSpan }), "inline code not parsed inside a fence")
    }

    func testInlineInsideListItem() {
        // Marker + the inline content of the item are both styled.
        assertContains("- a **b**", (.listMarker, "-"))
        assertContains("- a **b**", (.bold, "**b**"))
    }

    func testPlainTextProducesNoRuns() {
        XCTAssertTrue(runs("just some plain prose").isEmpty)
    }

    func testUncheckedTaskCheckbox() {
        assertContains("- [ ] do thing", (.listMarker, "-"))
        assertContains("- [ ] do thing", (.taskCheckbox(checked: false), "[ ]"))
        let found = runs("- [ ] do thing")
        XCTAssertFalse(found.contains(where: { $0.0 == .completedTask }), "unchecked tasks are not struck through")
    }

    func testCheckedTaskStrikesThroughText() {
        assertContains("- [x] done", (.taskCheckbox(checked: true), "[x]"))
        assertContains("- [x] done", (.completedTask, "done"))
        assertContains("- [X] done", (.taskCheckbox(checked: true), "[X]"))
    }

    func testInlineStillStyledInsideTaskText() {
        assertContains("- [ ] a **b**", (.bold, "**b**"))
    }

    func testHangingIndentForListsAndQuotesOnly() {
        let font = NSFont.systemFont(ofSize: 13)
        XCTAssertNotNil(MarkdownLiveStyler.hangingIndent(forLine: "- item", font: font))
        XCTAssertNotNil(MarkdownLiveStyler.hangingIndent(forLine: "1. item", font: font))
        XCTAssertNotNil(MarkdownLiveStyler.hangingIndent(forLine: "- [x] task", font: font))
        XCTAssertNotNil(MarkdownLiveStyler.hangingIndent(forLine: "> quote", font: font))
        XCTAssertNil(MarkdownLiveStyler.hangingIndent(forLine: "plain text", font: font))
        XCTAssertNil(MarkdownLiveStyler.hangingIndent(forLine: "# heading", font: font))
        // A list indent must leave room for the marker prefix.
        XCTAssertGreaterThan(MarkdownLiveStyler.hangingIndent(forLine: "- item", font: font) ?? 0, 0)
    }

    func testRangesAreWithinBounds() {
        let md = "# H\n- x **y**\n> q\n```\nc\n```\n[t](u)"
        let ns = md as NSString
        for run in MarkdownLiveStyler.styleRuns(in: ns) {
            XCTAssertGreaterThanOrEqual(run.range.location, 0)
            XCTAssertLessThanOrEqual(
                run.range.location + run.range.length,
                ns.length,
                "run \(run) out of bounds for length \(ns.length)"
            )
        }
    }
}
