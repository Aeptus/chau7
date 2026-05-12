import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class TelemetryRecorderTests: XCTestCase {
    func testShouldExtractRunContentInBackgroundForCodexImmediateRuns() {
        XCTAssertTrue(
            TelemetryRecorder.shouldExtractRunContentInBackground(
                provider: "codex",
                contentMode: .immediate
            )
        )
        XCTAssertTrue(
            TelemetryRecorder.shouldExtractRunContentInBackground(
                provider: "openai",
                contentMode: .immediate
            )
        )
    }

    func testShouldExtractRunContentInBackgroundStaysSynchronousForNonCodexProviders() {
        XCTAssertFalse(
            TelemetryRecorder.shouldExtractRunContentInBackground(
                provider: "claude",
                contentMode: .immediate
            )
        )
    }

    func testShouldExtractRunContentInBackgroundStaysOffForDeferredShutdown() {
        XCTAssertFalse(
            TelemetryRecorder.shouldExtractRunContentInBackground(
                provider: "codex",
                contentMode: .deferred(reason: "app_termination")
            )
        )
    }
}
#endif
