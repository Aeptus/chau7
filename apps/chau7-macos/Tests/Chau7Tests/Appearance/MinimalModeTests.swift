import XCTest
@testable import Chau7

@MainActor
final class MinimalModeTests: XCTestCase {

    private let testKeys = [
        "feature.minimalMode",
        "minimal.hideTabBar",
        "minimal.hideTitleBar",
        "minimal.hideStatusBar",
        "minimal.hideSidebar"
    ]

    // Snapshot of the singleton's state so tests restore exactly what they found
    // (MinimalMode.shared persists every mutation straight into UserDefaults).
    private var savedIsEnabled = false
    private var savedHideTabBar = true
    private var savedHideTitleBar = true
    private var savedHideStatusBar = true
    private var savedHideSidebar = true
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let mode = MinimalMode.shared
        savedIsEnabled = mode.isEnabled
        savedHideTabBar = mode.hideTabBar
        savedHideTitleBar = mode.hideTitleBar
        savedHideStatusBar = mode.hideStatusBar
        savedHideSidebar = mode.hideSidebar

        let defaults = UserDefaults.standard
        savedDefaults = [:]
        for key in testKeys {
            if let value = defaults.object(forKey: key) {
                savedDefaults[key] = value
            }
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        // Restore the singleton's in-memory state (the didSets re-persist it),
        // then restore the exact prior UserDefaults values.
        let mode = MinimalMode.shared
        mode.isEnabled = savedIsEnabled
        mode.hideTabBar = savedHideTabBar
        mode.hideTitleBar = savedHideTitleBar
        mode.hideStatusBar = savedHideStatusBar
        mode.hideSidebar = savedHideSidebar

        let defaults = UserDefaults.standard
        for key in testKeys {
            if let value = savedDefaults[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    // MARK: - Toggle Tests

    func testToggle() {
        let mode = MinimalMode.shared
        let initial = mode.isEnabled
        mode.toggle()
        XCTAssertNotEqual(mode.isEnabled, initial)
        mode.toggle()
        XCTAssertEqual(mode.isEnabled, initial)
    }

    func testTogglePersistence() {
        let mode = MinimalMode.shared
        mode.isEnabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "feature.minimalMode"))

        mode.isEnabled = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "feature.minimalMode"))
    }

    // MARK: - Notification Tests

    func testNotificationPosted() {
        let mode = MinimalMode.shared
        let expectation = expectation(forNotification: .minimalModeChanged, object: nil)

        mode.isEnabled.toggle()

        wait(for: [expectation], timeout: 1.0)
    }

    func testNotificationPostedOnToggle() {
        let mode = MinimalMode.shared
        let expectation = expectation(forNotification: .minimalModeChanged, object: nil)

        mode.toggle()

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Individual Element Hiding Tests

    func testHideTabBarPersistence() {
        let mode = MinimalMode.shared
        mode.hideTabBar = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "minimal.hideTabBar"))

        mode.hideTabBar = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "minimal.hideTabBar"))
    }

    func testHideTitleBarPersistence() {
        let mode = MinimalMode.shared
        mode.hideTitleBar = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "minimal.hideTitleBar"))

        mode.hideTitleBar = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "minimal.hideTitleBar"))
    }

    func testHideStatusBarPersistence() {
        let mode = MinimalMode.shared
        mode.hideStatusBar = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "minimal.hideStatusBar"))

        mode.hideStatusBar = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "minimal.hideStatusBar"))
    }

    func testHideSidebarPersistence() {
        let mode = MinimalMode.shared
        mode.hideSidebar = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "minimal.hideSidebar"))

        mode.hideSidebar = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "minimal.hideSidebar"))
    }

    // NOTE: the old testDefaultHideFlags was removed — it asserted
    // `object(forKey:) == nil || bool(forKey:)` right after removing the keys,
    // which is vacuously true and verified nothing about MinimalMode. The
    // singleton's defaults cannot be re-derived after first access (private init).

    // MARK: - Notification Name

    func testNotificationName() {
        XCTAssertEqual(
            Notification.Name.minimalModeChanged.rawValue,
            "com.chau7.minimalModeChanged"
        )
    }
}
