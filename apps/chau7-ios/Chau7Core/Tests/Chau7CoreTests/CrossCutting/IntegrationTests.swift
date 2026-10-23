import XCTest
@testable import Chau7Core

// MARK: - Integration Tests

/// Integration tests for component interactions
final class IntegrationTests: XCTestCase {

    // MARK: - Command Detection + Shell Escaping Integration

    func testIntegration_DetectAndEscape_Claude() {
        let command = "claude --help"
        let detection = CommandDetection.detectApp(from: command)

        XCTAssertEqual(detection, "Claude")

        // Verify command can be safely escaped
        let escaped = ShellEscaping.escapeArgument(command)
        XCTAssertTrue(escaped.hasPrefix("'"))
        XCTAssertTrue(escaped.hasSuffix("'"))
    }

    func testIntegration_DetectAndEscape_WithPath() {
        let command = "/usr/local/bin/codex chat"
        let detection = CommandDetection.detectApp(from: command)

        XCTAssertEqual(detection, "Codex")

        // Path should be valid
        let path = "/usr/local/bin/codex"
        XCTAssertTrue(ShellEscaping.isValidPath(path))
    }

    func testIntegration_DetectAndEscape_SSHStyle() {
        // Simulate SSH command that might run claude remotely
        let sshOptions = "-o StrictHostKeyChecking=no"
        let validation = ShellEscaping.validateSSHOptions(sshOptions)
        XCTAssertTrue(validation.isValid)

        // Then detect claude command
        let remoteCommand = "claude code"
        let detection = CommandDetection.detectApp(from: remoteCommand)
        XCTAssertEqual(detection, "Claude")
    }

    // MARK: - Snippet Parsing + Environment Integration

