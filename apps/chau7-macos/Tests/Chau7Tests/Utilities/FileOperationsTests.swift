import XCTest
@testable import Chau7

final class FileOperationsTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-fileops-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testAppendDataCreatesParentDirectoryAndAppendsInOrder() throws {
        let url = tempDir
            .appendingPathComponent("nested")
            .appendingPathComponent("pty.log")

        XCTAssertTrue(FileOperations.appendData(Data("hello".utf8), to: url))
        XCTAssertTrue(FileOperations.appendData(Data(" world".utf8), to: url))

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents, "hello world")
    }

    func testAppendDataReturnsFalseWhenTargetIsDirectory() throws {
        let directoryURL = tempDir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        XCTAssertFalse(FileOperations.appendData(Data("x".utf8), to: directoryURL))
    }
}
