import Foundation
import XCTest
@testable import Chau7

final class CodexContentProviderDiscoveryTests: XCTestCase {
    func testGlobalIndexRefreshesAfterPreviouslyMissingRolloutAppears() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-codex-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("CHAU7_HOME_ROOT", home.path, 1)
        defer {
            unsetenv("CHAU7_HOME_ROOT")
            try? FileManager.default.removeItem(at: home)
        }

        let sessionID = UUID().uuidString.lowercased()
        let provider = CodexContentProvider()
        let startedAt = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 9))
        )

        XCTAssertNil(provider.findRolloutFile(sessionID: sessionID, startedAt: startedAt))

        // Place the new rollout outside the current/previous-day fast paths so
        // this specifically proves that a cached global-index miss can recover.
        let oldDay = home.appendingPathComponent(".codex/sessions/2025/01/01")
        try FileManager.default.createDirectory(at: oldDay, withIntermediateDirectories: true)
        let rollout = oldDay.appendingPathComponent("rollout-2025-01-01T00-00-00-\(sessionID).jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: rollout.path, contents: Data()))

        XCTAssertEqual(
            provider.findRolloutFile(sessionID: sessionID, startedAt: startedAt)?.standardizedFileURL,
            rollout.standardizedFileURL
        )
    }
}
