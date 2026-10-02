import AppKit
import CoreText
import XCTest
@testable import Chau7

@MainActor
final class RustGridGlyphCacheTests: XCTestCase {
    func testRepeatedGraphemesReuseShapingAcrossFallbackFrames() {
        let view = RustGridView(frame: .zero)
        let first = view.glyphLine(cluster: "é", flags: 0, color: .red)
        for _ in 0 ..< 1000 {
            XCTAssertTrue(first === view.glyphLine(cluster: "é", flags: 0, color: .red))
        }
        // Underline is painted separately and must not require shaping again.
        XCTAssertTrue(first === view.glyphLine(cluster: "é", flags: RustCellFlags.underline, color: .red))
        XCTAssertEqual(view.cachedGlyphLineCount, 1)
    }

    func testResolvedColorsAndFontTraitsRemainDistinct() throws {
        let view = RustGridView(frame: .zero)
        let regular = view.glyphLine(cluster: "A", flags: 0, color: .red)
        let bold = view.glyphLine(cluster: "A", flags: RustCellFlags.bold, color: .red)
        let italic = view.glyphLine(cluster: "A", flags: RustCellFlags.italic, color: .red)
        let otherColor = view.glyphLine(cluster: "A", flags: 0, color: .blue)
        XCTAssertFalse(regular === bold)
        XCTAssertFalse(regular === italic)
        XCTAssertFalse(regular === otherColor)
        let runs = try XCTUnwrap(CTLineGetGlyphRuns(otherColor) as? [CTRun])
        let attributes = CTRunGetAttributes(runs[0]) as NSDictionary
        XCTAssertEqual(attributes[NSAttributedString.Key.foregroundColor] as? NSColor, .blue)
    }

    func testFontChangesAndMetalOwnershipReleaseCachedText() {
        let view = RustGridView(frame: .zero)
        let old = view.glyphLine(cluster: "A", flags: 0, color: .red)
        view.font = .monospacedSystemFont(ofSize: 24, weight: .regular)
        XCTAssertEqual(view.cachedGlyphLineCount, 0)
        let new = view.glyphLine(cluster: "A", flags: 0, color: .red)
        XCTAssertFalse(old === new)
        XCTAssertGreaterThan(CTLineGetTypographicBounds(new, nil, nil, nil), CTLineGetTypographicBounds(old, nil, nil, nil))
        view.releaseGridStorage()
        XCTAssertEqual(view.cachedGlyphLineCount, 0)
    }

    func testUniqueOutputCannotGrowGlyphStorageWithoutBound() {
        let view = RustGridView(frame: .zero)
        for i in 0 ..< (RustGridView.glyphLineCacheLimit * 2) {
            _ = view.glyphLine(cluster: "glyph-\(i)", flags: 0, color: .red)
            XCTAssertLessThanOrEqual(view.cachedGlyphLineCount, RustGridView.glyphLineCacheLimit)
        }
    }
}
