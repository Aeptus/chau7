import Foundation
import Chau7Core

// MARK: - CTO Manager

/// Manages the token optimization wrapper layer: script generation, optimizer
/// binary installation, PATH injection, and token-savings statistics.
///
/// ## Architecture
///
/// 1. **Wrapper scripts** live in `~/.chau7/cto_bin/` and shadow real binaries
///    via PATH prepend.
/// 2. Each wrapper checks a **flag file** in `~/.chau7/cto_active/<SESSION_ID>`.
///    When active, commands in `ctoRewriteMap` are routed through the built-in
///    `chau7-optim` optimizer for token-optimized output. When the optimizer is
///    absent, the real binary is exec'd directly.
/// 3. `CTOFlagManager` controls flag file creation/removal based on the global
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
final class CTOManager {

    static let shared = CTOManager()

    /// Directory containing CTO wrapper scripts (prepended to PATH).
    let wrapperBinDir: URL

    /// Directory for helper binaries like `chau7-md`.
    let binDir: URL

    /// Directory for CTO data/config files.
    private let dataDir: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(".chau7", isDirectory: true)
        self.wrapperBinDir = base.appendingPathComponent("cto_bin", isDirectory: true)
        self.binDir = base.appendingPathComponent("bin", isDirectory: true)
        self.dataDir = base.appendingPathComponent("cto_data", isDirectory: true)
    }

    // MARK: - Setup

    /// Performs first-time setup: creates directories and installs wrapper scripts.
    /// Called once during app startup when CTO mode is not `.off`.
    func setup() {
        CTORuntimeMonitor.shared.recordManagerSetup()
        let fm = FileManager.default

        // Migrate legacy RTK directories → CTO
        migrateDirectoryIfNeeded(fm: fm, from: "rtk_bin", to: "cto_bin")
        migrateDirectoryIfNeeded(fm: fm, from: "rtk_data", to: "cto_data")
        migrateDirectoryIfNeeded(fm: fm, from: "rtk_active", to: "cto_active")

        for dir in [wrapperBinDir, binDir, dataDir] {
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    Log.info("CTOManager: created directory \(dir.path)")
                } catch {
                    Log.error("CTOManager: failed to create \(dir.path): \(error)")
                }
            }
        }

        CTOFlagManager.ensureFlagDirectory()

        for command in supportedCommands {
            installWrapper(for: command)
        }

        // Auto-install bundled helper binaries
        if let bundlePath = Bundle.main.url(forResource: "chau7-md", withExtension: nil) {
            installMarkdownRenderer(from: bundlePath)
        }
        if let bundlePath = Bundle.main.url(forResource: "chau7-optim", withExtension: nil) {
            installOptimizer(from: bundlePath)
        }

        rotateCommandLogIfNeeded()
    }

    /// Moves `~/.chau7/<old>` to `~/.chau7/<new>` if old exists and new does not.
    private func migrateDirectoryIfNeeded(fm: FileManager, from oldName: String, to newName: String) {
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".chau7", isDirectory: true)
        let oldDir = base.appendingPathComponent(oldName, isDirectory: true)
        let newDir = base.appendingPathComponent(newName, isDirectory: true)
        guard fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) else { return }
        do {
            try fm.moveItem(at: oldDir, to: newDir)
            Log.info("CTOManager: migrated \(oldName) → \(newName)")
        } catch {
            Log.error("CTOManager: failed to migrate \(oldName) → \(newName): \(error)")
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

    // MARK: - Binary Installation

    /// Installs a named binary from a source path to `~/.chau7/bin/`.
    private func installBinary(name: String, from sourcePath: URL) -> Bool {
        let fm = FileManager.default
        let dest = binDir.appendingPathComponent(name)

        if !fm.fileExists(atPath: binDir.path) {
            do {
                try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            } catch {
                Log.error("CTOManager: failed to create bin dir: \(error)")
                return false
            }
        }

        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: sourcePath, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            Log.info("CTOManager: installed \(name) to \(dest.path)")
            return true
        } catch {
            Log.error("CTOManager: failed to install \(name): \(error)")
            return false
        }
    }

    /// Installs the chau7-optim binary from a source path to `~/.chau7/bin/`.
    @discardableResult
    func installOptimizer(from sourcePath: URL) -> Bool {
        installBinary(name: "chau7-optim", from: sourcePath)
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
            Log.trace("CTOManager: installed wrapper for \(command) → \(realBin ?? "dynamic")")
        } catch {
            Log.error("CTOManager: failed to install wrapper for \(command): \(error)")
        }
    }

    /// Resolves the real binary path for a command by searching PATH (skipping cto_bin).
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
    /// The fast path (no CTO session) reaches `exec` after just two shell tests and
    /// zero variable assignments — critical for tools like NVM that invoke coreutils
    /// thousands of times during shell init.
    ///
    /// When CTO is active:
    /// - If optimizer exists AND command has a rewrite mapping → `exec chau7-optim <subcommand> "$@"`
    /// - If optimizer not found or command is exec-only → `exec real_binary "$@"`
    private func generateGenericWrapperScript(for command: String, realBin: String?) -> String {
        let ctoSubcommand = ctoRewriteMap[command]

        // Optimizer block: run chau7-optim WITHOUT exec so we can fall through
        // to the real binary if it can't handle the invocation (exit code 2 = clap
        // parse error). This is critical because tools like NVM call grep/ls/cat
        // with flags chau7-optim doesn't support (e.g. grep -q).
        let optimizerBlock: String
        if let sub = ctoSubcommand {
            optimizerBlock = """
            _CHAU7_OPTIM="$HOME/.chau7/bin/chau7-optim"
            if [ -x "$_CHAU7_OPTIM" ]; then
                "$_CHAU7_OPTIM" \(sub) "$@" 2>>"${CHAU7_CTO_LOG:-/dev/null}"
                _rc=$?
                if [ $_rc -ne 2 ]; then
                    [ -n "$CHAU7_CTO_LOG" ] && echo "$(date +%s)|$CHAU7_CTO_SESSION|\(command)|$_rc|optimized" >>"$CHAU7_CTO_LOG"
                    exit $_rc
                fi
                [ -n "$CHAU7_CTO_LOG" ] && echo "$(date +%s)|$CHAU7_CTO_SESSION|\(command)|$_rc|fallthrough" >>"$CHAU7_CTO_LOG"
            fi
            """
        } else {
            optimizerBlock = ""
        }

        // Fast path: when we have a hardcoded binary, the non-CTO case is just
        // two tests + exec with no variable assignments at all.
        if let path = realBin {
            return """
            #!/bin/bash
            # CTO wrapper for \(command) — generated by Chau7

            # Fast path: no active CTO session → exec hardcoded binary immediately.
            if [ -z "$CHAU7_CTO_SESSION" ] || [ ! -f "$HOME/.chau7/cto_active/$CHAU7_CTO_SESSION" ]; then
                exec "\(path)" "$@"
            fi

            # CTO is active — try optimizer, fall through to real binary on failure.
            \(optimizerBlock)
            exec "\(path)" "$@"
            """
        }

        // No hardcoded path available — fall back to runtime PATH scan.
        return """
        #!/bin/bash
        # CTO wrapper for \(command) — generated by Chau7

        _CTO_WRAPPER_DIR="$HOME/.chau7/cto_bin"
        _CTO_REAL_BIN=""
        _OLD_IFS="$IFS"; IFS=':'
        for _dir in $PATH; do
            [ "$_dir" = "$_CTO_WRAPPER_DIR" ] && continue
            if [ -x "$_dir/\(command)" ]; then _CTO_REAL_BIN="$_dir/\(command)"; break; fi
        done
        IFS="$_OLD_IFS"

        if [ -z "$_CTO_REAL_BIN" ]; then
            echo "chau7: could not find real \(command) binary" >&2
            exit 127
        fi

        if [ -z "$CHAU7_CTO_SESSION" ] || [ ! -f "$HOME/.chau7/cto_active/$CHAU7_CTO_SESSION" ]; then
            exec "$_CTO_REAL_BIN" "$@"
        fi

        \(optimizerBlock)
        exec "$_CTO_REAL_BIN" "$@"
        """
    }

    /// Specialized `cat` wrapper with hardcoded real binary path:
    /// 1. Markdown files → chau7-md (when stdout is a terminal, no flags, all .md)
    /// 2. Other files → `chau7-optim read "$@"` (when optimizer available)
    /// 3. Fallback → real cat
    private func generateCatWrapperScript(realBin: String?) -> String {
        let realBinSetup: String
        let realBinFallback: String

        if let path = realBin {
            realBinSetup = """
            # Fast path: no active CTO session → exec hardcoded binary immediately.
            if [ -z "$CHAU7_CTO_SESSION" ] || [ ! -f "$HOME/.chau7/cto_active/$CHAU7_CTO_SESSION" ]; then
                exec "\(path)" "$@"
            fi
            _CTO_REAL_BIN="\(path)"
            """
            realBinFallback = ""
        } else {
            realBinSetup = """
            _CTO_WRAPPER_DIR="$HOME/.chau7/cto_bin"
            _CTO_REAL_BIN=""
            _OLD_IFS="$IFS"; IFS=':'
            for _dir in $PATH; do
                [ "$_dir" = "$_CTO_WRAPPER_DIR" ] && continue
                if [ -x "$_dir/cat" ]; then _CTO_REAL_BIN="$_dir/cat"; break; fi
            done
            IFS="$_OLD_IFS"
            """
            realBinFallback = """

            if [ -z "$_CTO_REAL_BIN" ]; then
                echo "chau7: could not find real cat binary" >&2
                exit 127
            fi

            if [ -z "$CHAU7_CTO_SESSION" ] || [ ! -f "$HOME/.chau7/cto_active/$CHAU7_CTO_SESSION" ]; then
                exec "$_CTO_REAL_BIN" "$@"
            fi
            """
        }

        return """
        #!/bin/bash
        # CTO wrapper for cat — generated by Chau7
        # Renders markdown files with chau7-md, routes others through chau7-optim read.

        \(realBinSetup)\(realBinFallback)

        # CTO is active below this point.

        # Cat with no args may read from stdin (e.g. pipes); avoid read-optimizer path.
        if [ "$#" -eq 0 ]; then
            exec "$_CTO_REAL_BIN" "$@"
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
                _CTO_EXIT=0
                for _arg in "$@"; do
                    "$_CHAU7_MD" "$_arg"
                    [ $? -ne 0 ] && _CTO_EXIT=1
                done
                exit $_CTO_EXIT
            fi
        fi

        # Route through built-in optimizer for non-markdown files
        _CHAU7_OPTIM="$HOME/.chau7/bin/chau7-optim"
        if [ -x "$_CHAU7_OPTIM" ]; then
            "$_CHAU7_OPTIM" read "$@" 2>>"${CHAU7_CTO_LOG:-/dev/null}"
            _rc=$?
            if [ $_rc -ne 2 ]; then
                [ -n "$CHAU7_CTO_LOG" ] && echo "$(date +%s)|$CHAU7_CTO_SESSION|cat|$_rc|optimized" >>"$CHAU7_CTO_LOG"
                exit $_rc
            fi
            [ -n "$CHAU7_CTO_LOG" ] && echo "$(date +%s)|$CHAU7_CTO_SESSION|cat|$_rc|fallthrough" >>"$CHAU7_CTO_LOG"
        fi

        exec "$_CTO_REAL_BIN" "$@"
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
        installBinary(name: "chau7-md", from: sourcePath)
    }

    // MARK: - PATH Injection

    /// Returns the PATH string with the CTO wrapper directory prepended.
    func prependedPATH(original: String) -> String {
        let wrapperDir = wrapperBinDir.path
        let components = original.split(separator: ":", omittingEmptySubsequences: false)
        if components.contains(where: { String($0) == wrapperDir }) {
            return original
        }
        return "\(wrapperDir):\(original)"
    }

    // MARK: - Installation Health Check

    /// Checks the installation status of every supported wrapper script.
    func checkInstallation() -> [WrapperHealth] {
        let fm = FileManager.default
        return supportedCommands.map { command in
            let path = wrapperBinDir.appendingPathComponent(command).path
            let exists = fm.fileExists(atPath: path)
            let executable = exists && fm.isExecutableFile(atPath: path)
            let hasRoute = ctoRewriteMap[command] != nil
            return WrapperHealth(
                command: command,
                isInstalled: exists,
                isExecutable: executable,
                hasCTORoute: hasRoute
            )
        }
    }

    /// Quick check: are all wrappers installed and executable?
    var isFullyInstalled: Bool {
        checkInstallation().allSatisfy { $0.isInstalled && $0.isExecutable }
    }

    // MARK: - CTO Gain Statistics

    /// Wrapper for the JSON envelope from `chau7-optim gain --format json`.
    private struct GainResponse: Codable {
        let summary: CTOGainStats
    }

    /// Fetches aggregated token savings from `chau7-optim gain --format json`.
    /// Returns nil if the optimizer is not installed or the command fails.
    func fetchGainStats() async -> CTOGainStats? {
        guard isOptimizerInstalled else { return nil }

        let optimPath = optimizerPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = optimPath
                process.arguments = ["gain", "--format", "json"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    Log.error("CTOManager: failed to run chau7-optim gain: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let response = try JSONDecoder().decode(GainResponse.self, from: data)
                    continuation.resume(returning: response.summary)
                } catch {
                    Log.error("CTOManager: failed to decode chau7-optim gain output: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Command Log

    /// Path to the structured command log written by wrapper scripts.
    var commandLogPath: URL {
        dataDir.appendingPathComponent("commands.log")
    }

    /// Parsed entry from the command log.
    struct CommandLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let sessionID: String
        let command: String
        let exitCode: Int
        let outcome: String  // "optimized", "fallthrough", or "error"
    }

    /// Reads the most recent entries from the command log.
    func readCommandLog(limit: Int = 100) -> [CommandLogEntry] {
        guard let data = try? String(contentsOf: commandLogPath, encoding: .utf8) else { return [] }
        let lines = data.components(separatedBy: "\n").filter { !$0.isEmpty }
        let recent = lines.suffix(limit)
        return recent.compactMap { line -> CommandLogEntry? in
            let parts = line.split(separator: "|", maxSplits: 4)
            guard parts.count == 5,
                  let epoch = TimeInterval(parts[0]),
                  let exitCode = Int(parts[3])
            else { return nil }
            return CommandLogEntry(
                timestamp: Date(timeIntervalSince1970: epoch),
                sessionID: String(parts[1]),
                command: String(parts[2]),
                exitCode: exitCode,
                outcome: String(parts[4])
            )
        }
    }

    /// Percentage of commands that were successfully optimized (vs fallthrough/error).
    func commandSuccessRate() -> Double? {
        let entries = readCommandLog(limit: 500)
        guard !entries.isEmpty else { return nil }
        let optimized = entries.filter { $0.outcome == "optimized" }.count
        return (Double(optimized) / Double(entries.count)) * 100
    }

    /// Truncates the command log if it exceeds 1 MB. Called during setup().
    func rotateCommandLogIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: commandLogPath.path) else { return }
        guard let attrs = try? fm.attributesOfItem(atPath: commandLogPath.path),
              let size = attrs[.size] as? UInt64,
              size > 1_048_576
        else { return }

        // Keep the last 500 lines
        guard let data = try? String(contentsOf: commandLogPath, encoding: .utf8) else { return }
        let lines = data.components(separatedBy: "\n").filter { !$0.isEmpty }
        let kept = lines.suffix(500).joined(separator: "\n") + "\n"
        try? kept.write(to: commandLogPath, atomically: true, encoding: .utf8)
        Log.info("CTOManager: rotated command log (was \(size) bytes)")
    }

    // MARK: - Cleanup

    /// Removes all wrapper scripts and flag files. Called on app quit or
    /// when switching to `.off` mode.
    func teardown() {
        CTORuntimeMonitor.shared.recordManagerTeardown()
        let removed = CTOFlagManager.removeAllFlags()
        CTORuntimeMonitor.shared.recordManagerBulkRemove(count: removed)

        let fm = FileManager.default
        if fm.fileExists(atPath: wrapperBinDir.path) {
            do {
                let contents = try fm.contentsOfDirectory(atPath: wrapperBinDir.path)
                for file in contents {
                    try fm.removeItem(atPath: wrapperBinDir.appendingPathComponent(file).path)
                }
                Log.info("CTOManager: removed \(contents.count) wrapper script(s)")
            } catch {
                Log.error("CTOManager: failed to clean up wrappers: \(error)")
            }
        }
    }
}
