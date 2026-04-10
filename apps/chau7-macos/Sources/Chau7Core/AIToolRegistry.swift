import Foundation

/// Metadata for a single AI coding tool (Claude, Codex, Gemini, etc.).
///
/// Chau7 strives to be fully backend-agnostic.  This is the single source of
/// truth for tool identity.  Every subsystem — detection, tab routing, logos,
/// persistence, resume — reads from this definition rather than maintaining
/// its own hardcoded table.  Never reference specific tool names in generic code.
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
    /// Tab color name for auto-theming (maps to `TabColor.rawValue` in the app layer).
    /// Nil means no auto-color assignment for this tool.
    public let tabColorName: String?
    /// Raw value for `AIEventSource` when this tool emits history/notification events.
    /// Must match the `rawValue` of the corresponding `AIEventSource` static constant.
    /// Nil means this tool has no dedicated event source (falls back to `.historyMonitor`).
    public let eventSourceRawValue: String?

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

public struct AIToolDisplayMetadata: Equatable, Sendable {
    public let logoAssetName: String?
    public let tabColorName: String?

    public init(logoAssetName: String?, tabColorName: String?) {
        self.logoAssetName = logoAssetName
        self.tabColorName = tabColorName
    }
}

/// Central registry of all known AI coding tools.
///
/// Chau7 strives to be fully backend-agnostic: every subsystem — detection,
/// tab routing, notifications, resume, UI — reads from this registry rather
/// than hardcoding tool names.  Adding a new AI tool is a single edit to
/// `allTools`; no changes are needed in `TabResolver`, notification pipeline,
/// or any other downstream code.
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
            logoAssetName: "claude-logo",
            tabColorName: "purple",
            eventSourceRawValue: "claude_code"
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
            logoAssetName: "codex-logo",
            tabColorName: "green",
            eventSourceRawValue: "codex"
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
            logoAssetName: "gemini-logo",
            tabColorName: "blue",
            eventSourceRawValue: "gemini"
        ),
        // — ChatGPT (OpenAI) —
        AIToolDefinition(
            displayName: "ChatGPT",
            commandNames: ["chatgpt", "chatgpt-cli", "gpt", "gpt-cli", "openai"],
            outputPatterns: ["chatgpt", "openai.com/", "openai.com"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: "chatgpt-logo",
            tabColorName: "green",
            eventSourceRawValue: "chatgpt"
        ),
        // — Copilot (GitHub) —
        AIToolDefinition(
            displayName: "Copilot",
            commandNames: ["copilot", "copilot-cli", "github-copilot"],
            outputPatterns: ["github copilot", "copilot cli", "gh copilot"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: "copilot-logo",
            tabColorName: "orange",
            eventSourceRawValue: "copilot"
        ),
        // — Aider —
        AIToolDefinition(
            displayName: "Aider",
            commandNames: ["aider", "aider-chat"],
            outputPatterns: ["aider v", "aider is running", "aider.chat"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: "aider-logo",
            tabColorName: "pink",
            eventSourceRawValue: "aider"
        ),
        // — Cursor —
        AIToolDefinition(
            displayName: "Cursor",
            commandNames: ["cursor"],
            outputPatterns: ["cursor.sh", "cursor ide", "cursor cli", "cursor.com"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: "cursor-logo",
            tabColorName: "teal",
            eventSourceRawValue: "cursor"
        ),
        // — Windsurf (Codeium) —
        AIToolDefinition(
            displayName: "Windsurf",
            commandNames: ["windsurf", "windsurf-cli"],
            outputPatterns: ["windsurf", "codeium", "windsurf.ai"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil,
            tabColorName: "teal",
            eventSourceRawValue: "windsurf"
        ),
        // — Cline —
        // Output patterns must be specific — bare "cline" matches common substrings
        // like "decline", "client", "incline" in any AI tool's output.
        AIToolDefinition(
            displayName: "Cline",
            commandNames: ["cline"],
            outputPatterns: ["cline v", "cline cli", "cline.bot", "cline agent"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil,
            tabColorName: nil,
            eventSourceRawValue: "cline"
        ),
        // — Cody (Sourcegraph) —
        AIToolDefinition(
            displayName: "Cody",
            commandNames: ["cody"],
            outputPatterns: ["sourcegraph cody", "cody cli", "cody.dev"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil,
            tabColorName: nil,
            eventSourceRawValue: "cody"
        ),
        // — Amazon Q —
        AIToolDefinition(
            displayName: "Amazon Q",
            commandNames: ["amazon-q"],
            outputPatterns: ["amazon q developer", "amazon q cli", "codewhisperer"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil,
            tabColorName: nil,
            eventSourceRawValue: "amazon_q"
        ),
        // — Devin —
        AIToolDefinition(
            displayName: "Devin",
            commandNames: ["devin"],
            outputPatterns: ["devin cli", "devin.ai"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil,
            tabColorName: nil,
            eventSourceRawValue: "devin"
        ),
        // — Continue.dev —
        AIToolDefinition(
            displayName: "Continue",
            commandNames: ["continue"],
            outputPatterns: ["continue.dev"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil,
            tabColorName: "yellow",
            eventSourceRawValue: "continue_ai"
        ),
        // — Goose (Block) —
        AIToolDefinition(
            displayName: "Goose",
            commandNames: ["goose"],
            outputPatterns: ["goose v", "goose.ai", "block goose"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil,
            tabColorName: nil,
            eventSourceRawValue: "goose"
        ),
        // — Mentat —
        AIToolDefinition(
            displayName: "Mentat",
            commandNames: ["mentat"],
            outputPatterns: ["mentat v", "mentat.ai"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil,
            tabColorName: nil,
            eventSourceRawValue: "mentat"
        ),
        // — Amp —
        AIToolDefinition(
            displayName: "Amp",
            commandNames: ["amp"],
            outputPatterns: ["amp.dev", "amp cli"],
            resumeProviderKey: nil,
            resumeFormat: nil,
            logoAssetName: nil,
            tabColorName: nil,
            eventSourceRawValue: "amp"
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

    /// All name variants → tab color name, for auto-theming.
    /// Keys include display name (lowercased), command names, and provider keys.
    public static let tabColorMap: [String: String] = {
        var map: [String: String] = [:]
        for tool in allTools {
            guard let colorName = tool.tabColorName else { continue }
            map[tool.displayName.lowercased()] = colorName
            for cmd in tool.commandNames {
                map[cmd] = colorName
            }
            if let key = tool.resumeProviderKey { map[key] = colorName }
        }
        return map
    }()

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

    /// Finds the tool definition by display name, command name, or provider key.
    public static func tool(matching name: String?) -> AIToolDefinition? {
        guard let lowered = normalizedLookupName(name) else { return nil }
        return allTools.first { tool in
            tool.displayName.lowercased() == lowered
                || tool.commandNames.contains(lowered)
                || tool.resumeProviderKey == lowered
        }
    }

    /// Returns the logo asset name for a given app name, or nil if no logo exists.
    public static func logoAssetName(forAppName appName: String) -> String? {
        tool(named: appName)?.logoAssetName
    }

    public static func logoAssetName(forName name: String?) -> String? {
        tool(matching: name)?.logoAssetName
    }

    public static func tabColorName(forName name: String?) -> String? {
        tool(matching: name)?.tabColorName
    }

    public static func displayMetadata(forName name: String?) -> AIToolDisplayMetadata? {
        guard let definition = tool(matching: name) else { return nil }
        return AIToolDisplayMetadata(
            logoAssetName: definition.logoAssetName,
            tabColorName: definition.tabColorName
        )
    }

    /// Returns the `AIEventSource` raw value for a tool name, checking display name,
    /// command names, and provider key. Returns nil if no registered tool matches.
    public static func eventSourceRawValue(for name: String) -> String? {
        let lowered = name.lowercased()
        for tool in allTools {
            guard let source = tool.eventSourceRawValue else { continue }
            if tool.displayName.lowercased() == lowered { return source }
            if tool.commandNames.contains(lowered) { return source }
            if let key = tool.resumeProviderKey, key == lowered { return source }
        }
        return nil
    }

    private static func normalizedLookupName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
