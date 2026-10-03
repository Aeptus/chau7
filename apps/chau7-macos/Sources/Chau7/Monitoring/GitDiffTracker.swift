import Foundation
import Chau7Core

/// Tracks files changed between two points in time using git diff.
///
/// Usage: call `snapshot(directory:)` when a command starts, then
/// `changedFiles(directory:)` when it finishes. The diff between the
/// two snapshots is the list of files the command modified.
final class GitDiffTracker {
    struct ChangedFilesResult {
        let files: [String]
        let unavailableReason: String?
        let usedFallback: Bool
        let status: CommandBlockChangedFilesStatus
        var truncated = false

        var diffUnavailable: Bool {
            unavailableReason != nil && files.isEmpty
        }
    }

    private enum SnapshotMode {
        case git(Set<String>)
        case unavailable(reason: String)
    }

    static func changedPath(fromStatusPorcelainLine line: String) -> String? {
        guard line.count > 3 else { return nil }
        let path = String(line.dropFirst(3))
        if let arrowRange = path.range(of: " -> ") {
            return String(path[arrowRange.upperBound...])
        }
        return path.isEmpty ? nil : path
    }

    static func firstChangedPath(inStatusPorcelain output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { changedPath(fromStatusPorcelainLine: String($0)) }
            .first
    }

    /// Serializes access to baselineFiles (snapshot and changedFiles may race on concurrent queues).
    private let lock = NSLock()
    /// The set of dirty/untracked files at the time of the snapshot.
    private var baselineSnapshot: SnapshotMode?
    private var snapshotDirectory: String?

    /// Capture the current git dirty state as the baseline.
    /// Call this at command start (OSC 133 C).
    func snapshot(directory: String) {
        let snapshot = currentSnapshot(in: directory)
        lock.lock()
        snapshotDirectory = directory
        baselineSnapshot = snapshot
        lock.unlock()
    }

    /// Compute which files changed since the snapshot.
    /// Call this at command finish (OSC 133 D). Returns file paths
    /// relative to the git root, or an empty array if not in a git repo.
    func changedFiles(directory: String) -> [String] {
        changedFilesResult(directory: directory).files
    }

    func changedFilesResult(directory: String) -> ChangedFilesResult {
        let raw = rawChangedFilesResult(directory: directory)
        let bounded = ChangedFilesBudget.select(raw.files, status: raw.status)
        return ChangedFilesResult(
            files: bounded.files,
            unavailableReason: raw.unavailableReason,
            usedFallback: false,
            status: raw.status,
            truncated: bounded.truncated
        )
    }

    private func rawChangedFilesResult(directory: String) -> ChangedFilesResult {
        let current = currentSnapshot(in: directory)
        lock.lock()
        let baseline = baselineSnapshot
        baselineSnapshot = nil
        snapshotDirectory = nil
        lock.unlock()
        guard let baseline else {
            let files = snapshotFiles(from: current)
            return ChangedFilesResult(
                files: files,
                unavailableReason: unavailableReason(from: current),
                usedFallback: false,
                status: status(for: current, files: files)
            )
        }

        switch (baseline, current) {
        case let (.git(before), .git(after)):
            let changed = Array(after.symmetricDifference(before)).sorted()
            return ChangedFilesResult(files: changed, unavailableReason: nil, usedFallback: false, status: .loaded)
        default:
            let files = snapshotFiles(from: current)
            return ChangedFilesResult(
                files: files,
                unavailableReason: unavailableReason(from: current),
                usedFallback: false,
                status: status(for: current, files: files)
            )
        }
    }

