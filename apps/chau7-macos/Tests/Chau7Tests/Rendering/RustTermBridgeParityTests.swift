import XCTest
@testable import Chau7

final class RustTermBridgeParityTests: XCTestCase {
    func testLocalEchoOverlayOverridesGridCellBeforeMetalSync() {
        var cells = [
            makeCell("a"),
            makeCell("b")
        ]
        let bridge = RustTermBridge()
        bridge.localEchoOverlay = [1: makeCell("z")]
        let buffer = TripleBufferedTerminal(rows: 1, cols: 2)

        sync(cells: &cells, rows: 1, cols: 2, bridge: bridge, buffer: buffer)

        XCTAssertEqual(buffer.getCell(row: 0, col: 0).character, scalar("a"))
        XCTAssertEqual(buffer.getCell(row: 0, col: 1).character, scalar("z"))
    }

    func testOSC8LinkCellsSetMetalLinkUnderlineFlagWhenNotExplicitlyUnderlined() {
        var cells = [
            makeCell("l", flags: 0, linkID: 42),
            makeCell("u", flags: RustCellFlags.underline, linkID: 43)
        ]
        let bridge = RustTermBridge()
        let buffer = TripleBufferedTerminal(rows: 1, cols: 2)

        sync(cells: &cells, rows: 1, cols: 2, bridge: bridge, buffer: buffer)

        let linkCell = buffer.getCell(row: 0, col: 0)
        let explicitlyUnderlinedLinkCell = buffer.getCell(row: 0, col: 1)
        XCTAssertNotEqual(linkCell.flags & TerminalCell.linkUnderlineFlag, 0)
        XCTAssertEqual(linkCell.flags & TerminalCell.underlineFlag, 0)
        XCTAssertEqual(explicitlyUnderlinedLinkCell.flags & TerminalCell.linkUnderlineFlag, 0)
        XCTAssertNotEqual(explicitlyUnderlinedLinkCell.flags & TerminalCell.underlineFlag, 0)
    }

    private func sync(
        cells: inout [RustCellData],
        rows: UInt16,
        cols: UInt16,
        bridge: RustTermBridge,
        buffer: TripleBufferedTerminal
    ) {
        let capacity = cells.count
        cells.withUnsafeMutableBufferPointer { cellBuffer in
            var snapshot = RustGridSnapshot(
                cells: cellBuffer.baseAddress,
                cols: cols,
                rows: rows,
                cursor_visible: 1,
                _pad: (0, 0, 0),
                scrollback_rows: 0,
                display_offset: 0,
                capacity: capacity
            )

            withUnsafeMutablePointer(to: &snapshot) { snapshotPointer in
                XCTAssertNotNil(
                    bridge.syncToTripleBuffer(
                        buffer,
                        grid: snapshotPointer,
                        viewID: 0
                    )
                )
            }
        }
    }

    private func makeCell(
        _ character: String,
        flags: UInt8 = 0,
        linkID: UInt16 = 0
    ) -> RustCellData {
        RustCellData(
            character: scalar(character),
            fg_r: 255,
            fg_g: 255,
            fg_b: 255,
            bg_r: 0,
            bg_g: 0,
            bg_b: 0,
            flags: flags,
            _pad: 0,
            link_id: linkID
        )
    }

    private func scalar(_ character: String) -> UInt32 {
        UInt32(character.unicodeScalars.first!.value)
    }
}
