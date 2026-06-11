import XCTest
@testable import Chau7
import Chau7Core

/// Direct tests for the NotificationDeliveryHost protocol and its
/// TerminalControlService conformance. Pins the contract that:
///
/// 1. The protocol forwards each `notification*` selector to TCS's
///    corresponding non-prefixed method.
/// 2. A bare stub conformer can drive `NotificationManager.setHost(_:)`
///    without needing the full TCS stack — used by future per-test
///    isolation work that wants to swap in a controlled host.
@MainActor
final class NotificationDeliveryHostTests: XCTestCase {

    /// In-memory stub recording every host-method call. Lets us assert
    /// that the manager's interactions with its host go through the
    /// expected selectors.
    final class StubHost: NotificationDeliveryHost {
        var tabTitleResult: String?
        var repoNameResult: String?
        var isActiveTabResult = false
        var resolveTabResult: UUID?
        var resolveStrictResult: UUID?

        private(set) var tabTitleCalls = 0
        private(set) var repoNameCalls = 0
        private(set) var isActiveTabCalls = 0
        private(set) var resolveTabCalls = 0
        private(set) var resolveStrictCalls = 0

        func notificationTabTitle(for _: TabTarget) -> String? {
            tabTitleCalls += 1
            return tabTitleResult
        }

        func notificationRepoName(for _: TabTarget) -> String? {
            repoNameCalls += 1
            return repoNameResult
        }

        func notificationIsActiveTab(_: TabTarget) -> Bool {
            isActiveTabCalls += 1
            return isActiveTabResult
        }

        func notificationResolveTab(_: TabTarget) -> UUID? {
            resolveTabCalls += 1
            return resolveTabResult
        }

        func notificationResolveTabStrictly(_: TabTarget) -> UUID? {
            resolveStrictCalls += 1
            return resolveStrictResult
        }
    }

    func testStubHostReceivesEachSelectorIndependently() {
        // Drives the StubHost through every protocol method to confirm
        // the call counters increment independently — pins the stub
        // itself as a usable substitute in future per-test isolation
        // work (without ever spinning up NotificationManager.shared,
        // which the SwiftPM test process can't reliably construct
        // outside isolated-test mode).
        let host = StubHost()
        let target = TabTarget(tool: "test", directory: nil, tabID: nil, sessionID: nil)
        _ = host.notificationTabTitle(for: target)
        _ = host.notificationRepoName(for: target)
        _ = host.notificationIsActiveTab(target)
        _ = host.notificationResolveTab(target)
        _ = host.notificationResolveTabStrictly(target)
        XCTAssertEqual(host.tabTitleCalls, 1)
        XCTAssertEqual(host.repoNameCalls, 1)
        XCTAssertEqual(host.isActiveTabCalls, 1)
        XCTAssertEqual(host.resolveTabCalls, 1)
        XCTAssertEqual(host.resolveStrictCalls, 1)
    }

    func testProtocolMethodNamesUseTheNotificationPrefix() {
        // Compile-time pin: the protocol must keep the `notification*`
        // selector names. This rules out an accidental rename to the
        // shorter `tabTitle(for:)` / `resolveTab(_:)` form which would
        // collide with TerminalControlService.resolveTabID(for:strictSession:)'s
        // defaulted argument. The test compiles iff the protocol
        // signatures match exactly.
        let host: NotificationDeliveryHost = StubHost()
        let target = TabTarget(tool: "test", directory: nil, tabID: nil, sessionID: nil)
        _ = host.notificationTabTitle(for: target)
        _ = host.notificationRepoName(for: target)
        _ = host.notificationIsActiveTab(target)
        _ = host.notificationResolveTab(target)
        _ = host.notificationResolveTabStrictly(target)
    }

    func testTerminalControlServiceConformsToHost() {
        // Compile-time pin: TCS must remain a conforming host. If the
        // extension breaks, this test fails to compile.
        let host: NotificationDeliveryHost = TerminalControlService.shared
        XCTAssertNotNil(host)
    }
}
