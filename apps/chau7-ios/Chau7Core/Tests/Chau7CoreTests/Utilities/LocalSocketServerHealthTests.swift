import XCTest
@testable import Chau7Core

final class LocalSocketServerHealthTests: XCTestCase {
    func testDoesNotRecoverWhenServerIsNotExpectedToRun() {
        XCTAssertFalse(
            LocalSocketServerHealth.needsRecovery(
                LocalSocketServerHealthSnapshot(
                    expectedRunning: false,
                    isRunning: false,
                    hasSocketDescriptor: false,
                    hasAcceptSource: false,
                    socketPathExists: false
                )
            )
        )
    }

    func testRecoversWhenExpectedServerIsNotRunning() {
        XCTAssertTrue(
            LocalSocketServerHealth.needsRecovery(
                LocalSocketServerHealthSnapshot(
                    expectedRunning: true,
                    isRunning: false,
                    hasSocketDescriptor: false,
                    hasAcceptSource: false,
                    socketPathExists: false
                )
            )
        )
    }

    func testRecoversWhenSocketDescriptorIsMissing() {
        XCTAssertTrue(
            LocalSocketServerHealth.needsRecovery(
                LocalSocketServerHealthSnapshot(
                    expectedRunning: true,
                    isRunning: true,
                    hasSocketDescriptor: false,
                    hasAcceptSource: true,
                    socketPathExists: true
                )
            )
        )
    }

    func testRecoversWhenAcceptSourceIsMissing() {
        XCTAssertTrue(
            LocalSocketServerHealth.needsRecovery(
                LocalSocketServerHealthSnapshot(
                    expectedRunning: true,
                    isRunning: true,
                    hasSocketDescriptor: true,
                    hasAcceptSource: false,
                    socketPathExists: true
                )
            )
        )
    }

    func testRecoversWhenSocketPathIsMissing() {
        XCTAssertTrue(
            LocalSocketServerHealth.needsRecovery(
                LocalSocketServerHealthSnapshot(
                    expectedRunning: true,
                    isRunning: true,
                    hasSocketDescriptor: true,
                    hasAcceptSource: true,
                    socketPathExists: false
                )
            )
        )
    }

    func testHealthyServerDoesNotNeedRecovery() {
        XCTAssertFalse(
            LocalSocketServerHealth.needsRecovery(
                LocalSocketServerHealthSnapshot(
                    expectedRunning: true,
                    isRunning: true,
                    hasSocketDescriptor: true,
                    hasAcceptSource: true,
                    socketPathExists: true
                )
            )
        )
    }
}
