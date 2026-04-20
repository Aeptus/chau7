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
