import XCTest
@testable import Chau7

final class CodexRestoreValidationTests: XCTestCase {
    private var temporaryHome: URL!
    private let referenceDate = Date(timeIntervalSince1970: 1_723_132_800)

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRestoreValidationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryHome {
            try? FileManager.default.removeItem(at: temporaryHome)
        }
        temporaryHome = nil
        try super.tearDownWithError()
    }

    func testRestoreDropsModernCodexSessionWithoutRollout() {
        let sessionID = "019dc912-2ddb-7791-b346-f15af4d592ec"
        let state = savedState(sessionID: sessionID, directory: "/tmp/old-checkout")

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(
            states: [state],
            environment: ["CHAU7_HOME_ROOT": temporaryHome.path]
        )

        XCTAssertNil(sanitized.first?.aiProvider)
        XCTAssertNil(sanitized.first?.aiSessionId)
        XCTAssertNil(sanitized.first?.aiResumeCommand)
    }

    func testRestoreKeepsModernCodexSessionWithRolloutAfterCheckoutMoved() throws {
        let sessionID = "019fdbe3-084a-7d71-baff-40b1bb0f7162"
        try writeRollout(
            sessionID: sessionID,
            directory: "/tmp/new-checkout",
            referenceDate: referenceDate
        )
        let state = savedState(sessionID: sessionID, directory: "/tmp/old-checkout")

        let sanitized = OverlayTabsModel.sanitizeRestoredAIResumeOwnership(
            states: [state],
            environment: ["CHAU7_HOME_ROOT": temporaryHome.path]
        )

        XCTAssertEqual(sanitized.first?.aiProvider, "codex")
        XCTAssertEqual(sanitized.first?.aiSessionId, sessionID)
        XCTAssertEqual(sanitized.first?.aiResumeCommand, "codex resume \(sessionID)")
    }

    func testExplicitCodexMetadataWithoutRolloutIsNotTrustedAtSaveTime() {
        let sessionID = "019dc912-2ddb-7791-b346-f15af4d592ec"

        let resolved = OverlayTabsModel.resolvedAIResumeMetadata(
            provider: "codex",
            sessionId: sessionID,
            directory: "/tmp/old-checkout",
            referenceDate: referenceDate,
            environment: ["CHAU7_HOME_ROOT": temporaryHome.path]
        )

        XCTAssertNil(resolved)
    }

    func testExplicitCodexMetadataWithRolloutIsTrustedAtSaveTime() throws {
        let sessionID = "019fdbe3-084a-7d71-baff-40b1bb0f7162"
        try writeRollout(
            sessionID: sessionID,
            directory: "/tmp/new-checkout",
            referenceDate: referenceDate
        )

        let resolved = OverlayTabsModel.resolvedAIResumeMetadata(
            provider: "codex",
            sessionId: sessionID,
            directory: "/tmp/old-checkout",
            referenceDate: referenceDate,
            environment: ["CHAU7_HOME_ROOT": temporaryHome.path]
        )

        XCTAssertEqual(resolved?.provider, "codex")
        XCTAssertEqual(resolved?.sessionId, sessionID)
    }

    private func savedState(sessionID: String, directory: String) -> SavedTabState {
        SavedTabState(
            tabID: UUID().uuidString,
            selectedTabID: nil,
            customTitle: "Codex",
            color: TabColor.blue.rawValue,
            directory: directory,
            selectedIndex: 0,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: "codex resume \(sessionID)",
            aiProvider: "codex",
            aiSessionId: sessionID,
            aiSessionIdSource: .explicit,
            splitLayout: nil,
            focusedPaneID: nil,
            paneStates: nil,
            createdAt: nil,
            repoGroupID: nil,
            agentStartedAt: referenceDate
        )
    }

    private func writeRollout(
        sessionID: String,
        directory: String,
        referenceDate: Date
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        let dayDirectory = temporaryHome
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", components.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

        let envelope: [String: Any] = [
            "type": "session_meta",
            "payload": ["id": sessionID, "cwd": directory]
        ]
        var data = try JSONSerialization.data(withJSONObject: envelope)
        data.append(0x0A)
        try data.write(to: dayDirectory.appendingPathComponent("rollout-test-\(sessionID).jsonl"))
    }
}
