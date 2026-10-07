import UIKit
import XCTest

@MainActor
final class RemoteTerminalCellMetricsTests: XCTestCase {
    func testUIKitGlyphsRemainInsideTheirTerminalRow() throws {
        for size in [9.0, 13.0, 18.0, 24.0] {
            for weight in [UIFont.Weight.regular, .bold] {
                let font = UIFont.monospacedSystemFont(ofSize: size, weight: weight)
                let metrics = RemoteTerminalCellMetrics(font: font)
                let rows = try paintedRows(font: font, metrics: metrics)
                XCTAssertFalse(rows.isEmpty, "Glyphs must be visible at \(size) points")
                XCTAssertTrue(rows.allSatisfy { $0 >= 0 && $0 < Int(metrics.cellHeight) },
                              "UIKit ink escaped its row at \(size) points: \(rows)")
            }
        }
    }

    func testStyleFontsShareTheCellBaseline() {
        let regular = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bold = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        let metrics = RemoteTerminalCellMetrics(font: regular)
        for font in [regular, bold] {
            XCTAssertEqual(metrics.textOriginOffset(for: font) + font.ascender,
                           metrics.baselineOffset, accuracy: 0.01)
        }
    }

    private func paintedRows(font: UIFont, metrics: RemoteTerminalCellMetrics) throws -> [Int] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let size = CGSize(width: metrics.cellWidth * 4, height: metrics.cellHeight * 3)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            metrics.drawGlyph("Ag", at: .zero, font: font,
                              attributes: [.font: font, .foregroundColor: UIColor.white])
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let provider = try XCTUnwrap(cgImage.dataProvider)
        let data = try XCTUnwrap(provider.data) as Data
        guard cgImage.bitsPerPixel == 32 else {
            XCTFail("Expected an RGB bitmap, got \(cgImage.bitsPerPixel) bits per pixel")
            return []
        }
        return (0 ..< cgImage.height).filter { row in
            (0 ..< cgImage.width).contains { column in
                let offset = row * cgImage.bytesPerRow + column * 4
                return data[offset] > 220 && data[offset + 1] > 220 && data[offset + 2] > 220
            }
        }
    }
}
