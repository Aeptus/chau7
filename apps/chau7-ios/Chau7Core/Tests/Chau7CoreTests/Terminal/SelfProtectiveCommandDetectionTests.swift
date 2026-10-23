import XCTest
import Chau7Core

final class SelfProtectiveCommandDetectionTests: XCTestCase {
    func testDetectsProtectedKillByPID() {
        let match = SelfProtectiveCommandDetection.detect(
            commandLine: "kill 4242",
            context: SelfProtectiveCommandContext(
                protectedPIDs: [4242],
                protectedProcessNames: ["chau7"]
            )
        )

        XCTAssertEqual(
            match,
            SelfProtectiveCommandDetection.Match(
                command: "kill 4242",
                reason: "would terminate a protected Chau7-managed process"
            )
        )
    }

    func testDetectsProtectedKillAllByName() {
        let match = SelfProtectiveCommandDetection.detect(
            commandLine: "killall Chau7",
            context: SelfProtectiveCommandContext(
                protectedProcessNames: ["chau7"]
            )
        )

        XCTAssertEqual(
            match,
            SelfProtectiveCommandDetection.Match(
                command: "killall Chau7",
                reason: "would target Chau7 or a protected Chau7 helper process"
            )
        )
    }

    func testDetectsProtectedAppleScriptQuit() {
        let match = SelfProtectiveCommandDetection.detect(
            commandLine: #"osascript -e 'quit app "Chau7"'"#,
            context: SelfProtectiveCommandContext(
                protectedProcessNames: ["chau7"]
            )
        )

        XCTAssertEqual(
            match,
            SelfProtectiveCommandDetection.Match(
                command: #"osascript -e 'quit app "Chau7"'"#,
                reason: "would ask macOS to quit Chau7"
            )
        )
    }

    func testIgnoresUnrelatedKill() {
        let match = SelfProtectiveCommandDetection.detect(
            commandLine: "kill 9999",
            context: SelfProtectiveCommandContext(
                protectedPIDs: [4242],
                protectedProcessNames: ["chau7"]
            )
        )

        XCTAssertNil(match)
    }

    func testIgnoresNormalCommand() {
        let match = SelfProtectiveCommandDetection.detect(
            commandLine: "git status",
            context: SelfProtectiveCommandContext(
                protectedPIDs: [4242],
                protectedProcessNames: ["chau7"]
            )
        )

        XCTAssertNil(match)
    }
}
