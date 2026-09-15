import XCTest
@testable import Chau7Core

final class JSONLTailReaderTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLTailReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileURL = tempDirectory.appendingPathComponent("rollout.jsonl")
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: fileURL)
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testAppendOnlyGrowthReadsOnlyTheDelta() throws {
        try write("{\"a\":1}\n{\"a\":2}\n")

        let first = try XCTUnwrap(JSONLTailReader.readNewChunk(path: fileURL.path, state: nil))
        XCTAssertEqual(first.completeLinesText, "{\"a\":1}\n{\"a\":2}\n")

        try append("{\"a\":3}\n")
        let second = try XCTUnwrap(JSONLTailReader.readNewChunk(path: fileURL.path, state: first.newState))
        XCTAssertEqual(second.completeLinesText, "{\"a\":3}\n", "Second read must return only the appended bytes")
    }

    func testUnchangedFileReturnsNilWithoutReading() throws {
        try write("{\"a\":1}\n")
        let first = try XCTUnwrap(JSONLTailReader.readNewChunk(path: fileURL.path, state: nil))
        XCTAssertNil(
            JSONLTailReader.readNewChunk(path: fileURL.path, state: first.newState),
            "Unchanged file must short-circuit to a single stat"
        )
    }

    func testPartialLineIsCarriedAcrossChunks() throws {
        try write("{\"a\":1}\n{\"par")
        let first = try XCTUnwrap(JSONLTailReader.readNewChunk(path: fileURL.path, state: nil))
        XCTAssertEqual(first.completeLinesText, "{\"a\":1}\n")
        XCTAssertEqual(String(decoding: first.newState.carry, as: UTF8.self), "{\"par")

        try append("tial\":2}\n")
        let second = try XCTUnwrap(JSONLTailReader.readNewChunk(path: fileURL.path, state: first.newState))
        XCTAssertEqual(second.completeLinesText, "{\"partial\":2}\n")
        XCTAssertTrue(second.newState.carry.isEmpty)
    }

    func testTruncationResetsToBoundedTail() throws {
        try write("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n")
        let first = try XCTUnwrap(JSONLTailReader.readNewChunk(path: fileURL.path, state: nil))

        try write("{\"b\":1}\n")
        let second = try XCTUnwrap(JSONLTailReader.readNewChunk(path: fileURL.path, state: first.newState))
        XCTAssertEqual(second.completeLinesText, "{\"b\":1}\n", "Shrunk file must restart from the beginning")
    }

    func testFirstReadOfLargeFileIsBoundedAndLineAligned() throws {
        let filler = String(repeating: "{\"filler\":\"\(String(repeating: "x", count: 100))\"}\n", count: 5000)
        let lastLine = "{\"last\":true}\n"
        try write(filler + lastLine)

        let chunk = try XCTUnwrap(JSONLTailReader.readNewChunk(path: fileURL.path, state: nil))
        XCTAssertLessThanOrEqual(
            UInt64(chunk.completeLinesText.utf8.count),
            JSONLTailReader.firstReadTailBytes,
            "First read of a large file must be bounded"
        )
        XCTAssertTrue(chunk.completeLinesText.hasPrefix("{"), "Bounded first read must start on a line boundary")
        XCTAssertTrue(chunk.completeLinesText.hasSuffix(lastLine), "The newest record must be present")
    }

    func testRolloverToNewFileStartsFresh() throws {
        try write("{\"a\":1}\n")
        let first = try XCTUnwrap(JSONLTailReader.readNewChunk(path: fileURL.path, state: nil))

        let newFile = tempDirectory.appendingPathComponent("rollout-2.jsonl")
        try Data("{\"c\":1}\n".utf8).write(to: newFile)
        let second = try XCTUnwrap(JSONLTailReader.readNewChunk(path: newFile.path, state: first.newState))
        XCTAssertEqual(second.completeLinesText, "{\"c\":1}\n")
        XCTAssertEqual(second.newState.path, newFile.path)
    }

    func testMultiLineObjectSplitAcrossChunksSurvivesViaUnconsumedTail() {
        // A quota event pretty-printed across lines, split across two reads at
        // a line boundary: chunk 1 alone must not parse, and its unconsumed
        // tail + chunk 2 must produce the snapshot.
        let part1 = "{\"timestamp\":\"2026-08-14T10:00:00Z\",\n\"payload\":{\"rate_limits\":{\n"
        let part2 = "\"primary\":{\"used_percent\":41.5}}}}\n"

        let first = CodexRolloutParser.latestQuotaSnapshot(inChunk: part1, rawSourceRef: "test")
        XCTAssertNil(first.snapshot)
        XCTAssertFalse(first.unconsumedTail.isEmpty)

        let combined = first.unconsumedTail + "\n" + part2
        let second = CodexRolloutParser.latestQuotaSnapshot(inChunk: combined, rawSourceRef: "test")
        XCTAssertEqual(second.snapshot?.windows.first?.usedPercent, 41.5)
        XCTAssertTrue(second.unconsumedTail.isEmpty)
    }

    func testChunkScanKeepsLatestOfMultipleQuotaEvents() {
        let chunk = """
        {"timestamp":"2026-08-14T09:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":10}}}}
        {"timestamp":"2026-08-14T10:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":55}}}}

        """
        let result = CodexRolloutParser.latestQuotaSnapshot(inChunk: chunk, rawSourceRef: "test")
        XCTAssertEqual(result.snapshot?.windows.first?.usedPercent, 55)
    }
}
