import XCTest
@testable import Chau7Core

final class AIToolRegistryTests: XCTestCase {

    // MARK: - Registry Completeness

    func testAllToolsNotEmpty() {
        XCTAssertGreaterThanOrEqual(AIToolRegistry.allTools.count, 15)
    }

    func testEveryToolHasDisplayName() {
        for tool in AIToolRegistry.allTools {
            XCTAssertFalse(tool.displayName.isEmpty, "Tool has empty displayName")
        }
    }

    func testEveryToolHasCommandNames() {
        for tool in AIToolRegistry.allTools {
            XCTAssertFalse(tool.commandNames.isEmpty, "\(tool.displayName) has no command names")
        }
    }

    func testEveryToolHasOutputPatterns() {
        for tool in AIToolRegistry.allTools {
            XCTAssertFalse(tool.outputPatterns.isEmpty, "\(tool.displayName) has no output patterns")
        }
    }

    func testDisplayNamesAreUnique() {
        let names = AIToolRegistry.allTools.map(\.displayName)
        XCTAssertEqual(names.count, Set(names).count, "Duplicate display names found")
    }

    // MARK: - Command Name Map

    func testCommandNameMapHasNoOverlaps() {
        var seen: [String: String] = [:]
        for tool in AIToolRegistry.allTools {
            for cmd in tool.commandNames {
                if let existing = seen[cmd] {
                    XCTFail("Command '\(cmd)' claimed by both '\(existing)' and '\(tool.displayName)'")
                }
                seen[cmd] = tool.displayName
            }
        }
    }

    func testCommandNameMapCoversAllTools() {
        for tool in AIToolRegistry.allTools {
            for cmd in tool.commandNames {
                XCTAssertEqual(
                    AIToolRegistry.commandNameMap[cmd],
                    tool.displayName,
                    "commandNameMap missing \(cmd) → \(tool.displayName)"
                )
            }
        }
    }

    // MARK: - Output Pattern List

    func testOutputPatternListPreservesAllPatterns() {
        let totalPatterns = AIToolRegistry.allTools.reduce(0) { $0 + $1.outputPatterns.count }
        XCTAssertEqual(AIToolRegistry.outputPatternList.count, totalPatterns)
    }

    func testOutputPatternsMapToCorrectTool() {
        for (pattern, appName) in AIToolRegistry.outputPatternList {
            let tool = AIToolRegistry.tool(named: appName)
            XCTAssertNotNil(tool, "Pattern '\(pattern)' maps to unknown tool '\(appName)'")
            XCTAssertTrue(
                tool!.outputPatterns.contains(pattern),
                "Pattern '\(pattern)' not in \(appName)'s outputPatterns"
            )
        }
    }

    // MARK: - tool(named:)

    func testToolNamedCaseInsensitive() {
        XCTAssertNotNil(AIToolRegistry.tool(named: "claude"))
        XCTAssertNotNil(AIToolRegistry.tool(named: "Claude"))
        XCTAssertNotNil(AIToolRegistry.tool(named: "CLAUDE"))
    }

    func testToolNamedReturnsNilForUnknown() {
        XCTAssertNil(AIToolRegistry.tool(named: "NotARealTool"))
        XCTAssertNil(AIToolRegistry.tool(named: ""))
    }

    func testToolNamedFindsKnownTools() {
        let knownTools = ["Claude", "Codex", "Cursor", "Aider"]
        for name in knownTools {
            XCTAssertNotNil(AIToolRegistry.tool(named: name), "tool(named:) can't find \(name)")
        }
    }

    // MARK: - Resume Provider Key

    func testResumeProviderKeyDirectMatch() {
        XCTAssertEqual(AIToolRegistry.resumeProviderKey(for: "claude"), "claude")
        XCTAssertEqual(AIToolRegistry.resumeProviderKey(for: "codex"), "codex")
    }

    func testResumeProviderKeySubstringMatch() {
        XCTAssertEqual(AIToolRegistry.resumeProviderKey(for: "Claude Code"), "claude")
    }

    func testResumeProviderKeyReturnsNilForNonResumable() {
        // Tools without resumeProviderKey
        XCTAssertNil(AIToolRegistry.resumeProviderKey(for: "Gemini"))
        XCTAssertNil(AIToolRegistry.resumeProviderKey(for: "ChatGPT"))
        XCTAssertNil(AIToolRegistry.resumeProviderKey(for: "Copilot"))
    }

    func testResumeProviderKeyReturnsNilForUnknown() {
        XCTAssertNil(AIToolRegistry.resumeProviderKey(for: "NotARealTool"))
    }

    // MARK: - Logo Asset

    func testLogoAssetForKnownTools() {
        XCTAssertNotNil(AIToolRegistry.logoAssetName(forAppName: "Claude"))
        XCTAssertNotNil(AIToolRegistry.logoAssetName(forAppName: "Codex"))
    }

    func testLogoAssetNilForToolsWithoutLogo() {
        // Tools with nil logoAssetName return nil through the lookup
        XCTAssertNil(AIToolRegistry.logoAssetName(forAppName: "NotARealTool"))
    }

    // MARK: - Event Source Raw Value

    func testEventSourceByDisplayName() {
        XCTAssertEqual(AIToolRegistry.eventSourceRawValue(for: "Claude"), "claude_code")
        XCTAssertEqual(AIToolRegistry.eventSourceRawValue(for: "Codex"), "codex")
    }

    func testEventSourceByCommandName() {
        XCTAssertEqual(AIToolRegistry.eventSourceRawValue(for: "claude"), "claude_code")
        XCTAssertEqual(AIToolRegistry.eventSourceRawValue(for: "codex"), "codex")
    }

    func testEventSourceByProviderKey() {
        XCTAssertEqual(AIToolRegistry.eventSourceRawValue(for: "claude"), "claude_code")
    }

    func testEventSourceNilForUnknown() {
        XCTAssertNil(AIToolRegistry.eventSourceRawValue(for: "NotARealTool"))
    }

    // MARK: - Tab Color Map

    func testTabColorMapCoversDisplayNames() {
        for tool in AIToolRegistry.allTools where tool.tabColorName != nil {
            XCTAssertNotNil(
                AIToolRegistry.tabColorMap[tool.displayName.lowercased()],
                "tabColorMap missing display name '\(tool.displayName)'"
            )
        }
    }

    func testTabColorMapCoversCommandNames() {
        for tool in AIToolRegistry.allTools where tool.tabColorName != nil {
            for cmd in tool.commandNames {
                XCTAssertNotNil(
                    AIToolRegistry.tabColorMap[cmd],
                    "tabColorMap missing command name '\(cmd)'"
                )
            }
        }
    }

    // MARK: - Resume Format

    func testDashFlagFormat() {
        let format = AIToolDefinition.ResumeFormat.dashFlag(command: "claude", flag: "--resume")
        XCTAssertEqual(format.buildCommand(sessionId: "abc123"), "claude --resume abc123")
    }

    func testSubcommandFormat() {
        let format = AIToolDefinition.ResumeFormat.subcommand(command: "codex", subcommand: "resume")
        XCTAssertEqual(format.buildCommand(sessionId: "xyz789"), "codex resume xyz789")
    }

    func testResumeFormatConsistency() {
        for tool in AIToolRegistry.allTools {
            if tool.resumeProviderKey != nil {
                XCTAssertNotNil(tool.resumeFormat, "\(tool.displayName) has providerKey but no resumeFormat")
            }
            if tool.resumeFormat != nil {
                XCTAssertNotNil(tool.resumeProviderKey, "\(tool.displayName) has resumeFormat but no providerKey")
            }
        }
    }
}
