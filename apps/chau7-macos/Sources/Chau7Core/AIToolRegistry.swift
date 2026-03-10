import Foundation

/// Metadata for a single AI coding tool (Claude, Codex, Gemini, etc.).
///
/// This is the single source of truth for tool identity in Chau7. Every subsystem
/// that needs to know about AI tools — detection, logos, persistence, resume —
/// reads from this definition rather than maintaining its own hardcoded table.
public struct AIToolDefinition: Sendable {
    /// Canonical display name shown in UI, e.g. "Claude"
    public let displayName: String
    /// CLI command names that map to this tool, lowercased (e.g. ["claude", "claude-code"])
    public let commandNames: [String]
    /// Terminal output patterns for detection, already lowercased
    public let outputPatterns: [String]
    /// Provider key for session resume/persistence (e.g. "claude", "codex").
    /// Nil for tools that don't support `--resume`-style session continuation.
    public let resumeProviderKey: String?
    /// Resume command format. Maps (providerKey, sessionId) → shell command.
    /// Nil for tools without resume support.
    public let resumeFormat: ResumeFormat?
    /// PNG asset name in the app bundle, without extension (e.g. "claude-logo").
    /// Nil means no bundled logo exists for this tool.
    public let logoAssetName: String?

    /// How to construct a resume command for this tool.
    public enum ResumeFormat: Sendable {
        /// `claude --resume <sessionId>`
        case dashFlag(command: String, flag: String)
        /// `codex resume <sessionId>`
        case subcommand(command: String, subcommand: String)

        public func buildCommand(sessionId: String) -> String {
            switch self {
            case let .dashFlag(command, flag):
                return "\(command) \(flag) \(sessionId)"
            case let .subcommand(command, subcommand):
                return "\(command) \(subcommand) \(sessionId)"
            }
        }
    }
}

/// Central registry of all known AI coding tools.
///
/// Consolidates tool metadata that was previously scattered across
/// `CommandDetection.appNameMap`, `CommandDetection.outputDetectionPatterns`,
/// `AIResumeParser.normalizeProviderName`, and `AIAgent` (logo rendering).
///
/// Adding a new AI tool is now a single edit to `allTools`.
public enum AIToolRegistry {

    // MARK: - Tool Definitions

    public static let allTools: [AIToolDefinition] = [
        // — Claude (Anthropic) —
        AIToolDefinition(
            displayName: "Claude",
            commandNames: ["claude", "claude-code", "claude-cli", "claude-pty", "claude-wrapper"],
            outputPatterns: [
                "╭─ claude", "╰─ claude", "powered by anthropic",
                "claude.ai/", "claude.ai", "claude code", "anthropic's claude"
            ],
            resumeProviderKey: "claude",
            resumeFormat: .dashFlag(command: "claude", flag: "--resume"),
            logoAssetName: "claude-logo"
        ),
        // — Codex (OpenAI) —
        AIToolDefinition(
            displayName: "Codex",
            commandNames: ["codex", "codex-cli", "codex-pty", "codex-wrapper"],
            outputPatterns: [
                "╭─ codex", "╰─ codex", "openai codex", "codex cli", "codex.openai"
            ],
            resumeProviderKey: "codex",
            resumeFormat: .subcommand(command: "codex", subcommand: "resume"),
            logoAssetName: "codex-logo"
        ),
        // — Gemini (Google) —
        AIToolDefinition(
            displayName: "Gemini",
            commandNames: ["gemini", "gemini-cli", "gemini-pty"],
            outputPatterns: [
                "google ai studio", "gemini pro", "gemini.google",
                "google gemini", "gemini cli"
            ],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: "gemini-logo"
        ),
        // — ChatGPT (OpenAI) —
        AIToolDefinition(
            displayName: "ChatGPT",
            commandNames: ["chatgpt", "chatgpt-cli", "gpt", "gpt-cli", "openai"],
            outputPatterns: ["chatgpt", "openai.com/", "openai.com"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: "chatgpt-logo"
        ),
        // — Copilot (GitHub) —
        AIToolDefinition(
            displayName: "Copilot",
            commandNames: ["copilot", "copilot-cli", "github-copilot"],
            outputPatterns: ["github copilot", "copilot cli", "gh copilot"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: "copilot-logo"
        ),
        // — Aider —
        AIToolDefinition(
            displayName: "Aider",
            commandNames: ["aider", "aider-chat"],
            outputPatterns: ["aider v", "aider is running", "aider.chat"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: "aider-logo"
        ),
        // — Cursor —
        AIToolDefinition(
            displayName: "Cursor",
            commandNames: ["cursor"],
            outputPatterns: ["cursor.sh", "cursor ide", "cursor cli", "cursor.com"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: "cursor-logo"
        ),
        // — Cody (Sourcegraph) —
        AIToolDefinition(
            displayName: "Cody",
            commandNames: ["cody"],
            outputPatterns: ["sourcegraph cody", "cody cli", "cody.dev"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil
        ),
        // — Amazon Q —
        AIToolDefinition(
            displayName: "Amazon Q",
            commandNames: ["amazon-q"],
            outputPatterns: ["amazon q developer", "amazon q cli", "codewhisperer"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil
        ),
        // — Devin —
        AIToolDefinition(
            displayName: "Devin",
            commandNames: ["devin"],
            outputPatterns: ["devin cli", "devin.ai"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil
        ),
        // — Continue.dev —
        AIToolDefinition(
            displayName: "Continue",
            commandNames: ["continue"],
            outputPatterns: ["continue.dev"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil
        ),
        // — Goose (Block) —
        AIToolDefinition(
            displayName: "Goose",
            commandNames: ["goose"],
            outputPatterns: ["goose v", "goose.ai", "block goose"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil
        ),
        // — Mentat —
        AIToolDefinition(
            displayName: "Mentat",
            commandNames: ["mentat"],
            outputPatterns: ["mentat v", "mentat.ai"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil
        ),
        // — Amp —
        AIToolDefinition(
            displayName: "Amp",
            commandNames: ["amp"],
            outputPatterns: ["amp.dev", "amp cli"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil
        )
    ]

    // MARK: - Derived Lookup Tables

    /// command name → display name (e.g. "claude-code" → "Claude")
    public static let commandNameMap: [String: String] = {
        var map: [String: String] = [:]
        for tool in allTools {
            for cmd in tool.commandNames {
                map[cmd] = tool.displayName
            }
        }
        return map
    }()

    /// Flat pattern list preserving per-tool order, for output detection.
    public static let outputPatternList: [(pattern: String, appName: String)] = allTools.flatMap { tool in
        tool.outputPatterns.map { (pattern: $0, appName: tool.displayName) }
    }

    // MARK: - Queries

    /// Returns the resume provider key for a display name or provider string.
    /// Uses substring matching to mirror the original `normalizeProviderName` semantics
    /// (e.g. "Claude Code" contains "claude" → returns "claude").
    public static func resumeProviderKey(for name: String) -> String? {
        let lowered = name.lowercased()
        for tool in allTools {
            guard let key = tool.resumeProviderKey else { continue }
            if lowered.contains(tool.displayName.lowercased()) || lowered == key {
                return key
            }
        }
        return nil
    }

    /// Finds the tool definition by display name (case-insensitive).
    public static func tool(named displayName: String) -> AIToolDefinition? {
        let lowered = displayName.lowercased()
        return allTools.first { $0.displayName.lowercased() == lowered }
    }

    /// Returns the logo asset name for a given app name, or nil if no logo exists.
    public static func logoAssetName(forAppName appName: String) -> String? {
        tool(named: appName)?.logoAssetName
    }
}
