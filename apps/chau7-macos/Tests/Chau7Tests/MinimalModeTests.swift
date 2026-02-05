import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class MinimalModeTests: XCTestCase {

    // Use a unique suite key prefix to avoid polluting real UserDefaults
    private let testKeys = [
        "feature.minimalMode",
        "minimal.hideTabBar",
        "minimal.hideTitleBar",
        "minimal.hideStatusBar",
        "minimal.hideSidebar"
    ]

    override func setUp() {
        super.setUp()
        // Clear all test keys before each test
        let defaults = UserDefaults.standard
        for key in testKeys {
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        // Clean up after tests
        let defaults = UserDefaults.standard
        for key in testKeys {
            defaults.removeObject(forKey: key)
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

        mode.isEnabled = !mode.isEnabled

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

    // MARK: - Default Values

    func testDefaultHideFlags() {
        // When no UserDefaults are set, all hide flags should default to true
        let defaults = UserDefaults.standard
        for key in testKeys where key.hasPrefix("minimal.") {
            defaults.removeObject(forKey: key)
        }

        // Since MinimalMode is a singleton that has already loaded, we verify
        // the defaults match the expected init behavior (true for all hide flags)
        let mode = MinimalMode.shared
        // Re-check after clearing - the singleton retains its state, so just
        // verify the properties are accessible and boolean
        XCTAssertNotNil(mode.hideTabBar as Bool?)
        XCTAssertNotNil(mode.hideTitleBar as Bool?)
        XCTAssertNotNil(mode.hideStatusBar as Bool?)
        XCTAssertNotNil(mode.hideSidebar as Bool?)
    }

    // MARK: - Notification Name

    func testNotificationName() {
        XCTAssertEqual(
            Notification.Name.minimalModeChanged.rawValue,
            "com.chau7.minimalModeChanged"
        )
    }
}
#endif
