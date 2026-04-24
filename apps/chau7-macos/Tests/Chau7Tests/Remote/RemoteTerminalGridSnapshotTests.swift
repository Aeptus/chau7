import XCTest
@testable import Chau7Core

final class RemoteTerminalGridSnapshotTests: XCTestCase {
    func testRoundTripPreservesMetadataAndCells() throws {
        // 2 cols × 1 row × 16 bytes/cell = 32 bytes
        let cells = Data((0 ..< 32).map(UInt8.init))
        let snapshot = RemoteTerminalGridSnapshot(
            cols: 2,
            rows: 1,
            cursorCol: 1,
            cursorRow: 0,
            cursorVisible: true,
            scrollbackRows: 42,
            displayOffset: 3,
            cells: cells
        )

        let encoded = try XCTUnwrap(snapshot.encode())
        let decoded = try RemoteTerminalGridSnapshot.decode(from: encoded)

        XCTAssertEqual(decoded, snapshot)
    }

    func testDecodeRejectsWrongCellLength() {
        var invalid = Data(capacity: RemoteTerminalGridSnapshotLayout.headerSize)
        invalid.append(RemoteTerminalGridSnapshotLayout.magic)
        invalid.append(RemoteTerminalGridSnapshotLayout.version)
        invalid.appendUInt16LE(2)
        invalid.appendUInt16LE(1)
        invalid.appendUInt16LE(0)
        invalid.appendUInt16LE(0)
        invalid.append(1)
        invalid.append(contentsOf: [0, 0, 0])
        invalid.appendUInt32LE(0)
        invalid.appendUInt32LE(0)
        invalid.appendUInt32LE(1)
        invalid.append(0)

        XCTAssertThrowsError(try RemoteTerminalGridSnapshot.decode(from: invalid))
    }

    // MARK: - Byte-boundary regression

    func testDecodeRejectsTruncatedBelowHeaderSize() {
        // Any payload shorter than the fixed header must fail fast with
        // insufficientData, not crash on index access.
        for length in 0 ..< RemoteTerminalGridSnapshotLayout.headerSize {
            let bytes = Data(repeating: 0, count: length)
            XCTAssertThrowsError(
                try RemoteTerminalGridSnapshot.decode(from: bytes),
                "length=\(length) should throw, not crash or decode garbage"
            )
        }
    }

    func testDecodeRejectsTruncatedCellPayload() throws {
        // Valid header declaring cols=4 rows=2 but cells payload cut to
        // a single byte: must throw insufficientData rather than read
        // out of bounds.
        var bytes = Data(capacity: RemoteTerminalGridSnapshotLayout.headerSize + 1)
        bytes.append(RemoteTerminalGridSnapshotLayout.magic)
        bytes.append(RemoteTerminalGridSnapshotLayout.version)
        bytes.appendUInt16LE(4)       // cols
        bytes.appendUInt16LE(2)       // rows
        bytes.appendUInt16LE(0)       // cursorCol
        bytes.appendUInt16LE(0)       // cursorRow
        bytes.append(1)               // cursorVisible
        bytes.append(contentsOf: [0, 0, 0])
        bytes.appendUInt32LE(0)       // scrollbackRows
        bytes.appendUInt32LE(0)       // displayOffset
        bytes.appendUInt32LE(128)     // claims 128 bytes of cell data
        bytes.append(0xFF)            // only 1 byte of payload actually present

        XCTAssertThrowsError(try RemoteTerminalGridSnapshot.decode(from: bytes))
    }

    func testEmptyGridRoundTrips() throws {
        // cols=0 / rows=0 corresponds to a placeholder snapshot that may
        // be emitted during window teardown or hidden-tab capture. It
        // must round-trip cleanly rather than tripping a bounds-guard.
        let snapshot = RemoteTerminalGridSnapshot(
            cols: 0,
            rows: 0,
            cursorCol: 0,
            cursorRow: 0,
            cursorVisible: false,
            scrollbackRows: 0,
            displayOffset: 0,
            cells: Data()
        )
        let encoded = try XCTUnwrap(snapshot.encode())
        let decoded = try RemoteTerminalGridSnapshot.decode(from: encoded)
        XCTAssertEqual(decoded, snapshot)
    }

    func testAppendReadUInt16LE_roundTripBoundaryValues() throws {
        let cases: [UInt16] = [0, 1, 0x00FF, 0x0100, 0xFFFE, 0xFFFF]
        for value in cases {
            var buffer = Data()
            buffer.appendUInt16LE(value)
            let decoded = try buffer.readUInt16LE(at: 0)
            XCTAssertEqual(decoded, value)
        }
    }

    func testReadUInt16LEThrowsAtExactBoundary() {
        // `readUInt16LE(at: offset)` needs `offset + 2` bytes. A buffer of
        // exactly `offset + 1` must throw, not return garbage.
        let buffer = Data([0x01])
        XCTAssertThrowsError(try buffer.readUInt16LE(at: 0))
    }
}
