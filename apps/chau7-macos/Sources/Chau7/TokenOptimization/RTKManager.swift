import Foundation

// MARK: - RTK Manager

/// Manages the token optimization wrapper layer: script generation, optimizer
/// binary installation, PATH injection, and token-savings statistics.
///
/// ## Architecture
///
/// 1. **Wrapper scripts** live in `~/.chau7/rtk_bin/` and shadow real binaries
///    via PATH prepend.
/// 2. Each wrapper checks a **flag file** in `~/.chau7/rtk_active/<SESSION_ID>`.
///    When active, commands in `rtkRewriteMap` are routed through the built-in
///    `chau7-optim` optimizer for token-optimized output. When the optimizer is
///    absent, the real binary is exec'd directly.
/// 3. `RTKFlagManager` controls flag file creation/removal based on the global
///    mode + per-tab override + AI detection state.
///
/// ## Supported Commands
///
/// Optimizer-routed: `cat`, `ls`, `find`, `tree`, `grep`, `rg`, `git`, `diff`,
///                   `cargo`, `curl`, `docker`, `kubectl`, `gh`, `pnpm`, `wget`,
///                   `npm`, `npx`, `vitest`, `prisma`, `tsc`, `next`, `lint`,
///                   `prettier`, `format`, `playwright`, `ruff`, `pytest`, `pip`,
///                   `go`, `golangci-lint`
/// Exec-only (no optimizer subcommand): `head`, `tail`, `wc`
final class RTKManager {

    static let shared = RTKManager()

    /// Directory containing RTK wrapper scripts (prepended to PATH).
    let wrapperBinDir: URL

    /// Directory for helper binaries like `chau7-md`.
    let binDir: URL

    /// Directory for RTK data/config files.
    private let dataDir: URL

    /// Maps shell command names to their optimizer subcommand equivalents.
    /// Commands in this map are routed through `chau7-optim` when active.
    static let rtkRewriteMap: [String: String] = [
        "cat": "read",
        "ls": "ls",
        "find": "find",
        "tree": "tree",
        "grep": "grep",
        "rg": "rg",
        "git": "git",
        "diff": "diff",
        "cargo": "cargo",
        "curl": "curl",
        "docker": "docker",
        "kubectl": "kubectl",
        "gh": "gh",
        "pnpm": "pnpm",
        "wget": "wget",
        "npm": "npm",
        "npx": "npx",
        "vitest": "vitest",
        "prisma": "prisma",
        "tsc": "tsc",
        "next": "next",
        "lint": "lint",
        "prettier": "prettier",
        "format": "format",
        "playwright": "playwright",
        "ruff": "ruff",
        "pytest": "pytest",
        "pip": "pip",
        "go": "go",
        "golangci-lint": "golangci-lint",
    ]

    /// All commands that have wrapper scripts (optimizer-routed + exec-only).
    static let supportedCommands: [String] = {
        (Array(rtkRewriteMap.keys) + Array(execOnlyCommands)).sorted()
    }()

