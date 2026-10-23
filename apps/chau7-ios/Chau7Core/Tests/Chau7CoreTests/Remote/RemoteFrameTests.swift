import XCTest
@testable import Chau7Core

final class RemoteFrameTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let frame = RemoteFrame(
            version: 1,
            type: RemoteFrameType.output.rawValue,
            flags: 0,
            reserved: 0,
            tabID: 42,
            seq: 9,
            payload: payload
        )

        let encoded = frame.encode()
        let decoded = try RemoteFrame.decode(from: encoded)

        XCTAssertEqual(decoded, frame)
    }

    func testDecodeRejectsShortData() {
        let data = Data([0x01, 0x02])
        XCTAssertThrowsError(try RemoteFrame.decode(from: data))
    }

    func testDecodeRejectsInvalidLength() {
        var data = Data()
        data.append(contentsOf: [1, 2, 3, 4])
        data.append(contentsOf: [0, 0, 0, 0]) // tabID
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0]) // seq
        data.append(contentsOf: [10, 0, 0, 0]) // payload_len=10
        data.append(contentsOf: [1, 2]) // actual payload shorter

        XCTAssertThrowsError(try RemoteFrame.decode(from: data))
    }

    func testHeaderBytesMatchesEncodedHeader() {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let frame = RemoteFrame(
            version: 1,
            type: RemoteFrameType.output.rawValue,
            flags: RemoteFrame.flagEncrypted,
            reserved: 0,
            tabID: 7,
            seq: 99,
            payload: payload
        )

        let header = frame.headerBytes(payloadLen: UInt32(payload.count))
        let encodedHeader = Data(frame.encode().prefix(RemoteFrame.headerSize))

        XCTAssertEqual(header, encodedHeader)
    }

    // MARK: - Edge Cases

    func testEmptyPayloadRoundTrip() throws {
        let frame = RemoteFrame(
            type: RemoteFrameType.ping.rawValue,
            tabID: 1,
            seq: 0,
            payload: Data()
        )

        let encoded = frame.encode()
        let decoded = try RemoteFrame.decode(from: encoded)

        XCTAssertEqual(decoded, frame)
        XCTAssertTrue(decoded.payload.isEmpty)
    }

    func testUInt32MaxTabID() throws {
        let frame = RemoteFrame(
            type: RemoteFrameType.output.rawValue,
            tabID: UInt32.max,
            seq: 0,
            payload: Data([0x01])
        )

        let encoded = frame.encode()
        let decoded = try RemoteFrame.decode(from: encoded)

        XCTAssertEqual(decoded.tabID, UInt32.max)
    }

    func testUInt64MaxSeq() throws {
        let frame = RemoteFrame(
            type: RemoteFrameType.output.rawValue,
            tabID: 1,
            seq: UInt64.max,
            payload: Data([0x01])
        )

        let encoded = frame.encode()
        let decoded = try RemoteFrame.decode(from: encoded)

        XCTAssertEqual(decoded.seq, UInt64.max)
    }

    func testAllFrameTypesRoundTrip() throws {
        for frameType in RemoteFrameType.allCases {
            let frame = RemoteFrame(
                type: frameType.rawValue,
                tabID: 1,
                seq: 1,
                payload: Data([0x00])
            )

            let encoded = frame.encode()
            let decoded = try RemoteFrame.decode(from: encoded)

            XCTAssertEqual(decoded.type, frameType.rawValue, "Round-trip failed for type \(frameType)")
        }
    }

    func testBoundaryValuesAllFields() throws {
        // Version must be 1 for decode to succeed (version validation)
        let frame = RemoteFrame(
            version: 1,
            type: UInt8.max,
            flags: UInt8.max,
            reserved: UInt8.max,
            tabID: UInt32.max,
            seq: UInt64.max,
            payload: Data([0xFF])
        )

        let encoded = frame.encode()
        let decoded = try RemoteFrame.decode(from: encoded)

        XCTAssertEqual(decoded, frame)
    }

    func testDecodeRejectsUnsupportedVersion() {
        let frame = RemoteFrame(
            version: 2,
            type: RemoteFrameType.output.rawValue,
            tabID: 1,
            seq: 0,
            payload: Data([0x01])
        )

        let encoded = frame.encode()
        XCTAssertThrowsError(try RemoteFrame.decode(from: encoded)) { error in
            XCTAssertTrue(error is RemoteFrameError, "Expected RemoteFrameError, got \(error)")
        }
    }

    // MARK: - Byte-boundary regression for DataLittleEndian codecs

    func testAppendReadUInt32LE_roundTripBoundaryValues() throws {
        let cases: [UInt32] = [0, 1, 0x0000_FFFF, 0x0001_0000, 0x7FFF_FFFF, 0xFFFF_FFFF]
        for value in cases {
            var buffer = Data()
            buffer.appendUInt32LE(value)
            let decoded = try buffer.readUInt32LE(at: 0)
            XCTAssertEqual(decoded, value)
        }
    }

    func testAppendReadUInt64LE_roundTripBoundaryValues() throws {
        let cases: [UInt64] = [
            0,
            1,
            0x0000_0000_FFFF_FFFF,
            0x0000_0001_0000_0000,
            0x7FFF_FFFF_FFFF_FFFF,
            0xFFFF_FFFF_FFFF_FFFF
        ]
        for value in cases {
            var buffer = Data()
            buffer.appendUInt64LE(value)
            let decoded = try buffer.readUInt64LE(at: 0)
            XCTAssertEqual(decoded, value)
        }
    }

    func testReadUInt32LEThrowsAtExactBoundary() {
        // Needs `offset + 4` bytes. Buffer of exactly `offset + 3` must throw.
        let buffer = Data([0x01, 0x02, 0x03])
        XCTAssertThrowsError(try buffer.readUInt32LE(at: 0))
    }

    func testReadUInt64LEThrowsAtExactBoundary() {
        // Needs `offset + 8` bytes. Buffer of exactly `offset + 7` must throw.
        let buffer = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        XCTAssertThrowsError(try buffer.readUInt64LE(at: 0))
    }

    func testReadAtNonZeroOffsetRespectsBounds() throws {
        // 16 bytes → last valid UInt32 read starts at offset 12; offset 13
        // must throw (would need bytes 13..16, only 15 available).
        var buffer = Data()
        buffer.appendUInt64LE(0x0123_4567_89AB_CDEF)
        buffer.appendUInt64LE(0xFEDC_BA98_7654_3210)
        let tail = try buffer.readUInt32LE(at: 12)
        XCTAssertEqual(tail, 0xFEDC_BA98)
        XCTAssertThrowsError(try buffer.readUInt32LE(at: 13))
    }

    func testEmptyPayloadRoundTrips() throws {
        // A frame with zero-byte payload must round-trip — this path is
        // exercised by broadcast frames (approvalRequest etc.) that
        // carry no body.
        let frame = RemoteFrame(
            type: RemoteFrameType.output.rawValue,
            tabID: 0,
            seq: 1,
            payload: Data()
        )
        let decoded = try RemoteFrame.decode(from: frame.encode())
        XCTAssertEqual(decoded, frame)
    }
}
