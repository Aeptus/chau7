import XCTest
@testable import Chau7

final class TerminalCellLayoutTests: XCTestCase {
    /// `TerminalCell` sizes every triple-buffer allocation and every sync
    /// memcpy in the render pipeline. The SIMD4 color members force 16-byte
    /// alignment, so any scalar declared *before* them picks up padding: the
    /// original layout (`clusterStart` first) was size 56 / stride 64 — 20
    /// wasted bytes per cell. Keep the SIMD members first; this test fails
    /// loudly if a future field addition or reorder regresses the stride.
    func testTerminalCellStrideStaysCompact() {
        XCTAssertEqual(MemoryLayout<TerminalCell>.stride, 48)
        XCTAssertLessThanOrEqual(MemoryLayout<TerminalCell>.size, 48)
        XCTAssertEqual(MemoryLayout<TerminalCell>.alignment, 16)
    }
}
