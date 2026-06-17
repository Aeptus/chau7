#if canImport(SwiftUI)
import XCTest
import SwiftUI
@testable import Chau7

/// Tests for `MarkdownRunbookView.renderInlineMarkdown(_:)`.
///
/// The runbook view used to call `Text(verbatim: text)` on every paragraph,
/// heading, list item, and checkbox label, which meant `**bold**`,
/// `*italic*`, `` `code` ``, and `[link](url)` showed as literal characters
/// — the reason the rendered side panel read as "slop" instead of as
/// rendered markdown. The new helper round-trips inline markdown through
/// `AttributedString(markdown:options:.inlineOnlyPreservingWhitespace)` so
/// SwiftUI's `Text(AttributedString)` actually renders the styled glyphs.
///
/// All assertions are on the AttributedString output, which the SPM test
/// runner can exercise without instantiating a SwiftUI view.
final class MarkdownRunbookInlineRenderingTests: XCTestCase {

    // MARK: - Bold

    func testBoldEmphasisAppliesInlinePresentationIntent() {
        let attributed = MarkdownRunbookView.renderInlineMarkdown("hello **world**")
        let plain = String(attributed.characters)
        XCTAssertEqual(plain, "hello world", "Asterisks must be consumed, not rendered as literal characters")

        // Find the run that covers "world" and verify it carries the bold intent.
        let worldRange = attributed.range(of: "world")
        XCTAssertNotNil(worldRange, "rendered output must contain 'world'")
        guard let range = worldRange else { return }
        let intents = attributed[range].inlinePresentationIntent ?? []
        XCTAssertTrue(
            intents.contains(.stronglyEmphasized),
            "the 'world' run must be marked stronglyEmphasized (bold)"
        )
    }

    func testItalicEmphasisAppliesInlinePresentationIntent() {
        let attributed = MarkdownRunbookView.renderInlineMarkdown("see *the docs* for details")
        XCTAssertEqual(String(attributed.characters), "see the docs for details")
        guard let range = attributed.range(of: "the docs") else {
            XCTFail("rendered output should contain 'the docs'")
            return
        }
        let intents = attributed[range].inlinePresentationIntent ?? []
        XCTAssertTrue(
            intents.contains(.emphasized),
            "the 'the docs' run must be marked emphasized (italic)"
        )
    }

    func testInlineCodeAppliesCodeIntent() {
        let attributed = MarkdownRunbookView.renderInlineMarkdown("run `make build`")
        XCTAssertEqual(String(attributed.characters), "run make build")
        guard let range = attributed.range(of: "make build") else {
            XCTFail("rendered output should contain 'make build'")
            return
        }
        let intents = attributed[range].inlinePresentationIntent ?? []
        XCTAssertTrue(
            intents.contains(.code),
            "the 'make build' run must be marked .code (rendered monospaced)"
        )
    }

    func testInlineLinkAttachesURL() {
        let attributed = MarkdownRunbookView.renderInlineMarkdown("see [docs](https://example.com/foo)")
        XCTAssertEqual(String(attributed.characters), "see docs")
        guard let range = attributed.range(of: "docs") else {
            XCTFail("rendered output should contain 'docs'")
            return
        }
        XCTAssertEqual(
            attributed[range].link,
            URL(string: "https://example.com/foo"),
            "the 'docs' run must carry the link URL"
        )
    }

    // MARK: - Negative cases

    func testPlainTextRoundTripsUnchanged() {
        let plain = "no markdown here"
        let attributed = MarkdownRunbookView.renderInlineMarkdown(plain)
        XCTAssertEqual(String(attributed.characters), plain)
    }

    func testEmptyStringYieldsEmptyAttributedString() {
        let attributed = MarkdownRunbookView.renderInlineMarkdown("")
        XCTAssertEqual(String(attributed.characters), "")
    }

    /// Malformed markdown (e.g. unmatched emphasis marker) must fall back to
    /// a safe rendering rather than throwing or rendering empty. We accept
    /// either: the parser recovers partially (preferred), OR the helper
    /// returns the raw string. Both keep the user's content visible.
    func testMalformedMarkdownDoesNotDropContent() {
        let raw = "weird **never closed"
        let attributed = MarkdownRunbookView.renderInlineMarkdown(raw)
        let rendered = String(attributed.characters)
        XCTAssertFalse(rendered.isEmpty, "malformed input must not drop the entire content")
        // The recoverable parser may strip the trailing markers but must
        // surface the substantive words.
        XCTAssertTrue(rendered.contains("weird"), "rendered output must preserve substantive text")
        XCTAssertTrue(rendered.contains("never closed"), "rendered output must preserve substantive text")
    }

    /// Whitespace preservation is required for runbook items where the user
    /// has intentional alignment (e.g. multi-space indentation in a list
    /// item). `inlineOnlyPreservingWhitespace` is what makes this work.
    func testInteriorWhitespacePreserved() {
        let attributed = MarkdownRunbookView.renderInlineMarkdown("a   b   c")
        XCTAssertEqual(
            String(attributed.characters),
            "a   b   c",
            "interior multi-space whitespace must survive the markdown parse"
        )
    }

    /// Block constructs (headings, fenced code, list bullets) must NOT be
    /// reinterpreted by the inline-only parser — the `parseMarkdown`
    /// infrastructure layer already peeled them off. Verify by feeding a
    /// string that LOOKS like a heading: the leading `#` characters should
    /// pass through as plain text.
    func testBlockSyntaxIsNotReinterpreted() {
        let attributed = MarkdownRunbookView.renderInlineMarkdown("# not actually a heading")
        XCTAssertEqual(
            String(attributed.characters),
            "# not actually a heading",
            "inline-only parser must NOT consume leading # as a heading marker"
        )
    }
}
#endif
