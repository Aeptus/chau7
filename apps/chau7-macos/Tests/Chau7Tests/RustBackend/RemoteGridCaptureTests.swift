import XCTest
@testable import Chau7

@MainActor
final class RemoteGridCaptureTests: XCTestCase {
    func testUnchangedDeltaAvoidsFullGridCopyAndFreesBackendSnapshot() throws {
        let backend = FakeTerminalBackend()
        var freed = 0
        backend.gridDeltaProvider = { generation in
            let pointer = UnsafeMutablePointer<RustGridDeltaSnapshot>.allocate(capacity: 1)
            pointer.initialize(to: RustGridDeltaSnapshot(
                cells: nil, clusters_utf8: nil, row_indices: nil,
                clusters_len: 0, clusters_capacity: 0, cells_capacity: 0, row_indices_capacity: 0,
                generation: generation, scrollback_rows: 0, display_offset: 0, row_count: 0,
                cols: 80, rows: 24, cursor_visible: 1, full_refresh: 0,
                _pad0: 0, _pad1: 0, _pad2: 0, _pad3: 0, _pad4: 0, _pad5: 0
            ))
            return (pointer, {
                pointer.deinitialize(count: 1)
                pointer.deallocate()
                freed += 1
            })
        }
        let view = RustTerminalView(frame: .zero)
        view.rustTerminal = backend
        let update = try XCTUnwrap(view.captureRemoteGridUpdate(since: 7))
        XCTAssertEqual(update.generation, 7)
        XCTAssertTrue(update.snapshot.cells.isEmpty)
        XCTAssertEqual(backend.fullGridReadCount, 0)
        XCTAssertEqual(backend.gridDeltaRequests, [7])
        XCTAssertEqual(freed, 1)
    }

    func testLegacyBackendKeepsFullGridFallback() {
        let backend = FakeTerminalBackend()
        let view = RustTerminalView(frame: .zero)
        view.rustTerminal = backend
        XCTAssertNil(view.captureRemoteGridUpdate(since: 4))
        XCTAssertEqual(backend.gridDeltaRequests, [4])
        XCTAssertEqual(backend.fullGridReadCount, 1)
    }
}
