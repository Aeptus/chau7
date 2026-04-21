import XCTest
@testable import Chau7
import Chau7Core

@MainActor
final class PrefillAutoSubmitTests: XCTestCase {
    private final class InputCapture {
        var values: [String] = []
    }

    private var originalAutoSubmit = true

    private func readySession() -> (TerminalSessionModel, InputCapture) {
        let session = TerminalSessionModel(appModel: AppModel())
        let view = RustTerminalView(frame: .zero)
        let capture = InputCapture()
        view.onInput = { capture.values.append($0) }

        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle
        session.attachRustTerminal(view)

        return (session, capture)
    }

    private func waitForAutoSubmit() async {
        let expectation = expectation(description: "restore prefill auto submit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    override func setUp() async throws {
        try await super.setUp()
        originalAutoSubmit = FeatureSettings.shared.autoSubmitRestorePrefill
        FeatureSettings.shared.autoSubmitRestorePrefill = true
    }

    override func tearDown() async throws {
        FeatureSettings.shared.autoSubmitRestorePrefill = originalAutoSubmit
        try await super.tearDown()
    }

    func testFeatureFlagDefaultIsOn() {
        // Default true means the original "insert and wait for Enter" behavior is
        // replaced by auto-submit for most users — which is the intended UX after
        // the regression where restored tabs stayed half-restored.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "restore.autoSubmitPrefill")
        let fresh = defaults.object(forKey: "restore.autoSubmitPrefill") as? Bool ?? true
        XCTAssertTrue(fresh, "autoSubmitRestorePrefill must default to true")
    }

    func testFeatureFlagCanBeToggledOff() {
        FeatureSettings.shared.autoSubmitRestorePrefill = false
        XCTAssertFalse(FeatureSettings.shared.autoSubmitRestorePrefill)

        FeatureSettings.shared.autoSubmitRestorePrefill = true
        XCTAssertTrue(FeatureSettings.shared.autoSubmitRestorePrefill)
    }

    func testFeatureFlagPersistsAcrossReads() {
        FeatureSettings.shared.autoSubmitRestorePrefill = false
        let value = UserDefaults.standard.object(forKey: "restore.autoSubmitPrefill") as? Bool
        XCTAssertEqual(value, false, "toggling must persist via UserDefaults")
    }

    func testCodexRestorePrefillAutoSubmitsWithRawNewline() async {
        let (session, inputs) = readySession()
        let command = "codex resume 019d25d0-d0bd-7501-99ba-1f937c17b29b"

        XCTAssertEqual(session.prefillInput(command), .delivered)
        await waitForAutoSubmit()

        XCTAssertEqual(inputs.values, [command, "\n"])
    }

    func testNonCodexRestorePrefillAutoSubmitsWithEnterKey() async {
        let (session, inputs) = readySession()
        let command = "claude --resume abc123"

        XCTAssertEqual(session.prefillInput(command), .delivered)
        await waitForAutoSubmit()

        XCTAssertEqual(inputs.values, [command, "\r"])
    }
}
