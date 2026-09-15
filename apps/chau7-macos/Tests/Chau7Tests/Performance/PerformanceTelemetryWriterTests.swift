import XCTest
@testable import Chau7

final class PerformanceTelemetryWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-performance-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    func testWritesStructuredJSONLEnvelope() throws {
        let fileURL = directory.appendingPathComponent("performance.jsonl")
        let writer = PerformanceTelemetryWriter(fileURL: fileURL, queueLabel: "test.performance.writer")

        writer.record(
            category: "terminal_work",
            fields: ["count": 3, "bytes": 4_096],
            at: Date(timeIntervalSince1970: 1_000)
        )
        writer.flush()

        let line = try XCTUnwrap(String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").first)
        let data = Data(line.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["category"] as? String, "terminal_work")
        let metrics = try XCTUnwrap(object["metrics"] as? [String: Any])
        XCTAssertEqual(metrics["count"] as? Int, 3)
        XCTAssertEqual(metrics["bytes"] as? Int, 4_096)
    }

    func testRotatesWholeJSONLLinesIntoOneArchive() throws {
        let fileURL = directory.appendingPathComponent("performance.jsonl")
        let writer = PerformanceTelemetryWriter(
            fileURL: fileURL,
            maxBytes: 1,
            queueLabel: "test.performance.rotation"
        )

        writer.record(category: "first", fields: ["value": 1])
        writer.flush()
        writer.record(category: "second", fields: ["value": 2])
        writer.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.archiveURLForTesting.path))
        XCTAssertTrue(try String(contentsOf: writer.archiveURLForTesting).contains("\"first\""))
        XCTAssertTrue(try String(contentsOf: fileURL).contains("\"second\""))
    }
}
