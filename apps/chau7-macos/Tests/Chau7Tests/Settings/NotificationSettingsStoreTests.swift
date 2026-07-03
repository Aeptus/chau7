import XCTest
@testable import Chau7
@testable import Chau7Core

/// The extracted notification settings store: loading, persistence
/// round-trips, and didSet normalization — now testable against an isolated
/// UserDefaults suite instead of the process-wide singleton.
final class NotificationSettingsStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "NotificationSettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshStoreSeedsCatalogDefaults() {
        let store = NotificationSettingsStore(defaults: defaults)
        XCTAssertFalse(store.settings.triggerActionBindings.isEmpty)
        XCTAssertNotNil(store.settings.triggerActionBindings["claude_code.failed"])
        XCTAssertEqual(store.settings.triggerActionBindings["claude_code.idle"], [])
        XCTAssertTrue(store.settings.pushTaskCompletionsToiOS, "push completions default on")
        XCTAssertTrue(store.settings.mutedRepos.isEmpty)
    }

    func testMutationPersistsAndReloads() {
        let store = NotificationSettingsStore(defaults: defaults)
        store.settings.pushTaskCompletionsToiOS = false
        store.settings.mutedRepos = ["/tmp/repo": RepoMute(snoozeUntil: nil)]

        let reloaded = NotificationSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.settings.pushTaskCompletionsToiOS, "an explicit off must survive the on-default")
        XCTAssertNotNil(reloaded.settings.mutedRepos["/tmp/repo"])
    }

    func testDidSetSyncsLegacyFiltersFromTriggerState() {
        let store = NotificationSettingsStore(defaults: defaults)
        var state = store.settings.triggerState
        for trigger in NotificationTriggerCatalog.all where trigger.type == "finished" {
            state.setEnabled(false, for: trigger)
        }
        store.settings.triggerState = state
        XCTAssertFalse(
            store.settings.filters.taskFinished,
            "legacy filters must be derived from trigger state on every write"
        )
    }

    func testMigrationsRunOnceAndAreFlagGated() {
        // Seed the literal pre-migration default: red finished border, 30s clear.
        let oldFinished = [NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
            "style": "custom", "customColor": "red", "borderWidth": "2", "autoClearSeconds": "30"
        ])]
        let bindings = ["claude_code.finished": oldFinished]
        defaults.set(
            JSONOperations.encode(bindings, context: "test seed"),
            forKey: NotificationSettingsStore.Keys.triggerActionBindings
        )

        let store = NotificationSettingsStore(defaults: defaults)
        let migrated = store.settings.triggerActionBindings["claude_code.finished"]?
            .first { $0.actionType == .styleTab }
        XCTAssertEqual(migrated?.config["customColor"], "green", "red default migrates to green")
        XCTAssertEqual(migrated?.config["autoClearSeconds"], "0", "auto-clear default migrates to persist-until-open")
        XCTAssertTrue(defaults.bool(forKey: "notification.finished.greenDefault.v1"))
        XCTAssertTrue(defaults.bool(forKey: "notification.finished.persistUntilOpen.v1"))
    }

    func testFacadeForwardsToStore() {
        // The FeatureSettings singleton must observe/mutate the same values
        // consumers see through the store-backed forwarding property.
        let before = FeatureSettings.shared.notificationSettings
        FeatureSettings.shared.notificationSettings.pushTaskCompletionsToiOS.toggle()
        XCTAssertNotEqual(
            FeatureSettings.shared.notificationSettings.pushTaskCompletionsToiOS,
            before.pushTaskCompletionsToiOS
        )
        FeatureSettings.shared.notificationSettings.pushTaskCompletionsToiOS = before.pushTaskCompletionsToiOS
    }
}
