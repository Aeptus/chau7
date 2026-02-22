import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class SIMDTerminalParserTests: XCTestCase {

    // MARK: - testScanFindsAnsiEscape

    func testScanFindsAnsiEscape() {
        // ESC [ 3 1 m  =  \x1B[31m (red foreground)
        let bytes: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F, // "Hello"
                              0x1B, 0x5B, 0x33, 0x31, 0x6D]  // ESC[31m
        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertTrue(result.hasEscapeSequences,
            "Should detect escape sequence")
        XCTAssertEqual(result.escapePositions, [5],
            "ESC byte should be found at position 5")
    }

    // MARK: - testScanEmptyInput

    func testScanEmptyInput() {
        let bytes: [UInt8] = []
        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertFalse(result.hasEscapeSequences,
            "Empty input should have no escape sequences")
        XCTAssertTrue(result.escapePositions.isEmpty)
        XCTAssertTrue(result.newlinePositions.isEmpty)
        XCTAssertTrue(result.carriageReturnPositions.isEmpty)
        XCTAssertTrue(result.tabPositions.isEmpty)
        XCTAssertTrue(result.bellPositions.isEmpty)
        XCTAssertTrue(result.isPureASCII,
            "Empty input should be considered pure ASCII")
    }

    // MARK: - testScanLargeInput

    func testScanLargeInput() {
        // Create a buffer larger than 64 bytes to exercise multiple SIMD chunks
        var bytes = [UInt8](repeating: 0x41, count: 128) // 128 'A' characters
        // Place escape bytes at various positions spanning multiple 16-byte chunks
        bytes[0] = 0x1B    // chunk 0
        bytes[17] = 0x1B   // chunk 1
        bytes[63] = 0x1B   // chunk 3 (boundary)
        bytes[64] = 0x1B   // chunk 4
        bytes[100] = 0x1B  // chunk 6

        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertEqual(result.escapePositions.count, 5,
            "Should find all 5 escape bytes across multiple SIMD chunks")
        XCTAssertEqual(result.escapePositions, [0, 17, 63, 64, 100])
    }

    // MARK: - testScanNoEscapes

    func testScanNoEscapes() {
        // Plain printable ASCII - no special characters
        let text = "Hello, World! This is plain text."
        let bytes = Array(text.utf8)
        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertFalse(result.hasEscapeSequences,
            "Plain text should have no escape sequences")
        XCTAssertTrue(result.escapePositions.isEmpty)
        XCTAssertTrue(result.isPureASCII,
            "Printable ASCII should be detected as pure ASCII")
    }

    // MARK: - testScanBoundaryDetection

    func testScanBoundaryDetectionAtStart() {
        // Escape at position 0
        var bytes: [UInt8] = [0x1B, 0x5B, 0x6D] // ESC [ m
        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertEqual(result.escapePositions, [0],
            "Should detect escape at start of buffer")
    }

    func testScanBoundaryDetectionAtEnd() {
        // Escape at the very end of the buffer
        var bytes = [UInt8](repeating: 0x41, count: 20)
        bytes[19] = 0x1B

        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertEqual(result.escapePositions, [19],
            "Should detect escape at end of buffer")
    }

    func testScanBoundaryDetectionAtChunkBoundary() {
        // Place escape at position 15 (last byte of first 16-byte chunk)
        // and position 16 (first byte of second chunk)
        var bytes = [UInt8](repeating: 0x41, count: 32)
        bytes[15] = 0x1B
        bytes[16] = 0x1B

        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertEqual(result.escapePositions, [15, 16],
            "Should detect escapes at SIMD chunk boundary")
    }

    // MARK: - Additional Character Detection

    func testScanDetectsNewlines() {
        let bytes: [UInt8] = [0x41, 0x0A, 0x42, 0x0A, 0x43] // A\nB\nC
        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertEqual(result.newlinePositions, [1, 3],
            "Should detect LF at correct positions")
        XCTAssertFalse(result.isPureASCII,
            "Buffer with newlines is not pure printable ASCII")
    }

    func testScanDetectsCarriageReturns() {
        let bytes: [UInt8] = [0x41, 0x0D, 0x0A, 0x42] // A\r\nB
        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertEqual(result.carriageReturnPositions, [1])
        XCTAssertEqual(result.newlinePositions, [2])
    }

    func testScanDetectsTabs() {
        let bytes: [UInt8] = [0x09, 0x41, 0x09, 0x42] // \tA\tB
        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertEqual(result.tabPositions, [0, 2])
    }

    func testScanDetectsBells() {
        let bytes: [UInt8] = [0x41, 0x07, 0x42] // A BEL B
        let result = SIMDTerminalParser.scan(bytes)

        XCTAssertEqual(result.bellPositions, [1])
    }

    // MARK: - isPureASCII

    func testIsPrintableASCIIWithPureASCII() {
        let bytes: [UInt8] = Array("Hello, World!".utf8)
        XCTAssertTrue(SIMDTerminalParser.isPrintableASCII(bytes.withUnsafeBufferPointer { $0 }),
            "Printable ASCII text should return true")
    }

    func testIsPrintableASCIIWithControlChars() {
        let bytes: [UInt8] = [0x41, 0x1B, 0x42] // A ESC B
        let isPure = bytes.withUnsafeBufferPointer { SIMDTerminalParser.isPrintableASCII($0) }
        XCTAssertFalse(isPure,
            "Buffer with ESC should not be pure printable ASCII")
    }

    func testIsPrintableASCIIEmptyBuffer() {
        let bytes: [UInt8] = []
        let isPure = bytes.withUnsafeBufferPointer { SIMDTerminalParser.isPrintableASCII($0) }
        XCTAssertTrue(isPure,
            "Empty buffer should be considered pure printable ASCII")
    }

    // MARK: - CSI / OSC Sequence Parsing

    func testFindCSIEnd() {
        // ESC [ 3 1 m
        let bytes: [UInt8] = [0x1B, 0x5B, 0x33, 0x31, 0x6D]
        let end = bytes.withUnsafeBufferPointer {
            SIMDTerminalParser.findCSIEnd($0, startingAt: 0)
        }
        XCTAssertEqual(end, 5, "CSI sequence should end after final byte 'm'")
    }

    func testFindOSCEnd() {
        // ESC ] 0 ; t i t l e BEL
        let bytes: [UInt8] = [0x1B, 0x5D, 0x30, 0x3B, 0x74, 0x69, 0x74, 0x6C, 0x65, 0x07]
        let end = bytes.withUnsafeBufferPointer {
            SIMDTerminalParser.findOSCEnd($0, startingAt: 0)
        }
        XCTAssertEqual(end, 10, "OSC sequence should end after BEL")
    }

    func testParseEscapeSequences() {
        // Two sequences: ESC[31m (CSI) followed by "text"
        let bytes: [UInt8] = [0x1B, 0x5B, 0x33, 0x31, 0x6D, // ESC[31m
                              0x48, 0x69]                      // Hi
        let sequences = SIMDTerminalParser.parseEscapeSequences(
            bytes.withUnsafeBufferPointer { $0 }
        )

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].type, .csi)
        XCTAssertEqual(sequences[0].csiFinalByte, 0x6D) // 'm'
    }
}
#endif
