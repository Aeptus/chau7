import XCTest
@testable import Chau7

final class TerminalTranscriptCaptureTests: XCTestCase {
    func testTailDataKeepsBoundedOutput() {
        let capture = TerminalTranscriptCapture(maxBytes: 10)

        capture.append(Data("12345".utf8))
        capture.append(Data("67890abc".utf8))

        XCTAssertEqual(String(decoding: capture.tailData(maxBytes: 100), as: UTF8.self), "4567890abc")
    }

    func testCommandBoundaryTracksLateDetectionBackfill() {
        let capture = TerminalTranscriptCapture(maxBytes: 100)

        capture.append(Data("old shell output\n".utf8))
        capture.markCommandBoundary()
        capture.append(Data("Welcome to Gemini\n".utf8))

        XCTAssertEqual(
            String(decoding: capture.dataSinceBoundary(), as: UTF8.self),
            "Welcome to Gemini\n"
        )
    }

    func testBoundarySurvivesTrim() {
        let capture = TerminalTranscriptCapture(maxBytes: 12)

        capture.append(Data("abcdef".utf8))
        capture.markCommandBoundary()
        capture.append(Data("ghijklmnop".utf8))

        XCTAssertEqual(String(decoding: capture.tailData(maxBytes: 100), as: UTF8.self), "efghijklmnop")
        XCTAssertEqual(String(decoding: capture.dataSinceBoundary(), as: UTF8.self), "ghijklmnop")
    }

    func testRepeatedSmallAppendsKeepChunkMetadataBoundedAtCapacity() {
        let capture = TerminalTranscriptCapture(maxBytes: 64)

        for value in 0 ..< 10_000 {
            capture.append(Data([UInt8(value % 251)]))
        }

        XCTAssertEqual(capture.tailData(maxBytes: 1_000).count, 64)
        XCTAssertLessThanOrEqual(capture.allocatedChunkSlotCountForTesting, 128)
    }

    func testOversizedAppendRetainsOnlyNewestBytesAcrossChunkBoundary() {
        let capture = TerminalTranscriptCapture(maxBytes: 8)
        capture.append(Data("old".utf8))
        capture.markCommandBoundary()
        capture.append(Data("0123456789".utf8))

        XCTAssertEqual(String(decoding: capture.tailData(maxBytes: 100), as: UTF8.self), "23456789")
        XCTAssertEqual(String(decoding: capture.dataSinceBoundary(), as: UTF8.self), "23456789")
    }
}
