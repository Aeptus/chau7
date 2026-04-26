import XCTest
@testable import Chau7
@testable import Chau7Core

/// SPM-runnable tests for `CommandHistoryManager`'s persistence integration.
///
/// The user-visible contract: per-tab arrow-key history persists across
/// app restarts when "Settings → History → Enable Persistent History" is
/// on. These tests pin the round-trip:
///
///   1. recordCommand writes through to the injected store.
///   2. previousInTab/previousGlobal lazy-bootstrap from the store on
///      first call after construction.
///   3. The `feature.persistentHistory` user default gates BOTH paths.
///   4. Sensitive commands are filtered before they reach the store.
///   5. Bootstrap doesn't clobber an in-memory cache that recordCommand
///      already populated this launch.
///   6. removeTab clears the bootstrap flag so a re-opened tab with the
///      same OverlayTab.id can re-bootstrap.
final class CommandHistoryManagerTests: XCTestCase {

    private static let flagKey = "feature.persistentHistory"

    private var store: PersistentHistoryStore!
    private var savedFlag: Any?

    override func setUp() {
        super.setUp()
        store = PersistentHistoryStore(path: ":memory:")
        store.maxRecords = 200
        savedFlag = UserDefaults.standard.object(forKey: Self.flagKey)
        UserDefaults.standard.set(true, forKey: Self.flagKey)
    }

    override func tearDown() {
        if let savedFlag {
            UserDefaults.standard.set(savedFlag, forKey: Self.flagKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.flagKey)
        }
        store = nil
        super.tearDown()
    }

    // MARK: - Write-through

    func testRecordCommandWritesToPersistentStore() {
        let manager = CommandHistoryManager(persistentStore: store)
        manager.recordCommand("ls -la", tabID: "tab-A", directory: "/tmp")
        manager.recordCommand("git status", tabID: "tab-A", directory: "/tmp/repo")

        store.waitForPendingWrites()
        let rows = store.recentForTab("tab-A", limit: 10)
        XCTAssertEqual(rows.count, 2,
                       "Both non-sensitive commands must reach the persistent store")
        XCTAssertEqual(Set(rows.map(\.command)), Set(["ls -la", "git status"]))
    }

    func testRecordCommandPersistsDirectoryAndShellMetadata() {
        let manager = CommandHistoryManager(persistentStore: store)
        manager.recordCommand("npm test", tabID: "tab-A", directory: "/tmp/repo", shell: "/bin/zsh")

        store.waitForPendingWrites()
        let rows = store.recentForTab("tab-A", limit: 1)
        XCTAssertEqual(rows.first?.directory, "/tmp/repo")
        XCTAssertEqual(rows.first?.shell, "/bin/zsh")
        XCTAssertEqual(rows.first?.tabID, "tab-A")
    }

    // MARK: - Bootstrap on first access

    func testBootstrapsTabHistoryFromPersistentStoreOnFirstAccess() {
        // Simulate prior-launch entries: insert directly via the store.
        for i in 0 ..< 3 {
            store.insert(HistoryRecord(
                command: "cmd-\(i)",
                tabID: "tab-A",
                timestamp: Date().addingTimeInterval(Double(i))
            ))
        }
        store.waitForPendingWrites()

        // Fresh manager (simulates app launch): in-memory caches start empty.
        let manager = CommandHistoryManager(persistentStore: store)

        let mostRecent = manager.previousInTab("tab-A")
        XCTAssertEqual(mostRecent, "cmd-2",
                       "First Up arrow must return the most recent persisted command")

        let secondMostRecent = manager.previousInTab("tab-A")
        XCTAssertEqual(secondMostRecent, "cmd-1")

        let oldest = manager.previousInTab("tab-A")
        XCTAssertEqual(oldest, "cmd-0")

        XCTAssertNil(manager.previousInTab("tab-A"),
                     "Beyond the oldest entry there's nothing to return")
    }

    func testBootstrapsGlobalHistoryOnFirstAccess() {
        store.insert(HistoryRecord(command: "alpha", tabID: "tab-A", timestamp: Date(timeIntervalSinceReferenceDate: 100)))
        store.insert(HistoryRecord(command: "beta", tabID: "tab-B", timestamp: Date(timeIntervalSinceReferenceDate: 200)))
        store.waitForPendingWrites()

        let manager = CommandHistoryManager(persistentStore: store)
        XCTAssertEqual(manager.previousGlobal(), "beta",
                       "Global history must include rows from any tab, newest-first")
        XCTAssertEqual(manager.previousGlobal(), "alpha")
    }

