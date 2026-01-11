import Foundation

// MARK: - Command Detection

/// Pure functions for detecting AI CLI tools from command lines.
/// Extracted for testability.
public enum CommandDetection {

    /// Map of command names to their display names
    public static let appNameMap: [String: String] = [
        // OpenAI Codex
        "codex": "Codex",
        "codex-cli": "Codex",
        "codex-pty": "Codex",
        "codex-wrapper": "Codex",
        // Anthropic Claude
        "claude": "Claude",
        "claude-code": "Claude",
        "claude-cli": "Claude",
        "claude-pty": "Claude",
        "claude-wrapper": "Claude",
        // Google Gemini
        "gemini": "Gemini",
        "gemini-cli": "Gemini",
        "gemini-pty": "Gemini",
        // OpenAI ChatGPT
        "chatgpt": "ChatGPT",
        "chatgpt-cli": "ChatGPT",
        "gpt": "ChatGPT",
        "gpt-cli": "ChatGPT",
        "openai": "ChatGPT",
        // GitHub Copilot
        "copilot": "Copilot",
        "copilot-cli": "Copilot",
        "github-copilot": "Copilot"
    ]

    /// Output patterns that indicate a specific AI CLI is running
    public static let outputDetectionPatterns: [(pattern: String, appName: String)] = [
        // Claude Code banners
        ("╭─ Claude", "Claude"),
        ("claude.ai", "Claude"),
        ("Anthropic", "Claude"),
        // Gemini patterns
        ("Google AI", "Gemini"),
        ("Gemini Pro", "Gemini"),
        ("gemini.google", "Gemini"),
        // ChatGPT patterns
        ("ChatGPT", "ChatGPT"),
        ("openai.com", "ChatGPT"),
        // Copilot patterns
        ("GitHub Copilot", "Copilot"),
        ("Copilot CLI", "Copilot"),
        // Codex patterns
        ("OpenAI Codex", "Codex")
    ]

    /// Shell wrapper commands that should be skipped
    public static let wrapperCommands: Set<String> = [
        "command",
        "builtin",
        "exec",
        "noglob",
        "time"
    ]

    /// Sudo options that take a value argument
    public static let sudoOptionsWithValue: Set<String> = [
        "-u", "-g", "-h", "-p", "-a", "-c", "-t", "-r"
    ]

    // MARK: - Public API

    /// Detects an AI app name from a command line
    /// - Parameter commandLine: The command line string
    /// - Returns: The detected app name, or nil
    public static func detectApp(from commandLine: String) -> String? {
        let tokens = tokenize(commandLine)
        guard let token = extractCommandToken(from: tokens) else { return nil }
        let normalized = normalizeToken(token)

        // Direct match
        if let match = appNameMap[normalized] {
            return match
        }

        // Special case: gh copilot
        if normalized == "gh" {
            if findSubcommand(tokens: tokens, after: "gh", looking: ["copilot"]) != nil {
                return "Copilot"
            }
        }

        // Special case: npx/bunx with AI packages
        if normalized == "npx" || normalized == "bunx" || normalized == "pnpm" {
            if let aiApp = findSubcommand(tokens: tokens, after: normalized, looking: Array(appNameMap.keys)) {
                return appNameMap[aiApp]
            }
        }

        return nil
    }

    /// Detects an AI app from terminal output
    /// - Parameter output: The terminal output string
    /// - Returns: The detected app name, or nil
    public static func detectAppFromOutput(_ output: String) -> String? {
        for (pattern, appName) in outputDetectionPatterns {
            if output.contains(pattern) {
                return appName
            }
        }
        return nil
    }

    // MARK: - Tokenization

    /// Tokenizes a command line respecting quotes and escapes
    public static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        func flushCurrent() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for char in line {
            if isEscaped {
                current.append(char)
                isEscaped = false
                continue
            }

            if char == "\\" && !inSingleQuote {
                isEscaped = true
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if !inSingleQuote && !inDoubleQuote {
                if char == "#" {
                    break
                }
                if char == "|" || char == ";" || char == "&" {
                    break
                }
                if char.isWhitespace {
                    flushCurrent()
                    continue
                }
            }

            current.append(char)
        }

        flushCurrent()
        return tokens
    }

