import XCTest
@testable import Chau7

final class RustTermBridgeParityTests: XCTestCase {
    func testOSC8LinkCellsSetMetalLinkUnderlineFlagWhenNotExplicitlyUnderlined() {
        var fixture = makeFixture(
            cells: [
                makeCell("l", linkID: 42),
                makeCell("u", flags: RustCellFlags.underline, linkID: 43)
            ]
        )
        let bridge = RustTermBridge()
        let buffer = TripleBufferedTerminal(rows: 1, cols: 2)

        sync(fixture: &fixture, rows: 1, cols: 2, bridge: bridge, buffer: buffer)

        let linkCell = buffer.getCell(row: 0, col: 0)
        let explicitlyUnderlinedLinkCell = buffer.getCell(row: 0, col: 1)
        XCTAssertNotEqual(linkCell.flags & TerminalCell.linkUnderlineFlag, 0)
        XCTAssertEqual(linkCell.flags & TerminalCell.underlineFlag, 0)
        XCTAssertEqual(explicitlyUnderlinedLinkCell.flags & TerminalCell.linkUnderlineFlag, 0)
        XCTAssertNotEqual(explicitlyUnderlinedLinkCell.flags & TerminalCell.underlineFlag, 0)
    }

    func testDimensionMismatchStillSyncsOverlapAsRaceFallback() {
        var fixture = makeFixture(strings: ["a", "b", "c", "d"])
        let bridge = RustTermBridge()
        let buffer = TripleBufferedTerminal(rows: 1, cols: 2)

        let result = syncAllowingMismatch(
            fixture: &fixture,
            rows: 2,
            cols: 2,
            bridge: bridge,
            buffer: buffer
        )

        XCTAssertNil(result)
        XCTAssertEqual(clusterString(buffer.getCell(row: 0, col: 0), in: buffer), "a")
        XCTAssertEqual(clusterString(buffer.getCell(row: 0, col: 1), in: buffer), "b")
    }

    func testMultiCodepointClusterRoundTripsThroughBridge() {
        // ❤️ = U+2764 U+FE0F — six UTF-8 bytes that must travel intact through
        // the snapshot → bridge → triple buffer chain.
        var fixture = makeFixture(strings: ["\u{2764}\u{FE0F}", "x"])
        let bridge = RustTermBridge()
        let buffer = TripleBufferedTerminal(rows: 1, cols: 2)

        sync(fixture: &fixture, rows: 1, cols: 2, bridge: bridge, buffer: buffer)

        XCTAssertEqual(clusterString(buffer.getCell(row: 0, col: 0), in: buffer), "\u{2764}\u{FE0F}")
        XCTAssertEqual(clusterString(buffer.getCell(row: 0, col: 1), in: buffer), "x")
    }

    func testGlyphForegroundIsRescuedWhenItWouldMatchDarkBackground() {
        var fixture = makeFixture(
            cells: [
                makeCell("x", fg: (0, 0, 0), bg: (30, 30, 30))
            ]
        )
        let bridge = RustTermBridge()
        let buffer = TripleBufferedTerminal(rows: 1, cols: 1)

        sync(fixture: &fixture, rows: 1, cols: 1, bridge: bridge, buffer: buffer)

        let cell = buffer.getCell(row: 0, col: 0)
        XCTAssertEqual(clusterString(cell, in: buffer), "x")
        XCTAssertGreaterThanOrEqual(contrastRatio(cell.foregroundColor, cell.backgroundColor), 1.4)
        XCTAssertGreaterThan(cell.foregroundColor.x + cell.foregroundColor.y + cell.foregroundColor.z, 0.1)
    }

    // MARK: - Helpers

    /// A test fixture owning the cells array AND the packed UTF-8 cluster bytes
    /// they reference. Mirrors the (cells, clusters_utf8) pair that Rust ships
    /// in a real `GridSnapshot`.
    private struct Fixture {
        var cells: [RustCellData]
        var clusters: [UInt8]
    }

    private func sync(
        fixture: inout Fixture,
        rows: UInt16,
        cols: UInt16,
        bridge: RustTermBridge,
        buffer: TripleBufferedTerminal
    ) {
        XCTAssertNotNil(
            syncAllowingMismatch(
                fixture: &fixture,
                rows: rows,
                cols: cols,
                bridge: bridge,
                buffer: buffer
            )
        )
    }

