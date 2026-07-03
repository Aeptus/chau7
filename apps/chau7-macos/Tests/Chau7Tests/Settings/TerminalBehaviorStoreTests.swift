import XCTest
@testable import Chau7
@testable import Chau7Core

/// The extracted general terminal behavior store against an isolated
/// UserDefaults suite.
final class TerminalBehaviorStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TerminalBehaviorStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshStoreUsesDefaults() {
        let store = TerminalBehaviorStore(defaults: defaults)
        XCTAssertEqual(store.cursorStyle, "block")
        XCTAssertTrue(store.cursorBlink)
        XCTAssertEqual(store.cursorBlinkRate, 0.6)
        XCTAssertEqual(store.cursorColor, "")
        XCTAssertEqual(store.unicodeAmbiguousWidth, 1)
        XCTAssertEqual(store.scrollbackLines, 10000)
        XCTAssertEqual(store.shellHistoryMaxLines, 1000)
        XCTAssertEqual(store.restoredScrollbackLines, 500)
        XCTAssertEqual(store.runtimeEventJournalCapacity, 1000)
        XCTAssertEqual(store.runtimeOutputChunkLimit, 8192)
        XCTAssertEqual(store.runtimeCostThresholdsUSD, [1, 5, 10])
        XCTAssertFalse(store.isUsageMonitoringEnabled)
        XCTAssertTrue(store.bellEnabled)
        XCTAssertEqual(store.bellSound, "default")
        XCTAssertFalse(store.bellVisual)
        XCTAssertEqual(store.bellRateLimitSeconds, 0.1)
        XCTAssertEqual(store.dangerousCommandHighlightScope, .allOutputs)
        XCTAssertEqual(store.dangerousCommandPatterns, TerminalBehaviorStore.defaultDangerousCommandPatterns)
        XCTAssertTrue(store.dangerousCommandProtectChau7Enabled)
        XCTAssertEqual(store.dangerousCommandProtectChau7Level, .blocking)
        XCTAssertEqual(
            store.dangerousCommandProtectedProcessPatterns,
            TerminalBehaviorStore.defaultDangerousProtectedProcessPatterns
        )
        XCTAssertEqual(store.dangerousOutputHighlightIdleDelayMs, 500)
        XCTAssertEqual(store.dangerousOutputHighlightMaxIntervalMs, 2000)
        XCTAssertTrue(store.dangerousOutputHighlightLowPowerEnabled)
        XCTAssertEqual(store.defaultStartDirectory, RuntimeIsolation.homePath())
    }

    func testMutationsPersistAndReload() {
        let store = TerminalBehaviorStore(defaults: defaults)
        store.cursorStyle = "underline"
        store.cursorBlink = false
        store.cursorBlinkRate = 1.5
        store.unicodeAmbiguousWidth = 2
        store.scrollbackLines = 5000
        store.shellHistoryMaxLines = 250
        store.restoredScrollbackLines = 100
        store.runtimeEventJournalCapacity = 2000
        store.runtimeCostThresholdsUSD = [3, 7]
        store.isUsageMonitoringEnabled = true
        store.bellEnabled = false
        store.bellSound = "Glass"
        store.dangerousCommandHighlightScope = .aiOutputs
        store.dangerousCommandPatterns = ["rm -rf"]
        store.dangerousCommandProtectChau7Level = .warning
        store.dangerousCommandProtectedProcessPatterns = ["  chau7  ", ""]
        store.dangerousOutputHighlightIdleDelayMs = 1000
        store.defaultStartDirectory = "/tmp"

        let reloaded = TerminalBehaviorStore(defaults: defaults)
        XCTAssertEqual(reloaded.cursorStyle, "underline")
        XCTAssertFalse(reloaded.cursorBlink)
        XCTAssertEqual(reloaded.cursorBlinkRate, 1.5)
        XCTAssertEqual(reloaded.unicodeAmbiguousWidth, 2)
        XCTAssertEqual(reloaded.scrollbackLines, 5000)
        XCTAssertEqual(reloaded.shellHistoryMaxLines, 250)
        XCTAssertEqual(reloaded.restoredScrollbackLines, 100)
        XCTAssertEqual(reloaded.runtimeEventJournalCapacity, 2000)
        XCTAssertEqual(reloaded.runtimeCostThresholdsUSD, [3, 7])
        XCTAssertTrue(reloaded.isUsageMonitoringEnabled)
        XCTAssertFalse(reloaded.bellEnabled)
        XCTAssertEqual(reloaded.bellSound, "Glass")
        XCTAssertEqual(reloaded.dangerousCommandHighlightScope, .aiOutputs)
        XCTAssertEqual(reloaded.dangerousCommandPatterns, ["rm -rf"])
        XCTAssertEqual(reloaded.dangerousCommandProtectChau7Level, .warning)
        XCTAssertEqual(reloaded.dangerousCommandProtectedProcessPatterns, ["chau7"])
        XCTAssertEqual(reloaded.dangerousOutputHighlightIdleDelayMs, 1000)
        XCTAssertEqual(reloaded.defaultStartDirectory, "/tmp")
    }

    func testClampingAndNormalization() {
        let store = TerminalBehaviorStore(defaults: defaults)

        store.cursorBlinkRate = 5.0
        XCTAssertEqual(store.cursorBlinkRate, 2.0)
        store.cursorBlinkRate = 0.1
        XCTAssertEqual(store.cursorBlinkRate, 0.3)

        store.unicodeAmbiguousWidth = 7
        XCTAssertEqual(store.unicodeAmbiguousWidth, 1)

        store.scrollbackLines = 5
        XCTAssertEqual(store.scrollbackLines, 100)
        store.scrollbackLines = 999_999
        XCTAssertEqual(store.scrollbackLines, 100_000)

        store.shellHistoryMaxLines = -10
        XCTAssertEqual(store.shellHistoryMaxLines, 0)

        store.restoredScrollbackLines = 99999
        XCTAssertEqual(store.restoredScrollbackLines, 10000)

        store.runtimeEventJournalCapacity = 1
        XCTAssertEqual(store.runtimeEventJournalCapacity, 100)
        store.runtimeOutputChunkLimit = 1
        XCTAssertEqual(store.runtimeOutputChunkLimit, 1024)

        // Thresholds are de-duplicated, filtered to positive values, and sorted.
        store.runtimeCostThresholdsUSD = [5, -1, 5, 2, 0]
        XCTAssertEqual(store.runtimeCostThresholdsUSD, [2, 5])

        store.bellRateLimitSeconds = 120
        XCTAssertEqual(store.bellRateLimitSeconds, 60)

        store.dangerousOutputHighlightIdleDelayMs = 9999
        XCTAssertEqual(store.dangerousOutputHighlightIdleDelayMs, 5000)
        store.dangerousOutputHighlightMaxIntervalMs = 1
        XCTAssertEqual(store.dangerousOutputHighlightMaxIntervalMs, 250)

        // Whitespace-only start directory normalizes back to home.
        store.defaultStartDirectory = "   "
        XCTAssertEqual(store.defaultStartDirectory, RuntimeIsolation.homePath())
    }

    func testLegacyHighlightEnabledKeyMigratesToScope() {
        defaults.set(false, forKey: TerminalBehaviorStore.Keys.dangerousCommandHighlightEnabled)
        let store = TerminalBehaviorStore(defaults: defaults)
        XCTAssertEqual(store.dangerousCommandHighlightScope, DangerousCommandHighlightScope.none)
    }

    func testResetToDefaultsMatchesFreshStore() {
        let store = TerminalBehaviorStore(defaults: defaults)
        store.cursorStyle = "bar"
        store.cursorBlink = false
        store.scrollbackLines = 200
        store.shellHistoryMaxLines = 42
        store.runtimeEventJournalCapacity = 5000
        store.isUsageMonitoringEnabled = true
        store.bellEnabled = false
        store.bellSound = "Ping"
        store.dangerousCommandHighlightScope = DangerousCommandHighlightScope.none
        store.dangerousCommandPatterns = []
        store.dangerousCommandProtectChau7Level = .verboseLogging
        store.defaultStartDirectory = "/tmp"

        store.resetToDefaults()

        let fresh = TerminalBehaviorStore(defaults: defaults)
        XCTAssertEqual(store.cursorStyle, fresh.cursorStyle)
        XCTAssertEqual(store.cursorBlink, fresh.cursorBlink)
        XCTAssertEqual(store.scrollbackLines, fresh.scrollbackLines)
        XCTAssertEqual(store.shellHistoryMaxLines, fresh.shellHistoryMaxLines)
        XCTAssertEqual(store.runtimeEventJournalCapacity, 1000)
        XCTAssertFalse(store.isUsageMonitoringEnabled)
        XCTAssertEqual(store.bellEnabled, fresh.bellEnabled)
        XCTAssertEqual(store.bellSound, fresh.bellSound)
        XCTAssertEqual(store.dangerousCommandHighlightScope, .allOutputs)
        XCTAssertEqual(store.dangerousCommandPatterns, TerminalBehaviorStore.defaultDangerousCommandPatterns)
        XCTAssertEqual(store.dangerousCommandProtectChau7Level, .blocking)
        XCTAssertEqual(store.defaultStartDirectory, RuntimeIsolation.homePath())
    }
}
