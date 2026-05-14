import XCTest
@testable import Chau7

final class RustTermBridgeParityTests: XCTestCase {
    func testLocalEchoOverlayOverridesGridCellBeforeMetalSync() {
        var fixture = makeFixture(strings: ["a", "b"])
        let bridge = RustTermBridge()
        bridge.localEchoOverlay = [1: makeOverlayCell("z")]
        let buffer = TripleBufferedTerminal(rows: 1, cols: 2)

        sync(fixture: &fixture, rows: 1, cols: 2, bridge: bridge, buffer: buffer)

        XCTAssertEqual(clusterString(buffer.getCell(row: 0, col: 0), in: buffer), "a")
        XCTAssertEqual(clusterString(buffer.getCell(row: 0, col: 1), in: buffer), "z")
    }

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
        cell.fg_r = 255
        cell.fg_g = 255
        cell.fg_b = 255
        cell.flags = flags
        cell.link_id = linkID
        return cell
    }

    /// Build a local-echo overlay cell using the sentinel encoding.
    private func makeOverlayCell(_ character: String) -> RustCellData {
        var cell = RustCellData()
        let byte = UInt8(character.unicodeScalars.first!.value)
        cell.cluster_offset = RustCellLocalEcho.encode(byte: byte)
        cell.cluster_len = 1
        cell.width = 1
        cell.fg_r = 255
        cell.fg_g = 255
        cell.fg_b = 255
        return cell
    }

    /// Read a terminal cell's cluster bytes from the buffer's parallel clusters store.
    private func clusterString(_ cell: TerminalCell, in tb: TripleBufferedTerminal) -> String {
        tb.renderBuffer.clusterString(at: cell.clusterStart, length: cell.clusterLen)
    }
}
