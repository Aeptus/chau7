import XCTest
@testable import Chau7Core

final class RemoteGridSnapshotCacheTests: XCTestCase {
    func testDirtyRowsPreserveUnchangedUnicodeAndRebaseClusterOffsets() throws {
        var cache = RemoteGridSnapshotCache()
        _ = cache.encode(update(text: ["é", "👩🏽‍💻"], indices: [0, 1], full: true, generation: 1))
        let payload = try XCTUnwrap(cache.encode(update(text: ["界"], indices: [0], full: false, generation: 2, base: 1)))
        let decoded = try RemoteTerminalGridSnapshot.decode(from: payload)
        XCTAssertEqual(decoded.cells.count, 40)
        XCTAssertEqual(decoded.clusters, Data("界👩🏽‍💻".utf8))
        XCTAssertEqual(try decoded.cells.readUInt32LE(at: 20), UInt32("界".utf8.count))
        XCTAssertEqual(cache.generation, 2)
    }

    func testUnchangedGridDoesNotEncodeOrRetainAnotherFrame() {
        var cache = RemoteGridSnapshotCache()
        _ = cache.encode(update(text: ["a", "b"], indices: [0, 1], full: true, generation: 1))
        let bytes = cache.retainedBytes
        XCTAssertNil(cache.encode(update(text: [], indices: [], full: false, generation: 1, base: 1)))
        XCTAssertEqual(cache.retainedBytes, bytes)
    }

    func testCursorOnlyChangeStillReachesClient() throws {
        var cache = RemoteGridSnapshotCache()
        _ = cache.encode(update(text: ["a", "b"], indices: [0, 1], full: true, generation: 1))
        let payload = try XCTUnwrap(cache.encode(update(text: [], indices: [], full: false, generation: 2, base: 1, cursorRow: 1)))
        XCTAssertEqual(try RemoteTerminalGridSnapshot.decode(from: payload).cursorRow, 1)
    }

    func testReconnectFullSnapshotIsNeverSuppressed() {
        var cache = RemoteGridSnapshotCache()
        let frame = update(text: ["a", "b"], indices: [0, 1], full: true, generation: 1)
        XCTAssertNotNil(cache.encode(frame))
        XCTAssertNotNil(cache.encode(frame))
    }

    func testWrongBaseGenerationResetsCacheAndRequiresFullRefresh() {
        var cache = RemoteGridSnapshotCache()
        _ = cache.encode(update(text: ["a", "b"], indices: [0, 1], full: true, generation: 5))
        XCTAssertNil(cache.encode(update(text: ["x"], indices: [1], full: false, generation: 6, base: 4)))
        XCTAssertEqual(cache.generation, 0)
        XCTAssertEqual(cache.retainedBytes, 0)
    }

    func testOversizedFrameIsDeliveredWithoutRetainingItsCache() {
        var cache = RemoteGridSnapshotCache(maximumBytes: 1)
        XCTAssertNotNil(cache.encode(update(text: ["a", "b"], indices: [0, 1], full: true, generation: 1)))
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertEqual(cache.generation, 0)
    }

    func testIncompleteAndDuplicateFullRowsAreRejected() {
        var cache = RemoteGridSnapshotCache()
        XCTAssertNil(cache.encode(update(text: ["a"], indices: [0], full: true, generation: 1)))
        XCTAssertNil(cache.encode(update(text: ["a", "b"], indices: [0, 0], full: true, generation: 1)))
    }

    func testInvalidClusterOffsetFailsClosed() {
        var cache = RemoteGridSnapshotCache()
        let original = update(text: ["a", "b"], indices: [0, 1], full: true, generation: 1)
        var cells = original.snapshot.cells
        cells[0] = 255
        let invalid = RemoteTerminalGridSnapshot(
            cols: 1, rows: 2, cursorCol: 0, cursorRow: 0, cursorVisible: true,
            scrollbackRows: 0, displayOffset: 0, cells: cells, clusters: original.snapshot.clusters
        )
        XCTAssertNil(cache.encode(RemoteGridUpdate(
            baseGeneration: 0,
            generation: 1,
            fullRefresh: true,
            rowIndices: [0, 1],
            snapshot: invalid
        )))
    }

    func testFullResizeReplacesRetainedRows() throws {
        var cache = RemoteGridSnapshotCache()
        _ = cache.encode(update(text: ["a", "b"], indices: [0, 1], full: true, generation: 1))
        let payload = try XCTUnwrap(cache.encode(update(text: ["c"], indices: [0], full: true, generation: 2, rows: 1)))
        XCTAssertEqual(try RemoteTerminalGridSnapshot.decode(from: payload).clusters, Data("c".utf8))
    }

    private func update(
        text: [String],
        indices: [UInt16],
        full: Bool,
        generation: UInt64,
        base: UInt64 = 0,
        cursorRow: UInt16 = 0,
        rows: UInt16 = 2
    ) -> RemoteGridUpdate {
        var cells = Data()
        var clusters = Data()
        for grapheme in text {
            let bytes = Data(grapheme.utf8)
            cells.appendUInt32LE(UInt32(clusters.count))
            cells.append(Data(repeating: 0, count: 6))
            cells.appendUInt16LE(UInt16(bytes.count))
            cells.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0])
            clusters.append(bytes)
        }
        return RemoteGridUpdate(
            baseGeneration: base, generation: generation, fullRefresh: full, rowIndices: indices,
            snapshot: RemoteTerminalGridSnapshot(
                cols: 1, rows: rows, cursorCol: 0, cursorRow: cursorRow, cursorVisible: true,
                scrollbackRows: 0, displayOffset: 0, cells: cells, clusters: clusters
            )
        )
    }
}
