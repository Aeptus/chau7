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

        var diffUnavailable: Bool {
            unavailableReason != nil && files.isEmpty
        }
    }

    private enum SnapshotMode {
        case git(Set<String>)
        case fileSystem([String: Date], reason: String?)
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
                usedFallback: isFallback(current),
                status: status(for: current, files: files)
            )
        }

        switch (baseline, current) {
        case let (.git(before), .git(after)):
            let changed = Array(after.symmetricDifference(before)).sorted()
            return ChangedFilesResult(files: changed, unavailableReason: nil, usedFallback: false, status: .loaded)
        case let (.fileSystem(before, _), .fileSystem(after, _)):
            let changed = Array(changedPaths(from: before, to: after)).sorted()
            return ChangedFilesResult(
                files: changed,
                unavailableReason: unavailableReason(from: current),
                usedFallback: true,
                status: status(for: current, files: changed)
            )
        default:
            let files = snapshotFiles(from: current)
            return ChangedFilesResult(
                files: files,
                unavailableReason: unavailableReason(from: current),
                usedFallback: isFallback(current),
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
        return .fileSystem(currentFileModDates(in: directory), reason: gitResult.reason)
    }

    private func snapshotFiles(from snapshot: SnapshotMode) -> [String] {
        switch snapshot {
        case .git(let files):
            return Array(files).sorted()
        case .fileSystem(let files, _):
            return Array(files.keys).sorted()
        }
    }

    private func unavailableReason(from snapshot: SnapshotMode) -> String? {
        switch snapshot {
        case .git:
            return nil
        case .fileSystem(_, let reason):
            return reason
        }
    }

    private func isFallback(_ snapshot: SnapshotMode) -> Bool {
        if case .fileSystem = snapshot { return true }
        return false
    }

    private func status(for snapshot: SnapshotMode, files: [String]) -> CommandBlockChangedFilesStatus {
        switch snapshot {
        case .git:
            return .loaded
        case .fileSystem(_, let reason):
            guard let reason else { return .loaded }
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

    private func currentFileModDates(in directory: String) -> [String: Date] {
        let rootURL = URL(fileURLWithPath: directory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .isDirectoryKey],
            options: []
        ) else {
            return [:]
        }

        var result: [String: Date] = [:]
        let ignoredDirectories: Set = [".git", ".build", "node_modules", "DerivedData"]

        for case let url as URL in enumerator {
            if ignoredDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            result[relative] = values?.contentModificationDate ?? Date.distantPast
        }
        return result
    }

    private func changedPaths(from before: [String: Date], to after: [String: Date]) -> Set<String> {
        let allPaths = Set(before.keys).union(after.keys)
        return Set(allPaths.filter { path in
            switch (before[path], after[path]) {
            case (.none, .some), (.some, .none):
                return true
            case let (.some(lhs), .some(rhs)):
                return lhs != rhs
            default:
                return false
            }
        })
    }

    /// Result of a git command that captures both outputs and exit status.
    struct GitResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32

        var succeeded: Bool {
            exitCode == 0
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

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()

        let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GitResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
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
