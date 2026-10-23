import XCTest
@testable import Chau7Core

final class RemoteProtectionTests: XCTestCase {

    func testDetectsTerminateChau7ProcessCommands() {
        XCTAssertEqual(
            RemoteProtection.flaggedTerminationAction(for: "killall Chau7"),
            "Terminate Chau7 on Mac"
        )
        XCTAssertEqual(
            RemoteProtection.flaggedTerminationAction(for: "pkill -f com.chau7.app"),
            "Terminate Chau7 on Mac"
        )
        XCTAssertEqual(
            RemoteProtection.flaggedTerminationAction(for: "kill $(pgrep -f Chau7)"),
            "Terminate Chau7 on Mac"
        )
    }

    func testDetectsLaunchctlDisableCommands() {
        XCTAssertEqual(
            RemoteProtection.flaggedTerminationAction(for: "launchctl bootout gui/501/com.chau7.agent"),
            "Disable Chau7 launch services on Mac"
        )
    }

    func testDetectsQuitViaOsaScript() {
        XCTAssertEqual(
            RemoteProtection.flaggedTerminationAction(for: "osascript -e 'quit app \"Chau7\"'"),
            "Quit Chau7 on Mac"
        )
    }

    func testHandlesMultilineInput() {
        let input = """
        echo safe
        killall chau7
        """

        XCTAssertEqual(
            RemoteProtection.flaggedTerminationAction(for: input),
            "Terminate Chau7 on Mac"
        )
    }

    func testIgnoresUnrelatedCommands() {
        XCTAssertNil(RemoteProtection.flaggedTerminationAction(for: "echo hello"))
        XCTAssertNil(RemoteProtection.flaggedTerminationAction(for: "killall Finder"))
        XCTAssertNil(RemoteProtection.flaggedTerminationAction(for: "launchctl list"))
    }
}
