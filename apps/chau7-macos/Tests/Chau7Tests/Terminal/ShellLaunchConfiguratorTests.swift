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
        // OSC 7 cwd + OSC 9 exit-status integration hooks
        XCTAssertTrue(contents.contains("chau7_emit_exit_status"))
        XCTAssertTrue(contents.contains("smartoverlay_precmd"))
        XCTAssertTrue(contents.contains(#"print -Pn "\e]7;file://$HOSTNAME$PWD\a""#))
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
        // Integration hooks are chained through PROMPT_COMMAND
        XCTAssertTrue(contents.contains("PROMPT_COMMAND=\"smartoverlay_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}\""))
        XCTAssertTrue(contents.contains("PROMPT_COMMAND=\"chau7_emit_exit_status${PROMPT_COMMAND:+;$PROMPT_COMMAND}\""))
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
        // Integration hooks fire on prompt and PWD changes
        XCTAssertTrue(contents.contains("function smartoverlay_precmd --on-event fish_prompt --on-variable PWD"))
        XCTAssertTrue(contents.contains("function chau7_update_project --on-variable PWD"))
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
            apiAnalytics: ShellLaunchConfigurator.APIAnalyticsProxyContext(port: 8899, includeOpenAI: true)
        ))
        XCTAssertEqual(withOpenAI["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8899")
        XCTAssertEqual(withOpenAI["OPENAI_BASE_URL"], "https://127.0.0.1:8900/v1")
        XCTAssertEqual(withOpenAI["GOOGLE_GEMINI_BASE_URL"], "http://127.0.0.1:8899")

        let withoutOpenAI = launchEnvironment(makeInputs(
            apiAnalytics: ShellLaunchConfigurator.APIAnalyticsProxyContext(port: 8899, includeOpenAI: false)
        ))
        XCTAssertEqual(withoutOpenAI["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8899")
        XCTAssertNil(withoutOpenAI["OPENAI_BASE_URL"])

        let disabled = launchEnvironment(makeInputs(apiAnalytics: nil))
        XCTAssertNil(disabled["ANTHROPIC_BASE_URL"])
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
