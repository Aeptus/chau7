import XCTest
@testable import Chau7Core

final class RelayReceiveAcknowledgerTests: XCTestCase {
    private let interval = Int(RelayReceiveAcknowledger.byteInterval)

    func testNothingIsReportedUntilEnoughHasBeenTakenIn() {
        var acknowledger = RelayReceiveAcknowledger()
        acknowledger.noteReceived(bytes: interval - 1)
        XCTAssertNil(acknowledger.totalToAcknowledge(queuedBytes: 0))
        acknowledger.noteReceived(bytes: 1)
        XCTAssertEqual(acknowledger.totalToAcknowledge(queuedBytes: 0), UInt64(interval))
        // The same total is not reported twice.
        XCTAssertNil(acknowledger.totalToAcknowledge(queuedBytes: 0))
    }

    func testBytesStillQueuedAreNotReportedAsTakenIn() {
        var acknowledger = RelayReceiveAcknowledger()
        acknowledger.noteReceived(bytes: 3 * interval)
        XCTAssertEqual(acknowledger.totalToAcknowledge(queuedBytes: 2 * interval), UInt64(interval))
        XCTAssertNil(acknowledger.totalToAcknowledge(queuedBytes: 2 * interval))
        XCTAssertEqual(acknowledger.totalToAcknowledge(queuedBytes: 0), UInt64(3 * interval))
    }

    func testTheFrameIsAHeaderAndTheTotalInLittleEndian() throws {
        let data = RelayReceiveAcknowledger.frame(total: 0x0102_0304_0506_0708)
        XCTAssertEqual(data.count, RemoteFrame.headerSize + 8)
        XCTAssertEqual(data[1], 0x65)
        XCTAssertEqual(Array(data.suffix(8)), [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(try RemoteFrame.decode(from: data).frameType, .relayAck)
    }
}