    /// Returns `git diff --stat` summary for a specific file (e.g., "3 insertions(+), 1 deletion(-)").
    func diffStat(file: String, in directory: String) -> String {
        let output = Self.runGit(args: ["diff", "--stat", "--", file], in: directory)
        // Last line of --stat is the summary: " 1 file changed, 3 insertions(+), 1 deletion(-)"
        guard let lastLine = output.components(separatedBy: "\n").last(where: { $0.contains("changed") }) else {
            // Try staged diff
            let staged = Self.runGit(args: ["diff", "--cached", "--stat", "--", file], in: directory)
            return staged.components(separatedBy: "\n").last(where: { $0.contains("changed") })?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        return lastLine.trimmingCharacters(in: .whitespaces)
    }

    private func currentSnapshot(in directory: String) -> SnapshotMode {
        let gitResult = currentDirtyFilesResult(in: directory)
        if gitResult.succeeded {
            return .git(gitResult.files)
        }
        return .unavailable(reason: gitResult.reason ?? "git status unavailable")
    }

    private func snapshotFiles(from snapshot: SnapshotMode) -> [String] {
        switch snapshot {
        case .git(let files):
            return Array(files).sorted()
        case .unavailable:
            return []
        }
    }

    private func unavailableReason(from snapshot: SnapshotMode) -> String? {
        switch snapshot {
        case .git:
            return nil
        case .unavailable(let reason):
            return reason
        }
    }

    private func status(for snapshot: SnapshotMode, files: [String]) -> CommandBlockChangedFilesStatus {
        switch snapshot {
        case .git:
            return .loaded
        case .unavailable(let reason):
            if reason.localizedCaseInsensitiveContains("not a git repository") {
                return .notGitRepo
            }
            return files.isEmpty ? .failed : .loaded
        }
    }

    private func currentDirtyFilesResult(in directory: String) -> (files: Set<String>, succeeded: Bool, reason: String?) {
        let first = Self.runGitWithStatus(args: ["status", "--porcelain"], in: directory)
        let result = first.succeeded ? first : Self.runGitWithStatus(args: ["status", "--porcelain"], in: directory)
        guard result.succeeded else {
            let reason = result.stderr.isEmpty ? "git status unavailable" : result.stderr
            return ([], false, reason)
        }

        var files = Set<String>()
        for line in result.stdout.components(separatedBy: "\n") {
            guard let path = Self.changedPath(fromStatusPorcelainLine: line) else { continue }
            files.insert(path)
        }
        return (files, true, nil)
    }

    /// Result of a git command that captures both outputs and exit status.
    struct GitResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var terminationReason: Process.TerminationReason = .exit

        /// A git killed by the timeout, or crashed, did not succeed — whatever
        /// `terminationStatus` happens to report for a signalled process. Treating
        /// it as success made a timed-out probe look like "inside a repository",
        /// which silently downgraded every changed-files call to an empty git
        /// answer instead of the filesystem fallback it should have used.
        var succeeded: Bool {
            terminationReason == .exit && exitCode == 0
        }
    }

    /// Runs a git command and returns stdout, stderr, and exit code.
    /// Use this for write operations where the caller needs error details.
    static func runGitWithStatus(args: [String], in directory: String) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return GitResult(stdout: "", stderr: "Failed to launch git: \(error.localizedDescription)", exitCode: -1)
        }

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: deadline)

        // Drain both pipes concurrently. Reading stdout to EOF *then* stderr
        // deadlocks whenever stderr fills its 64 KB buffer: git blocks writing
        // stderr, we block reading stdout waiting for an EOF that never comes,
        // and the only thing that ends it is the timeout below -- so a busy
        // machine turns a normal command into a killed one.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let lock = NSLock()
        DispatchQueue.global(qos: .utility).async(group: group) {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            outData = data
            lock.unlock()
        }
        DispatchQueue.global(qos: .utility).async(group: group) {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            errData = data
            lock.unlock()
        }
        group.wait()
        process.waitUntilExit()
        deadline.cancel()

        let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GitResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus,
            terminationReason: process.terminationReason
        )
    }

    static func runGit(args: [String], in directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // Distinguish launch failure from "git returned no output":
            // the empty-string sentinel previously collided with a clean
            // tree, so callers (diff coloring, change detection) treated
            // a broken git install as "nothing changed." Log at warn so
            // the genuine launch failure is visible.
            Log.warn("GitDiffTracker.runGit: Process launch failed at \(process.executableURL?.path ?? "<nil>") for args=\(args.prefix(4).joined(separator: " ")): \(error)")
            return ""
        }

        // Kill if git takes longer than 5 seconds (large repos)
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)

        // Read stdout BEFORE waitUntilExit to avoid deadlock when the pipe
        // buffer fills (git blocks on write, we block on wait → both stuck).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
