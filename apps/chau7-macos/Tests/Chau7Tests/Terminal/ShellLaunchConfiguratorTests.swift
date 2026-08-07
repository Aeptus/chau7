import XCTest
@testable import Chau7
import Chau7Core

final class ShellLaunchConfiguratorTests: XCTestCase {

    // MARK: - Helpers

    private func environmentDictionary(_ entries: [String]) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry -> (String, String)? in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )
    }

    private func makeInputs(
        processEnvironment: [String: String] = ["HOME": "/Users/tester"],
        pathValue: String = "/opt/homebrew/bin:/usr/bin:/bin",
        shellPath: String = "/bin/zsh",
        startDirectory: String = "/Users/tester",
        startupCommand: String = "",
        isLsColorsEnabled: Bool = false,
        integrationDir: String? = nil,
        proxyCorrelationSessionID: String = "session-123",
        tabID: String = "tab-456",
        projectDirectory: String = "/Users/tester/project",
        aiEventsLogPath: String = "/Users/tester/.ai-events.log",
        cto: ShellLaunchConfigurator.CTOLaunchContext? = nil,
        apiAnalytics: ShellLaunchConfigurator.APIAnalyticsProxyContext? = nil
    ) -> ShellLaunchConfigurator.LaunchEnvironmentInputs {
        ShellLaunchConfigurator.LaunchEnvironmentInputs(
            processEnvironment: processEnvironment,
            pathValue: pathValue,
            shellPath: shellPath,
            startDirectory: startDirectory,
            startupCommand: startupCommand,
            isLsColorsEnabled: isLsColorsEnabled,
            integrationDir: integrationDir,
            proxyCorrelationSessionID: proxyCorrelationSessionID,
            tabID: tabID,
            projectDirectory: projectDirectory,
            aiEventsLogPath: aiEventsLogPath,
            cto: cto,
            apiAnalytics: apiAnalytics
        )
    }

    private func launchEnvironment(
        _ inputs: ShellLaunchConfigurator.LaunchEnvironmentInputs
    ) -> [String: String] {
        environmentDictionary(ShellLaunchConfigurator.launchEnvironment(inputs))
    }

    // MARK: - RC-File Contents (zsh)

    func testZshrcContainsIntegrationMarkers() {
        let contents = ShellLaunchConfigurator.zshrcContents(
            fallbackHome: "/Users/tester",
            fallbackZdotdir: "/Users/tester"
        )

        XCTAssertTrue(contents.contains("export CHAU7_USER_HOME=\"${CHAU7_USER_HOME:-${HOME:-/Users/tester}}\""))
        XCTAssertTrue(contents.contains("export CHAU7_USER_ZDOTDIR=\"${CHAU7_USER_ZDOTDIR:-/Users/tester}\""))
        XCTAssertTrue(contents.contains("export ZDOTDIR=\"$CHAU7_USER_ZDOTDIR\""))
        // Sources the user's real zsh config
        XCTAssertTrue(contents.contains("[ -f \"$CHAU7_USER_ZDOTDIR/.zshrc\" ] && source \"$CHAU7_USER_ZDOTDIR/.zshrc\""))
        // Per-tab isolated history keyed off CHAU7_TAB_ID
        XCTAssertTrue(contents.contains("export HISTFILE=\"$CHAU7_USER_HOME/.chau7/history/${CHAU7_TAB_ID}.zsh_history\""))
        XCTAssertTrue(contents.contains("setopt NO_PROMPT_CR"))
        // CTO wrapper dir re-asserted at the FRONT of PATH after user rc files
        XCTAssertTrue(contents.contains(#"[[ ${path[(Ie)$_chau7_cto_bin]} -gt 0 ]] && path=("$_chau7_cto_bin" $path)"#))
        // OSC 7 cwd + OSC 9 exit-status integration hooks
        XCTAssertTrue(contents.contains("chau7_emit_exit_status"))
        XCTAssertTrue(contents.contains("smartoverlay_precmd"))
        XCTAssertTrue(contents.contains(#"print -Pn "\e]7;file://$HOSTNAME$PWD\a""#))
        XCTAssertTrue(contents.contains("ANTHROPIC_CUSTOM_HEADERS"))
        XCTAssertFalse(contents.contains("ANTHROPIC_EXTRA_HEADERS"))
        XCTAssertTrue(contents.contains("X-Chau7-Session:${CHAU7_SESSION_ID:-}\nX-Chau7-Tab:${CHAU7_TAB_ID:-}\nX-Chau7-Project:${CHAU7_PROJECT:-}"))
        XCTAssertTrue(contents.contains("CHAU7_OPENAI_PROXY_BASE_URL/_chau7/project/$project_token/v1"))
        XCTAssertTrue(contents.contains("CHAU7_CODEX_PROXY_WRAPPER_DIR/codex"))
        // Startup command runs last
        XCTAssertTrue(contents.hasSuffix("if [ -n \"$CHAU7_STARTUP_CMD\" ]; then\n  eval \"$CHAU7_STARTUP_CMD\"\nfi"))
    }

    func testZshrcInterpolatesProvidedFallbackPaths() {
        let contents = ShellLaunchConfigurator.zshrcContents(
            fallbackHome: "/custom/home",
            fallbackZdotdir: "/custom/zdotdir"
        )

        XCTAssertTrue(contents.contains("${HOME:-/custom/home}"))
        XCTAssertTrue(contents.contains("${CHAU7_USER_ZDOTDIR:-/custom/zdotdir}"))
    }

    // MARK: - RC-File Contents (bash)

    func testBashrcContainsIntegrationMarkers() {
        let contents = ShellLaunchConfigurator.bashrcContents(fallbackHome: "/Users/tester")

        XCTAssertTrue(contents.contains("export CHAU7_USER_HOME=\"${CHAU7_USER_HOME:-${HOME:-/Users/tester}}\""))
        // Sources the user's real bash config
        XCTAssertTrue(contents.contains("[ -f \"$CHAU7_USER_HOME/.bashrc\" ] && source \"$CHAU7_USER_HOME/.bashrc\""))
        XCTAssertTrue(contents.contains("[ -f \"$CHAU7_USER_HOME/.bash_profile\" ] && source \"$CHAU7_USER_HOME/.bash_profile\""))
        // Per-tab isolated history keyed off CHAU7_TAB_ID
        XCTAssertTrue(contents.contains("export HISTFILE=\"$CHAU7_USER_HOME/.chau7/history/${CHAU7_TAB_ID}.bash_history\""))
        // CTO wrapper dir re-asserted at the FRONT of PATH after user rc files
        XCTAssertTrue(contents.contains("export PATH=\"$_chau7_cto_bin:$PATH\""))
        // Integration hooks are chained through PROMPT_COMMAND
        XCTAssertTrue(contents.contains("PROMPT_COMMAND=\"smartoverlay_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}\""))
        XCTAssertTrue(contents.contains("PROMPT_COMMAND=\"chau7_emit_exit_status${PROMPT_COMMAND:+;$PROMPT_COMMAND}\""))
        XCTAssertTrue(contents.contains("ANTHROPIC_CUSTOM_HEADERS"))
        XCTAssertTrue(contents.contains("X-Chau7-Session:${CHAU7_SESSION_ID:-}\nX-Chau7-Tab:${CHAU7_TAB_ID:-}\nX-Chau7-Project:${CHAU7_PROJECT:-}"))
        XCTAssertTrue(contents.contains("CHAU7_OPENAI_PROXY_BASE_URL/_chau7/project/$project_token/v1"))
        XCTAssertTrue(contents.contains("CHAU7_CODEX_PROXY_WRAPPER_DIR/codex"))
        // Startup command runs last
        XCTAssertTrue(contents.hasSuffix("if [ -n \"$CHAU7_STARTUP_CMD\" ]; then\n  eval \"$CHAU7_STARTUP_CMD\"\nfi"))
    }

    // MARK: - RC-File Contents (fish)

    func testFishConfigContainsIntegrationMarkers() {
        let contents = ShellLaunchConfigurator.fishConfigContents(
            fallbackHome: "/Users/tester",
            fallbackXDGConfigHome: "/Users/tester/.config"
        )

        XCTAssertTrue(contents.contains("set -gx CHAU7_USER_HOME \"/Users/tester\""))
        XCTAssertTrue(contents.contains("set -gx CHAU7_USER_XDG_CONFIG_HOME \"/Users/tester/.config\""))
        // Sources the user's real config.fish
        XCTAssertTrue(contents.contains("source \"$CHAU7_USER_XDG_CONFIG_HOME/fish/config.fish\""))
        // Per-tab isolated history via fish_history session name (hyphens swapped)
        XCTAssertTrue(contents.contains("set -gx fish_history (string replace -a -- - _ \"chau7_$CHAU7_TAB_ID\")"))
        // CTO wrapper dir re-asserted at the FRONT of PATH after user rc files
        XCTAssertTrue(contents.contains("set -gx PATH \"$_chau7_cto_bin\" (string match -v -- \"$_chau7_cto_bin\" $PATH)"))
        // Integration hooks fire on prompt and PWD changes
        XCTAssertTrue(contents.contains("function smartoverlay_precmd --on-event fish_prompt --on-variable PWD"))
        XCTAssertTrue(contents.contains("function chau7_update_project --on-variable PWD"))
        XCTAssertTrue(contents.contains("ANTHROPIC_CUSTOM_HEADERS"))
        XCTAssertTrue(contents.contains("X-Chau7-Session:$CHAU7_SESSION_ID\nX-Chau7-Tab:$CHAU7_TAB_ID\nX-Chau7-Project:$CHAU7_PROJECT"))
        XCTAssertTrue(contents.contains("CHAU7_OPENAI_PROXY_BASE_URL/_chau7/project/$project_token/v1"))
        XCTAssertTrue(contents.contains("CHAU7_CODEX_PROXY_WRAPPER_DIR/codex"))
        // Startup command runs last
        XCTAssertTrue(contents.hasSuffix("if test -n \"$CHAU7_STARTUP_CMD\"\n  eval \"$CHAU7_STARTUP_CMD\"\nend"))
    }

    // MARK: - RC-File Writing

    func testWriteShellIntegrationFilesWritesAllThreeShellsUnderInjectedDirectory() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-launch-configurator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let environment = ["HOME": "/Users/tester"]
        let didWrite = ShellLaunchConfigurator.writeShellIntegrationFiles(
            to: baseDir.path,
            environment: environment
        )
        XCTAssertTrue(didWrite)

        let zshrc = try String(contentsOfFile: baseDir.path + "/.zshrc", encoding: .utf8)
        let bashrc = try String(contentsOfFile: baseDir.path + "/.bashrc", encoding: .utf8)
        let fishConfig = try String(
            contentsOfFile: baseDir.path + "/.config/fish/config.fish",
            encoding: .utf8
        )
        let codexWrapper = try String(contentsOfFile: baseDir.path + "/bin/codex", encoding: .utf8)

        XCTAssertEqual(
            zshrc,
            ShellLaunchConfigurator.zshrcContents(fallbackHome: "/Users/tester", fallbackZdotdir: "/Users/tester")
        )
        XCTAssertEqual(bashrc, ShellLaunchConfigurator.bashrcContents(fallbackHome: "/Users/tester"))
        XCTAssertEqual(
            fishConfig,
            ShellLaunchConfigurator.fishConfigContents(
                fallbackHome: "/Users/tester",
                fallbackXDGConfigHome: "/Users/tester/.config"
            )
        )
        XCTAssertEqual(codexWrapper, ShellLaunchConfigurator.codexProxyWrapperContents())
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: baseDir.path + "/bin/codex"))
    }

    func testCodexProxyWrapperUsesSupportedConfigAndCombinesCABundles() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-proxy-wrapper-tests-\(UUID().uuidString)")
        let integrationDir = baseDir.appendingPathComponent("integration")
        let fakeBinDir = baseDir.appendingPathComponent("real-bin")
        try FileManager.default.createDirectory(at: integrationDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBinDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        XCTAssertTrue(ShellLaunchConfigurator.writeShellIntegrationFiles(to: integrationDir.path))
        let captureArgs = baseDir.appendingPathComponent("args.txt")
        let captureCA = baseDir.appendingPathComponent("ca-path.txt")
        let capturePATH = baseDir.appendingPathComponent("path.txt")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "$CHAU7_CAPTURE_ARGS"
        printf '%s\\n' "$CODEX_CA_CERTIFICATE" > "$CHAU7_CAPTURE_CA"
        printf '%s\\n' "$PATH" > "$CHAU7_CAPTURE_PATH"
        """.write(to: fakeBinDir.appendingPathComponent("codex"), atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s\\n' "$CHAU7_TEST_GIT_ROOT"
        """.write(to: fakeBinDir.appendingPathComponent("git"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBinDir.appendingPathComponent("codex").path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBinDir.appendingPathComponent("git").path
        )

        let userCA = baseDir.appendingPathComponent("user-ca.pem")
        let localCA = baseDir.appendingPathComponent("local-ca.pem")
        try "USER CA\n".write(to: userCA, atomically: true, encoding: .utf8)
        try "LOCAL CA\n".write(to: localCA, atomically: true, encoding: .utf8)

        let wrapper = integrationDir.appendingPathComponent("bin/codex")
        let process = Process()
        process.executableURL = wrapper
        process.arguments = ["exec", "--json"]
        process.currentDirectoryURL = baseDir
        process.environment = [
            "PATH": "\(integrationDir.path)/bin:\(fakeBinDir.path):/usr/bin:/bin",
            "CHAU7_OPENAI_PROXY_BASE_URL": "https://127.0.0.1:8900",
            "CHAU7_CODEX_CA_CERTIFICATE": localCA.path,
            "CHAU7_TAB_ID": "tab-123",
            "CHAU7_CAPTURE_ARGS": captureArgs.path,
            "CHAU7_CAPTURE_CA": captureCA.path,
            "CHAU7_CAPTURE_PATH": capturePATH.path,
            "CHAU7_TEST_GIT_ROOT": "/repo/Codex Project",
            "CODEX_CA_CERTIFICATE": userCA.path,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let expectedBase = "https://127.0.0.1:8900\(ShellLaunchConfigurator.proxyProjectPath("/repo/Codex Project"))/v1"
        XCTAssertEqual(
            try String(contentsOf: captureArgs, encoding: .utf8).split(separator: "\n").map(String.init),
            ["-c", "openai_base_url=\"\(expectedBase)\"", "exec", "--json"]
        )
        let combinedCAPath = try String(contentsOf: captureCA, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try String(contentsOfFile: combinedCAPath, encoding: .utf8), "USER CA\nLOCAL CA\n")
        let childPATH = try String(contentsOf: capturePATH, encoding: .utf8)
        XCTAssertFalse(childPATH.contains(integrationDir.appendingPathComponent("bin").path))
    }

    func testCodexProxyWrapperFallsBackToDirectCodexWhenCertificateIsMissing() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-proxy-fallback-tests-\(UUID().uuidString)")
        let integrationDir = baseDir.appendingPathComponent("integration")
        let fakeBinDir = baseDir.appendingPathComponent("real-bin")
        try FileManager.default.createDirectory(at: integrationDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBinDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        XCTAssertTrue(ShellLaunchConfigurator.writeShellIntegrationFiles(to: integrationDir.path))
        let captureArgs = baseDir.appendingPathComponent("args.txt")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "$CHAU7_CAPTURE_ARGS"
        """.write(to: fakeBinDir.appendingPathComponent("codex"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBinDir.appendingPathComponent("codex").path
        )

        let process = Process()
        process.executableURL = integrationDir.appendingPathComponent("bin/codex")
        process.arguments = ["login", "status"]
        process.environment = [
            "PATH": "\(integrationDir.path)/bin:\(fakeBinDir.path):/usr/bin:/bin",
            "CHAU7_OPENAI_PROXY_BASE_URL": "https://127.0.0.1:8900",
            "CHAU7_CODEX_CA_CERTIFICATE": baseDir.appendingPathComponent("missing.pem").path,
            "CHAU7_CAPTURE_ARGS": captureArgs.path,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: captureArgs, encoding: .utf8).split(separator: "\n").map(String.init),
            ["login", "status"]
        )
    }

    func testWriteShellIntegrationFilesReturnsFalseWhenDirectoryDoesNotExist() {
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-launch-configurator-missing-\(UUID().uuidString)")
            .appendingPathComponent("nested")

        // The base directory is missing and .zshrc cannot be created inside it.
        XCTAssertFalse(ShellLaunchConfigurator.writeShellIntegrationFiles(to: missingDir.path))
    }

    // MARK: - Launch Environment

    func testLaunchEnvironmentIncludesCoreTerminalIdentity() {
        let env = launchEnvironment(makeInputs())

        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["TERM_PROGRAM"], "Chau7")
        XCTAssertEqual(env["TERM_PROGRAM_VERSION"], "1.0")
        XCTAssertEqual(env["SHELL_SESSIONS_DISABLE"], "1")
    }

    func testLaunchEnvironmentUsesProvidedPATHAndHome() {
        let env = launchEnvironment(makeInputs(
            processEnvironment: ["HOME": "/Users/tester"],
            pathValue: "/custom/bin:/usr/bin"
        ))

        XCTAssertEqual(env["PATH"], "/custom/bin:/usr/bin")
        XCTAssertEqual(env["HOME"], "/Users/tester")
        XCTAssertEqual(env["CHAU7_USER_HOME"], "/Users/tester")
    }

    func testLaunchEnvironmentOmitsHomeWhenProcessEnvironmentLacksIt() {
        let env = launchEnvironment(makeInputs(processEnvironment: [:]))

        XCTAssertNil(env["HOME"])
    }

    func testLaunchEnvironmentIncludesUTF8LocaleHints() {
        let env = launchEnvironment(makeInputs(processEnvironment: [:]))

        XCTAssertTrue(env["LANG"]?.lowercased().contains("utf") ?? false)
        XCTAssertTrue(env["LC_CTYPE"]?.lowercased().contains("utf") ?? false)
    }

    func testLaunchEnvironmentIncludesSessionAndTabIdentity() {
        let env = launchEnvironment(makeInputs(
            startDirectory: "/start/here",
            proxyCorrelationSessionID: "proxy-session",
            tabID: "tab-uuid",
            projectDirectory: "/repo",
            aiEventsLogPath: "/logs/.ai-events.log"
        ))

        XCTAssertEqual(env["TERM_SESSION_ID"], "proxy-session")
        XCTAssertEqual(env["CHAU7_SESSION_ID"], "proxy-session")
        XCTAssertEqual(env["CHAU7_TAB_ID"], "tab-uuid")
        XCTAssertEqual(env["CHAU7_PROJECT"], "/repo")
        XCTAssertEqual(env["CHAU7_AI_EVENTS_LOG"], "/logs/.ai-events.log")
        XCTAssertEqual(env["CHAU7_START_DIR"], "/start/here")
        XCTAssertEqual(env["SHELL"], "/bin/zsh")
    }

    func testLaunchEnvironmentIncludesStartupCommandWhenConfigured() {
        let env = launchEnvironment(makeInputs(startupCommand: "  claude --resume  "))

        XCTAssertEqual(env["CHAU7_STARTUP_CMD"], "claude --resume")
    }

    func testLaunchEnvironmentOmitsStartupCommandWhenBlank() {
        let env = launchEnvironment(makeInputs(startupCommand: "   "))

        XCTAssertNil(env["CHAU7_STARTUP_CMD"])
    }

    func testLaunchEnvironmentHonorsLsColorsToggle() {
        let enabled = launchEnvironment(makeInputs(isLsColorsEnabled: true))
        XCTAssertEqual(enabled["CLICOLOR"], "1")
        XCTAssertEqual(enabled["LSCOLORS"], ShellLaunchConfigurator.defaultLsColors)

        let disabled = launchEnvironment(makeInputs(isLsColorsEnabled: false))
        XCTAssertNil(disabled["CLICOLOR"])
        XCTAssertNil(disabled["LSCOLORS"])
    }

    func testLaunchEnvironmentIncludesCTOVariablesOnlyWhenEnabled() {
        let enabled = launchEnvironment(makeInputs(
            cto: ShellLaunchConfigurator.CTOLaunchContext(
                sessionID: "cto-session",
                commandLogPath: "/cto/commands.log"
            )
        ))
        XCTAssertEqual(enabled["CHAU7_CTO_SESSION"], "cto-session")
        XCTAssertEqual(enabled["CHAU7_CTO_LOG"], "/cto/commands.log")

        let disabled = launchEnvironment(makeInputs(cto: nil))
        XCTAssertNil(disabled["CHAU7_CTO_SESSION"])
        XCTAssertNil(disabled["CHAU7_CTO_LOG"])
    }

    func testLaunchEnvironmentSetsPerShellIntegrationVariable() {
        let zsh = launchEnvironment(makeInputs(shellPath: "/bin/zsh", integrationDir: "/integration"))
        XCTAssertEqual(zsh["ZDOTDIR"], "/integration")
        XCTAssertNil(zsh["BASH_ENV"])
        XCTAssertNil(zsh["XDG_CONFIG_HOME"])

        let bash = launchEnvironment(makeInputs(shellPath: "/bin/bash", integrationDir: "/integration"))
        XCTAssertEqual(bash["BASH_ENV"], "/integration/.bashrc")
        XCTAssertNil(bash["ZDOTDIR"])

        let fish = launchEnvironment(makeInputs(
            shellPath: "/opt/homebrew/bin/fish",
            integrationDir: "/integration"
        ))
        XCTAssertEqual(fish["XDG_CONFIG_HOME"], "/integration/.config")
        XCTAssertNil(fish["ZDOTDIR"])
    }

    func testLaunchEnvironmentOmitsIntegrationVariablesWithoutIntegrationDir() {
        let env = launchEnvironment(makeInputs(shellPath: "/bin/zsh", integrationDir: nil))

        XCTAssertNil(env["ZDOTDIR"])
        XCTAssertNil(env["BASH_ENV"])
        XCTAssertNil(env["XDG_CONFIG_HOME"])
    }

    func testLaunchEnvironmentInjectsAPIAnalyticsProxyEndpoints() {
        let withOpenAI = launchEnvironment(makeInputs(
            integrationDir: "/integration",
            apiAnalytics: ShellLaunchConfigurator.APIAnalyticsProxyContext(
                port: 8899,
                includeOpenAI: true,
                tlsCertificatePath: "/proxy/proxy-cert.pem"
            )
        ))
        XCTAssertEqual(withOpenAI["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8899")
        XCTAssertEqual(
            withOpenAI["ANTHROPIC_CUSTOM_HEADERS"],
            "X-Chau7-Session:session-123\nX-Chau7-Tab:tab-456\nX-Chau7-Project:/Users/tester/project"
        )
        XCTAssertEqual(withOpenAI["CHAU7_PROXY_CORRELATION_ENABLED"], "1")
        XCTAssertEqual(withOpenAI["CHAU7_OPENAI_PROXY_BASE_URL"], "https://127.0.0.1:8900")
        XCTAssertEqual(withOpenAI["CHAU7_CODEX_PROXY_WRAPPER_DIR"], "/integration/bin")
        XCTAssertEqual(withOpenAI["CHAU7_CODEX_CA_CERTIFICATE"], "/proxy/proxy-cert.pem")
        XCTAssertEqual(
            withOpenAI["OPENAI_BASE_URL"],
            "https://127.0.0.1:8900/_chau7/project/L1VzZXJzL3Rlc3Rlci9wcm9qZWN0/v1"
        )
        XCTAssertEqual(withOpenAI["GOOGLE_GEMINI_BASE_URL"], "http://127.0.0.1:8899")

        let withoutOpenAI = launchEnvironment(makeInputs(
            apiAnalytics: ShellLaunchConfigurator.APIAnalyticsProxyContext(port: 8899, includeOpenAI: false)
        ))
        XCTAssertEqual(withoutOpenAI["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8899")
        XCTAssertNotNil(withoutOpenAI["ANTHROPIC_CUSTOM_HEADERS"])
        XCTAssertNil(withoutOpenAI["OPENAI_BASE_URL"])
        XCTAssertNil(withoutOpenAI["CHAU7_OPENAI_PROXY_BASE_URL"])
        XCTAssertNil(withoutOpenAI["CHAU7_CODEX_PROXY_WRAPPER_DIR"])
        XCTAssertNil(withoutOpenAI["CHAU7_CODEX_CA_CERTIFICATE"])

        let disabled = launchEnvironment(makeInputs(apiAnalytics: nil))
        XCTAssertNil(disabled["ANTHROPIC_BASE_URL"])
        XCTAssertNil(disabled["ANTHROPIC_CUSTOM_HEADERS"])
        XCTAssertNil(disabled["CHAU7_PROXY_CORRELATION_ENABLED"])
        XCTAssertNil(disabled["OPENAI_BASE_URL"])
        XCTAssertNil(disabled["GOOGLE_GEMINI_BASE_URL"])
    }

    // MARK: - Shell Arguments

    func testShellArgumentsForBashUsesRcfile() {
        XCTAssertEqual(
            ShellLaunchConfigurator.shellArguments(shellPath: "/bin/bash", integrationDir: "/integration"),
            ["--rcfile", "/integration/.bashrc"]
        )
    }

    func testShellArgumentsForBashWithoutIntegrationDirIsEmpty() {
        XCTAssertEqual(
            ShellLaunchConfigurator.shellArguments(shellPath: "/bin/bash", integrationDir: nil),
            []
        )
    }

    func testShellArgumentsForZshAndFishAreEmpty() {
        XCTAssertEqual(
            ShellLaunchConfigurator.shellArguments(shellPath: "/bin/zsh", integrationDir: "/integration"),
            []
        )
        XCTAssertEqual(
            ShellLaunchConfigurator.shellArguments(shellPath: "/opt/homebrew/bin/fish", integrationDir: "/integration"),
            []
        )
    }

    // MARK: - Shell Path Resolution

    func testShellPathForFixedShellTypes() {
        XCTAssertEqual(
            ShellLaunchConfigurator.shellPath(for: .zsh, customShellPath: "", fileExists: { _ in false }),
            "/bin/zsh"
        )
        XCTAssertEqual(
            ShellLaunchConfigurator.shellPath(for: .bash, customShellPath: "", fileExists: { _ in false }),
            "/bin/bash"
        )
    }

    func testShellPathForSystemUsesSystemShell() {
        let path = ShellLaunchConfigurator.shellPath(
            for: .system,
            customShellPath: "",
            fileExists: { _ in false },
            systemShell: { "/system/shell" }
        )
        XCTAssertEqual(path, "/system/shell")
    }

    func testShellPathForFishPrefersAppleSiliconThenIntelThenZsh() {
        XCTAssertEqual(
            ShellLaunchConfigurator.shellPath(
                for: .fish,
                customShellPath: "",
                fileExists: { $0 == "/opt/homebrew/bin/fish" }
            ),
            "/opt/homebrew/bin/fish"
        )
        XCTAssertEqual(
            ShellLaunchConfigurator.shellPath(
                for: .fish,
                customShellPath: "",
                fileExists: { $0 == "/usr/local/bin/fish" }
            ),
            "/usr/local/bin/fish"
        )
        XCTAssertEqual(
            ShellLaunchConfigurator.shellPath(for: .fish, customShellPath: "", fileExists: { _ in false }),
            "/bin/zsh"
        )
    }

    func testShellPathForFishIntelFallsBackToZsh() {
        XCTAssertEqual(
            ShellLaunchConfigurator.shellPath(
                for: .fishIntel,
                customShellPath: "",
                fileExists: { $0 == "/usr/local/bin/fish" }
            ),
            "/usr/local/bin/fish"
        )
        XCTAssertEqual(
            ShellLaunchConfigurator.shellPath(for: .fishIntel, customShellPath: "", fileExists: { _ in false }),
            "/bin/zsh"
        )
    }

    func testShellPathForCustomUsesExistingPathOrSystemShell() {
        XCTAssertEqual(
            ShellLaunchConfigurator.shellPath(
                for: .custom,
                customShellPath: "  /custom/shell  ",
                fileExists: { $0 == "/custom/shell" },
                systemShell: { "/system/shell" }
            ),
            "/custom/shell"
        )
        XCTAssertEqual(
            ShellLaunchConfigurator.shellPath(
                for: .custom,
                customShellPath: "/missing/shell",
                fileExists: { _ in false },
                systemShell: { "/system/shell" }
            ),
            "/system/shell"
        )
        XCTAssertEqual(
            ShellLaunchConfigurator.shellPath(
                for: .custom,
                customShellPath: "   ",
                fileExists: { _ in true },
                systemShell: { "/system/shell" }
            ),
            "/system/shell"
        )
    }

    func testSystemDefaultShellFallsBackToZshWhenPasswdShellIsNotExecutable() {
        XCTAssertEqual(ShellLaunchConfigurator.systemDefaultShell(isExecutable: { _ in false }), "/bin/zsh")
    }

    func testSystemDefaultShellReturnsPasswdShellWhenExecutable() {
        let shell = ShellLaunchConfigurator.systemDefaultShell(isExecutable: { _ in true })
        XCTAssertTrue(shell.hasPrefix("/"))
        XCTAssertFalse(shell.isEmpty)
    }

    // MARK: - Start Directory

    func testStartDirectoryForLaunchUsesRequestedDirectoryWhenItExists() {
        let result = ShellLaunchConfigurator.startDirectoryForLaunch(
            requested: "/tmp",
            defaultDirectory: "/default",
            isDirectory: { $0 == "/tmp" }
        )
        XCTAssertEqual(result, "/tmp")
    }

    func testStartDirectoryForLaunchFallsBackToDefaultWhenRequestedIsEmpty() {
        let result = ShellLaunchConfigurator.startDirectoryForLaunch(
            requested: "   ",
            defaultDirectory: "/default",
            isDirectory: { $0 == "/default" }
        )
        XCTAssertEqual(result, "/default")
    }

    func testStartDirectoryForLaunchFallsBackToDefaultWhenRequestedIsMissing() {
        let result = ShellLaunchConfigurator.startDirectoryForLaunch(
            requested: "/does/not/exist",
            defaultDirectory: "/default",
            isDirectory: { $0 == "/default" }
        )
        XCTAssertEqual(result, "/default")
    }

    func testResolveStartDirectoryExpandsTildeAndAnchorsRelativePaths() {
        let home = RuntimeIsolation.homePath()

        XCTAssertEqual(ShellLaunchConfigurator.resolveStartDirectory("~"), home)
        XCTAssertEqual(ShellLaunchConfigurator.resolveStartDirectory(""), home)
        XCTAssertEqual(ShellLaunchConfigurator.resolveStartDirectory("/tmp"), "/tmp")
        XCTAssertEqual(
            ShellLaunchConfigurator.resolveStartDirectory("Desktop"),
            (home as NSString).appendingPathComponent("Desktop")
        )
    }
}