    func testIntegration_SnippetWithUserEnv() {
        // Note: replaceEnvTokens uses ${env:VAR} format, not ${VAR}
        let template = "cd ${env:HOME}/projects && ls"
        let expanded = SnippetParsing.replaceEnvTokens(in: template)

        // If HOME is set, it should be expanded
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            XCTAssertTrue(expanded.contains(home))
        }
        XCTAssertFalse(expanded.contains("${env:HOME}"))
    }

    func testIntegration_SnippetWithPlaceholdersAndEnv() {
        let template = "ssh ${1:user}@${2:host} 'cd ${env:HOME} && ${3:command}'"

        // First expand environment
        let withEnv = SnippetParsing.replaceEnvTokens(in: template)

        // Then expand placeholders
        let result = SnippetParsing.expandPlaceholders(in: withEnv)

        // Should have 3 placeholders
        XCTAssertEqual(result.placeholders.count, 3)

        // env:HOME should be expanded
        XCTAssertFalse(result.text.contains("${env:HOME}"))
    }

    // MARK: - Color Parsing + Theme Integration

    func testIntegration_ParseAndAdjustColor() {
        let hex = "#1E1E1E"

        // Parse hex
        guard let rgb = ColorParsing.parseHex(hex) else {
            XCTFail("Failed to parse hex color")
            return
        }

        // Check parsed values (30/255 ≈ 0.1176)
        XCTAssertEqual(rgb.red, 30.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(rgb.green, 30.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(rgb.blue, 30.0 / 255.0, accuracy: 0.001)

        // Adjust brightness
        let brighter = ColorParsing.adjustBrightness(rgb, factor: 1.5)

        XCTAssertEqual(brighter.red, 45.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(brighter.green, 45.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(brighter.blue, 45.0 / 255.0, accuracy: 0.001)
    }

    func testIntegration_ColorSchemeColors() {
        // Test a set of theme colors
        let themeColors = [
            "#282A36", // Background
            "#F8F8F2", // Foreground
            "#FF79C6", // Pink
            "#50FA7B", // Green
            "#8BE9FD" // Cyan
        ]

        for hex in themeColors {
            guard let rgb = ColorParsing.parseHex(hex) else {
                XCTFail("Failed to parse \(hex)")
                continue
            }

            // Verify luminance calculation doesn't crash
            let luminance = ColorParsing.luminance(rgb)
            XCTAssertGreaterThanOrEqual(luminance, 0)
            XCTAssertLessThanOrEqual(luminance, 1)
        }
    }

    // MARK: - Security Integration

    func testIntegration_SecurityChain() {
        // Simulate user input going through security chain

        // 1. User enters SSH options
        let userOptions = "-L 8080:localhost:80"
        let validation = ShellEscaping.validateSSHOptions(userOptions)
        XCTAssertTrue(validation.isValid)

        // 2. User enters a path
        let userPath = "~/Documents/my file.txt"
        let isValid = ShellEscaping.isValidPath(userPath)
        XCTAssertTrue(isValid)

        // 3. Path is sanitized
        let sanitized = ShellEscaping.sanitizePath(userPath)
        XCTAssertFalse(sanitized.contains("\0"))

        // 4. Path is escaped for shell
        let escaped = ShellEscaping.escapePath(sanitized)
        XCTAssertTrue(escaped.hasPrefix("'"))
    }

    func testIntegration_SecurityChain_MaliciousInput() {
        // 1. Malicious SSH options should be blocked
        let maliciousSSH = "-o ProxyCommand=evil"
        let validation = ShellEscaping.validateSSHOptions(maliciousSSH)
        XCTAssertFalse(validation.isValid)
        guard case .dangerousOption(let option)? = validation.issue else {
            return XCTFail("Expected dangerous option issue")
        }
        XCTAssertTrue(option.contains("ProxyCommand"))

        // 2. Malicious path should be detected
        let maliciousPath = "/etc/passwd; rm -rf /"
        let hasMetachars = ShellEscaping.containsMetacharacters(maliciousPath)
        XCTAssertTrue(hasMetachars)

        // 3. Even if escaped, detection should work
        let escaped = ShellEscaping.escapeArgument(maliciousPath)
        // The escaped version should be safe
        XCTAssertTrue(escaped.hasPrefix("'"))
        XCTAssertTrue(escaped.hasSuffix("'"))
    }

    // MARK: - Full Workflow Tests

    func testIntegration_WorkflowSSHConnection() {
        // Simulate creating an SSH connection

        // User input
        let host = "server.example.com"
        let user = "admin"
        let port = 22
        let identityFile = "~/.ssh/id_rsa"
        let extraOptions = "-o ServerAliveInterval=60"

        // Validate options
        let validation = ShellEscaping.validateSSHOptions(extraOptions)
        XCTAssertTrue(validation.isValid)

        // Build command parts
        let escapedHost = ShellEscaping.escapeArgument(host)
        let escapedUser = ShellEscaping.escapeArgument(user)
        let escapedIdentity = ShellEscaping.escapePath(identityFile)

        // Verify all parts are properly escaped
        XCTAssertTrue(escapedHost.hasPrefix("'"))
        XCTAssertTrue(escapedUser.hasPrefix("'"))
        XCTAssertTrue(escapedIdentity.hasPrefix("'"))

        // Build final command
        let command = "ssh -p \(port) -i \(escapedIdentity) \(extraOptions) \(escapedUser)@\(escapedHost)"
        XCTAssertFalse(command.isEmpty)
    }

    func testIntegration_WorkflowSnippetInsertion() {
        // Simulate snippet insertion workflow

        // 1. User selects a snippet
        let snippetBody = "git commit -m \"${1:feat: description}\" && git push ${2:origin} ${3:main}"

        // 2. Environment tokens would be replaced (none in this case)
        let withEnv = SnippetParsing.replaceEnvTokens(in: snippetBody)
        XCTAssertEqual(withEnv, snippetBody) // No env vars to replace

        // 3. Placeholders are expanded
        let result = SnippetParsing.expandPlaceholders(in: withEnv)

        // 4. Verify result
        XCTAssertEqual(result.placeholders.count, 3)
        XCTAssertTrue(result.text.contains("feat: description"))
        XCTAssertTrue(result.text.contains("origin"))
        XCTAssertTrue(result.text.contains("main"))
    }

    // MARK: - Error Handling Integration

    func testIntegration_GracefulDegradation_InvalidColor() {
        // Invalid hex should return nil, not crash
        let invalidHex = "not-a-color"
        let result = ColorParsing.parseHex(invalidHex)
        XCTAssertNil(result)
    }

    func testIntegration_GracefulDegradation_EmptyCommand() {
        // Empty command should return nil detection
        let result = CommandDetection.detectApp(from: "")
        XCTAssertNil(result)
    }

    func testIntegration_GracefulDegradation_EmptySnippet() {
        // Empty snippet should return empty result
        let result = SnippetParsing.expandPlaceholders(in: "")
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.placeholders.count, 0)
    }
}
