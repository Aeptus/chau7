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
///                   `cargo`, `curl`, `docker`, `kubectl`
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
        "rg": "grep",
        "git": "git",
        "diff": "diff",
        "cargo": "cargo",
        "curl": "curl",
        "docker": "docker",
        "kubectl": "kubectl",
    ]

    /// All commands that have wrapper scripts (optimizer-routed + exec-only).
    static let supportedCommands: [String] = [
        "cat", "ls", "find", "tree",
        "grep", "rg", "git", "diff",
        "cargo", "curl", "docker", "kubectl",
        "head", "tail", "wc",
    ]

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
        let script = generateWrapperScript(for: command)

        do {
            try script.write(to: wrapperPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: wrapperPath.path
            )
            Log.trace("RTKManager: installed wrapper for \(command)")
        } catch {
            Log.error("RTKManager: failed to install wrapper for \(command): \(error)")
        }
    }

    /// Generates the shell wrapper script for a command.
    private func generateWrapperScript(for command: String) -> String {
        if command == "cat" {
            return generateCatWrapperScript()
        }
        return generateGenericWrapperScript(for: command)
    }

    /// Generic wrapper: find real binary, check flag, route through optimizer or exec.
    ///
    /// When RTK is active:
    /// - If optimizer exists AND command has a rewrite mapping → `exec chau7-optim <subcommand> "$@"`
    /// - If optimizer not found or command is exec-only → `exec real_binary "$@"`
    private func generateGenericWrapperScript(for command: String) -> String {
        let rtkSubcommand = Self.rtkRewriteMap[command]

        let optimizerBlock: String
        if let sub = rtkSubcommand {
            optimizerBlock = """

                    # Route through built-in optimizer
                    _CHAU7_OPTIM="$HOME/.chau7/bin/chau7-optim"
                    if [ -x "$_CHAU7_OPTIM" ]; then
                        exec "$_CHAU7_OPTIM" \(sub) "$@"
                    fi
            """
        } else {
            optimizerBlock = ""
        }

        return """
        #!/bin/bash
        # RTK wrapper for \(command) — generated by Chau7
        # Checks flag file to decide: optimize output or pass through.

        _RTK_FLAG_DIR="$HOME/.chau7/rtk_active"
        _RTK_SESSION_FLAG="$_RTK_FLAG_DIR/$CHAU7_RTK_SESSION"

        # Find the real binary (skip our wrapper directory in PATH)
        _RTK_WRAPPER_DIR="$HOME/.chau7/rtk_bin"
        _RTK_REAL_BIN=""
        _OLD_IFS="$IFS"
        IFS=':'
        for _dir in $PATH; do
            if [ "$_dir" = "$_RTK_WRAPPER_DIR" ]; then
                continue
            fi
            if [ -x "$_dir/\(command)" ]; then
                _RTK_REAL_BIN="$_dir/\(command)"
                break
            fi
        done
        IFS="$_OLD_IFS"

        if [ -z "$_RTK_REAL_BIN" ]; then
            echo "chau7: could not find real \(command) binary" >&2
            exit 127
        fi

        # If no session ID or no flag file, exec real binary directly (zero overhead)
        if [ -z "$CHAU7_RTK_SESSION" ] || [ ! -f "$_RTK_SESSION_FLAG" ]; then
            exec "$_RTK_REAL_BIN" "$@"
        fi

        # RTK is active\(optimizerBlock)

        # Fallback: exec real binary
        exec "$_RTK_REAL_BIN" "$@"
        """
    }

    /// Specialized `cat` wrapper:
    /// 1. Markdown files → chau7-md (when stdout is a terminal, no flags, all .md)
    /// 2. Other files → `chau7-optim read "$@"` (when optimizer available)
    /// 3. Fallback → real cat
    private func generateCatWrapperScript() -> String {
        return """
        #!/bin/bash
        # RTK wrapper for cat — generated by Chau7
        # Renders markdown files with chau7-md, routes others through chau7-optim read.

        _RTK_FLAG_DIR="$HOME/.chau7/rtk_active"
        _RTK_SESSION_FLAG="$_RTK_FLAG_DIR/$CHAU7_RTK_SESSION"

        # Find real cat (skip our wrapper directory)
        _RTK_WRAPPER_DIR="$HOME/.chau7/rtk_bin"
        _RTK_REAL_BIN=""
        _OLD_IFS="$IFS"
        IFS=':'
        for _dir in $PATH; do
            if [ "$_dir" = "$_RTK_WRAPPER_DIR" ]; then
                continue
            fi
            if [ -x "$_dir/cat" ]; then
                _RTK_REAL_BIN="$_dir/cat"
                break
            fi
        done
        IFS="$_OLD_IFS"

        if [ -z "$_RTK_REAL_BIN" ]; then
            echo "chau7: could not find real cat binary" >&2
            exit 127
        fi

        # No RTK session → pass through
        if [ -z "$CHAU7_RTK_SESSION" ] || [ ! -f "$_RTK_SESSION_FLAG" ]; then
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
                        # Any flag means fall through
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
        if [ -x "$_CHAU7_OPTIM" ]; then
            exec "$_CHAU7_OPTIM" read "$@"
        fi

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
