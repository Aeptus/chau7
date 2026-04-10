import XCTest
import Chau7Core

final class LatencyMeasurementSemanticsTests: XCTestCase {
    func testUsesTerminalResponsivenessForPlainShellCommands() {
        XCTAssertEqual(
            LatencyMeasurementSemantics.inputMeasurementKind(
                hasBackgroundAIContext: false,
                detectedLaunchableApp: nil
            ),
            .terminalResponsiveness
        )
    }

    func testUsesAIRoundTripForDetectedAILaunch() {
        XCTAssertEqual(
            LatencyMeasurementSemantics.inputMeasurementKind(
                hasBackgroundAIContext: false,
                detectedLaunchableApp: "Codex"
            ),
            .aiRoundTrip
        )
    }

    func testUsesAIRoundTripForExistingAIContext() {
        XCTAssertEqual(
            LatencyMeasurementSemantics.inputMeasurementKind(
                hasBackgroundAIContext: true,
                detectedLaunchableApp: nil
            ),
            .aiRoundTrip
        )
    }
}
