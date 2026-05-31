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
}
