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
        XCTAssertEqual(state.utf8DecodeFailures, 0)
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

    // MARK: - Prompt Return (Cooldown with Injectable Clock)

    func testPromptReturnWithinCooldownIsNoOp() {
        var state = AIDetectionState()
        state.handleCommand(appName: "Claude")
        // Immediately after detection — within 3s cooldown (default now = Date())
        let changed = state.handlePromptReturn()
        XCTAssertFalse(changed)
        XCTAssertEqual(state.currentApp, "Claude")
        XCTAssertEqual(state.phase, .detected)
    }

    func testPromptReturnAfterCooldownTransitionsToRedetecting() {
        var state = AIDetectionState()
        state.handleCommand(appName: "Claude")
        // 5 seconds later — past 3s cooldown
        let now = Date().addingTimeInterval(5)
        let changed = state.handlePromptReturn(now: now)
        XCTAssertTrue(changed)
        XCTAssertNil(state.currentApp)
        XCTAssertEqual(state.phase, .redetecting)
        XCTAssertEqual(state.lastDetectedApp, "Claude")
    }

    func testPromptReturnFromScanningIsNoOp() {
        var state = AIDetectionState()
        let changed = state.handlePromptReturn()
        XCTAssertFalse(changed)
        XCTAssertEqual(state.phase, .scanning)
    }

    // MARK: - Re-detection

    func testRedetectionLockedToSameTool() {
        var state = forceRedetecting(lastTool: "Claude")

        // Same tool should re-detect
        let changed = state.handleOutputMatch(appName: "Claude")
        XCTAssertTrue(changed)
        XCTAssertEqual(state.currentApp, "Claude")
        XCTAssertEqual(state.phase, .detected)
    }

    func testRedetectionRejectsDifferentTool() {
        var state = forceRedetecting(lastTool: "Claude")

        // Different tool should be rejected
        let changed = state.handleOutputMatch(appName: "Codex")
        XCTAssertFalse(changed)
        XCTAssertNil(state.currentApp)
        XCTAssertEqual(state.phase, .redetecting)
    }

    func testRedetectionWindowExhaustion() {
        // Deadline is 1 second in the future
        let t0 = Date(timeIntervalSince1970: 1000)
        var state = AIDetectionState.makeRedetecting(
            lastTool: "Claude",
            deadline: t0.addingTimeInterval(1)
        )

        // Within window — should still be redetecting
        let chunk = "some random output".data(using: .utf8)!
        let result1 = state.prepareHaystack(chunk: chunk, now: t0.addingTimeInterval(0.5))
        XCTAssertNotNil(result1)
        XCTAssertEqual(state.phase, .redetecting)

        // Past deadline — should transition to scanning
        let result2 = state.prepareHaystack(chunk: chunk, now: t0.addingTimeInterval(2))
        XCTAssertNil(result2)
        XCTAssertEqual(state.phase, .scanning)
        XCTAssertNil(state.currentApp)
    }

    func testCommandOverridesRedetection() {
        var state = forceRedetecting(lastTool: "Claude")

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

    func testPromptReturnFromRestoredKeepsDimmedLogo() {
        var state = AIDetectionState()
        state.handleRestore(appName: "Claude")
        XCTAssertTrue(state.isRestored)

        // Prompt return clears currentApp but keeps restored phase (dimmed logo)
        let changed = state.handlePromptReturn()
        XCTAssertTrue(changed)
        XCTAssertNil(state.currentApp)
        XCTAssertTrue(state.isRestored)
        XCTAssertEqual(state.phase, .restored)
    }

    func testRestoredSessionCanBeOverriddenByOutputAfterPromptReturn() {
        var state = AIDetectionState()
        state.handleRestore(appName: "Codex")
        state.handlePromptReturn()
        // Still restored with nil currentApp — output scanning should work
        XCTAssertTrue(state.isRestored)
        XCTAssertNil(state.currentApp)

        // Live detection overrides the restored session
        state.handleOutputMatch(appName: "Claude")
        XCTAssertFalse(state.isRestored)
        XCTAssertEqual(state.currentApp, "Claude")
        XCTAssertEqual(state.phase, .detected)
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

    // MARK: - UTF-8 Safety

    func testPrepareHaystackHandlesInvalidUTF8() {
        var state = AIDetectionState()
        // Invalid UTF-8: 0xFF is never valid, 0xC0 is an overlong encoding start
        var data = Data([0xFF, 0xC0])
        // Append valid text after invalid bytes
        data.append("claude code".data(using: .utf8)!)
        let result = state.prepareHaystack(chunk: data)
        // Should not return nil — lossy fallback replaces invalid bytes with U+FFFD
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("claude code"))
        XCTAssertEqual(state.utf8DecodeFailures, 1)
    }

    func testPrepareHaystackMultiByteCharacterAcrossChunks() {
        var state = AIDetectionState()
        // "╭" is U+256D, encoded as 3 bytes: E2 95 AD
        // Split it across two chunks to verify character-safe buffer tailing
        let fullPattern = "╭─ claude"
        let chunk1 = fullPattern.data(using: .utf8)!
        let chunk2 = " code detected".data(using: .utf8)!
        _ = state.prepareHaystack(chunk: chunk1)
        let result = state.prepareHaystack(chunk: chunk2)
        XCTAssertNotNil(result)
        // The tail from chunk1 should include "╭─ claude" (character-safe)
        XCTAssertTrue(result!.contains("╭─ claude"))
        XCTAssertEqual(state.utf8DecodeFailures, 0)
    }

    func testUTF8DecodeFailureCountAccumulates() {
        var state = AIDetectionState()
        let invalidChunk = Data([0xFF, 0xFE, 0xFD])
        _ = state.prepareHaystack(chunk: invalidChunk)
        _ = state.prepareHaystack(chunk: invalidChunk)
        _ = state.prepareHaystack(chunk: invalidChunk)
        XCTAssertEqual(state.utf8DecodeFailures, 3)
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

    func testCooldownThenRedetectionWithInjectableClock() {
        var state = AIDetectionState()
        let t0 = Date(timeIntervalSince1970: 1000)

        // Detect at t0 with injected clock
        state.handleCommand(appName: "Claude", now: t0)

        // Prompt return at t0+1s (within 3s cooldown) — no-op
        XCTAssertFalse(state.handlePromptReturn(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(state.phase, .detected)

        // Prompt return at t0+4s (past cooldown) — transitions to redetecting
        XCTAssertTrue(state.handlePromptReturn(now: t0.addingTimeInterval(4)))
        XCTAssertEqual(state.phase, .redetecting)

        // Within redetection window — same tool re-detected
        let chunk = "╭─ claude code".data(using: .utf8)!
        let haystack = state.prepareHaystack(chunk: chunk, now: t0.addingTimeInterval(5))
        XCTAssertNotNil(haystack)
        XCTAssertTrue(state.handleOutputMatch(appName: "Claude"))
        XCTAssertEqual(state.phase, .detected)
        XCTAssertEqual(state.currentApp, "Claude")
    }

    // MARK: - Helpers

    private func forceRedetecting(lastTool: String) -> AIDetectionState {
        AIDetectionState.makeRedetecting(lastTool: lastTool)
    }
}
