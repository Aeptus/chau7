import XCTest
import AppKit
import CoreText
import Metal
@testable import Chau7

final class MetalTerminalRendererTests: XCTestCase {

    func testSystemMonospacedFontDoesNotReportColorGlyphTables() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont

        XCTAssertFalse(MetalTerminalRenderer.hasColorGlyphTables(font: font))
    }

    func testAppleColorEmojiReportsColorGlyphTablesWhenAvailable() throws {
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, 13, nil)
        let fullName = CTFontCopyFullName(font) as String

        try XCTSkipUnless(
            fullName.localizedCaseInsensitiveContains("Apple Color Emoji"),
            "Apple Color Emoji is not available on this system"
        )
        XCTAssertTrue(MetalTerminalRenderer.hasColorGlyphTables(font: font))
    }

    func testSlotColorDetectionIgnoresMonochromeMasks() {
        let pixels: [UInt8] = [
            255, 255, 255, 255,
            80, 80, 80, 128
        ]

        let containsColor = pixels.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return MetalTerminalRenderer.slotContainsColorPixels(
                data: baseAddress,
                bytesPerRow: 8,
                atlasWidth: 2,
                atlasHeight: 1,
                x: 0,
                y: 0,
                width: 2,
                height: 1
            )
        }

        XCTAssertFalse(containsColor)
    }

    func testSlotColorDetectionFindsChroma() {
        let pixels: [UInt8] = [
            255, 255, 255, 255,
            220, 40, 20, 255
        ]

        let containsColor = pixels.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return MetalTerminalRenderer.slotContainsColorPixels(
                data: baseAddress,
                bytesPerRow: 8,
                atlasWidth: 2,
                atlasHeight: 1,
                x: 0,
                y: 0,
                width: 2,
                height: 1
            )
        }

        XCTAssertTrue(containsColor)
    }

    func testAsciiRasterizationRemainsMonochromeMask() throws {
        let renderer = try makeRenderer()
        let info = try XCTUnwrap(renderer.rasterizeGlyphForTesting("A"))

        XCTAssertFalse(info.isColor)
    }

    func testGlyphBearingDoesNotIncludeAtlasPackingPosition() throws {
        let renderer = try makeRenderer()

        let info = try XCTUnwrap(renderer.rasterizeGlyphForTesting("A"))
        let expectedBounds = try localImageBounds(for: "A")

        XCTAssertEqual(info.bearing.x, expectedBounds.origin.x, accuracy: 0.5)
        XCTAssertEqual(info.bearing.y, expectedBounds.origin.y, accuracy: 0.5)
    }

    func testTUISymbolRasterizationRemainsMonochromeMask() throws {
        let renderer = try makeRenderer()
        let symbols = ["─", "│", "╭", "╮", "╰", "╯", "✳", "✽", "⏺", "★", "⏵", "❯"]

        for symbol in symbols {
            let info = try XCTUnwrap(renderer.rasterizeGlyphForTesting(symbol), symbol)
            XCTAssertFalse(info.isColor, "\(symbol) should use the ANSI foreground color")
        }
    }

    func testEmojiRasterizationMarksColorGlyphWhenAvailable() throws {
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, 13, nil)
        let fullName = CTFontCopyFullName(font) as String

        try XCTSkipUnless(
            fullName.localizedCaseInsensitiveContains("Apple Color Emoji"),
            "Apple Color Emoji is not available on this system"
        )

        let renderer = try makeRenderer()
        let info = try XCTUnwrap(renderer.rasterizeGlyphForTesting("🧪", isWideHint: true))

        XCTAssertTrue(info.isColor)
    }

    func testDefaultEmojiPresentationStillMarksColorGlyphWhenAvailable() throws {
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, 13, nil)
        let fullName = CTFontCopyFullName(font) as String

        try XCTSkipUnless(
            fullName.localizedCaseInsensitiveContains("Apple Color Emoji"),
            "Apple Color Emoji is not available on this system"
        )

        let renderer = try makeRenderer()
        let info = try XCTUnwrap(renderer.rasterizeGlyphForTesting("✅", isWideHint: true))

        XCTAssertTrue(info.isColor)
    }

    func testAchromaticEmojiPresentationStillMarksColorGlyphWhenAvailable() throws {
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, 13, nil)
        let fullName = CTFontCopyFullName(font) as String

        try XCTSkipUnless(
            fullName.localizedCaseInsensitiveContains("Apple Color Emoji"),
            "Apple Color Emoji is not available on this system"
        )

        let renderer = try makeRenderer()
        let info = try XCTUnwrap(renderer.rasterizeGlyphForTesting("⚫️", isWideHint: true))

        XCTAssertTrue(info.isColor)
    }

    func testTextPresentationSelectorKeepsEmojiCapableSymbolMonochrome() throws {
        let renderer = try makeRenderer()
        let info = try XCTUnwrap(renderer.rasterizeGlyphForTesting("⚫︎", isWideHint: true))

        XCTAssertFalse(info.isColor)
    }

    private func makeRenderer() throws -> MetalTerminalRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available on this system")
        }
        guard let renderer = MetalTerminalRenderer(device: device) else {
            throw XCTSkip("MetalTerminalRenderer could not be initialized")
        }
        renderer.setFont(nsFont: .monospacedSystemFont(ofSize: 13, weight: .regular))
        return renderer
    }

    private func localImageBounds(for string: String) throws -> CGRect {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
        let drawFont = CTFontCreateForString(font, string as CFString, CFRangeMake(0, string.utf16.count))
        let attrString = NSAttributedString(
            string: string,
            attributes: [.font: drawFont]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 128,
                height: 128,
                bitsPerComponent: 8,
                bytesPerRow: 128 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.textPosition = .zero
        return CTLineGetImageBounds(line, context)
    }
}
