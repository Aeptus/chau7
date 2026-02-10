import XCTest
import Chau7Core

final class FrameParserTests: XCTestCase {

    private func makeFrame(
        type: UInt8 = RemoteFrameType.output.rawValue,
        tabID: UInt32 = 1,
        seq: UInt64 = 0,
        payload: Data = Data([0xAA])
    ) -> RemoteFrame {
        RemoteFrame(type: type, tabID: tabID, seq: seq, payload: payload)
    }

    // MARK: - parseFrames

    func testParsesSingleCompleteFrame() throws {
        let frame = makeFrame()
        var buffer = FrameParser.packForTransport(frame)

        let result = FrameParser.parseFrames(from: &buffer)

        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames.first, frame)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testParsesMultipleFrames() throws {
        let frame1 = makeFrame(tabID: 1, seq: 10)
        let frame2 = makeFrame(tabID: 2, seq: 20)
        let frame3 = makeFrame(tabID: 3, seq: 30)
        var buffer = FrameParser.packForTransport(frame1)
            + FrameParser.packForTransport(frame2)
            + FrameParser.packForTransport(frame3)

        let result = FrameParser.parseFrames(from: &buffer)

        XCTAssertEqual(result.frames.count, 3)
        XCTAssertEqual(result.frames[0], frame1)
        XCTAssertEqual(result.frames[1], frame2)
        XCTAssertEqual(result.frames[2], frame3)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPreservesIncompleteFrame() {
        let frame = makeFrame()
        let packed = FrameParser.packForTransport(frame)
        // Truncate: only provide the length prefix + partial payload
        var buffer = packed.prefix(packed.count - 1)

        let originalBuffer = buffer
        let result = FrameParser.parseFrames(from: &buffer)

        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(buffer, originalBuffer, "Buffer should be preserved for later")
    }

    func testPreservesIncompleteLengthPrefix() {
        var buffer = Data([0x01, 0x02]) // less than 4 bytes

        let originalBuffer = buffer
        let result = FrameParser.parseFrames(from: &buffer)

        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(buffer, originalBuffer)
    }

    func testEmptyBuffer() {
        var buffer = Data()

        let result = FrameParser.parseFrames(from: &buffer)

        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testRejectsZeroLengthFrame() {
        // 4-byte LE encoding of 0
        var buffer = Data([0x00, 0x00, 0x00, 0x00])

        let result = FrameParser.parseFrames(from: &buffer)

        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertGreaterThanOrEqual(result.errors.count, 1)
        // Skip-not-clear: removes 4-byte prefix, buffer becomes empty
        XCTAssertTrue(buffer.count < FrameParser.lengthPrefixSize)

        if let error = result.errors.first as? FrameParsingError {
            XCTAssertEqual(error, .invalidFrameLength(0))
        } else {
            XCTFail("Expected FrameParsingError.invalidFrameLength")
        }
    }

    func testRejectsOversizedFrame() {
        let oversized = FrameParser.defaultMaxFrameSize + 1
        var buffer = Data(count: 4)
        buffer[0] = UInt8(truncatingIfNeeded: oversized)
        buffer[1] = UInt8(truncatingIfNeeded: oversized >> 8)
        buffer[2] = UInt8(truncatingIfNeeded: oversized >> 16)
        buffer[3] = UInt8(truncatingIfNeeded: oversized >> 24)

        let result = FrameParser.parseFrames(from: &buffer)

        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertGreaterThanOrEqual(result.errors.count, 1)
        // Skip-not-clear: removes 4-byte prefix, buffer becomes empty
        XCTAssertTrue(buffer.count < FrameParser.lengthPrefixSize)
    }

    func testCustomMaxFrameSize() {
        let frame = makeFrame(payload: Data(repeating: 0xFF, count: 100))
        var buffer = FrameParser.packForTransport(frame)

        // Use a very small max that the frame exceeds
        let result = FrameParser.parseFrames(from: &buffer, maxFrameSize: 10)

        XCTAssertTrue(result.frames.isEmpty)
        // Skip-not-clear may produce cascading errors as remaining bytes are re-parsed
        XCTAssertGreaterThanOrEqual(result.errors.count, 1)
        XCTAssertTrue(buffer.count < FrameParser.lengthPrefixSize)
    }

    func testDecodeErrorContinuesParsing() {
        // First frame: valid length prefix but corrupt payload (too short for RemoteFrame header)
        var corruptFrame = Data([0x02, 0x00, 0x00, 0x00]) // length = 2
        corruptFrame.append(Data([0xFF, 0xFF])) // 2 bytes, too short for RemoteFrame.decode

        // Second frame: valid
        let validFrame = makeFrame(tabID: 99)
        let validPacked = FrameParser.packForTransport(validFrame)

        var buffer = corruptFrame + validPacked

        let result = FrameParser.parseFrames(from: &buffer)

        XCTAssertEqual(result.frames.count, 1, "Should still parse the valid frame after error")
        XCTAssertEqual(result.frames.first, validFrame)
        XCTAssertEqual(result.errors.count, 1, "Should collect the decode error")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testInvalidLengthSkipsAndContinues() {
        // Valid frame followed by zero-length frame followed by trailing garbage
        let validFrame = makeFrame()
        let validPacked = FrameParser.packForTransport(validFrame)
        let zeroLength = Data([0x00, 0x00, 0x00, 0x00])
        let trailingData = Data(repeating: 0xBB, count: 52) // divisible by 4

        var buffer = validPacked + zeroLength + trailingData

        let result = FrameParser.parseFrames(from: &buffer)

        XCTAssertEqual(result.frames.count, 1, "Should parse the valid frame before the error")
        XCTAssertEqual(result.frames.first, validFrame)
        // Skip-not-clear: zero-length skips 4 bytes, then trailing data produces cascading errors
        XCTAssertGreaterThanOrEqual(result.errors.count, 1)
        XCTAssertTrue(buffer.count < FrameParser.lengthPrefixSize)
    }

    // MARK: - packForTransport

    func testPackForTransportRoundTrip() throws {
        let frame = makeFrame(
            type: RemoteFrameType.ping.rawValue,
            tabID: 42,
            seq: 12345,
            payload: Data("hello".utf8)
        )

        let packed = FrameParser.packForTransport(frame)
        var buffer = packed

        let result = FrameParser.parseFrames(from: &buffer)

        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames.first, frame)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPackForTransportLengthPrefix() {
        let frame = makeFrame(payload: Data(repeating: 0x00, count: 50))
        let packed = FrameParser.packForTransport(frame)

        // First 4 bytes should be the LE-encoded size of the encoded frame
        let encoded = frame.encode()
        let expectedLen = UInt32(encoded.count)

        let b0 = UInt32(packed[0])
        let b1 = UInt32(packed[1]) << 8
        let b2 = UInt32(packed[2]) << 16
        let b3 = UInt32(packed[3]) << 24
        let actualLen = b0 | b1 | b2 | b3

        XCTAssertEqual(actualLen, expectedLen)
        XCTAssertEqual(packed.count, 4 + Int(expectedLen))
    }
}
