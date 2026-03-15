import XCTest
@testable import Chau7Core

final class ShellLaunchEnvironmentTests: XCTestCase {

    func testPreferredPATHPrependsCommonUserBins() {
        let environment = [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin:/bin"
        ]

        let result = ShellLaunchEnvironment.preferredPATH(environment: environment)

        XCTAssertEqual(
            result,
            "/Users/tester/bin:/Users/tester/.local/bin:/Users/tester/.volta/bin:/Users/tester/.cargo/bin:/Users/tester/.bun/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin"
        )
    }

    func testPreferredPATHFallsBackWhenPATHMissing() {
        let environment = [
            "HOME": "/Users/tester"
        ]

        let result = ShellLaunchEnvironment.preferredPATH(environment: environment)

        XCTAssertTrue(result.contains("/opt/homebrew/bin"))
        XCTAssertTrue(result.contains("/usr/bin"))
        XCTAssertTrue(result.contains("/Users/tester/.volta/bin"))
    }

    func testUserZdotdirPrefersExplicitEnvironment() {
        let environment = [
            "HOME": "/Users/tester",
            "ZDOTDIR": "/Users/tester/.config/zsh"
        ]

        XCTAssertEqual(
            ShellLaunchEnvironment.userZdotdir(environment: environment),
            "/Users/tester/.config/zsh"
        )
    }

    func testUserXDGConfigHomeFallsBackToHomeConfig() {
        let environment = [
            "HOME": "/Users/tester"
        ]

        XCTAssertEqual(
            ShellLaunchEnvironment.userXDGConfigHome(environment: environment),
            "/Users/tester/.config"
        )
    }
}
