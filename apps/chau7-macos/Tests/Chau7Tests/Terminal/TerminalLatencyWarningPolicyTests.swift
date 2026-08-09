import XCTest
@testable import Chau7

final class TerminalLatencyWarningPolicyTests: XCTestCase {
    func testWarningRequiresMatureRepeatedOrSevereSignal() {
        XCTAssertFalse(TerminalSessionModel.shouldWarnForLatencySpike(
            elapsedMs: 160,
            thresholdMs: 100,
            sampleCount: 3,
            p95Ms: 160
        ))
        XCTAssertFalse(TerminalSessionModel.shouldWarnForLatencySpike(
            elapsedMs: 160,
            thresholdMs: 100,
            sampleCount: 120,
            p95Ms: 2
        ))
        XCTAssertTrue(TerminalSessionModel.shouldWarnForLatencySpike(
            elapsedMs: 160,
            thresholdMs: 100,
            sampleCount: 120,
            p95Ms: 110
        ))
        XCTAssertTrue(TerminalSessionModel.shouldWarnForLatencySpike(
            elapsedMs: 300,
            thresholdMs: 100,
            sampleCount: 20,
            p95Ms: 2
        ))
    }
}
