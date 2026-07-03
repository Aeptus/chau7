import XCTest
import Chau7Core
@testable import Chau7

/// The extracted MCP + remote control + CTO integration store against an
/// isolated UserDefaults suite.
final class MCPRemoteSettingsStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MCPRemoteSettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshStoreUsesDefaults() {
        let store = MCPRemoteSettingsStore(defaults: defaults)
        XCTAssertEqual(store.tokenOptimizationMode, .off)
        XCTAssertTrue(store.mcpEnabled)
        XCTAssertEqual(store.mcpMaxTabs, 4)
        XCTAssertFalse(store.mcpRequiresApproval)
        XCTAssertTrue(store.mcpShowTabIndicator)
        XCTAssertEqual(store.mcpPermissionMode, .allowAll)
        XCTAssertTrue(store.mcpAllowedCommands.isEmpty)
        XCTAssertTrue(store.mcpBlockedCommands.isEmpty)
        XCTAssertTrue(store.mcpProfiles.isEmpty)
        XCTAssertFalse(store.isRemoteEnabled)
        XCTAssertEqual(store.remoteRelayURL, "wss://relay.chau7.sh/connect")
        XCTAssertFalse(store.isCTOEnabled)
        XCTAssertEqual(store.ctoPrefix, "")
        XCTAssertTrue(store.ctoTabOverrides.isEmpty)
        // The one-time migration marker is set on first load.
        XCTAssertTrue(defaults.bool(forKey: "cto.migrated.v1"))
    }

    func testMutationsPersistAndReload() {
        let store = MCPRemoteSettingsStore(defaults: defaults)
        store.tokenOptimizationMode = .allTabs
        store.mcpEnabled = false
        store.mcpMaxTabs = 9
        store.mcpRequiresApproval = true
        store.mcpShowTabIndicator = false
        store.mcpPermissionMode = .allowlist
        store.mcpAllowedCommands = ["ls", "git status"]
        store.mcpBlockedCommands = ["rm"]
        store.isRemoteEnabled = true
        store.remoteRelayURL = "wss://relay.example.com/connect"
        store.isCTOEnabled = true
        store.ctoPrefix = "be terse"
        store.ctoTabOverrides = ["tab-1": false]

        let reloaded = MCPRemoteSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.tokenOptimizationMode, .allTabs)
        XCTAssertFalse(reloaded.mcpEnabled)
        XCTAssertEqual(reloaded.mcpMaxTabs, 9)
        XCTAssertTrue(reloaded.mcpRequiresApproval)
        XCTAssertFalse(reloaded.mcpShowTabIndicator)
        XCTAssertEqual(reloaded.mcpPermissionMode, .allowlist)
        XCTAssertEqual(reloaded.mcpAllowedCommands, ["ls", "git status"])
        XCTAssertEqual(reloaded.mcpBlockedCommands, ["rm"])
        XCTAssertTrue(reloaded.isRemoteEnabled)
        XCTAssertEqual(reloaded.remoteRelayURL, "wss://relay.example.com/connect")
        XCTAssertTrue(reloaded.isCTOEnabled)
        XCTAssertEqual(reloaded.ctoPrefix, "be terse")
        XCTAssertEqual(reloaded.ctoTabOverrides, ["tab-1": false])
    }

    func testRelayURLTrimmingAndCTOPrefixNormalization() {
        let store = MCPRemoteSettingsStore(defaults: defaults)
        store.remoteRelayURL = "  wss://relay.example.com  "
        XCTAssertEqual(store.remoteRelayURL, "wss://relay.example.com")
        store.ctoPrefix = "line one\nline two"
        XCTAssertEqual(store.ctoPrefix, "line one line two")
    }

    func testLegacyRTKKeysMigrateOnce() {
        defaults.set("aiOnly", forKey: "rtk.mode")
        defaults.set(true, forKey: "feature.rtkEnabled")
        defaults.set("old prefix", forKey: "feature.rtkPrefix")
        defaults.set(false, forKey: "tabs.display.showRTKIndicator")

        let store = MCPRemoteSettingsStore(defaults: defaults)
        XCTAssertEqual(store.tokenOptimizationMode, .aiOnly)
        XCTAssertTrue(store.isCTOEnabled)
        XCTAssertEqual(store.ctoPrefix, "old prefix")
        // The RTK tab-indicator value lands on the TabDisplaySettingsStore key.
        XCTAssertEqual(
            defaults.object(forKey: TabDisplaySettingsStore.Keys.showTabCTOIndicator) as? Bool,
            false
        )
        // Old keys are removed and the marker prevents re-migration.
        XCTAssertNil(defaults.object(forKey: "rtk.mode"))
        XCTAssertNil(defaults.object(forKey: "feature.rtkEnabled"))
        XCTAssertNil(defaults.object(forKey: "feature.rtkPrefix"))
        XCTAssertNil(defaults.object(forKey: "tabs.display.showRTKIndicator"))
        XCTAssertTrue(defaults.bool(forKey: "cto.migrated.v1"))
    }

    func testResetToDefaultsMatchesFreshStore() {
        let store = MCPRemoteSettingsStore(defaults: defaults)
        store.tokenOptimizationMode = .allTabs
        store.mcpEnabled = false
        store.mcpMaxTabs = 1
        store.mcpRequiresApproval = true
        store.mcpShowTabIndicator = false
        store.mcpPermissionMode = .askUnlisted
        store.mcpAllowedCommands = ["ls"]
        store.mcpBlockedCommands = ["rm"]
        store.isRemoteEnabled = true
        store.remoteRelayURL = "wss://relay.example.com"
        store.isCTOEnabled = true
        store.ctoPrefix = "prefix"
        store.ctoTabOverrides = ["tab-1": true]

        store.resetToDefaults()

        let fresh = MCPRemoteSettingsStore(defaults: defaults)
        XCTAssertEqual(store.tokenOptimizationMode, fresh.tokenOptimizationMode)
        XCTAssertEqual(store.mcpEnabled, fresh.mcpEnabled)
        XCTAssertEqual(store.mcpMaxTabs, fresh.mcpMaxTabs)
        XCTAssertEqual(store.mcpRequiresApproval, fresh.mcpRequiresApproval)
        XCTAssertEqual(store.mcpShowTabIndicator, fresh.mcpShowTabIndicator)
        XCTAssertEqual(store.mcpPermissionMode, fresh.mcpPermissionMode)
        XCTAssertEqual(store.mcpAllowedCommands, fresh.mcpAllowedCommands)
        XCTAssertEqual(store.mcpBlockedCommands, fresh.mcpBlockedCommands)
        XCTAssertEqual(store.mcpProfiles, fresh.mcpProfiles)
        XCTAssertEqual(store.isRemoteEnabled, fresh.isRemoteEnabled)
        XCTAssertEqual(store.remoteRelayURL, fresh.remoteRelayURL)
        XCTAssertEqual(store.isCTOEnabled, fresh.isCTOEnabled)
        XCTAssertEqual(store.ctoPrefix, fresh.ctoPrefix)
        XCTAssertEqual(store.ctoTabOverrides, fresh.ctoTabOverrides)
        // Regression guard: MCP returns to enabled with the stock relay URL.
        XCTAssertTrue(store.mcpEnabled)
        XCTAssertEqual(store.remoteRelayURL, "wss://relay.chau7.sh/connect")
    }
}
