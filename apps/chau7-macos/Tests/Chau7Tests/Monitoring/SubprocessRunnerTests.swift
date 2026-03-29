import XCTest
@testable import Chau7Core

final class SubprocessRunnerTests: XCTestCase {
    func testRunCapturesStdout() {
        let output = SubprocessRunner.run(
            executablePath: "/bin/echo",
            arguments: ["chau7"]
        )

        XCTAssertEqual(output, "chau7\n")
    }

    func testRunReturnsNilForMissingExecutable() {
        XCTAssertNil(
            SubprocessRunner.run(
                executablePath: "/path/that/does/not/exist",
                arguments: []
            )
        )
    }
}