    func testBootstrapIsolatedPerTab() {
        store.insert(HistoryRecord(command: "tab-a-only", tabID: "tab-A", timestamp: Date()))
        store.waitForPendingWrites()

        let manager = CommandHistoryManager(persistentStore: store)
        XCTAssertNil(manager.previousInTab("tab-B"),
                     "Tab B must not see Tab A's persisted entries")
        XCTAssertEqual(manager.previousInTab("tab-A"), "tab-a-only")
    }

    func testBootstrapDoesNotOverwriteInMemoryEntries() {
        // recordCommand populates the in-memory cache for tab-A; a
        // subsequent persistent row from a different launch must not
        // displace it.
        store.insert(HistoryRecord(command: "from-disk", tabID: "tab-A", timestamp: Date()))
        store.waitForPendingWrites()

        let manager = CommandHistoryManager(persistentStore: store)
        manager.recordCommand("just-recorded", tabID: "tab-A")

        XCTAssertEqual(manager.previousInTab("tab-A"), "just-recorded",
                       "Bootstrap must skip when the in-memory cache is already populated")
    }

    // MARK: - Feature flag gating

    func testFeatureFlagDisabledSkipsPersistence() {
        UserDefaults.standard.set(false, forKey: Self.flagKey)
        let manager = CommandHistoryManager(persistentStore: store)
        manager.recordCommand("should-not-persist", tabID: "tab-A")

        store.waitForPendingWrites()
        XCTAssertEqual(store.recentForTab("tab-A", limit: 10).count, 0,
                       "With the feature flag off, write-through must not happen")
    }

    func testFeatureFlagDisabledSkipsBootstrap() {
        store.insert(HistoryRecord(command: "from-disk", tabID: "tab-A", timestamp: Date()))
        store.waitForPendingWrites()

        UserDefaults.standard.set(false, forKey: Self.flagKey)
        let manager = CommandHistoryManager(persistentStore: store)

        XCTAssertNil(manager.previousInTab("tab-A"),
                     "With the feature flag off, bootstrap must not pull rows from the store")
    }

    // MARK: - Security

    func testSensitiveCommandIsNotPersisted() {
        let manager = CommandHistoryManager(persistentStore: store)
        manager.recordCommand("sudo apt update", tabID: "tab-A", isSensitive: true)

        store.waitForPendingWrites()
        XCTAssertEqual(store.recentForTab("tab-A", limit: 10).count, 0,
                       "Sensitive commands must not reach the persistent store")
    }

    func testSensitiveCommandIsNotKeptInMemoryEither() {
        let manager = CommandHistoryManager(persistentStore: store)
        manager.recordCommand("password123", tabID: "tab-A", isSensitive: true)
        XCTAssertNil(manager.previousInTab("tab-A"),
                     "Sensitive commands must not enter the in-memory cache either")
    }

    // MARK: - removeTab clears bootstrap flag

    func testRemoveTabAllowsRebootstrap() {
        store.insert(HistoryRecord(command: "first", tabID: "tab-A", timestamp: Date(timeIntervalSinceReferenceDate: 100)))
        store.waitForPendingWrites()

        let manager = CommandHistoryManager(persistentStore: store)
        XCTAssertEqual(manager.previousInTab("tab-A"), "first")

        manager.removeTab("tab-A")

        // Second-launch state for the same tab — new persisted row arrived.
        store.insert(HistoryRecord(command: "second", tabID: "tab-A", timestamp: Date(timeIntervalSinceReferenceDate: 300)))
        store.waitForPendingWrites()

        XCTAssertEqual(manager.previousInTab("tab-A"), "second",
                       "After removeTab, the next previousInTab call must re-bootstrap from the store")
    }

    // MARK: - Nil store (pure in-memory mode)

    func testNilStoreLeavesInMemoryHistoryFunctional() {
        let manager = CommandHistoryManager(persistentStore: nil)
        manager.recordCommand("ls", tabID: "tab-A")
        manager.recordCommand("pwd", tabID: "tab-A")

        XCTAssertEqual(manager.previousInTab("tab-A"), "pwd")
        XCTAssertEqual(manager.previousInTab("tab-A"), "ls")
    }
}
