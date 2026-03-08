import XCTest
@testable import Chau7Core

final class AIDetectionStateTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let state = AIDetectionState()
        XCTAssertNil(state.currentApp)
        XCTAssertNil(state.lastDetectedApp)
        XCTAssertEqual(state.phase, .scanning)
        XCTAssertFalse(state.isRestored)
    }

    // MARK: - Command Detection

    func testHandleCommandSetsDetected() {
        var state = AIDetectionState()
        let changed = state.handleCommand(appName: "Claude")
        XCTAssertTrue(changed)
        XCTAssertEqual(state.currentApp, "Claude")
        XCTAssertEqual(state.phase, .detected)
        XCTAssertEqual(state.lastDetectedApp, "Claude")
        XCTAssertFalse(state.isRestored)
    }

    func testHandleCommandNilIsNoOp() {
        var state = AIDetectionState()
        let changed = state.handleCommand(appName: nil)
        XCTAssertFalse(changed)
        XCTAssertNil(state.currentApp)
        XCTAssertEqual(state.phase, .scanning)
    }

    func testHandleCommandOverridesRestored() {
        var state = AIDetectionState()
        state.handleRestore(appName: "Codex")
        XCTAssertTrue(state.isRestored)

        state.handleCommand(appName: "Claude")
        XCTAssertEqual(state.currentApp, "Claude")
        XCTAssertEqual(state.phase, .detected)
        XCTAssertFalse(state.isRestored)
    }

    // MARK: - Output Detection

    func testHandleOutputMatchFromScanning() {
        var state = AIDetectionState()
        let changed = state.handleOutputMatch(appName: "Gemini")
        XCTAssertTrue(changed)
        XCTAssertEqual(state.currentApp, "Gemini")
        XCTAssertEqual(state.phase, .detected)
    }

    func testHandleOutputMatchNilIsNoOp() {
        var state = AIDetectionState()
        let changed = state.handleOutputMatch(appName: nil)
        XCTAssertFalse(changed)
        XCTAssertEqual(state.phase, .scanning)
    }

    func testHandleOutputMatchOverridesRestored() {
        var state = AIDetectionState()
        state.handleRestore(appName: "Codex")
        state.handleOutputMatch(appName: "Claude")
        XCTAssertEqual(state.currentApp, "Claude")
        XCTAssertFalse(state.isRestored)
    }

    // MARK: - Prompt Return (Cooldown)

    func testPromptReturnWithinCooldownIsNoOp() {
        var state = AIDetectionState()
        state.handleCommand(appName: "Claude")
        // Immediately after detection — within 3s cooldown
        let changed = state.handlePromptReturn()
        XCTAssertFalse(changed)
        XCTAssertEqual(state.currentApp, "Claude")
        XCTAssertEqual(state.phase, .detected)
    }

    func testPromptReturnFromScanningIsNoOp() {
        var state = AIDetectionState()
        let changed = state.handlePromptReturn()
        XCTAssertFalse(changed)
        XCTAssertEqual(state.phase, .scanning)
    }

    // MARK: - Re-detection

    func testRedetectionLockedToSameTool() {
        var state = AIDetectionState()
        state.handleCommand(appName: "Claude")
        // Simulate cooldown expiry by using internal knowledge
        // Force prompt return to work by setting detectedAt in the past
        // We'll test this via the prepareHaystack + handleOutputMatch flow
        state = forceRedetecting(state, lastTool: "Claude")

        // Same tool should re-detect
        let changed = state.handleOutputMatch(appName: "Claude")
        XCTAssertTrue(changed)
        XCTAssertEqual(state.currentApp, "Claude")
        XCTAssertEqual(state.phase, .detected)
    }

    func testRedetectionRejectsDifferentTool() {
        var state = AIDetectionState()
        state = forceRedetecting(state, lastTool: "Claude")

        // Different tool should be rejected
        let changed = state.handleOutputMatch(appName: "Codex")
        XCTAssertFalse(changed)
        XCTAssertNil(state.currentApp)
        XCTAssertEqual(state.phase, .redetecting)
    }

    func testRedetectionWindowExhaustion() {
        var state = AIDetectionState()
        state = forceRedetecting(state, lastTool: "Claude")

        // Exhaust the retry window (30 chunks of no match)
        let chunk = "some random output".data(using: .utf8)!
        for _ in 0...30 {
            _ = state.prepareHaystack(chunk: chunk)
        }

        XCTAssertEqual(state.phase, .scanning)
        XCTAssertNil(state.currentApp)
    }

    func testCommandOverridesRedetection() {
        var state = AIDetectionState()
        state = forceRedetecting(state, lastTool: "Claude")

        // Command detection always wins, even for a different tool
        state.handleCommand(appName: "Codex")
        XCTAssertEqual(state.currentApp, "Codex")
        XCTAssertEqual(state.phase, .detected)
    }

    // MARK: - Restoration

    func testHandleRestore() {
        var state = AIDetectionState()
        let changed = state.handleRestore(appName: "Claude")
        XCTAssertTrue(changed)
        XCTAssertEqual(state.currentApp, "Claude")
        XCTAssertTrue(state.isRestored)
        XCTAssertEqual(state.phase, .restored)
        // Restored sessions don't set lastDetectedApp
        XCTAssertNil(state.lastDetectedApp)
    }

    // MARK: - Exit

    func testHandleExit() {
        var state = AIDetectionState()
        state.handleCommand(appName: "Claude")
        let changed = state.handleExit()
        XCTAssertTrue(changed)
        XCTAssertNil(state.currentApp)
        XCTAssertEqual(state.phase, .scanning)
    }

    func testHandleExitFromScanningIsNoOp() {
        var state = AIDetectionState()
        let changed = state.handleExit()
        XCTAssertFalse(changed)
    }

    func testHandleExitPreservesLastDetectedApp() {
        var state = AIDetectionState()
        state.handleCommand(appName: "Claude")
        state.handleExit()
        XCTAssertEqual(state.lastDetectedApp, "Claude")
    }

    // MARK: - Sliding Buffer

    func testPrepareHaystackReturnsNilWhenDetected() {
        var state = AIDetectionState()
        state.handleCommand(appName: "Claude")
        let chunk = "hello world".data(using: .utf8)!
        let result = state.prepareHaystack(chunk: chunk)
        XCTAssertNil(result)
    }

    func testPrepareHaystackReturnsLowercasedString() {
        var state = AIDetectionState()
        let chunk = "Hello WORLD".data(using: .utf8)!
        let result = state.prepareHaystack(chunk: chunk)
        XCTAssertEqual(result, "hello world")
    }

    func testPrepareHaystackStitchesAcrossChunks() {
        var state = AIDetectionState()
        let chunk1 = "╭─ clau".data(using: .utf8)!
        let chunk2 = "de code".data(using: .utf8)!
        _ = state.prepareHaystack(chunk: chunk1)
        let result = state.prepareHaystack(chunk: chunk2)
        // Should contain the stitched pattern
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("claude code") || result!.contains("clau") && result!.contains("de code"))
    }

    // MARK: - Full Lifecycle

    func testFullLifecycle() {
        var state = AIDetectionState()

        // 1. Start scanning
        XCTAssertEqual(state.phase, .scanning)

        // 2. Detect via command
        state.handleCommand(appName: "Claude")
        XCTAssertEqual(state.phase, .detected)
        XCTAssertEqual(state.currentApp, "Claude")

        // 3. Prompt return within cooldown — no-op
        XCTAssertFalse(state.handlePromptReturn())
        XCTAssertEqual(state.phase, .detected)

        // 4. Exit
        state.handleExit()
        XCTAssertEqual(state.phase, .scanning)
        XCTAssertNil(state.currentApp)
        XCTAssertEqual(state.lastDetectedApp, "Claude")

        // 5. Re-detect via output
        state.handleOutputMatch(appName: "Claude")
        XCTAssertEqual(state.phase, .detected)

        // 6. Restore
        state.handleRestore(appName: "Codex")
        XCTAssertTrue(state.isRestored)
        XCTAssertEqual(state.currentApp, "Codex")

        // 7. Live detection overrides restore
        state.handleOutputMatch(appName: "Aider")
        XCTAssertFalse(state.isRestored)
        XCTAssertEqual(state.currentApp, "Aider")
    }

    // MARK: - Helpers

    /// Creates a state in the `.redetecting` phase with the given last tool.
    /// Uses the internal factory on AIDetectionState (visible via @testable import).
    private func forceRedetecting(_ state: AIDetectionState, lastTool: String) -> AIDetectionState {
        AIDetectionState.makeRedetecting(lastTool: lastTool)
    }
}
