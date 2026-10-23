import XCTest
@testable import Chau7Core

final class TerminalScrollPolicyTests: XCTestCase {
    func testShellScrollUsesNormalScrollback() {
        let state = TerminalRuntimeState(
            alternateScreenActive: false,
            mouseReportingActive: false,
            scrollbackRows: 42,
            displayOffset: 0,
            transcriptAvailable: true
        )

        XCTAssertEqual(
            TerminalScrollPolicy.action(deltaY: 9, state: state),
            .scrollback(lines: 3)
        )
        XCTAssertEqual(
            TerminalScrollPolicy.action(deltaY: -9, state: state),
            .scrollback(lines: -3)
        )
    }

    func testMouseReportingTUIReceivesScroll() {
        let state = TerminalRuntimeState(
            alternateScreenActive: true,
            mouseReportingActive: true,
            scrollbackRows: 0,
            displayOffset: 0,
            transcriptAvailable: true
        )

        XCTAssertEqual(
            TerminalScrollPolicy.action(deltaY: 12, state: state),
            .forwardToApplication
        )
    }

    func testAlternateScreenWithoutScrollbackUsesTranscriptForHistory() {
        let state = TerminalRuntimeState(
            alternateScreenActive: true,
            mouseReportingActive: false,
            scrollbackRows: 0,
            displayOffset: 0,
            transcriptAvailable: true
        )

        XCTAssertEqual(
            TerminalScrollPolicy.action(deltaY: 12, state: state),
            .transcript(lines: 4)
        )
    }

    func testVisibleTranscriptKeepsConsumingBothDirections() {
        let state = TerminalRuntimeState(
            alternateScreenActive: true,
            mouseReportingActive: false,
            scrollbackRows: 0,
            displayOffset: 0,
            transcriptAvailable: true,
            transcriptOverlayVisible: true
        )

        XCTAssertEqual(
            TerminalScrollPolicy.action(deltaY: -12, state: state),
            .transcript(lines: -4)
        )
    }
}
