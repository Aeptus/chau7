import XCTest
@testable import Chau7
import Chau7Core

@MainActor
final class TerminalSessionModelLiveAgentTests: XCTestCase {

    func testLiveAgentNameWinsOverActiveAppName() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.activeAppName = "Codex"
        session.lastAIProvider = "codex"
        XCTAssertEqual(session.aiDisplayAppName, "Codex", "sanity: fallback chain returns active")

        session.overrideLiveAgentNameForTesting("Claude")
        XCTAssertEqual(
            session.aiDisplayAppName,
            "Claude",
            "live signal must override stale persisted identity"
        )
    }

    func testLiveAgentNameWinsOverPersistedProvider() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.lastAIProvider = "codex"
        XCTAssertEqual(session.aiDisplayAppName, "Codex")

        session.overrideLiveAgentNameForTesting("Claude")
        XCTAssertEqual(session.aiDisplayAppName, "Claude")
    }

    func testNilLiveAgentFallsBackThroughChain() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.activeAppName = "Claude"
        session.lastAIProvider = "claude"

        session.overrideLiveAgentNameForTesting(nil)
        XCTAssertEqual(
            session.aiDisplayAppName,
            "Claude",
            "nil live signal must fall through to activeAppName"
        )

        session.activeAppName = nil
        XCTAssertEqual(
            session.aiDisplayAppName,
            "Claude",
            "nil live and active must fall through to persisted provider"
        )

        session.lastAIProvider = nil
        XCTAssertNil(session.aiDisplayAppName)
    }

    func testBlankLiveAgentTreatedAsAbsent() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.activeAppName = "Codex"

        session.overrideLiveAgentNameForTesting("   ")
        XCTAssertEqual(
            session.aiDisplayAppName,
            "Codex",
            "whitespace-only live signal must not shadow a valid fallback"
        )
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
        session.activeAppName = "Claude"  // restored identity
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

    // MARK: - aiDisplayAppName: lastDetectedAppName fallback

    /// `updateLastDetectedApp` writes both lastDetectedAppName + lastAIProvider
    /// in lockstep, so the typical fallback works. But persisting against
    /// future code paths that might clear one but not the other: when
    /// lastDetectedAppName is set without lastAIProvider, the logo source
    /// chain must still find a name.
    func testAiDisplayAppNameFallsBackToLastDetectedAppNameWhenProviderCleared() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.overrideLiveAgentNameForTesting(nil)
        session.activeAppName = nil
        session.lastAIProvider = nil
        session.lastDetectedAppName = "Codex"
        XCTAssertEqual(
            session.aiDisplayAppName,
            "Codex",
            "lastDetectedAppName must back-stop the display chain even when lastAIProvider is nil"
        )
    }

    func testAiDisplayAppNameRespectsExistingPriorityOverLastDetected() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.activeAppName = "Claude"
        session.lastDetectedAppName = "Codex"
        XCTAssertEqual(
            session.aiDisplayAppName,
            "Claude",
            "activeAppName must still win over the new lastDetectedAppName fallback"
        )
        session.overrideLiveAgentNameForTesting("Gemini")
        XCTAssertEqual(
            session.aiDisplayAppName,
            "Gemini",
            "liveAgentName is still the top of the chain"
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
