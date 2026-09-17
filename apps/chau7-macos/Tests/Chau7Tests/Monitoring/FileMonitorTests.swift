import XCTest
import Chau7Core
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
        // A single write can surface as multiple dispatch-source events.
        expectation.assertForOverFulfill = false
        let monitor = FileMonitor(url: fileURL) {
            expectation.fulfill()
        }
        monitor.start()

        // start() arms asynchronously on the monitor's queue — give it a beat
        // before mutating the file.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            try? "modified content".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        wait(for: [expectation], timeout: 5.0)
        monitor.stop()
    }

    // MARK: - URL Property

    func testURLProperty() {
        let fileURL = tempDir.appendingPathComponent("test.txt")
        let monitor = FileMonitor(url: fileURL) {}
        XCTAssertEqual(monitor.url, fileURL)
    }

    func testRegistryDeduplicatesCanonicalPathSubscriptions() throws {
        let fileURL = tempDir.appendingPathComponent("shared.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        let aliasURL = tempDir.appendingPathComponent("shared-alias.txt")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: fileURL)
        let registry = FileSystemWatchRegistry(label: "com.chau7.tests.registry-dedup")
        let callbackQueue = DispatchQueue(label: "com.chau7.tests.registry-callback")

        let first = try XCTUnwrap(registry.watch(
            url: fileURL,
            eventMask: [.write, .delete, .rename],
            callbackQueue: callbackQueue,
            handler: { _ in }
        ))
        let second = try XCTUnwrap(registry.watch(
            url: aliasURL,
            eventMask: [.write, .extend, .delete, .rename],
            callbackQueue: callbackQueue,
            handler: { _ in }
        ))

        XCTAssertEqual(registry.activeWatchCountForTesting(), 1)
        XCTAssertEqual(registry.subscriptionCountForTesting(), 2)

        first.cancel()
        registry.drainForTesting()
        XCTAssertEqual(registry.activeWatchCountForTesting(), 1)
        XCTAssertEqual(registry.subscriptionCountForTesting(), 1)

        second.cancel()
        registry.drainForTesting()
        XCTAssertEqual(registry.activeWatchCountForTesting(), 0)
    }

    func testMissingFileUsesParentEventsAfterActiveRetriesExpire() throws {
        let sessionDirectory = tempDir.appendingPathComponent("sessions/missing-session", isDirectory: true)
        let fileURL = sessionDirectory.appendingPathComponent("note.md")
        let registry = FileSystemWatchRegistry(label: "com.chau7.tests.parent-recreation")
        let changed = expectation(description: "recreated file change detected")
        changed.assertForOverFulfill = false
        let monitor = FileMonitor(
            url: fileURL,
            retryPolicy: FileObservationRetryPolicy(activeRetryDuration: 0),
            watchRegistry: registry
        ) {
            changed.fulfill()
        }
        monitor.start()

        waitUntil { registry.activeWatchCountForTesting() == 1 }
        XCTAssertFalse(registry.activePathsForTesting().contains(fileURL.path))

        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        waitUntil { registry.activePathsForTesting().contains(fileURL.path) }
        try "updated".write(to: fileURL, atomically: false, encoding: .utf8)

        wait(for: [changed], timeout: 3)
        monitor.stop()
        waitUntil { registry.activeWatchCountForTesting() == 0 }
    }

    func testRepeatedMissingFileStartStopReleasesParentSubscriptions() {
        let fileURL = tempDir.appendingPathComponent("missing/note.md")
        let registry = FileSystemWatchRegistry(label: "com.chau7.tests.parent-lifecycle")
        let monitor = FileMonitor(
            url: fileURL,
            retryPolicy: FileObservationRetryPolicy(activeRetryDuration: 0),
            watchRegistry: registry
        ) {}

        for _ in 0 ..< 10 {
            monitor.start()
            waitUntil { registry.activeWatchCountForTesting() == 1 }
            XCTAssertEqual(registry.subscriptionCountForTesting(), 1)
            monitor.stop()
            waitUntil { registry.activeWatchCountForTesting() == 0 }
            XCTAssertEqual(registry.subscriptionCountForTesting(), 0)
        }
    }

    func testFileTailerRecoversAfterParentDirectoryDeletion() throws {
        let sessionDirectory = tempDir.appendingPathComponent("sessions/live-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        let registry = FileSystemWatchRegistry(label: "com.chau7.tests.tailer-recreation")
        let received = expectation(description: "tailer receives recreated file content")
        let tailer = FileTailer<String>(
            fileURL: fileURL,
            pollInterval: .milliseconds(100),
            retryPolicy: FileObservationRetryPolicy(activeRetryDuration: 0),
            watchRegistry: registry,
            parser: { $0 },
            onItem: { line in
                if line == "after recreation" {
                    received.fulfill()
                }
            }
        )
        tailer.start()

        try FileManager.default.removeItem(at: sessionDirectory)
        waitUntil { !registry.activePathsForTesting().contains(fileURL.path) }
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        waitUntil { registry.activePathsForTesting().contains(fileURL.path) }
        try Data("after recreation\n".utf8).write(to: fileURL)

        wait(for: [received], timeout: 3)
        tailer.stop()
        waitUntil { registry.activeWatchCountForTesting() == 0 }
    }

    func testWaitUntilLatchesTheFirstSuccessfulObservation() {
        var observations = 0
        waitUntil {
            observations += 1
            return observations == 1
        }
        XCTAssertEqual(observations, 1)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // A watch handoff may briefly change the registry again. Once the
            // awaited state is observed, don't evaluate it a second time.
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}
