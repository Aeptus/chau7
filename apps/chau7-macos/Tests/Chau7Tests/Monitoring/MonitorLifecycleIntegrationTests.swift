#if !SWIFT_PACKAGE
import Foundation
import XCTest
@testable import Chau7

final class MonitorLifecycleIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-monitor-lifecycle-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - ProcessResourceMonitor lifecycle

    func testProcessResourceMonitorCancelsPollingAfterStop() {
        let monitor = ProcessResourceMonitor()
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)

        var updateCount = 0
        var stopTime: Date?
        var sawPostStopUpdate = false
        let lock = NSLock()
        let firstUpdate = expectation(description: "first poll update arrives")
        let noUpdateAfterStop = expectation(description: "no update after stop")
        noUpdateAfterStop.isInverted = true

        monitor.onUpdate = { _ in
            lock.lock()
            updateCount += 1
            if updateCount == 1 {
                firstUpdate.fulfill()
            }

            if let stopAt = stopTime,
               Date().timeIntervalSince(stopAt) >= 0.05 {
                sawPostStopUpdate = true
                noUpdateAfterStop.fulfill()
            }
            lock.unlock()
        }

        monitor.start(shellPID: pid)
        wait(for: [firstUpdate], timeout: 3.0)

        monitor.stop()
        lock.lock()
        stopTime = Date()
        let countAtStop = updateCount
        lock.unlock()

        wait(for: [noUpdateAfterStop], timeout: 2.0)

        lock.lock()
        let countAfterStop = updateCount
        let stopped = sawPostStopUpdate
        lock.unlock()

        XCTAssertEqual(countAtStop, countAfterStop)
        XCTAssertFalse(stopped)
    }

    func testProcessResourceMonitorCanRestartWithoutRetainingStaleTimer() {
        let monitor = ProcessResourceMonitor()
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)

        var updateCount = 0
        var shouldExpectSecondPoll = false
        let lock = NSLock()
        let firstPoll = expectation(description: "first poll before restart")
        let secondPoll = expectation(description: "poll after restart")

        monitor.onUpdate = { _ in
            lock.lock()
            updateCount += 1
            if updateCount == 1 {
                firstPoll.fulfill()
            } else if shouldExpectSecondPoll && updateCount >= 2 {
                secondPoll.fulfill()
            }
            lock.unlock()
        }

        monitor.start(shellPID: pid)
        wait(for: [firstPoll], timeout: 3.0)

        monitor.stop()
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock()
        shouldExpectSecondPoll = true
        lock.unlock()

        monitor.start(shellPID: pid)
        wait(for: [secondPoll], timeout: 3.0)
        monitor.stop()

        lock.lock()
        let finalCount = updateCount
        lock.unlock()
        XCTAssertGreaterThanOrEqual(finalCount, 2)
    }

    // MARK: - HistoryIdleMonitor lifecycle

    func testHistoryIdleMonitorStopsSchedulingAfterStop() {
        let historyPath = tempDir.appendingPathComponent("history.jsonl")
        FileManager.default.createFile(atPath: historyPath.path, contents: Data())

        let lock = NSLock()
        var onEntryCount = 0
        var onIdleCount = 0
        var stopAt: Date?
        var sawPostStopIdle = false

        let entrySeen = expectation(description: "history entry observed")
        let idleSeen = expectation(description: "history entry becomes idle")
        let noIdleAfterStop = expectation(description: "no idle update after stop")
        noIdleAfterStop.isInverted = true

        let monitor = HistoryIdleMonitor(
            fileURL: historyPath,
            idleSecondsProvider: { 0.2 },
            staleSecondsProvider: { 5.0 },
            onEntry: { entry in
                lock.lock()
                onEntryCount += 1
                if onEntryCount == 1 {
                    entrySeen.fulfill()
                }
                lock.unlock()
            },
            onStateChange: nil,
            onIdle: { _, _ in
                lock.lock()
                onIdleCount += 1
                if onIdleCount == 1 {
                    idleSeen.fulfill()
                }

                if let stopped = stopAt,
                   Date().timeIntervalSince(stopped) >= 0.05 {
                    sawPostStopIdle = true
                    noIdleAfterStop.fulfill()
                }
                lock.unlock()
            }
        )

        monitor.start()
        appendHistoryEntry(to: historyPath, sessionId: "session-stop", text: "first command")
        wait(for: [entrySeen, idleSeen], timeout: 4.0)

        lock.lock()
        let idleAtStop = onIdleCount
        lock.unlock()

        monitor.stop()
        lock.lock()
        stopAt = Date()
        lock.unlock()

        appendHistoryEntry(to: historyPath, sessionId: "session-stop", text: "after stop")
        wait(for: [noIdleAfterStop], timeout: 2.0)

        lock.lock()
        let idleAfterStop = onIdleCount
        let postStopIdle = sawPostStopIdle
        lock.unlock()

        XCTAssertEqual(idleAtStop, idleAfterStop)
        XCTAssertFalse(postStopIdle)
    }

    func testHistoryIdleMonitorCanRestartAfterStop() {
        let historyPath = tempDir.appendingPathComponent("history_restart.jsonl")
        FileManager.default.createFile(atPath: historyPath.path, contents: Data())

        let lock = NSLock()
        var onEntryCount = 0
        let firstEntry = expectation(description: "first run sees entry")
        let secondEntry = expectation(description: "second run sees entry")

        let monitor = HistoryIdleMonitor(
            fileURL: historyPath,
            idleSecondsProvider: { 0.2 },
            staleSecondsProvider: { 5.0 },
            onEntry: { _ in
                lock.lock()
                onEntryCount += 1
                if onEntryCount == 1 {
                    firstEntry.fulfill()
                } else if onEntryCount == 2 {
                    secondEntry.fulfill()
                }
                lock.unlock()
            }
        )

        monitor.start()
        appendHistoryEntry(to: historyPath, sessionId: "one", text: "first session")
        wait(for: [firstEntry], timeout: 4.0)
        monitor.stop()

        monitor.start()
        appendHistoryEntry(to: historyPath, sessionId: "two", text: "second session")
        wait(for: [secondEntry], timeout: 4.0)
        monitor.stop()

        lock.lock()
        let totalEntries = onEntryCount
        lock.unlock()
        XCTAssertEqual(totalEntries, 2)
    }

    private func appendHistoryEntry(to fileURL: URL, sessionId: String, text: String) {
        let payload = """
        {"session_id":"\(sessionId)","ts":\(Date().timeIntervalSince1970),"text":"\(text)"}
        """

        let line = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n"

        let data = line.data(using: .utf8) ?? Data()
        append(data: data, to: fileURL)
    }

    private func append(data: Data, to fileURL: URL) {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }
        defer { try? handle.close() }
        _ = handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
    }
}
#endif
