import Chau7Core
import Darwin
import Foundation

/// Shell-launch configuration for terminal sessions, extracted from
/// `TerminalSessionModel` (SOLID/DRY review, stage 5).
///
/// Everything here is a pure static function of its inputs except:
/// - `prepareShellIntegration()` / `writeShellIntegrationFiles(to:environment:)`,
///   which own the one filesystem side effect (writing the rc files) plus the
///   "did write" flag, and
/// - `systemDefaultShell(isExecutable:)`, which reads the user's passwd entry.
enum ShellLaunchConfigurator {

    // MARK: - Shell Integration Directory

    /// Directory the rc wrapper files are written into. zsh is pointed here via
    /// `ZDOTDIR`, bash via `--rcfile`, fish via `XDG_CONFIG_HOME`.
    static let integrationDirectoryPath: String = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smartoverlay")
        FileOperations.createDirectory(at: dir)
        return dir.path
    }()

    private static var didWriteShellIntegration = false

    /// The shell integration directory, or nil until the rc files have been
    /// written successfully (env vars / argv must not point at missing files).
    static var shellIntegrationDirectory: String? {
        didWriteShellIntegration ? integrationDirectoryPath : nil
    }

    /// Writes the integration rc files for all supported shells into the shared
    /// integration directory. Call once at app launch — the integration runs at
    /// shell startup (not as a command) so it won't be in history.
    static func prepareShellIntegration() {
        if writeShellIntegrationFiles(to: integrationDirectoryPath) {
            didWriteShellIntegration = true
        }
    }

    /// Writes `.zshrc`, `.bashrc`, and `.config/fish/config.fish` under
    /// `integrationDir`. The single effectful entry point — the base path is
    /// injected so tests can target a temp directory.
    @discardableResult
    static func writeShellIntegrationFiles(
        to integrationDir: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let fallbackHome = ShellLaunchEnvironment.userHome(environment: environment)
        let fallbackZdotdir = ShellLaunchEnvironment.userZdotdir(environment: environment)
        let fallbackXDGConfigHome = ShellLaunchEnvironment.userXDGConfigHome(environment: environment)

        do {
            try zshrcContents(fallbackHome: fallbackHome, fallbackZdotdir: fallbackZdotdir)
                .write(toFile: integrationDir + "/.zshrc", atomically: true, encoding: .utf8)
            try bashrcContents(fallbackHome: fallbackHome)
                .write(toFile: integrationDir + "/.bashrc", atomically: true, encoding: .utf8)

            // Create fish config directory
            let fishDir = integrationDir + "/.config/fish"
            try FileManager.default.createDirectory(atPath: fishDir, withIntermediateDirectories: true)
            try fishConfigContents(fallbackHome: fallbackHome, fallbackXDGConfigHome: fallbackXDGConfigHome)
                .write(toFile: fishDir + "/config.fish", atomically: true, encoding: .utf8)

            Log.info("Created shell integration files at \(integrationDir)")
            return true
        } catch {
            Log.error("Failed to create shell integration files: \(error)")
            return false
        }
    }

    // MARK: - RC-File Contents (pure)

    /// The `.zshrc` wrapper contents (pure function of the fallback paths).
    static func zshrcContents(fallbackHome: String, fallbackZdotdir: String) -> String {
        """
        # Chau7 wrapper - source user's shell config first
        export CHAU7_USER_HOME="${CHAU7_USER_HOME:-${HOME:-\(fallbackHome)}}"
        export CHAU7_USER_ZDOTDIR="${CHAU7_USER_ZDOTDIR:-\(fallbackZdotdir)}"
        export ZDOTDIR="$CHAU7_USER_ZDOTDIR"
        [ -f "$CHAU7_USER_ZDOTDIR/.zshenv" ] && source "$CHAU7_USER_ZDOTDIR/.zshenv"
        [ -f "$CHAU7_USER_ZDOTDIR/.zshrc" ] && source "$CHAU7_USER_ZDOTDIR/.zshrc"
        if [[ -o login ]]; then
          [ -f "$CHAU7_USER_ZDOTDIR/.zprofile" ] && source "$CHAU7_USER_ZDOTDIR/.zprofile"
          [ -f "$CHAU7_USER_ZDOTDIR/.zlogin" ] && source "$CHAU7_USER_ZDOTDIR/.zlogin"
        fi
        # Per-tab isolated command history. macOS /etc/zshrc derives HISTFILE from
        # ZDOTDIR (HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history); because Chau7 points
        # ZDOTDIR at a shared temp integration dir, every tab inadvertently collapsed
        # onto one throwaway history file (and SHELL_SESSIONS_DISABLE=1 turns off the
        # per-session isolation Terminal.app would otherwise provide). Re-anchor
        # HISTFILE on the stable per-tab CHAU7_TAB_ID — which survives tab restore —
        # so each tab keeps its own history and a reloaded tab reloads exactly its
        # own, not the merged history of every tab. Set after the user's config so it
        # wins. zsh reads HISTFILE once after the rc files, so this value is the one
        # loaded.
        if [ -n "$CHAU7_TAB_ID" ]; then
          mkdir -p "$CHAU7_USER_HOME/.chau7/history" 2>/dev/null
          export HISTFILE="$CHAU7_USER_HOME/.chau7/history/${CHAU7_TAB_ID}.zsh_history"
          HISTSIZE=100000
          SAVEHIST=100000
        fi
        # Ensure Codex's npm-managed Volta image bin stays ahead of the legacy ~/.volta/bin shim.
        path=("${(s/:/)PATH}")
        for _codex_image_bin in "$CHAU7_USER_HOME/.volta/tools/image/node/"*"/bin"(N); do
          [ -x "$_codex_image_bin/codex" ] && path=($_codex_image_bin $path)
        done
        if command -v volta >/dev/null 2>&1; then
          _codex_node_path="$(volta which node 2>/dev/null || true)"
          _codex_node_bin="${_codex_node_path%/*}"
          [ -n "$_codex_node_bin" ] && [ -x "$_codex_node_bin/codex" ] && path=($_codex_node_bin $path)
        fi
        typeset -U path
        export PATH="${(j/:/)path}"
        unset _codex_image_bin _codex_node_path _codex_node_bin
        # Disable PROMPT_CR - prevents the 143 spaces + CRs before each prompt
        # that can cause visual artifacts in some terminals
        setopt NO_PROMPT_CR
        # Chau7 default start directory
        if [ -n "$CHAU7_START_DIR" ] && [ -d "$CHAU7_START_DIR" ]; then
          cd "$CHAU7_START_DIR"
        fi
        # Chau7 shell integration (runs at startup, not in history). Defined and
        # invoked *before* CHAU7_STARTUP_CMD so the initial OSC 7 cwd report
        # lands even when the startup command is a TUI (Claude, Codex) that
        # seizes the PTY indefinitely — without this, restored AI tabs spend
        # ~13s pinned in `isShellLoading=true` until the resume-prefill
        # watchdog force-clears it.
        chau7_emit_exit_status() {
          local code=$?
          print -Pn "\\e]9;chau7;exit=${code}\\a"
        }
        smartoverlay_precmd() {
          print -Pn "\\e]7;file://$HOSTNAME$PWD\\a"
          local __g=$(git rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)
          if [ -n "$__g" ]; then
            local __r=${__g%%$'\\n'*}
            local __b=${__g##*$'\\n'}
            [ -n "$__r" ] && print -Pn "\\e]9;chau7;repo-root=${__r}\\a"
            [ -n "$__b" ] && [ "$__b" != "$__r" ] && print -Pn "\\e]9;chau7;branch=${__b}\\a"
          fi
        }
        autoload -Uz add-zsh-hook 2>/dev/null
        if command -v add-zsh-hook >/dev/null 2>&1; then
          add-zsh-hook precmd chau7_emit_exit_status
          add-zsh-hook precmd smartoverlay_precmd
          # Also fire on chpwd so chained commands like `cd X && tui-app` still
          # update the cwd. precmd only runs before the next prompt is rendered,
          # which a TUI app seizing the PTY skips entirely.
          add-zsh-hook chpwd smartoverlay_precmd
        else
          precmd_functions+=chau7_emit_exit_status
          precmd_functions+=smartoverlay_precmd
          chpwd_functions+=smartoverlay_precmd
        fi
        smartoverlay_precmd
        # Chau7 CLI header injection for Claude Code
        chau7_update_project() {
          local git_root=$(git rev-parse --show-toplevel 2>/dev/null)
          export CHAU7_PROJECT="${git_root:-$PWD}"
          export ANTHROPIC_EXTRA_HEADERS="X-Chau7-Session:${CHAU7_SESSION_ID:-},X-Chau7-Tab:${CHAU7_TAB_ID:-},X-Chau7-Project:${CHAU7_PROJECT:-}"
        }
        chau7_update_project
        if command -v add-zsh-hook >/dev/null 2>&1; then
          add-zsh-hook chpwd chau7_update_project
        fi
        # Chau7 startup command — runs LAST so a TUI startup command (Claude,
        # Codex, …) can seize the PTY without leaving the integration / OSC 7
        # emission unrun.
        if [ -n "$CHAU7_STARTUP_CMD" ]; then
          eval "$CHAU7_STARTUP_CMD"
        fi
        """
    }

    /// The `.bashrc` wrapper contents (pure function of the fallback home).
    static func bashrcContents(fallbackHome: String) -> String {
        """
        # Chau7 wrapper - source user's real .bashrc first
        export CHAU7_USER_HOME="${CHAU7_USER_HOME:-${HOME:-\(fallbackHome)}}"
        [ -f "$CHAU7_USER_HOME/.bashrc" ] && source "$CHAU7_USER_HOME/.bashrc"
        [ -f "$CHAU7_USER_HOME/.bash_profile" ] && source "$CHAU7_USER_HOME/.bash_profile"
        # Per-tab isolated command history (mirrors the zsh integration). Keyed off
        # the stable CHAU7_TAB_ID so each tab keeps its own history across restore.
        if [ -n "$CHAU7_TAB_ID" ]; then
          mkdir -p "$CHAU7_USER_HOME/.chau7/history" 2>/dev/null
          export HISTFILE="$CHAU7_USER_HOME/.chau7/history/${CHAU7_TAB_ID}.bash_history"
          HISTSIZE=100000
          HISTFILESIZE=100000
        fi
        # Chau7 default start directory
        if [ -n "$CHAU7_START_DIR" ] && [ -d "$CHAU7_START_DIR" ]; then
          cd "$CHAU7_START_DIR"
        fi
        # Chau7 shell integration. Defined and run BEFORE CHAU7_STARTUP_CMD so
        # the initial OSC 7 cwd report lands even when the startup command is
        # a TUI (Claude, Codex) that seizes the PTY indefinitely.
        smartoverlay_precmd() {
          printf '\\e]7;file://%s%s\\a' "$HOSTNAME" "$PWD"
          local __g
          __g=$(git rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)
          if [ -n "$__g" ]; then
            local __r=${__g%%$'\\n'*}
            local __b=${__g##*$'\\n'}
            [ -n "$__r" ] && printf '\\e]9;chau7;repo-root=%s\\a' "$__r"
            [ -n "$__b" ] && [ "$__b" != "$__r" ] && printf '\\e]9;chau7;branch=%s\\a' "$__b"
          fi
        }
        chau7_emit_exit_status() {
          local code=$?
          printf '\\e]9;chau7;exit=%s\\a' "$code"
        }
        PROMPT_COMMAND="smartoverlay_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        # Chau7 CLI header injection for Claude Code
        chau7_update_project() {
          local git_root=$(git rev-parse --show-toplevel 2>/dev/null)
          export CHAU7_PROJECT="${git_root:-$PWD}"
          export ANTHROPIC_EXTRA_HEADERS="X-Chau7-Session:${CHAU7_SESSION_ID:-},X-Chau7-Tab:${CHAU7_TAB_ID:-},X-Chau7-Project:${CHAU7_PROJECT:-}"
        }
        chau7_update_project
        # Update on directory change via PROMPT_COMMAND
        PROMPT_COMMAND="chau7_update_project${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        PROMPT_COMMAND="chau7_emit_exit_status${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        # Emit the initial OSC 7 / repo-root / branch report immediately —
        # PROMPT_COMMAND only fires before the next prompt is rendered, which
        # a TUI startup command skips entirely.
        smartoverlay_precmd
        # Chau7 startup command — runs LAST so a TUI startup command can seize
        # the PTY without leaving integration / OSC 7 emission unrun.
        if [ -n "$CHAU7_STARTUP_CMD" ]; then
          eval "$CHAU7_STARTUP_CMD"
        fi
        """
    }

    /// The fish `config.fish` wrapper contents (pure function of the fallback paths).
    static func fishConfigContents(fallbackHome: String, fallbackXDGConfigHome: String) -> String {
        """
        # Chau7 wrapper - source user's real config.fish first
        set -gx CHAU7_USER_HOME (string trim -- "$CHAU7_USER_HOME")
        if test -z "$CHAU7_USER_HOME"
          if test -n "$HOME"
            set -gx CHAU7_USER_HOME "$HOME"
          else
            set -gx CHAU7_USER_HOME "\(fallbackHome)"
          end
        end
        set -gx CHAU7_USER_XDG_CONFIG_HOME (string trim -- "$CHAU7_USER_XDG_CONFIG_HOME")
        if test -z "$CHAU7_USER_XDG_CONFIG_HOME"
          set -gx CHAU7_USER_XDG_CONFIG_HOME "\(fallbackXDGConfigHome)"
        end
        if test -f "$CHAU7_USER_XDG_CONFIG_HOME/fish/config.fish"
          source "$CHAU7_USER_XDG_CONFIG_HOME/fish/config.fish"
        end
        # Per-tab isolated command history (mirrors zsh/bash). fish keys history by
        # session name; derive a stable per-tab name from CHAU7_TAB_ID (hyphens are
        # not valid in a fish history session name, so swap them for underscores).
        if test -n "$CHAU7_TAB_ID"
          set -gx fish_history (string replace -a -- - _ "chau7_$CHAU7_TAB_ID")
        end
        # Chau7 default start directory
        if test -n "$CHAU7_START_DIR"; and test -d "$CHAU7_START_DIR"
          cd "$CHAU7_START_DIR"
        end
        # Chau7 shell integration. Listening to both fish_prompt and PWD changes
        # so chained commands like `cd X && tui-app` still update the cwd —
        # fish_prompt only fires before the next prompt is rendered, which a
        # TUI app seizing the PTY skips entirely. Defined and emitted BEFORE
        # CHAU7_STARTUP_CMD so the initial OSC 7 cwd report lands even when
        # the startup command is a TUI (Claude, Codex) that seizes the PTY
        # indefinitely.
        function smartoverlay_precmd --on-event fish_prompt --on-variable PWD
          set -l code $status
          printf '\\e]9;chau7;exit=%s\\a' $code
          printf '\\e]7;file://%s%s\\a' (hostname) (pwd)
          set -l __g (git rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)
          if test (count $__g) -ge 1
            set -l __r $__g[1]
            if test -n "$__r"
              printf '\\e]9;chau7;repo-root=%s\\a' $__r
            end
            if test (count $__g) -ge 2
              set -l __b $__g[2]
              if test -n "$__b"; and test "$__b" != "$__r"
                printf '\\e]9;chau7;branch=%s\\a' $__b
              end
            end
          end
        end
        # Chau7 CLI header injection for Claude Code
        function chau7_update_project --on-variable PWD
          set -l git_root (git rev-parse --show-toplevel 2>/dev/null)
          if test -n "$git_root"
            set -gx CHAU7_PROJECT $git_root
          else
            set -gx CHAU7_PROJECT $PWD
          end
          set -gx ANTHROPIC_EXTRA_HEADERS "X-Chau7-Session:$CHAU7_SESSION_ID,X-Chau7-Tab:$CHAU7_TAB_ID,X-Chau7-Project:$CHAU7_PROJECT"
        end
        # Initialize on startup
        chau7_update_project
        # Emit the initial OSC 7 / repo-root / branch report immediately —
        # fish_prompt only fires before the next prompt is rendered, which
        # a TUI startup command skips entirely.
        smartoverlay_precmd
        # Chau7 startup command — runs LAST so a TUI startup command can seize
        # the PTY without leaving integration / OSC 7 emission unrun.
        if test -n "$CHAU7_STARTUP_CMD"
          eval "$CHAU7_STARTUP_CMD"
        end
        """
    }

    // MARK: - Shell Path Resolution

    /// Resolves the shell binary to launch for a configured `ShellType`.
    /// Filesystem probes and the passwd lookup are injectable for tests.
    static func shellPath(
        for shellType: ShellType,
        customShellPath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        systemShell: () -> String = { systemDefaultShell() }
    ) -> String {
        switch shellType {
        case .system:
            // Use system default shell (from user's passwd entry)
            return systemShell()
        case .zsh:
            return "/bin/zsh"
        case .bash:
            return "/bin/bash"
        case .fish:
            // Apple Silicon path
            if fileExists("/opt/homebrew/bin/fish") {
                return "/opt/homebrew/bin/fish"
            }
            // Intel path fallback
            if fileExists("/usr/local/bin/fish") {
                return "/usr/local/bin/fish"
            }
            // Fallback to zsh if fish not found
            return "/bin/zsh"
        case .fishIntel:
            if fileExists("/usr/local/bin/fish") {
                return "/usr/local/bin/fish"
            }
            return "/bin/zsh"
        case .custom:
            let customPath = customShellPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !customPath.isEmpty, fileExists(customPath) {
                return customPath
            }
            return systemShell()
        }
    }

    /// Returns the system's default shell from the user's passwd entry.
    static func systemDefaultShell(
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else {
            return "/bin/zsh"
        }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer { buffer.deallocate() }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        guard getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) == 0,
              result != nil else {
            return "/bin/zsh"
        }
        let shell = String(cString: pwd.pw_shell)
        // The passwd entry can point at a deleted binary (e.g. an uninstalled
        // Homebrew shell). Spawning that yields a permanently blank tab, so
        // verify and fall back to the system zsh.
        guard isExecutable(shell) else {
            Log.warn("systemDefaultShell: passwd shell \(shell) is missing or not executable; falling back to /bin/zsh")
            return "/bin/zsh"
        }
        return shell
    }

    // MARK: - Start Directory

    /// Resolves a raw start-directory setting to an absolute, standardized path
    /// (tilde expansion; relative paths anchored at home; empty means home).
    static func resolveStartDirectory(_ rawValue: String) -> String {
        let home = RuntimeIsolation.homePath()
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return home }

        let expanded = RuntimeIsolation.expandTilde(in: trimmed)
        let resolved: String
        if expanded.hasPrefix("/") {
            resolved = expanded
        } else {
            resolved = (home as NSString).appendingPathComponent(expanded)
        }

        return URL(fileURLWithPath: resolved).standardized.path
    }

    /// Picks the directory a new shell should start in: the requested directory
    /// when it resolves to an existing directory, otherwise the default.
    static func startDirectoryForLaunch(
        requested: String,
        defaultDirectory: @autoclosure () -> String,
        isDirectory: (String) -> Bool = defaultIsDirectory
    ) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? defaultDirectory() : resolveStartDirectory(trimmed)
        guard isDirectory(resolved) else {
            return defaultDirectory()
        }
        return resolved
    }

    private static func defaultIsDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Launch Environment (pure)

    static let defaultLsColors = "exfxcxdxbxegedabagacad"

    /// CTO (token optimization) values injected into the environment when enabled.
    struct CTOLaunchContext {
        var sessionID: String
        var commandLogPath: String
    }

    /// API analytics proxy values injected into the environment when enabled.
    struct APIAnalyticsProxyContext {
        var port: Int
        var includeOpenAI: Bool
    }

    /// Everything the launch environment depends on, gathered by the caller so
    /// the assembly itself is a pure function.
    struct LaunchEnvironmentInputs {
        var processEnvironment: [String: String] = ProcessInfo.processInfo.environment
        var pathValue: String
        var shellPath: String
        var startDirectory: String
        var startupCommand: String
        var isLsColorsEnabled: Bool
        var integrationDir: String?
        var proxyCorrelationSessionID: String
        var tabID: String
        var projectDirectory: String
        var aiEventsLogPath: String
        var cto: CTOLaunchContext?
        var apiAnalytics: APIAnalyticsProxyContext?
    }

    /// Assembles the `KEY=value` environment entries for a shell launch.
    static func launchEnvironment(_ inputs: LaunchEnvironmentInputs) -> [String] {
        var dict: [String: String] = [:]
        dict["TERM"] = "xterm-256color"
        dict["COLORTERM"] = "truecolor"

        let current = inputs.processEnvironment
        dict.merge(ShellLaunchEnvironment.utf8LocaleEnvironment(environment: current)) { _, new in new }

        dict["PATH"] = inputs.pathValue
        if let home = current["HOME"] {
            dict["HOME"] = home
        }
        dict["CHAU7_USER_HOME"] = ShellLaunchEnvironment.userHome(environment: current)
        dict["CHAU7_USER_ZDOTDIR"] = ShellLaunchEnvironment.userZdotdir(environment: current)
        dict["CHAU7_USER_XDG_CONFIG_HOME"] = ShellLaunchEnvironment.userXDGConfigHome(environment: current)
        dict["CHAU7_START_DIR"] = inputs.startDirectory

        // CTO: set session ID for flag file lookup by wrapper scripts.
        // Uses a dedicated env var to avoid conflicting with CHAU7_SESSION_ID
        // which the analytics proxy uses for per-shell-launch correlation.
        if let cto = inputs.cto {
            dict["CHAU7_CTO_SESSION"] = cto.sessionID
            dict["CHAU7_CTO_LOG"] = cto.commandLogPath
        }

        // Set startup command if configured
        let startupCmd = inputs.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !startupCmd.isEmpty {
            dict["CHAU7_STARTUP_CMD"] = startupCmd
        }

        // Use Chau7 as TERM_PROGRAM to avoid sourcing /etc/zshrc_Apple_Terminal
        // which adds duplicate precmd hooks and can cause display issues.
        // CLI tools that check TERM_PROGRAM for theming will still work fine.
        dict["TERM_PROGRAM"] = "Chau7"
        dict["TERM_PROGRAM_VERSION"] = "1.0"
        dict["TERM_SESSION_ID"] = inputs.proxyCorrelationSessionID
        dict["SHELL"] = inputs.shellPath
        dict["CHAU7_SESSION_ID"] = inputs.proxyCorrelationSessionID
        dict["CHAU7_TAB_ID"] = inputs.tabID
        dict["CHAU7_PROJECT"] = inputs.projectDirectory
        dict["CHAU7_AI_EVENTS_LOG"] = inputs.aiEventsLogPath

        // Disable macOS shell session save/restore (avoids "Restored session" message and % marker)
        // Chau7 manages its own session state; macOS session restoration is designed for Terminal.app
        dict["SHELL_SESSIONS_DISABLE"] = "1"

        if inputs.isLsColorsEnabled {
            dict["CLICOLOR"] = dict["CLICOLOR"] ?? "1"
            dict["LSCOLORS"] = dict["LSCOLORS"] ?? defaultLsColors
        }

        // Set shell-specific environment variables based on configured shell
        if let integrationDir = inputs.integrationDir {
            let shellName = (inputs.shellPath as NSString).lastPathComponent.lowercased()

            if shellName == "zsh" {
                // ZDOTDIR tells zsh where to look for .zshrc
                dict["ZDOTDIR"] = integrationDir
            } else if shellName == "bash" {
                // BASH_ENV is sourced for non-interactive shells
                // For interactive shells, we use --rcfile in arguments
                dict["BASH_ENV"] = integrationDir + "/.bashrc"
            } else if shellName == "fish" {
                // XDG_CONFIG_HOME tells fish where to find config.fish
                dict["XDG_CONFIG_HOME"] = integrationDir + "/.config"
            }
        }

        // API Analytics Proxy Injection
        if let analytics = inputs.apiAnalytics {
            let proxyBase = "http://127.0.0.1:\(analytics.port)"
            let tlsBase = "https://127.0.0.1:\(analytics.port + 1)"

            // Claude Code / Anthropic SDK (HTTP — no WebSocket needed)
            dict["ANTHROPIC_BASE_URL"] = proxyBase

            if analytics.includeOpenAI {
                // Codex CLI / OpenAI SDK — routed through the TLS port so that
                // subscription-based Codex can do its native WSS upgrade through
                // the proxy. The self-signed cert is trusted via the login keychain.
                dict["OPENAI_BASE_URL"] = "\(tlsBase)/v1"
            }

            // Gemini CLI / Google GenAI SDK (HTTP — no WebSocket needed)
            dict["GOOGLE_GEMINI_BASE_URL"] = proxyBase
        }

        return dict.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Shell Arguments

    /// Returns shell arguments for the selected shell binary. Only bash needs
    /// an explicit `--rcfile`; zsh uses ZDOTDIR and fish uses XDG_CONFIG_HOME.
    static func shellArguments(shellPath: String, integrationDir: String?) -> [String] {
        let shellName = (shellPath as NSString).lastPathComponent.lowercased()

        if shellName == "bash", let integrationDir {
            // Use --rcfile to specify our custom bashrc for interactive shells
            return ["--rcfile", integrationDir + "/.bashrc"]
        }

        // Default: no extra arguments (zsh uses ZDOTDIR, fish uses XDG_CONFIG_HOME)
        return []
    }
}
