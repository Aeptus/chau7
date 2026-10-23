import XCTest
@testable import Chau7Core

final class TerminalKeyboardInputPolicyTests: XCTestCase {
    func testRoutesEventOnlyToActiveTerminalWindow() {
        XCTAssertTrue(
            shouldRoute(
                isApplicationActive: true,
                isWindowKey: true,
                isWindowOnActiveSpace: true,
                eventTargetsWindow: true,
                terminalOwnsFirstResponder: true
            )
        )
    }

    func testRejectsEventWhenApplicationIsInactive() {
        XCTAssertFalse(shouldRoute(isApplicationActive: false))
    }

    func testRejectsEventWhenWindowIsNotKey() {
        XCTAssertFalse(shouldRoute(isWindowKey: false))
    }

    func testRejectsEventWhenWindowIsOutsideActiveSpace() {
        XCTAssertFalse(shouldRoute(isWindowOnActiveSpace: false))
    }

    func testRejectsEventTargetingAnotherWindow() {
        XCTAssertFalse(shouldRoute(eventTargetsWindow: false))
    }

    func testRejectsEventWhenTerminalDoesNotOwnFirstResponder() {
        XCTAssertFalse(shouldRoute(terminalOwnsFirstResponder: false))
    }

    private func shouldRoute(
        isApplicationActive: Bool = true,
        isWindowKey: Bool = true,
        isWindowOnActiveSpace: Bool = true,
        eventTargetsWindow: Bool = true,
        terminalOwnsFirstResponder: Bool = true
    ) -> Bool {
        TerminalKeyboardInputPolicy.shouldRouteHardwareEvent(
            isApplicationActive: isApplicationActive,
            isWindowKey: isWindowKey,
            isWindowOnActiveSpace: isWindowOnActiveSpace,
            eventTargetsWindow: eventTargetsWindow,
            terminalOwnsFirstResponder: terminalOwnsFirstResponder
        )
    }
}
