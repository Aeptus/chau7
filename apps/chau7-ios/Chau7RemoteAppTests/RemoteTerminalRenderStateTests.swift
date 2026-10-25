import Chau7Core
import Foundation
import XCTest

final class RemoteTerminalRenderStateTests: XCTestCase {
    func testFoldedCursorUsesMappedCoordinatesAndRejectsInvalidPositions() {
        var display = RemoteTerminalDisplayState(cells: [], clusters: Data(), rowOffsets: [0, 0, 0],
                                                  displayCols: 5, displayRows: 2)
        XCTAssertNil(display.visibleCursor)
        display.cursorVisible = true
        display.cursorCol = 3
        display.cursorRow = 1
        XCTAssertEqual(display.visibleCursor?.column, 3)
        XCTAssertEqual(display.visibleCursor?.row, 1)
        display.cursorCol = 5
        XCTAssertNil(display.visibleCursor)
        display.cursorCol = -1
        XCTAssertNil(display.visibleCursor)
        display.cursorCol = 0
        display.cursorRow = 2
        XCTAssertNil(display.visibleCursor)
    }

    func testFoldedBufferMatchesRust64BitLayout() {
        XCTAssertEqual(MemoryLayout<RustDisplayRowBuffer>.stride, 88)
        XCTAssertEqual(MemoryLayout<RustDisplayRowBuffer>.alignment, 8)
        XCTAssertEqual(MemoryLayout<RustDisplayRowBuffer>.offset(of: \.cursor_col), 80)
        XCTAssertEqual(MemoryLayout<RustDisplayRowBuffer>.offset(of: \.cursor_row), 82)
        XCTAssertEqual(MemoryLayout<RustDisplayRowBuffer>.offset(of: \.cursor_visible), 84)
    }

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

final class RemoteTerminalOutputStoreTests: XCTestCase {
    func testAppendJoinsUTF8ScalarSplitAcrossOutputFramesAndFlushes() {
        var store = RemoteTerminalOutputStore()
        store.append(Data([0xC3]), to: 7)
        _ = store.flushPendingOutput(for: 7)
        XCTAssertEqual(store.visibleOutput(for: 7), "")

        store.append(Data([0xA9]), to: 7)
        _ = store.flushPendingOutput(for: 7)
        XCTAssertEqual(store.visibleOutput(for: 7), "é")
    }

    func testAppendJoinsFourByteScalarSplitAcrossFrames() {
        var store = RemoteTerminalOutputStore()
        store.append(Data([0xF0, 0x9F]), to: 7)
        store.append(Data([0x98, 0x80]), to: 7)
        _ = store.flushPendingOutput(for: 7)
        XCTAssertEqual(store.visibleOutput(for: 7), "😀")
    }

    func testInvalidTrailingBytesStillBecomeReplacementCharacters() {
        var store = RemoteTerminalOutputStore()
        store.append(Data([0xC3]), to: 7)
        store.append(Data([0x78]), to: 7)
        _ = store.flushPendingOutput(for: 7)
        XCTAssertEqual(store.visibleOutput(for: 7), "�x")
    }

    func testUTF8SuffixOffsetIsRelativeToWholeFrame() {
        var store = RemoteTerminalOutputStore()
        store.append(Data("abcdefghij".utf8) + Data([0xF0, 0x9F, 0x98]), to: 7)
        XCTAssertEqual(store.visibleOutput(for: 7), "abcdefghij")
        store.append(Data([0x80]), to: 7)
        XCTAssertEqual(store.visibleOutput(for: 7), "abcdefghij😀")
    }

    func testUTF8SuffixesStayIsolatedBetweenTabsAndSnapshotReplacement() {
        var store = RemoteTerminalOutputStore()
        store.append(Data([0xC3]), to: 7)
        store.append(Data("hello".utf8), to: 8)
        store.replaceSnapshot(Data("reset".utf8), for: 7)
        store.append(Data([0xA9]), to: 7)
        XCTAssertEqual(store.visibleOutput(for: 7), "reset�")
        XCTAssertEqual(store.visibleOutput(for: 8), "hello")
    }

    func testInvalidUTF8PrefixesAreNotHeldIndefinitely() {
        for bytes: [UInt8] in [[0xE0, 0x80], [0xED, 0xA0], [0xF4, 0x90]] {
            var store = RemoteTerminalOutputStore()
            store.append(Data(bytes), to: 7)
            XCTAssertEqual(store.visibleOutput(for: 7), String(decoding: bytes, as: UTF8.self))
        }
    }

    func testRetainedTranscriptRemainsBounded() {
        var store = RemoteTerminalOutputStore()
        let frame = Data(repeating: 0x61, count: RemoteOutputTuning.maxIncomingFrameBytes)
        for _ in 0 ..< 4 {
            store.append(frame, to: 7)
            _ = store.flushPendingOutput(for: 7)
        }
        XCTAssertEqual(store.visibleOutput(for: 7).utf8.count, RemoteOutputTuning.maxRetainedBytes)
    }

    func testFullBufferKeepsTheNewestTailAcrossAmortizedTrims() {
        var store = RemoteTerminalOutputStore()
        // Many small flushes past the cap and its slack: each flush appends,
        // and the visible tail stays exact and ends with the latest output.
        let chunkCount = (RemoteOutputTuning.maxRetainedBytes + RemoteTerminalOutputStore.trimSlackBytes) / 1000 + 50
        for index in 0 ..< chunkCount {
            let chunk = String(format: "%04d", index % 10000) + String(repeating: "x", count: 996)
            store.append(Data(chunk.utf8), to: 7)
            _ = store.flushPendingOutput(for: 7)
        }
        let visible = store.visibleOutput(for: 7)
        XCTAssertEqual(visible.utf8.count, RemoteOutputTuning.maxRetainedBytes)
        XCTAssertTrue(visible.hasSuffix(String(format: "%04d", (chunkCount - 1) % 10000) + String(repeating: "x", count: 996)))
    }
}
