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

    func testToolMatchingFindsProviderAndCommandNames() {
        XCTAssertEqual(AIToolRegistry.tool(matching: "claude")?.displayName, "Claude")
        XCTAssertEqual(AIToolRegistry.tool(matching: "codex")?.displayName, "Codex")
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

    func testDisplayMetadataResolvesAcrossProviderNames() {
        let metadata = AIToolRegistry.displayMetadata(forName: "claude")
        XCTAssertEqual(metadata?.logoAssetName, "claude-logo")
        XCTAssertEqual(metadata?.tabColorName, "purple")
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

    // MARK: - usesTerminalUIHeuristics (W3.7)

    func testUsesTerminalUIHeuristicsTrueForTUIAgentVariants() {
        let positives = [
            "Claude", "Claude Code", "CLAUDE",
            "Codex", "Codex CLI", "codex",
            "Gemini", "Gemini CLI", "gemini"
        ]
        for name in positives {
            XCTAssertTrue(
                AIToolRegistry.usesTerminalUIHeuristics(forName: name),
                "\(name) should be treated as a TUI-heuristics tool"
            )
        }
    }

    func testUsesTerminalUIHeuristicsFalseForNonTUITools() {
        XCTAssertFalse(AIToolRegistry.usesTerminalUIHeuristics(forName: "Cursor"))
        XCTAssertFalse(AIToolRegistry.usesTerminalUIHeuristics(forName: "Windsurf"))
        XCTAssertFalse(AIToolRegistry.usesTerminalUIHeuristics(forName: "Aider"))
        XCTAssertFalse(AIToolRegistry.usesTerminalUIHeuristics(forName: "Copilot"))
        XCTAssertFalse(AIToolRegistry.usesTerminalUIHeuristics(forName: "ChatGPT"))
        XCTAssertFalse(AIToolRegistry.usesTerminalUIHeuristics(forName: ""))
        XCTAssertFalse(AIToolRegistry.usesTerminalUIHeuristics(forName: "random-shell"))
    }

    func testUsesTerminalUIHeuristicsFlagMatchesExpectedTools() {
        // Lock in the current set so adding a new TUI-heuristics tool is
        // a deliberate choice, not a drive-by flag flip.
        let flagged = AIToolRegistry.allTools
            .filter(\.usesTerminalUIHeuristics)
            .map(\.displayName)
            .sorted()
        XCTAssertEqual(flagged, ["Claude", "Codex", "Gemini"])
    }

    // MARK: - Registry as the single tool-identity table (drift guards)

    /// Every `AIEventSource` tool static must have a registry tool declaring
    /// its raw value, and vice versa. If this fails after adding a tool to
    /// `AIToolRegistry.allTools`, add the matching static on `AIEventSource`
    /// (and extend this list); if it fails after adding a static, register
    /// the tool.
    func testEventSourceStaticsMatchRegistry() {
        let statics: [AIEventSource] = [
            .claudeCode, .codex, .gemini, .chatgpt, .cursor, .windsurf,
            .copilot, .aider, .cline, .cody, .amazonQ, .devin, .goose,
            .mentat, .amp, .continueAI
        ]
        XCTAssertEqual(
            Set(AIEventSource.registryToolSources),
            Set(statics),
            "AIEventSource tool statics and AIToolRegistry event sources drifted apart"
        )
        XCTAssertEqual(
            AIEventSource.registryToolSources.count,
            Set(AIEventSource.registryToolSources).count,
            "duplicate event source raw values in AIToolRegistry"
        )
    }

    /// The generic-adapter set is derived: all registry tool sources minus
    /// the dedicated adapters, plus the runtime agent.
    func testGenericAIAdapterSourcesDerivedFromRegistry() {
        let expected = Set(AIEventSource.registryToolSources)
            .subtracting([.claudeCode, .codex])
            .union([.runtime])
        XCTAssertEqual(AIEventSource.genericAIAdapterSources, expected)
        XCTAssertFalse(AIEventSource.genericAIAdapterSources.contains(.claudeCode))
        XCTAssertFalse(AIEventSource.genericAIAdapterSources.contains(.codex))
        XCTAssertTrue(AIEventSource.genericAIAdapterSources.contains(.runtime))
    }

    /// The notification trigger catalog derives its per-AI-source rows from
    /// the registry: every registry tool source must have a source info whose
    /// label is the tool's notification display name.
    func testTriggerCatalogSourcesDerivedFromRegistry() {
        let infosBySource = Dictionary(
            uniqueKeysWithValues: NotificationTriggerCatalog.sources.map { ($0.id, $0) }
        )
        for tool in AIToolRegistry.allTools {
            guard let source = tool.eventSource else { continue }
            let info = infosBySource[source]
            XCTAssertNotNil(info, "\(tool.displayName) missing from NotificationTriggerCatalog.sources")
            XCTAssertEqual(info?.labelFallback, tool.notificationDisplayName)
            XCTAssertEqual(info?.labelKey, "notifications.source.\(tool.eventSourceCamelKey ?? "")")
        }
    }

    func testNotificationDisplayNameOverrides() {
        XCTAssertEqual(AIToolRegistry.tool(named: "Claude")?.notificationDisplayName, "Claude Code")
        XCTAssertEqual(AIToolRegistry.tool(named: "Copilot")?.notificationDisplayName, "GitHub Copilot")
        // Defaults to displayName when no override is given.
        XCTAssertEqual(AIToolRegistry.tool(named: "Codex")?.notificationDisplayName, "Codex")
        XCTAssertEqual(AIToolRegistry.tool(named: "Gemini")?.notificationDisplayName, "Gemini")
    }

    func testEventSourceCamelKeyDerivation() {
        XCTAssertEqual(AIToolRegistry.tool(named: "Claude")?.eventSourceCamelKey, "claudeCode")
        XCTAssertEqual(AIToolRegistry.tool(named: "Amazon Q")?.eventSourceCamelKey, "amazonQ")
        XCTAssertEqual(AIToolRegistry.tool(named: "Continue")?.eventSourceCamelKey, "continueAI")
        XCTAssertEqual(AIToolRegistry.tool(named: "ChatGPT")?.eventSourceCamelKey, "chatgpt")
        // Multi-word components stay title-cased; short (<=2 char) tails are
        // acronym-uppercased.
        XCTAssertEqual("needs_validation".snakeToCamelKey, "needsValidation")
        XCTAssertEqual("git_branch_changed".snakeToCamelKey, "gitBranchChanged")
        XCTAssertEqual("continue_ai".snakeToCamelKey, "continueAI")
        XCTAssertEqual("finished".snakeToCamelKey, "finished")
    }
}
