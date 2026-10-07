import Foundation
import XCTest

final class RemoteTerminalRenderStateTests: XCTestCase {
    func testCopyKeepsGraphemesAndOmitsWideContinuations() {
        let state = makeState(["😀", "", "é"], cols: 3, continuations: [1])
        XCTAssertEqual(state.selectableText, "😀é")
    }

    func testCopyMasksHiddenCells() {
        let state = makeState(["s", "e", "c", "r", "e", "t", "x"], cols: 7,
                              hidden: Set(0 ..< 6))
        XCTAssertEqual(state.selectableText, "      x")
    }

    func testCopyJoinsTheActualGridWrapFlag() {
        let state = makeState(["a", "b", " ", "c", "d", ""], cols: 3, wrapped: [1])
        XCTAssertEqual(state.selectableText, "ab cd")
    }

    func testCopyKeepsHardRowsAndToleratesMissingCells() {
        let state = makeState(["a", "b", "", "c"], cols: 3)
        XCTAssertEqual(state.selectableText, "ab\nc")
    }

    private func makeState(_ text: [String], cols: Int, continuations: Set<Int> = [],
                           hidden: Set<Int> = [], wrapped: Set<Int> = []) -> RemoteTerminalRenderState {
        var clusters = Data()
        let cells = text.enumerated().map { index, text in
            var cell = RustCellData()
            let bytes = Data(text.utf8)
            cell.cluster_offset = UInt32(clusters.count)
            cell.cluster_len = UInt16(bytes.count)
            cell.continuation = continuations.contains(index) ? 1 : 0
            if hidden.contains(index) { cell.flags |= rustCellFlagHidden }
            if index % cols == 0, wrapped.contains(index / cols) { cell.flags |= rustCellFlagWrapped }
            clusters.append(bytes)
            return cell
        }
        return RemoteTerminalRenderState(cells: cells, clusters: clusters, cols: cols,
                                         rows: (cells.count + cols - 1) / cols,
                                         cursorCol: 0, cursorRow: 0, cursorVisible: false,
                                         scrollbackRows: 0, displayOffset: 0)
    }
}