    /// Commands that are exec-only (no optimizer subcommand mapping).
    static let execOnlyCommands: Set<String> = ["head", "tail", "wc"]

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(".chau7", isDirectory: true)
        self.wrapperBinDir = base.appendingPathComponent("rtk_bin", isDirectory: true)
        self.binDir = base.appendingPathComponent("bin", isDirectory: true)
        self.dataDir = base.appendingPathComponent("rtk_data", isDirectory: true)
    }

    // MARK: - Setup

    /// Performs first-time setup: creates directories and installs wrapper scripts.
    /// Called once during app startup when RTK mode is not `.off`.
    func setup() {
        let fm = FileManager.default

        for dir in [wrapperBinDir, binDir, dataDir] {
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    Log.info("RTKManager: created directory \(dir.path)")
                } catch {
                    Log.error("RTKManager: failed to create \(dir.path): \(error)")
                }
            }
        }

        RTKFlagManager.ensureFlagDirectory()

        for command in Self.supportedCommands {
            installWrapper(for: command)
        }

        // Auto-install bundled helper binaries
        if let bundlePath = Bundle.main.url(forResource: "chau7-md", withExtension: nil) {
            installMarkdownRenderer(from: bundlePath)
        }
        if let bundlePath = Bundle.main.url(forResource: "chau7-optim", withExtension: nil) {
            installOptimizer(from: bundlePath)
        }
    }

    // MARK: - Optimizer Binary

    /// Path where the chau7-optim binary should be installed.
    var optimizerPath: URL {
        binDir.appendingPathComponent("chau7-optim")
    }

    /// Whether the optimizer binary is installed and executable.
    var isOptimizerInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: optimizerPath.path)
    }

    /// Installs the chau7-optim binary from a source path to `~/.chau7/bin/`.
    @discardableResult
    func installOptimizer(from sourcePath: URL) -> Bool {
        let fm = FileManager.default
        let dest = optimizerPath

        if !fm.fileExists(atPath: binDir.path) {
            do {
                try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            } catch {
                Log.error("RTKManager: failed to create bin dir: \(error)")
                return false
            }
        }

        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: sourcePath, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            Log.info("RTKManager: installed chau7-optim to \(dest.path)")
            return true
        } catch {
            Log.error("RTKManager: failed to install chau7-optim: \(error)")
            return false
        }
    }

    // MARK: - Wrapper Scripts

    /// Installs a wrapper script for the given command.
    private func installWrapper(for command: String) {
        let wrapperPath = wrapperBinDir.appendingPathComponent(command)
        let realBin = resolveRealBinary(for: command)
        let script = generateWrapperScript(for: command, realBin: realBin)

        do {
            try script.write(to: wrapperPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: wrapperPath.path
            )
            Log.trace("RTKManager: installed wrapper for \(command) → \(realBin ?? "dynamic")")
        } catch {
            Log.error("RTKManager: failed to install wrapper for \(command): \(error)")
        }
    }

    /// Resolves the real binary path for a command by searching PATH (skipping rtk_bin).
    /// Called once at wrapper-generation time so the path can be hardcoded into the script.
    private func resolveRealBinary(for command: String) -> String? {
        let fm = FileManager.default
        let wrapperDir = wrapperBinDir.path
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        for dir in pathEnv.split(separator: ":") {
            let dirStr = String(dir)
            if dirStr == wrapperDir { continue }
            let candidate = "\(dirStr)/\(command)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Generates the shell wrapper script for a command.
    private func generateWrapperScript(for command: String, realBin: String?) -> String {
        if command == "cat" {
            return generateCatWrapperScript(realBin: realBin)
        }
        return generateGenericWrapperScript(for: command, realBin: realBin)
    }

    /// Generic wrapper with hardcoded real binary path for near-zero passthrough overhead.
    ///
    /// The fast path (no RTK session) reaches `exec` after just two shell tests and
    /// zero variable assignments — critical for tools like NVM that invoke coreutils
    /// thousands of times during shell init.
    ///
    /// When RTK is active:
    /// - If optimizer exists AND command has a rewrite mapping → `exec chau7-optim <subcommand> "$@"`
    /// - If optimizer not found or command is exec-only → `exec real_binary "$@"`
    private func generateGenericWrapperScript(for command: String, realBin: String?) -> String {
        let rtkSubcommand = Self.rtkRewriteMap[command]

        let optimizerBlock: String
        if let sub = rtkSubcommand {
            optimizerBlock = """
            _CHAU7_OPTIM="$HOME/.chau7/bin/chau7-optim"
            [ -x "$_CHAU7_OPTIM" ] && exec "$_CHAU7_OPTIM" \(sub) "$@"
            """
        } else {
            optimizerBlock = ""
        }

        // Fast path: when we have a hardcoded binary, the non-RTK case is just
        // two tests + exec with no variable assignments at all.
        if let path = realBin {
            return """
            #!/bin/bash
            # RTK wrapper for \(command) — generated by Chau7

            # Fast path: no active RTK session → exec hardcoded binary immediately.
            if [ -z "$CHAU7_RTK_SESSION" ] || [ ! -f "$HOME/.chau7/rtk_active/$CHAU7_RTK_SESSION" ]; then
                exec "\(path)" "$@"
            fi

            # RTK is active.
            \(optimizerBlock)
            exec "\(path)" "$@"
            """
        }

        // No hardcoded path available — fall back to runtime PATH scan.
        return """
        #!/bin/bash
        # RTK wrapper for \(command) — generated by Chau7

        _RTK_WRAPPER_DIR="$HOME/.chau7/rtk_bin"
        _RTK_REAL_BIN=""
        _OLD_IFS="$IFS"; IFS=':'
        for _dir in $PATH; do
            [ "$_dir" = "$_RTK_WRAPPER_DIR" ] && continue
            if [ -x "$_dir/\(command)" ]; then _RTK_REAL_BIN="$_dir/\(command)"; break; fi
        done
        IFS="$_OLD_IFS"

        if [ -z "$_RTK_REAL_BIN" ]; then
            echo "chau7: could not find real \(command) binary" >&2
            exit 127
        fi

        if [ -z "$CHAU7_RTK_SESSION" ] || [ ! -f "$HOME/.chau7/rtk_active/$CHAU7_RTK_SESSION" ]; then
            exec "$_RTK_REAL_BIN" "$@"
        fi

        \(optimizerBlock)
        exec "$_RTK_REAL_BIN" "$@"
        """
    }

    /// Specialized `cat` wrapper with hardcoded real binary path:
    /// 1. Markdown files → chau7-md (when stdout is a terminal, no flags, all .md)
    /// 2. Other files → `chau7-optim read "$@"` (when optimizer available)
    /// 3. Fallback → real cat
    private func generateCatWrapperScript(realBin: String?) -> String {
        // The cat wrapper's RTK-active path is more complex (markdown rendering),
        // so we use a helper variable for the real binary. The fast path (no RTK session)
        // still reaches exec after just two tests when a hardcoded path is available.
        let realBinSetup: String
        let realBinFallback: String

        if let path = realBin {
            realBinSetup = """
            # Fast path: no active RTK session → exec hardcoded binary immediately.
            if [ -z "$CHAU7_RTK_SESSION" ] || [ ! -f "$HOME/.chau7/rtk_active/$CHAU7_RTK_SESSION" ]; then
                exec "\(path)" "$@"
            fi
            _RTK_REAL_BIN="\(path)"
            """
            realBinFallback = ""
        } else {
            realBinSetup = """
            _RTK_WRAPPER_DIR="$HOME/.chau7/rtk_bin"
            _RTK_REAL_BIN=""
            _OLD_IFS="$IFS"; IFS=':'
            for _dir in $PATH; do
                [ "$_dir" = "$_RTK_WRAPPER_DIR" ] && continue
                if [ -x "$_dir/cat" ]; then _RTK_REAL_BIN="$_dir/cat"; break; fi
            done
            IFS="$_OLD_IFS"
            """
            realBinFallback = """

            if [ -z "$_RTK_REAL_BIN" ]; then
                echo "chau7: could not find real cat binary" >&2
                exit 127
            fi

            if [ -z "$CHAU7_RTK_SESSION" ] || [ ! -f "$HOME/.chau7/rtk_active/$CHAU7_RTK_SESSION" ]; then
                exec "$_RTK_REAL_BIN" "$@"
            fi
            """
        }

        return """
        #!/bin/bash
        # RTK wrapper for cat — generated by Chau7
        # Renders markdown files with chau7-md, routes others through chau7-optim read.

        \(realBinSetup)\(realBinFallback)

        # RTK is active below this point.

        # Cat with no args may read from stdin (e.g. pipes); avoid read-optimizer path.
        if [ "$#" -eq 0 ]; then
            exec "$_RTK_REAL_BIN" "$@"
        fi

        # Markdown rendering: check if chau7-md is available,
        # stdout is a terminal, no flags are passed, and all args are .md/.markdown
        _CHAU7_MD="$HOME/.chau7/bin/chau7-md"

        if [ -x "$_CHAU7_MD" ] && [ -t 1 ]; then
            _ALL_MD=true
            _HAS_FILES=false
            for _arg in "$@"; do
                case "$_arg" in
                    -*)
                        _ALL_MD=false
                        break
                        ;;
                    *)
                        _HAS_FILES=true
                        _ext="${_arg##*.}"
                        _ext_lower="$(printf '%s' "$_ext" | tr '[:upper:]' '[:lower:]')"
                        case "$_ext_lower" in
                            md|markdown) ;;
                            *) _ALL_MD=false; break ;;
                        esac
                        ;;
                esac
            done

            if [ "$_HAS_FILES" = true ] && [ "$_ALL_MD" = true ]; then
                _RTK_EXIT=0
                for _arg in "$@"; do
                    "$_CHAU7_MD" "$_arg"
                    [ $? -ne 0 ] && _RTK_EXIT=1
                done
                exit $_RTK_EXIT
            fi
        fi

        # Route through built-in optimizer for non-markdown files
        _CHAU7_OPTIM="$HOME/.chau7/bin/chau7-optim"
        [ -x "$_CHAU7_OPTIM" ] && exec "$_CHAU7_OPTIM" read "$@"

        exec "$_RTK_REAL_BIN" "$@"
        """
    }

    // MARK: - Helper Binary Installation

    /// Path where the chau7-md binary should be installed.
    var markdownRendererPath: URL {
        binDir.appendingPathComponent("chau7-md")
    }

    /// Whether the markdown renderer binary is installed and executable.
    var isMarkdownRendererInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: markdownRendererPath.path)
    }

    /// Installs the chau7-md binary from a source path to `~/.chau7/bin/`.
    @discardableResult
    func installMarkdownRenderer(from sourcePath: URL) -> Bool {
        let fm = FileManager.default
        let dest = markdownRendererPath

        if !fm.fileExists(atPath: binDir.path) {
            do {
                try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            } catch {
                Log.error("RTKManager: failed to create bin dir: \(error)")
                return false
            }
        }

        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: sourcePath, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            Log.info("RTKManager: installed chau7-md to \(dest.path)")
            return true
        } catch {
            Log.error("RTKManager: failed to install chau7-md: \(error)")
            return false
        }
    }

    // MARK: - PATH Injection

    /// Returns the PATH string with the RTK wrapper directory prepended.
    func prependedPATH(original: String) -> String {
        let wrapperDir = wrapperBinDir.path
        let components = original.split(separator: ":", omittingEmptySubsequences: false)
        if components.contains(where: { String($0) == wrapperDir }) {
            return original
        }
        return "\(wrapperDir):\(original)"
    }

    // MARK: - Installation Health Check

    /// Per-command installation status.
    struct WrapperHealth: Identifiable {
        let command: String
        let isInstalled: Bool
        let isExecutable: Bool
        /// Whether this command routes through the optimizer (vs exec-only).
        let hasRTKRoute: Bool
        var id: String { command }
    }

    /// Checks the installation status of every supported wrapper script.
    func checkInstallation() -> [WrapperHealth] {
        let fm = FileManager.default
        return Self.supportedCommands.map { command in
            let path = wrapperBinDir.appendingPathComponent(command).path
            let exists = fm.fileExists(atPath: path)
            let executable = exists && fm.isExecutableFile(atPath: path)
            let hasRoute = Self.rtkRewriteMap[command] != nil
            return WrapperHealth(
                command: command,
                isInstalled: exists,
                isExecutable: executable,
                hasRTKRoute: hasRoute
            )
        }
    }

    /// Quick check: are all wrappers installed and executable?
    var isFullyInstalled: Bool {
        checkInstallation().allSatisfy { $0.isInstalled && $0.isExecutable }
    }

    // MARK: - RTK Gain Statistics

    /// Token savings data returned by `chau7-optim gain --format json`.
    struct RTKGainStats: Codable, Equatable {
        let commands: Int
        let inputTokens: Int
        let outputTokens: Int
        let savedTokens: Int
        let savingsPct: Double
        let totalTimeMs: Int
        let avgTimeMs: Int

        enum CodingKeys: String, CodingKey {
            case commands = "total_commands"
            case inputTokens = "total_input"
            case outputTokens = "total_output"
            case savedTokens = "total_saved"
            case savingsPct = "avg_savings_pct"
            case totalTimeMs = "total_time_ms"
            case avgTimeMs = "avg_time_ms"
        }
    }

    /// Wrapper for the JSON envelope from `chau7-optim gain --format json`.
    private struct GainResponse: Codable {
        let summary: RTKGainStats
    }

    /// Fetches aggregated token savings from `chau7-optim gain --format json`.
    /// Returns nil if the optimizer is not installed or the command fails.
    func fetchGainStats() async -> RTKGainStats? {
        guard isOptimizerInstalled else { return nil }

        let process = Process()
        process.executableURL = optimizerPath
        process.arguments = ["gain", "--format", "json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.error("RTKManager: failed to run chau7-optim gain: \(error)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else { return nil }

        do {
            let response = try JSONDecoder().decode(GainResponse.self, from: data)
            return response.summary
        } catch {
            Log.error("RTKManager: failed to decode chau7-optim gain output: \(error)")
            return nil
        }
    }

    // MARK: - Cleanup

    /// Removes all wrapper scripts and flag files. Called on app quit or
    /// when switching to `.off` mode.
    func teardown() {
        RTKFlagManager.removeAllFlags()

        let fm = FileManager.default
        if fm.fileExists(atPath: wrapperBinDir.path) {
            do {
                let contents = try fm.contentsOfDirectory(atPath: wrapperBinDir.path)
                for file in contents {
                    try fm.removeItem(atPath: wrapperBinDir.appendingPathComponent(file).path)
                }
                Log.info("RTKManager: removed \(contents.count) wrapper script(s)")
            } catch {
                Log.error("RTKManager: failed to clean up wrappers: \(error)")
            }
        }
    }
}
