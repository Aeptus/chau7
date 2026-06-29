import XCTest
@testable import Chau7
import Chau7Core

@MainActor
final class TerminalSessionModelLiveAgentTests: XCTestCase {

    // MARK: - aiDisplayAppName: single-field contract

    //
    // The display chain collapsed: `aiDisplayAppName` is now just a
    // canonical read of `lastAIProvider`. Every detection write path
    // (live process tree, output match, history adoption, restore) is
    // expected to call `updateLastDetectedApp` so the persisted field
    // stays current. These tests pin the new shape.

    func testAiDisplayAppNameReadsLastAIProviderOnly() {
        let session = TerminalSessionModel(appModel: AppModel())
        XCTAssertNil(session.aiDisplayAppName)

        session.lastAIProvider = "codex"
        XCTAssertEqual(session.aiDisplayAppName, "Codex")

        session.lastAIProvider = "claude"
        XCTAssertEqual(session.aiDisplayAppName, "Claude")

        session.lastAIProvider = nil
        XCTAssertNil(session.aiDisplayAppName)
    }

    /// Old fallback rungs no longer drive display directly. Setting any
    /// of them without `lastAIProvider` must NOT produce a display name —
    /// detection paths are responsible for writing through.
    func testLegacyFallbackFieldsDoNotResurrectAiDisplayAppName() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.activeAppName = "Claude"
        session.lastDetectedAppName = "Codex"
        session.overrideLiveAgentNameForTesting("Gemini")
        XCTAssertNil(
            session.aiDisplayAppName,
            "Display must not fall back to liveAgentName / activeAppName / lastDetectedAppName"
        )
    }

    /// `updateLastDetectedApp` is the canonical write path: it sets
    /// `lastDetectedAppName` AND `lastAIProvider` in lockstep, so the
    /// display picks up the change without any fallback gymnastics.
    func testUpdateLastDetectedAppPropagatesToDisplay() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.updateLastDetectedApp("Codex")
        XCTAssertEqual(session.lastAIProvider, "codex")
        XCTAssertEqual(session.aiDisplayAppName, "Codex")
    }

    // MARK: - isAIRunning (logo opacity contract)

    /// Regression: post-b39a863a, output detection is gated on corroboration
    /// and URL fingerprints have been purged. On a restored tab whose AI
    /// process is still in the tree but whose state machine has cleared
    /// `activeAppName` (prompt return), `isAIRunning` was returning false
    /// — dropping the tab's logo to 0.35 opacity even though Codex was
    /// running. The live process-tree signal must keep the logo solid.
    func testIsAIRunningTrueWhenLiveAgentPresentEvenIfActiveAppCleared() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.activeAppName = nil
        session.overrideLiveAgentNameForTesting("Codex")
        XCTAssertTrue(
            session.isAIRunning,
            "live process-tree signal must keep isAIRunning true so the logo stays solid"
        )
    }

    func testIsAIRunningTrueWhenLiveAgentPresentEvenIfDetectionStillRestored() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.activeAppName = "Claude" // restored identity
        // Restored sessions normally render at 0.35 opacity (isAIRunning false)
        // until live detection re-confirms. With the process-tree signal in,
        // the re-confirmation happens via liveAgentName.
        session.overrideLiveAgentNameForTesting("Claude")
        XCTAssertTrue(
            session.isAIRunning,
            "live process-tree confirmation must promote a restored session to running"
        )
    }

    func testIsAIRunningFalseWhenNoLiveAndNoActive() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.activeAppName = nil
        session.overrideLiveAgentNameForTesting(nil)
        XCTAssertFalse(session.isAIRunning, "nothing live, nothing active → not running")
    }

    func testIsAIRunningFalseWhenLiveAgentIsWhitespace() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.activeAppName = nil
        session.overrideLiveAgentNameForTesting("   ")
        XCTAssertFalse(
            session.isAIRunning,
            "whitespace-only live signal must not be treated as a running AI"
        )
    }

    func testLiveAgentChangeFiresSessionStateChanged() {
        let session = TerminalSessionModel(appModel: AppModel())
        var fires = 0
        session.onSessionStateChanged = { fires += 1 }

        session.overrideLiveAgentNameForTesting("Claude")
        XCTAssertGreaterThan(fires, 0, "liveAgentName change must notify observers")

        let before = fires
        session.overrideLiveAgentNameForTesting("Claude")
        XCTAssertEqual(
            fires,
            before,
            "setting to same value must not fire (didSet guards equality)"
        )
    }
}
