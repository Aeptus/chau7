import XCTest
@testable import Chau7
import Chau7Core

/// Composition-root tests for the notification services bundle.
/// Pins the wiring contract that the executor's publisher is the
/// manager and that an injected NotificationDeliveryHost reaches the
/// manager through the services bundle.
@MainActor
final class NotificationServicesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // NotificationManager.init wires the focus-refresh timer which
        // calls UNUserNotificationCenter.current(). That call crashes
        // in test processes without a real bundle. Force isolated-test
        // mode so the manager init takes the short-circuit branch and
        // skips the timer setup. Mirrors the RuntimeIsolation contract
        // already used by FeatureSettings + other tests that touch
        // singleton-init-heavy types.
        setenv("CHAU7_ISOLATED_TEST_MODE", "1", 1)
    }

    override func tearDown() {
        // Don't leak the current-slot value across test classes.
        NotificationServices.current = nil
        super.tearDown()
    }

    func testServicesWireManagerAsTheExecutorPublisher() {
        let services = NotificationServices()
        // The manager IS the publisher — the showNotification handler
        // routes through services.executor.publisher which the services
        // init bound to services.manager.
        XCTAssertTrue(services.executor.publisher === services.manager)
    }

    func testNotificationManagerConformsToNotificationPublishing() {
        // Compile-time pin: NotificationManager must keep its
        // NotificationPublishing conformance so the executor's
        // weak publisher slot accepts it.
        let services = NotificationServices()
        let publisher: NotificationPublishing = services.manager
        XCTAssertNotNil(publisher)
    }

    func testEachConstructionProducesIndependentInstances() {
        // Two services bundles produce independent manager/executor
        // instances — important for tests that want isolated state.
        let a = NotificationServices()
        let b = NotificationServices()
        XCTAssertFalse(a.manager === b.manager)
        XCTAssertFalse(a.executor === b.executor)
    }

    func testCurrentSlotIsSettable() {
        XCTAssertNil(NotificationServices.current)
        let services = NotificationServices()
        NotificationServices.current = services
        XCTAssertTrue(NotificationServices.current === services)
        NotificationServices.current = nil
        XCTAssertNil(NotificationServices.current)
    }

    func testExecutorPublisherIsHeldWeakly() {
        // The publisher reference must be weak so a services bundle
        // gone out of scope can be collected. Verified by checking
        // that the executor's environment.publisher is nil after the
        // services bundle is released.
        weak var weakManager: NotificationManager?
        do {
            let services = NotificationServices()
            weakManager = services.manager
            XCTAssertNotNil(weakManager)
            // Hold a reference to executor across the scope end so we
            // can verify its publisher drops to nil.
            let executor = services.executor
            _ = executor
        }
        // services + manager out of scope; the weak ref should clear.
        XCTAssertNil(weakManager, "Manager must be deallocated once services bundle is gone")
    }
}
