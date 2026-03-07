import XCTest
#if !SWIFT_PACKAGE
import SQLite3
@testable import Chau7
@testable import Chau7Core

final class PersistentHistoryStoreTests: XCTestCase {

    private var store: PersistentHistoryStore!

    override func setUp() {
        super.setUp()
        // Use in-memory database for each test for isolation and speed
        store = PersistentHistoryStore(path: ":memory:")
        store.maxRecords = 100
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: - Insert and Retrieve

    func testInsertAndRetrieve() {
        let record = HistoryRecord(
            command: "ls -la",
            directory: "/tmp",
            exitCode: 0,
            shell: "zsh",
            tabID: "tab-1",
            sessionID: "session-1",
            timestamp: Date(),
            duration: 0.5
        )

        store.insertSync(record)

        let results = store.recent(limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.command, "ls -la")
        XCTAssertEqual(results.first?.directory, "/tmp")
        XCTAssertEqual(results.first?.exitCode, 0)
        XCTAssertEqual(results.first?.shell, "zsh")
        XCTAssertEqual(results.first?.tabID, "tab-1")
        XCTAssertEqual(results.first?.sessionID, "session-1")
        XCTAssertNotNil(results.first?.id)
        XCTAssertEqual(results.first?.duration, 0.5)
    }

    func testInsertWithNilOptionals() {
        let record = HistoryRecord(
            command: "echo hello",
            timestamp: Date()
        )

        store.insertSync(record)

        let results = store.recent(limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.command, "echo hello")
        XCTAssertNil(results.first?.directory)
        XCTAssertNil(results.first?.exitCode)
        XCTAssertNil(results.first?.shell)
        XCTAssertNil(results.first?.tabID)
        // sessionID gets filled from store.sessionID when nil
        XCTAssertNotNil(results.first?.sessionID)
        XCTAssertNil(results.first?.duration)
    }

    // MARK: - Search

    func testSearchWithQuery() {
        store.insertSync(HistoryRecord(command: "git status", timestamp: Date()))
        store.insertSync(HistoryRecord(command: "git commit -m 'fix'", timestamp: Date()))
        store.insertSync(HistoryRecord(command: "ls -la", timestamp: Date()))
        store.insertSync(HistoryRecord(command: "npm install", timestamp: Date()))

        let gitResults = store.search(query: "git")
        XCTAssertEqual(gitResults.count, 2)

        let lsResults = store.search(query: "ls")
        XCTAssertEqual(lsResults.count, 1)
        XCTAssertEqual(lsResults.first?.command, "ls -la")

        let noResults = store.search(query: "python")
        XCTAssertTrue(noResults.isEmpty)
    }

    func testSearchWithLimit() {
        for i in 0 ..< 20 {
            store.insertSync(HistoryRecord(
                command: "command-\(i)",
                timestamp: Date().addingTimeInterval(Double(i))
            ))
        }

        let limited = store.search(query: "command", limit: 5)
        XCTAssertEqual(limited.count, 5)
    }

    // MARK: - Recent with Limit

    func testRecentWithLimit() {
        for i in 0 ..< 10 {
            store.insertSync(HistoryRecord(
                command: "cmd-\(i)",
                timestamp: Date().addingTimeInterval(Double(i))
            ))
        }

        let recent3 = store.recent(limit: 3)
        XCTAssertEqual(recent3.count, 3)
        // Most recent first
        XCTAssertEqual(recent3[0].command, "cmd-9")
        XCTAssertEqual(recent3[1].command, "cmd-8")
        XCTAssertEqual(recent3[2].command, "cmd-7")
    }

    func testRecentOrderByTimestamp() {
        let now = Date()
        store.insertSync(HistoryRecord(command: "oldest", timestamp: now.addingTimeInterval(-100)))
        store.insertSync(HistoryRecord(command: "newest", timestamp: now))
        store.insertSync(HistoryRecord(command: "middle", timestamp: now.addingTimeInterval(-50)))

        let results = store.recent(limit: 10)
        XCTAssertEqual(results[0].command, "newest")
        XCTAssertEqual(results[1].command, "middle")
        XCTAssertEqual(results[2].command, "oldest")
    }

    // MARK: - Directory Filtering

    func testRecentForDirectory() {
        store.insertSync(HistoryRecord(command: "ls", directory: "/home", timestamp: Date()))
        store.insertSync(HistoryRecord(command: "pwd", directory: "/tmp", timestamp: Date()))
        store.insertSync(HistoryRecord(command: "cat file", directory: "/home", timestamp: Date()))
        store.insertSync(HistoryRecord(command: "echo hi", directory: "/var", timestamp: Date()))

        let homeResults = store.recentForDirectory("/home")
        XCTAssertEqual(homeResults.count, 2)
        XCTAssertTrue(homeResults.allSatisfy { $0.directory == "/home" })

        let tmpResults = store.recentForDirectory("/tmp")
        XCTAssertEqual(tmpResults.count, 1)
        XCTAssertEqual(tmpResults.first?.command, "pwd")

        let emptyResults = store.recentForDirectory("/nonexistent")
        XCTAssertTrue(emptyResults.isEmpty)
    }

    // MARK: - Frequent Commands

    func testFrequentCommands() {
        let now = Date()
        // "git status" appears 3 times
        for i in 0 ..< 3 {
            store.insertSync(HistoryRecord(command: "git status", timestamp: now.addingTimeInterval(Double(i))))
        }
        // "ls" appears 5 times
        for i in 0 ..< 5 {
            store.insertSync(HistoryRecord(command: "ls", timestamp: now.addingTimeInterval(Double(i + 10))))
        }
        // "pwd" appears once
        store.insertSync(HistoryRecord(command: "pwd", timestamp: now))

        let frequent = store.frequentCommands(limit: 10)
        XCTAssertGreaterThanOrEqual(frequent.count, 3)

        // "ls" should be first (highest count)
        XCTAssertEqual(frequent[0].command, "ls")
        XCTAssertEqual(frequent[0].count, 5)

        // "git status" second
        XCTAssertEqual(frequent[1].command, "git status")
        XCTAssertEqual(frequent[1].count, 3)

        // "pwd" last
        XCTAssertEqual(frequent[2].command, "pwd")
        XCTAssertEqual(frequent[2].count, 1)
    }

    func testFrequentCommandsLimit() {
        for i in 0 ..< 10 {
            store.insertSync(HistoryRecord(
                command: "unique-cmd-\(i)",
                timestamp: Date()
            ))
        }

        let limited = store.frequentCommands(limit: 3)
        XCTAssertEqual(limited.count, 3)
    }

    // MARK: - Total Count

    func testTotalCount() {
        XCTAssertEqual(store.totalCount(), 0)

        store.insertSync(HistoryRecord(command: "a", timestamp: Date()))
        XCTAssertEqual(store.totalCount(), 1)

        store.insertSync(HistoryRecord(command: "b", timestamp: Date()))
        XCTAssertEqual(store.totalCount(), 2)
    }

    // MARK: - Clear Operations

    func testClearAll() {
        for i in 0 ..< 5 {
            store.insertSync(HistoryRecord(command: "cmd-\(i)", timestamp: Date()))
        }
        XCTAssertEqual(store.totalCount(), 5)

        store.clearAll()
        XCTAssertEqual(store.totalCount(), 0)
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testClearOlderThan() {
        let now = Date()
        // Insert old records (60 days ago)
        for i in 0 ..< 3 {
            store.insertSync(HistoryRecord(
                command: "old-\(i)",
                timestamp: now.addingTimeInterval(-60 * 86400 + Double(i))
            ))
        }
        // Insert recent records (1 day ago)
        for i in 0 ..< 2 {
            store.insertSync(HistoryRecord(
                command: "new-\(i)",
                timestamp: now.addingTimeInterval(-86400 + Double(i))
            ))
        }

        XCTAssertEqual(store.totalCount(), 5)

        store.clearOlderThan(days: 30)

        XCTAssertEqual(store.totalCount(), 2)
        let remaining = store.recent(limit: 10)
        XCTAssertTrue(remaining.allSatisfy { $0.command.hasPrefix("new-") })
    }

    // MARK: - Trim at Capacity

    func testTrimAtCapacity() {
        store.maxRecords = 5

        for i in 0 ..< 10 {
            store.insertSync(HistoryRecord(
                command: "cmd-\(i)",
                timestamp: Date().addingTimeInterval(Double(i))
            ))
        }

        // After inserting 10 records with maxRecords=5, should trim to 5
        XCTAssertLessThanOrEqual(store.totalCount(), 5)

        // The most recent records should survive
        let remaining = store.recent(limit: 10)
        XCTAssertTrue(remaining.contains { $0.command == "cmd-9" })
    }

    // MARK: - Export / Import

    func testExportImportRoundTrip() {
        let now = Date()
        store.insertSync(HistoryRecord(command: "exported-cmd", directory: "/test", exitCode: 0, shell: "zsh", timestamp: now))

        guard let jsonData = store.exportJSON() else {
            XCTFail("Export returned nil")
            return
        }

        // Create a fresh store and import
        let store2 = PersistentHistoryStore(path: ":memory:")
        let count = store2.importJSON(jsonData)
        XCTAssertEqual(count, 1)

        let imported = store2.recent(limit: 10)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.command, "exported-cmd")
        XCTAssertEqual(imported.first?.directory, "/test")
    }
}
#endif
