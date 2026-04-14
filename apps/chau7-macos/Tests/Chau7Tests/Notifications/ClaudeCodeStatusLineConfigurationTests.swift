import XCTest
@testable import Chau7Core

final class ClaudeCodeStatusLineConfigurationTests: XCTestCase {
    func testHelperScriptWritesLatestPayloadWithoutPythonDependency() {
        let script = ClaudeCodeStatusLineConfiguration.helperScript(
            latestStatusPayloadPath: "/tmp/claude-statusline-latest.json",
            originalStatusLinePath: "/tmp/claude-original-statusline.json"
        )

        XCTAssertTrue(script.contains("LATEST_STATUS_PAYLOAD_FILE"))
        XCTAssertFalse(script.contains("python3"))
        XCTAssertTrue(script.contains("/usr/bin/plutil"))
    }

    func testUpsertStatusLineAddsHelperCommand() throws {
        let data = Data("""
        {
          "hooks": {
            "SessionStart": []
          }
        }
        """.utf8)

        let updated = ClaudeCodeStatusLineConfiguration.upsertStatusLine(
            in: data,
            helperPath: "/tmp/chau7-claude-statusline"
        )

        XCTAssertNotNil(updated)
        XCTAssertTrue(
            try ClaudeCodeStatusLineConfiguration.statusLineIncludesHelper(
                in: XCTUnwrap(updated),
                helperPath: "/tmp/chau7-claude-statusline"
            )
        )
    }

    func testCurrentStatusLineDataExtractsExistingCommand() throws {
        let data = Data("""
        {
          "statusLine": {
            "type": "command",
            "command": "echo old"
          }
        }
        """.utf8)

        let extracted = try XCTUnwrap(
            ClaudeCodeStatusLineConfiguration.currentStatusLineData(in: data)
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: extracted) as? [String: Any])

        XCTAssertEqual(json["command"] as? String, "echo old")
    }

    func testRestoreStatusLineRemovesHelperWhenNoBackupExists() throws {
        let data = Data("""
        {
          "statusLine": {
            "type": "command",
            "command": "/tmp/chau7-claude-statusline"
          }
        }
        """.utf8)

        let restored = try XCTUnwrap(
            ClaudeCodeStatusLineConfiguration.restoreStatusLine(in: data, backupStatusLineData: nil)
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: restored) as? [String: Any])

        XCTAssertNil(json["statusLine"])
    }

    func testQuotaSnapshotParsesClaudeStatusPayload() {
        let data = Data("""
        {
          "plan_type": "max",
          "rate_limits": {
            "five_hour": {
              "used_percentage": 41.5,
              "resets_at": "2026-04-14T10:30:45Z"
            },
            "seven_day": {
              "used_percentage": 72,
              "resets_at": 1776433461
            }
          }
        }
        """.utf8)

        let capturedAt = Date(timeIntervalSince1970: 1_776_157_200)
        let snapshot = ClaudeCodeStatusLineConfiguration.quotaSnapshot(
            fromStatusJSON: data,
            capturedAt: capturedAt,
            rawSourceRef: "/tmp/claude-statusline-latest.json"
        )

        XCTAssertEqual(snapshot?.provider, "claude")
        XCTAssertEqual(snapshot?.planType, "max")
        XCTAssertEqual(snapshot?.rawSourceRef, "/tmp/claude-statusline-latest.json")
        XCTAssertEqual(snapshot?.windows.count, 2)
        XCTAssertEqual(snapshot?.windows.first(where: { $0.id == "five_hour" })?.usedPercent, 41.5)
        XCTAssertEqual(snapshot?.windows.first(where: { $0.id == "seven_day" })?.usedPercent, 72)
    }
}
