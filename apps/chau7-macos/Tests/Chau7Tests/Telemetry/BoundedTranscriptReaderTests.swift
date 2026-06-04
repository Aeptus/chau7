import XCTest
@testable import Chau7Core

final class BoundedTranscriptReaderTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bounded-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func write(_ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReadsWholeFileWhenUnderCap() throws {
        let body = "line1\nline2\nline3\n"
        let reading = try XCTUnwrap(BoundedTranscriptReader.read(at: write(body)))
        XCTAssertNil(reading.truncatedFromBytes)
        XCTAssertEqual(reading.text, body)
    }

    func testTruncatesToTailAndDropsPartialLeadingRecord() throws {
        // 1000 records, each a complete 10-char "lineNNNNNN" + newline (11 bytes).
        let lines = (0 ..< 1000).map { String(format: "line%06d", $0) }
        let body = lines.joined(separator: "\n") + "\n"
        let url = try write(body)
        let total = body.utf8.count

        // A tiny cap forces a tail read spanning the last few records.
        let reading = try XCTUnwrap(BoundedTranscriptReader.read(at: url, maxBytes: 50))
        XCTAssertEqual(reading.truncatedFromBytes, total)

        // The partial leading record is dropped, so every line is a complete
        // 10-char record and the final record is preserved.
        let resultLines = reading.text.split(separator: "\n")
        XCTAssertFalse(resultLines.isEmpty)
        for line in resultLines {
            XCTAssertEqual(line.count, 10, "expected a complete record, got partial: \(line)")
            XCTAssertTrue(line.hasPrefix("line"))
        }
        XCTAssertEqual(resultLines.last.map(String.init), "line000999")
    }

    func testTailRemainsValidWhenSeekLandsMidMultibyteCharacter() throws {
        // Pad with a multibyte char so a byte-offset seek can land mid-sequence;
        // lenient decoding + leading-record drop must still yield clean records.
        let lines = (0 ..< 200).map { "ré\(String(format: "%04d", $0))" }
        let body = lines.joined(separator: "\n") + "\n"
        let url = try write(body)
        let reading = try XCTUnwrap(BoundedTranscriptReader.read(at: url, maxBytes: 33))
        XCTAssertNotNil(reading.truncatedFromBytes)
        XCTAssertTrue(reading.text.contains("ré0199"))
    }

    func testReturnsNilForMissingFile() {
        XCTAssertNil(BoundedTranscriptReader.read(at: tmpDir.appendingPathComponent("nope.jsonl")))
    }

    func testFileSizeReportsBytes() throws {
        XCTAssertEqual(try BoundedTranscriptReader.fileSize(at: write("abcde").path), 5)
        XCTAssertEqual(BoundedTranscriptReader.fileSize(at: "/no/such/path"), 0)
    }
}
