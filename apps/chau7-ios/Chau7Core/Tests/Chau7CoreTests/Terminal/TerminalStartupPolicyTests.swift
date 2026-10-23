import XCTest
import Chau7Core

final class TerminalStartupPolicyTests: XCTestCase {
    func testShouldStartTerminalWhenContainerHasSize() {
        XCTAssertTrue(
            TerminalStartupPolicy.shouldStartTerminal(
                isStarted: false,
                containerWidth: 1100,
                containerHeight: 640,
                rustViewWidth: 0,
                rustViewHeight: 0
            )
        )
    }

    func testShouldStartTerminalWhenRustViewHasSize() {
        XCTAssertTrue(
            TerminalStartupPolicy.shouldStartTerminal(
                isStarted: false,
                containerWidth: 0,
                containerHeight: 0,
                rustViewWidth: 1100,
                rustViewHeight: 640
            )
        )
    }

    func testShouldNotStartTerminalTwice() {
        XCTAssertFalse(
            TerminalStartupPolicy.shouldStartTerminal(
                isStarted: true,
                containerWidth: 1100,
                containerHeight: 640,
                rustViewWidth: 1100,
                rustViewHeight: 640
            )
        )
    }

    func testShouldWaitUntilViewHasRealSize() {
        XCTAssertFalse(
            TerminalStartupPolicy.shouldStartTerminal(
                isStarted: false,
                containerWidth: 0,
                containerHeight: 0,
                rustViewWidth: 0,
                rustViewHeight: 0
            )
        )
    }
}
