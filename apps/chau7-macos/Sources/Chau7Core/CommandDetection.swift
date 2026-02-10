import Foundation

// MARK: - Command Detection

/// Pure functions for detecting AI CLI tools from command lines.
/// Extracted for testability.
public enum CommandDetection {

    /// Map of command names to their display names (AI tools)
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
        "github-copilot": "Copilot",
        // Aider
        "aider": "Aider",
        "aider-chat": "Aider",
        // Cursor
        "cursor": "Cursor",
        // Sourcegraph Cody
        "cody": "Cody",
        // Amazon Q (formerly CodeWhisperer)
        "amazon-q": "Amazon Q",
        "q": "Amazon Q",
        // Devin
        "devin": "Devin",
        // Continue.dev
        "continue": "Continue",
        // Goose (Block)
        "goose": "Goose",
        // Mentat
        "mentat": "Mentat",
        // amp
        "amp": "Amp"
    ]

    /// Map of dev server command names to their display names
    public static let devServerMap: [String: String] = [
        // Vite
        "vite": "Vite",
        "vite-node": "Vite",
        // Next.js
        "next": "Next.js",
        "next-dev": "Next.js",
        // Nuxt
        "nuxt": "Nuxt",
        "nuxi": "Nuxt",
        // Webpack
        "webpack": "Webpack",
        "webpack-dev-server": "Webpack",
        "webpack-cli": "Webpack",
        // Parcel
        "parcel": "Parcel",
        // Turbo
        "turbo": "Turbo",
        "turbopack": "Turbo",
        // Remix
        "remix": "Remix",
        // Astro
        "astro": "Astro",
        // SvelteKit
        "svelte-kit": "SvelteKit",
        // Angular
        "ng": "Angular",
        // Vue CLI
        "vue-cli-service": "Vue",
        // Create React App
        "react-scripts": "React",
        // Gatsby
        "gatsby": "Gatsby",
        // Expo
        "expo": "Expo",
        // Electron
        "electron": "Electron",
        // Tauri
        "tauri": "Tauri",
        // Generic dev servers
        "live-server": "Live Server",
        "http-server": "HTTP Server",
        "serve": "Serve",
        "nodemon": "Nodemon",
        "ts-node-dev": "TS Node Dev",
        "tsx": "TSX"
    ]

    /// Common dev ports and their typical associations
    public static let commonDevPorts: [Int: String] = [
        3000: "Dev Server",      // Next.js, Create React App, many others
        3001: "Dev Server",
        4000: "Dev Server",      // Phoenix, some Node apps
        4200: "Angular",         // Angular CLI default
        5000: "Dev Server",      // Flask, many others
        5173: "Vite",            // Vite default
        5174: "Vite",
        8000: "Dev Server",      // Django, many others
        8080: "Dev Server",      // Common alternative
        8081: "Dev Server",
        8888: "Dev Server",      // Jupyter, some servers
        9000: "Dev Server",
        19000: "Expo",           // Expo default
        19001: "Expo",
        19002: "Expo"
    ]

    /// Output patterns that indicate a specific AI CLI is running.
    /// IMPORTANT: All patterns are stored **lowercased** so the matcher can do a
    /// single case-insensitive comparison by lowercasing the haystack once.
    /// Generic words like "cursor" are avoided — use specific identifiers only.
    public static let outputDetectionPatterns: [(pattern: String, appName: String)] = [
        // Claude Code banners — box-drawing characters are unique to the CLI
        ("╭─ claude", "Claude"),
        ("╰─ claude", "Claude"),
        ("powered by anthropic", "Claude"),
        ("claude.ai/", "Claude"),
        ("claude.ai", "Claude"),
        ("claude code", "Claude"),
        ("anthropic's claude", "Claude"),
        // Gemini patterns
        ("google ai studio", "Gemini"),
        ("gemini pro", "Gemini"),
        ("gemini.google", "Gemini"),
        ("google gemini", "Gemini"),
        ("gemini cli", "Gemini"),
        // ChatGPT patterns
        ("chatgpt", "ChatGPT"),
        ("openai.com/", "ChatGPT"),
        ("openai.com", "ChatGPT"),
        // Copilot patterns
        ("github copilot", "Copilot"),
        ("copilot cli", "Copilot"),
        ("gh copilot", "Copilot"),
        // Codex patterns — box-drawing characters are unique to the CLI
        ("╭─ codex", "Codex"),
        ("╰─ codex", "Codex"),
        ("openai codex", "Codex"),
        ("codex cli", "Codex"),
        ("codex.openai", "Codex"),
        // Aider patterns — use specific identifiers
        ("aider v", "Aider"),
        ("aider is running", "Aider"),
        ("aider.chat", "Aider"),
        // Cursor patterns — must be very specific, "cursor" alone is too generic
        ("cursor.sh", "Cursor"),
        ("cursor ide", "Cursor"),
        ("cursor cli", "Cursor"),
        ("cursor.com", "Cursor"),
        // Sourcegraph Cody
        ("sourcegraph cody", "Cody"),
        ("cody cli", "Cody"),
        ("cody.dev", "Cody"),
        // Amazon Q (formerly CodeWhisperer)
        ("amazon q developer", "Amazon Q"),
        ("amazon q cli", "Amazon Q"),
        ("codewhisperer", "Amazon Q"),
        // Goose (Block)
        ("goose v", "Goose"),
        ("goose.ai", "Goose"),
        ("block goose", "Goose"),
        // Mentat
        ("mentat v", "Mentat"),
        ("mentat.ai", "Mentat"),
        // Amp
        ("amp.dev", "Amp"),
        ("amp cli", "Amp"),
        // Devin
        ("devin cli", "Devin"),
        ("devin.ai", "Devin"),
        // Continue.dev
        ("continue.dev", "Continue")
    ]

    /// Output patterns that indicate a dev server is running
    public static let devServerOutputPatterns: [(pattern: String, appName: String)] = [
        // Vite — the banner is "  VITE v6.x.x  ready in Nms"
        ("VITE v", "Vite"),
        ("vite v", "Vite"),
        ("localhost:5173", "Vite"),     // Vite default port
        ("localhost:5174", "Vite"),     // Vite secondary port
        // Next.js
        ("ready started server on", "Next.js"),
        ("▲ Next.js", "Next.js"),
        ("Next.js", "Next.js"),
        // Nuxt
        ("Nuxt", "Nuxt"),
        ("Nitro", "Nuxt"),
        // Webpack
        ("webpack compiled", "Webpack"),
        ("｢wds｣", "Webpack"),
        ("｢wdm｣", "Webpack"),
        // Parcel
        ("Server running at http://localhost:", "Parcel"),
        ("✨ Built in", "Parcel"),
        // Angular
        ("Angular Live Development Server", "Angular"),
        ("Compiled successfully", "Angular"),
        // React (Create React App)
        ("Compiled successfully!", "React"),
        ("Starting the development server", "React"),
        // Remix
        ("Remix App Server", "Remix"),
        // Astro
        ("astro", "Astro"),
        ("🚀  astro", "Astro"),
        // SvelteKit
        ("SvelteKit", "SvelteKit"),
        // Gatsby
        ("gatsby develop", "Gatsby"),
        ("Gatsby develop", "Gatsby"),
        // Expo
        ("Starting Metro Bundler", "Expo"),
        ("Metro waiting on", "Expo"),
        // Electron
        ("Electron", "Electron"),
        // Nodemon
        ("nodemon", "Nodemon"),
        ("[nodemon]", "Nodemon"),
        // Generic patterns (lower priority - checked last)
        ("Listening on port", "Dev Server"),
        ("listening on port", "Dev Server"),
        ("Server listening on", "Dev Server"),
        ("Server running at", "Dev Server"),
        ("Development server", "Dev Server"),
        ("dev server running", "Dev Server"),
        ("Local:", "Dev Server")
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

    /// Detects a dev server from a command line
    /// - Parameter commandLine: The command line string
    /// - Returns: The detected dev server name, or nil
    public static func detectDevServer(from commandLine: String) -> String? {
        let tokens = tokenize(commandLine)
        guard let token = extractCommandToken(from: tokens) else { return nil }
        let normalized = normalizeToken(token)

        // Direct match on dev server commands
        if let match = devServerMap[normalized] {
            return match
        }

        // Package manager with dev/start scripts: npm run dev, pnpm dev, yarn dev, bun dev
        let packageManagers = ["npm", "pnpm", "yarn", "bun"]
        if packageManagers.contains(normalized) {
            let devScripts = ["dev", "start", "serve", "develop", "watch"]
            // Check for "run dev", "run start", etc.
            if findSubcommand(tokens: tokens, after: normalized, looking: ["run"]) != nil {
                if let script = findSubcommand(tokens: tokens, after: "run", looking: devScripts) {
                    return scriptToServerName(script)
                }
            }
            // Direct: pnpm dev, yarn dev, bun dev
            if let script = findSubcommand(tokens: tokens, after: normalized, looking: devScripts) {
                return scriptToServerName(script)
            }
        }

        // npx/bunx with dev server packages
        if normalized == "npx" || normalized == "bunx" {
            if let devServer = findSubcommand(tokens: tokens, after: normalized, looking: Array(devServerMap.keys)) {
                return devServerMap[devServer]
            }
        }

        return nil
    }

    /// Detects a dev server from terminal output
    /// - Parameter output: The terminal output string
    /// - Returns: The detected dev server name, or nil
    public static func detectDevServerFromOutput(_ output: String) -> String? {
        for (pattern, appName) in devServerOutputPatterns {
            if output.contains(pattern) {
                return appName
            }
        }
        return nil
    }

    // MARK: - Cached URL/Port Patterns

    private static let devServerURLPatterns: [NSRegularExpression] = [
        "http://localhost:\\d+",
        "http://127\\.0\\.0\\.1:\\d+",
        "https://localhost:\\d+",
        "http://0\\.0\\.0\\.0:\\d+"
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let portRegex = try! NSRegularExpression(pattern: ":(\\d{4,5})(?:/|\\s|$)")

    /// Extracts a URL from dev server output (e.g., "http://localhost:3000")
    /// - Parameter output: The terminal output string
    /// - Returns: The URL string if found, or nil
    public static func extractDevServerURL(from output: String) -> String? {
        let nsRange = NSRange(output.startIndex..., in: output)
        for regex in devServerURLPatterns {
            if let match = regex.firstMatch(in: output, range: nsRange),
               let range = Range(match.range, in: output) {
                return String(output[range])
            }
        }
        return nil
    }

    /// Extracts the port number from a URL or output
    /// - Parameter text: Text containing a port number
    /// - Returns: The port number if found
    public static func extractPort(from text: String) -> Int? {
        let nsRange = NSRange(text.startIndex..., in: text)
        if let match = portRegex.firstMatch(in: text, range: nsRange),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: text) {
            return Int(text[range])
        }
        return nil
    }

    /// Maps a script name to a dev server display name
    private static func scriptToServerName(_ script: String) -> String {
        switch script.lowercased() {
        case "dev", "develop":
            return "Dev Server"
        case "start":
            return "Dev Server"
        case "serve":
            return "Dev Server"
        case "watch":
            return "Watch Mode"
        default:
            return "Dev Server"
        }
    }

    /// Extracts the command token from a raw command line
    public static func commandToken(from commandLine: String) -> String? {
        let tokens = tokenize(commandLine)
        guard let index = commandTokenIndex(from: tokens) else { return nil }
        return tokens[index]
    }

    /// Returns the index of the command token inside tokenized input
    public static func commandTokenIndex(from tokens: [String]) -> Int? {
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

            return index
        }

        return nil
    }

    /// Detects an AI app from terminal output (case-insensitive).
    /// Patterns in `outputDetectionPatterns` are already lowercased, so we only
    /// need to lowercase the haystack once.
    /// - Parameter output: The terminal output string
    /// - Returns: The detected app name, or nil
    public static func detectAppFromOutput(_ output: String) -> String? {
        let lowered = output.lowercased()
        for (pattern, appName) in outputDetectionPatterns {
            if lowered.contains(pattern) {
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
        guard let index = commandTokenIndex(from: tokens) else { return nil }
        return tokens[index]
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
    public enum EventType: String, Codable, CaseIterable, Sendable {
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
    public struct ParsedEvent: Sendable {
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
