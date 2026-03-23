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
}
