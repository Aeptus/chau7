import XCTest
@testable import Chau7

final class LogFileCompactorTests: XCTestCase {
    private var path: String!

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "chau7-compact-\(UUID().uuidString).log"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testCompactsOversizedFileToKeepBytesOnLineBoundary() throws {
        var content = ""
        for i in 0 ..< 2000 {
            content += "line \(i) " + String(repeating: "x", count: 90) + "\n"
        }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        let before = try fileSize()

        let didCompact = LogFileCompactor.compactIfNeeded(path: path, maxBytes: 50000, keepBytes: 20000)

        XCTAssertTrue(didCompact)
        let after = try fileSize()
        XCTAssertLessThan(after, before)
        XCTAssertLessThanOrEqual(after, 20000, "kept region must not exceed keepBytes")

        let result = try String(contentsOfFile: path, encoding: .utf8)
        let firstLine = try XCTUnwrap(result.split(separator: "\n").first)
        XCTAssertTrue(firstLine.hasPrefix("line "), "leading partial line must be dropped; got \(firstLine)")
        XCTAssertTrue(result.contains("line 1999"), "most recent lines must be retained")
    }

    func testNoOpWhenUnderThreshold() throws {
        try "small payload\n".write(toFile: path, atomically: true, encoding: .utf8)

        let didCompact = LogFileCompactor.compactIfNeeded(path: path, maxBytes: 1_000_000, keepBytes: 100_000)

        XCTAssertFalse(didCompact)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "small payload\n")
    }

    func testMissingFileIsNoOp() {
        XCTAssertFalse(LogFileCompactor.compactIfNeeded(path: path + ".missing", maxBytes: 1, keepBytes: 1))
    }

    private func fileSize() throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.size] as? Int) ?? -1
    }
}