    private func syncAllowingMismatch(
        fixture: inout Fixture,
        rows: UInt16,
        cols: UInt16,
        bridge: RustTermBridge,
        buffer: TripleBufferedTerminal
    ) -> (rows: Int, cols: Int)? {
        let cellCapacity = fixture.cells.count
        let clustersLen = fixture.clusters.count
        return fixture.cells.withUnsafeMutableBufferPointer { cellBuffer in
            fixture.clusters.withUnsafeMutableBufferPointer { clusterBuffer in
                var snapshot = RustGridSnapshot(
                    cells: cellBuffer.baseAddress,
                    clusters_utf8: clusterBuffer.baseAddress,
                    clusters_len: clustersLen,
                    clusters_capacity: clustersLen,
                    cols: cols,
                    rows: rows,
                    cursor_visible: 1,
                    _pad: (0, 0, 0),
                    scrollback_rows: 0,
                    display_offset: 0,
                    capacity: cellCapacity
                )
                return withUnsafeMutablePointer(to: &snapshot) { snapshotPointer in
                    bridge.syncToTripleBuffer(buffer, grid: snapshotPointer, viewID: 0)
                }
            }
        }
    }

    /// Build a Fixture from an array of single-grapheme strings, one per cell.
    private func makeFixture(strings: [String]) -> Fixture {
        var clusters: [UInt8] = []
        let cells = strings.map { s -> RustCellData in
            let bytes = Array(s.utf8)
            let offset = UInt32(clusters.count)
            clusters.append(contentsOf: bytes)
            var cell = RustCellData()
            cell.cluster_offset = offset
            cell.cluster_len = UInt16(bytes.count)
            cell.width = 1
            cell.fg_r = 255
            cell.fg_g = 255
            cell.fg_b = 255
            return cell
        }
        return Fixture(cells: cells, clusters: clusters)
    }

    /// Build a Fixture from explicit RustCellData values plus auto-populated
    /// 1-byte ASCII clusters keyed by their `cluster_offset` written-in below.
    private func makeFixture(cells: [RustCellData]) -> Fixture {
        // Each cell's existing cluster_offset references positions assigned by
        // `makeCell()` — concatenate clusters in cell order.
        var clusters: [UInt8] = []
        var rewritten: [RustCellData] = []
        rewritten.reserveCapacity(cells.count)
        for cell in cells {
            // cluster_len > 0 means makeCell stashed the byte in cluster_offset's low bits.
            var c = cell
            if cell.cluster_len > 0 {
                let byte = UInt8(cell.cluster_offset & 0xFF)
                c.cluster_offset = UInt32(clusters.count)
                clusters.append(byte)
            }
            rewritten.append(c)
        }
        return Fixture(cells: rewritten, clusters: clusters)
    }

    private func makeCell(
        _ character: String,
        fg: (UInt8, UInt8, UInt8) = (255, 255, 255),
        bg: (UInt8, UInt8, UInt8) = (0, 0, 0),
        flags: UInt8 = 0,
        linkID: UInt16 = 0
    ) -> RustCellData {
        var cell = RustCellData()
        // Temporarily stash the byte in cluster_offset so makeFixture(cells:)
        // can pack it into a real clusters buffer.
        let byte = UInt8(character.unicodeScalars.first!.value)
        cell.cluster_offset = UInt32(byte)
        cell.cluster_len = 1
        cell.width = 1
        cell.fg_r = fg.0
        cell.fg_g = fg.1
        cell.fg_b = fg.2
        cell.bg_r = bg.0
        cell.bg_g = bg.1
        cell.bg_b = bg.2
        cell.flags = flags
        cell.link_id = linkID
        return cell
    }

    /// Read a terminal cell's cluster bytes from the buffer's parallel clusters store.
    private func clusterString(_ cell: TerminalCell, in tb: TripleBufferedTerminal) -> String {
        tb.renderBuffer.clusterString(at: cell.clusterStart, length: cell.clusterLen)
    }

    private func contrastRatio(_ lhs: SIMD4<Float>, _ rhs: SIMD4<Float>) -> Float {
        let l1 = relativeLuminance(lhs)
        let l2 = relativeLuminance(rhs)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: SIMD4<Float>) -> Float {
        let r = linearizedSRGB(color.x)
        let g = linearizedSRGB(color.y)
        let b = linearizedSRGB(color.z)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func linearizedSRGB(_ component: Float) -> Float {
        if component <= 0.03928 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }
}
