import XCTest
@testable import Chau7Core

final class ChangedFilesBudgetTests: XCTestCase {
    func testInitializerAndMutationCapCount() {
        let files = (0 ..< 2000).map { "file-\($0)" }
        var block = CommandBlock(command: "test", startLine: 0, changedFiles: files, changedFilesStatus: .loaded)
        XCTAssertEqual(block.changedFiles.count, 1000)
        XCTAssertTrue(block.changedFilesTruncated)
        block.changedFilesTruncated = false
        block.changedFiles = files
        XCTAssertEqual(block.changedFiles.count, 1000)
        XCTAssertTrue(block.changedFilesTruncated)
    }

    func testEncodedByteBudgetAndOversizedPath() throws {
        let paths = Array(repeating: String(repeating: "\n/", count: 2000), count: 1000)
        let selected = ChangedFilesBudget.select(paths, status: .loaded)
        XCTAssertTrue(selected.truncated)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(selected.files).count, ChangedFilesBudget.maximumEncodedBytes)
        let huge = ChangedFilesBudget.select([String(repeating: "a", count: 100_000)], status: .loaded)
        XCTAssertTrue(huge.files.isEmpty)
        XCTAssertTrue(huge.truncated)
    }

    func testNotGitInitializerAndStatusMutationDropPaths() {
        var block = CommandBlock(command: "test", startLine: 0, changedFiles: ["secret"], changedFilesStatus: .notGitRepo)
        XCTAssertTrue(block.changedFiles.isEmpty)
        block.changedFilesStatus = .loaded
        block.changedFiles = ["secret"]
        block.changedFilesStatus = .notGitRepo
        XCTAssertTrue(block.changedFiles.isEmpty)
        XCTAssertFalse(block.changedFilesTruncated)
    }

    func testLegacyOversizedDecodeIsBoundedAndRoundTripsTruncation() throws {
        let original = CommandBlock(command: "test", startLine: 0, changedFilesStatus: .loaded)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["changedFiles"] = (0 ..< 2000).map { "file-\($0)" }
        object.removeValue(forKey: "changedFilesTruncated")
        let block = try JSONDecoder().decode(CommandBlock.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(block.changedFiles.count, 1000)
        XCTAssertTrue(block.changedFilesTruncated)
        XCTAssertEqual(try JSONDecoder().decode(CommandBlock.self, from: JSONEncoder().encode(block)), block)
        object["changedFilesStatus"] = "notGitRepo"
        let nonGit = try JSONDecoder().decode(CommandBlock.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(nonGit.changedFiles.isEmpty)
        XCTAssertFalse(nonGit.changedFilesTruncated)
    }

    func testLegacyByteLimitedDecodeAndSmallPayloadRemainCompatible() throws {
        let original = CommandBlock(command: "test", startLine: 0, changedFiles: ["a"], changedFilesStatus: .loaded)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["changedFiles"] = Array(repeating: String(repeating: "x", count: 8192), count: 100)
        let block = try JSONDecoder().decode(CommandBlock.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(block.changedFilesTruncated)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(block.changedFiles).count, ChangedFilesBudget.maximumEncodedBytes)
        XCTAssertEqual(try JSONDecoder().decode(CommandBlock.self, from: JSONEncoder().encode(original)), original)
    }
}
