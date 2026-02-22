import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class FileMonitorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Lifecycle

    func testStartAndStopWithoutCrash() {
        let fileURL = tempDir.appendingPathComponent("test.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        let monitor = FileMonitor(url: fileURL) {}
        monitor.start()
        monitor.stop()
    }

    func testDoubleStopIsNoop() {
        let fileURL = tempDir.appendingPathComponent("test.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        let monitor = FileMonitor(url: fileURL) {}
        monitor.start()
        monitor.stop()
        monitor.stop() // Should not crash
    }

    func testStopWithoutStartIsNoop() {
        let fileURL = tempDir.appendingPathComponent("test.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        let monitor = FileMonitor(url: fileURL) {}
        monitor.stop() // Should not crash
    }

    func testStartOnNonExistentFileDoesNotCrash() {
        let fileURL = tempDir.appendingPathComponent("nonexistent.txt")
        let monitor = FileMonitor(url: fileURL) {}
        monitor.start()
        monitor.stop()
    }

    // MARK: - Change Detection

    func testDetectsFileWrite() {
        let fileURL = tempDir.appendingPathComponent("watched.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        let expectation = expectation(description: "file change detected")
        let monitor = FileMonitor(url: fileURL) {
            expectation.fulfill()
        }
        monitor.start()

        // Write to file after a short delay
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            try? "modified content".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        wait(for: [expectation], timeout: 2.0)
        monitor.stop()
    }

    // MARK: - URL Property

    func testURLProperty() {
        let fileURL = tempDir.appendingPathComponent("test.txt")
        let monitor = FileMonitor(url: fileURL) {}
        XCTAssertEqual(monitor.url, fileURL)
    }
}
#endif