    /// Normalizes a command token to a lookup key
    public static func normalizeToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathComponent = (trimmed as NSString).lastPathComponent
        let baseName = (pathComponent as NSString).deletingPathExtension
        return baseName.lowercased()
    }

    /// Checks if a token is an environment variable assignment
    public static func isEnvAssignment(_ token: String) -> Bool {
        guard let eqIndex = token.firstIndex(of: "=") else { return false }
        let name = token[..<eqIndex]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        for ch in name.dropFirst() {
            if ch != "_" && !ch.isLetter && !ch.isNumber {
                return false
            }
        }
        return true
    }

    // MARK: - Internal Helpers

    /// Extracts the command token from tokenized input
    static func extractCommandToken(from tokens: [String]) -> String? {
        guard !tokens.isEmpty else { return nil }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.isEmpty {
                index += 1
                continue
            }

            if isEnvAssignment(token) {
                index += 1
                continue
            }

            let lower = token.lowercased()
            if lower == "env" {
                index = consumeEnv(tokens: tokens, start: index + 1)
                continue
            }

            if lower == "sudo" {
                index = consumeSudo(tokens: tokens, start: index + 1)
                continue
            }

            if wrapperCommands.contains(lower) {
                index += 1
                continue
            }

            if lower.hasPrefix("-") {
                index += 1
                continue
            }

            return token
        }

        return nil
    }

    static func consumeEnv(tokens: [String], start: Int) -> Int {
        var index = start
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                return index + 1
            }
            if token.hasPrefix("-") || isEnvAssignment(token) {
                index += 1
                continue
            }
            break
        }
        return index
    }

    static func consumeSudo(tokens: [String], start: Int) -> Int {
        var index = start
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                return index + 1
            }
            if token.hasPrefix("-") {
                if sudoOptionsWithValue.contains(token), index + 1 < tokens.count {
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            break
        }
        return index
    }

    static func findSubcommand(tokens: [String], after command: String, looking targets: [String]) -> String? {
        guard let cmdIndex = tokens.firstIndex(where: { normalizeToken($0) == command }) else { return nil }
        for i in (cmdIndex + 1)..<tokens.count {
            let token = tokens[i]
            if token.hasPrefix("-") { continue }
            let normalized = normalizeToken(token)
            if targets.contains(normalized) {
                return normalized
            }
            break
        }
        return nil
    }
}

// MARK: - Event Parsing

/// Pure functions for parsing Claude Code hook events.
public enum EventParsing {

    /// Event types from hooks
    public enum EventType: String, Codable, CaseIterable {
        case userPrompt = "user_prompt"
        case toolStart = "tool_start"
        case toolComplete = "tool_complete"
        case permissionRequest = "permission_request"
        case responseComplete = "response_complete"
        case notification = "notification"
        case sessionEnd = "session_end"
        case unknown = "unknown"

        public init(from hookEvent: String) {
            switch hookEvent {
            case "UserPromptSubmit":
                self = .userPrompt
            case "PreToolUse":
                self = .toolStart
            case "PostToolUse":
                self = .toolComplete
            case "PermissionRequest":
                self = .permissionRequest
            case "Stop":
                self = .responseComplete
            case "SessionEnd":
                self = .sessionEnd
            default:
                self = .unknown
            }
        }
    }

    /// Parsed event data
    public struct ParsedEvent {
        public let type: EventType
        public let hook: String
        public let toolName: String
        public let message: String
        public let sessionId: String
        public let projectPath: String

        public init(type: EventType, hook: String, toolName: String, message: String, sessionId: String, projectPath: String) {
            self.type = type
            self.hook = hook
            self.toolName = toolName
            self.message = message
            self.sessionId = sessionId
            self.projectPath = projectPath
        }
    }

    /// Parses a JSON event payload from a hook
    public static func parseEvent(json: Data) -> ParsedEvent? {
        guard let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return nil
        }

        let typeString = dict["type"] as? String ?? "unknown"
        let type = EventType(rawValue: typeString) ?? .unknown

        return ParsedEvent(
            type: type,
            hook: dict["hook"] as? String ?? "",
            toolName: dict["tool_name"] as? String ?? "",
            message: dict["message"] as? String ?? "",
            sessionId: dict["session_id"] as? String ?? "",
            projectPath: dict["project_path"] as? String ?? ""
        )
    }

    /// Extracts session ID from a transcript path
    public static func extractSessionId(from transcriptPath: String) -> String {
        // Extract filename without extension as session ID
        let url = URL(fileURLWithPath: transcriptPath)
        return url.deletingPathExtension().lastPathComponent
    }

    /// Extracts project name from a project path
    public static func extractProjectName(from projectPath: String) -> String {
        let url = URL(fileURLWithPath: projectPath)
        return url.lastPathComponent
    }
}
