import XCTest
import os.log
@testable import Chau7

final class ManagedProcessTests: XCTestCase {
    func testCleanupClearsReadabilityHandlersAndReferences() {
        let output = Pipe()
        let error = Pipe()
        output.fileHandleForReading.readabilityHandler = { _ in }
        error.fileHandleForReading.readabilityHandler = { _ in }

        var outputPipe: Pipe? = output
        var errorPipe: Pipe? = error

        ManagedProcess.cleanup(outputPipe: &outputPipe, errorPipe: &errorPipe)

        XCTAssertNil(outputPipe)
        XCTAssertNil(errorPipe)
        XCTAssertNil(output.fileHandleForReading.readabilityHandler)
        XCTAssertNil(error.fileHandleForReading.readabilityHandler)
    }

    func testTerminateStopsRunningProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]

        try process.run()
        XCTAssertTrue(process.isRunning)

        ManagedProcess.terminate(
            process,
            name: "sleep",
            logger: Logger(subsystem: "com.chau7.tests", category: "ManagedProcessTests")
        )

        XCTAssertFalse(process.isRunning)
    }
}
