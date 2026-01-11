import XCTest
@testable import Chau7Core

final class CommandDetectionTests: XCTestCase {

    // MARK: - Basic Detection

    func testDetectClaude() {
        XCTAssertEqual(CommandDetection.detectApp(from: "claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "claude-code"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "claude-cli"), "Claude")
    }

    func testDetectGemini() {
        XCTAssertEqual(CommandDetection.detectApp(from: "gemini"), "Gemini")
        XCTAssertEqual(CommandDetection.detectApp(from: "gemini-cli"), "Gemini")
    }

    func testDetectChatGPT() {
        XCTAssertEqual(CommandDetection.detectApp(from: "chatgpt"), "ChatGPT")
        XCTAssertEqual(CommandDetection.detectApp(from: "gpt"), "ChatGPT")
        XCTAssertEqual(CommandDetection.detectApp(from: "openai"), "ChatGPT")
    }

    func testDetectCopilot() {
        XCTAssertEqual(CommandDetection.detectApp(from: "copilot"), "Copilot")
        XCTAssertEqual(CommandDetection.detectApp(from: "copilot-cli"), "Copilot")
    }

    func testDetectCodex() {
        XCTAssertEqual(CommandDetection.detectApp(from: "codex"), "Codex")
        XCTAssertEqual(CommandDetection.detectApp(from: "codex-cli"), "Codex")
    }

    func testUnknownCommand() {
        XCTAssertNil(CommandDetection.detectApp(from: "vim"))
        XCTAssertNil(CommandDetection.detectApp(from: "ls -la"))
        XCTAssertNil(CommandDetection.detectApp(from: "git status"))
    }

    // MARK: - Path Handling

    func testDetectWithAbsolutePath() {
        XCTAssertEqual(CommandDetection.detectApp(from: "/usr/local/bin/claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "/opt/homebrew/bin/gemini-cli"), "Gemini")
    }

    func testDetectWithRelativePath() {
        XCTAssertEqual(CommandDetection.detectApp(from: "./claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "../bin/chatgpt"), "ChatGPT")
    }

    // MARK: - Sudo Handling

    func testDetectWithSudo() {
        XCTAssertEqual(CommandDetection.detectApp(from: "sudo claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "sudo -u root claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "sudo -E claude"), "Claude")
    }

    func testSudoWithOptions() {
        XCTAssertEqual(CommandDetection.detectApp(from: "sudo -u admin -g wheel claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "sudo -- claude"), "Claude")
    }

    // MARK: - Environment Variables

    func testDetectWithEnvPrefix() {
        XCTAssertEqual(CommandDetection.detectApp(from: "FOO=bar claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "PATH=/usr/bin TERM=xterm claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "env FOO=bar claude"), "Claude")
    }

    func testEnvWithOptions() {
        XCTAssertEqual(CommandDetection.detectApp(from: "env -i claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "env -- claude"), "Claude")
    }

    // MARK: - Shell Wrappers

    func testDetectWithCommand() {
        XCTAssertEqual(CommandDetection.detectApp(from: "command claude"), "Claude")
    }

    func testDetectWithExec() {
        XCTAssertEqual(CommandDetection.detectApp(from: "exec claude"), "Claude")
    }

    func testDetectWithTime() {
        XCTAssertEqual(CommandDetection.detectApp(from: "time claude"), "Claude")
    }

    func testDetectWithNoglob() {
        XCTAssertEqual(CommandDetection.detectApp(from: "noglob claude"), "Claude")
    }

    // MARK: - Complex Commands

    func testDetectWithMultipleWrappers() {
        XCTAssertEqual(CommandDetection.detectApp(from: "env FOO=bar sudo -u root command claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "time sudo env PATH=/bin claude"), "Claude")
    }

    // MARK: - GitHub Copilot (gh copilot)

    func testDetectGhCopilot() {
        XCTAssertEqual(CommandDetection.detectApp(from: "gh copilot"), "Copilot")
        XCTAssertEqual(CommandDetection.detectApp(from: "gh copilot suggest"), "Copilot")
        XCTAssertEqual(CommandDetection.detectApp(from: "gh copilot explain"), "Copilot")
    }

    func testGhOtherSubcommands() {
        XCTAssertNil(CommandDetection.detectApp(from: "gh pr list"))
        XCTAssertNil(CommandDetection.detectApp(from: "gh issue create"))
    }

    // MARK: - npx/bunx

    func testDetectNpxClaude() {
        XCTAssertEqual(CommandDetection.detectApp(from: "npx claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "npx -y claude"), "Claude")
    }

    func testDetectBunxClaude() {
        XCTAssertEqual(CommandDetection.detectApp(from: "bunx claude"), "Claude")
    }

    func testDetectPnpmClaude() {
        XCTAssertEqual(CommandDetection.detectApp(from: "pnpm claude"), "Claude")
    }

    // MARK: - Output Detection

    func testDetectClaudeFromOutput() {
        XCTAssertEqual(CommandDetection.detectAppFromOutput("╭─ Claude Code"), "Claude")
        XCTAssertEqual(CommandDetection.detectAppFromOutput("Powered by Anthropic"), "Claude")
        XCTAssertEqual(CommandDetection.detectAppFromOutput("Visit claude.ai for more"), "Claude")
    }

    func testDetectGeminiFromOutput() {
        XCTAssertEqual(CommandDetection.detectAppFromOutput("Google AI Studio"), "Gemini")
        XCTAssertEqual(CommandDetection.detectAppFromOutput("Using Gemini Pro model"), "Gemini")
    }

    func testDetectChatGPTFromOutput() {
        XCTAssertEqual(CommandDetection.detectAppFromOutput("ChatGPT CLI v1.0"), "ChatGPT")
        XCTAssertEqual(CommandDetection.detectAppFromOutput("Visit openai.com"), "ChatGPT")
    }

    func testDetectCopilotFromOutput() {
        XCTAssertEqual(CommandDetection.detectAppFromOutput("GitHub Copilot CLI"), "Copilot")
        XCTAssertEqual(CommandDetection.detectAppFromOutput("Copilot CLI ready"), "Copilot")
    }

    func testNoDetectionFromOutput() {
        XCTAssertNil(CommandDetection.detectAppFromOutput("Hello, world!"))
        XCTAssertNil(CommandDetection.detectAppFromOutput("$ ls -la"))
    }

    // MARK: - Tokenization

    func testBasicTokenization() {
        XCTAssertEqual(CommandDetection.tokenize("claude"), ["claude"])
        XCTAssertEqual(CommandDetection.tokenize("claude --help"), ["claude", "--help"])
        XCTAssertEqual(CommandDetection.tokenize("ls -la /tmp"), ["ls", "-la", "/tmp"])
    }

    func testQuotedTokenization() {
        XCTAssertEqual(CommandDetection.tokenize("echo 'hello world'"), ["echo", "hello world"])
        XCTAssertEqual(CommandDetection.tokenize("echo \"hello world\""), ["echo", "hello world"])
    }

    func testEscapedTokenization() {
        XCTAssertEqual(CommandDetection.tokenize("echo hello\\ world"), ["echo", "hello world"])
    }

    func testCommentHandling() {
        XCTAssertEqual(CommandDetection.tokenize("claude # this is a comment"), ["claude"])
    }

    func testPipeHandling() {
        XCTAssertEqual(CommandDetection.tokenize("claude | grep foo"), ["claude"])
    }

    func testSemicolonHandling() {
        XCTAssertEqual(CommandDetection.tokenize("claude; echo done"), ["claude"])
    }

    func testAmpersandHandling() {
        XCTAssertEqual(CommandDetection.tokenize("claude &"), ["claude"])
        XCTAssertEqual(CommandDetection.tokenize("claude && echo done"), ["claude"])
    }

    // MARK: - Token Normalization

    func testNormalizeToken() {
        XCTAssertEqual(CommandDetection.normalizeToken("claude"), "claude")
        XCTAssertEqual(CommandDetection.normalizeToken("CLAUDE"), "claude")
        XCTAssertEqual(CommandDetection.normalizeToken("/usr/bin/claude"), "claude")
        XCTAssertEqual(CommandDetection.normalizeToken("./claude.sh"), "claude")
    }

    // MARK: - Environment Assignment Detection

    func testEnvAssignmentDetection() {
        XCTAssertTrue(CommandDetection.isEnvAssignment("FOO=bar"))
        XCTAssertTrue(CommandDetection.isEnvAssignment("_VAR=value"))
        XCTAssertTrue(CommandDetection.isEnvAssignment("PATH=/usr/bin"))
        XCTAssertFalse(CommandDetection.isEnvAssignment("claude"))
        XCTAssertFalse(CommandDetection.isEnvAssignment("--option=value"))
        XCTAssertFalse(CommandDetection.isEnvAssignment("123=invalid"))
    }

    // MARK: - Edge Cases

    func testEmptyInput() {
        XCTAssertNil(CommandDetection.detectApp(from: ""))
        XCTAssertNil(CommandDetection.detectApp(from: "   "))
    }

    func testOnlyEnvVars() {
        XCTAssertNil(CommandDetection.detectApp(from: "FOO=bar BAZ=qux"))
    }

    func testOnlyOptions() {
        XCTAssertNil(CommandDetection.detectApp(from: "-v --help"))
    }

    func testCaseSensitivity() {
        XCTAssertEqual(CommandDetection.detectApp(from: "CLAUDE"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "Claude"), "Claude")
        XCTAssertEqual(CommandDetection.detectApp(from: "cLaUdE"), "Claude")
    }
}

// MARK: - Event Parsing Tests

final class EventParsingTests: XCTestCase {

    func testEventTypeFromHook() {
        XCTAssertEqual(EventParsing.EventType(from: "UserPromptSubmit"), .userPrompt)
        XCTAssertEqual(EventParsing.EventType(from: "PreToolUse"), .toolStart)
        XCTAssertEqual(EventParsing.EventType(from: "PostToolUse"), .toolComplete)
        XCTAssertEqual(EventParsing.EventType(from: "PermissionRequest"), .permissionRequest)
        XCTAssertEqual(EventParsing.EventType(from: "Stop"), .responseComplete)
        XCTAssertEqual(EventParsing.EventType(from: "SessionEnd"), .sessionEnd)
        XCTAssertEqual(EventParsing.EventType(from: "UnknownHook"), .unknown)
    }

    func testParseEventJson() {
        let json = """
        {
            "type": "tool_start",
            "hook": "PreToolUse",
            "tool_name": "Read",
            "message": "Reading file.swift",
            "session_id": "abc123",
            "project_path": "/Users/test/project"
        }
        """.data(using: .utf8)!

        let event = EventParsing.parseEvent(json: json)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.type, .toolStart)
        XCTAssertEqual(event?.hook, "PreToolUse")
        XCTAssertEqual(event?.toolName, "Read")
        XCTAssertEqual(event?.message, "Reading file.swift")
        XCTAssertEqual(event?.sessionId, "abc123")
        XCTAssertEqual(event?.projectPath, "/Users/test/project")
    }

    func testParseInvalidJson() {
        let json = "not json".data(using: .utf8)!
        XCTAssertNil(EventParsing.parseEvent(json: json))
    }

    func testExtractSessionId() {
        XCTAssertEqual(
            EventParsing.extractSessionId(from: "/Users/test/.claude/sessions/abc123.jsonl"),
            "abc123"
        )
        XCTAssertEqual(
            EventParsing.extractSessionId(from: "/tmp/session-xyz.log"),
            "session-xyz"
        )
    }

    func testExtractProjectName() {
        XCTAssertEqual(
            EventParsing.extractProjectName(from: "/Users/test/projects/my-app"),
            "my-app"
        )
        XCTAssertEqual(
            EventParsing.extractProjectName(from: "/home/user/code/"),
            "code"
        )
    }

    func testAllEventTypes() {
        // Ensure all event types are testable
        for type in EventParsing.EventType.allCases {
            XCTAssertNotNil(type.rawValue)
        }
    }
}
