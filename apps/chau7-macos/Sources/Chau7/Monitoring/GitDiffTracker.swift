import Foundation

/// Tracks files changed between two points in time using git diff.
///
/// Usage: call `snapshot(directory:)` when a command starts, then
/// `changedFiles(directory:)` when it finishes. The diff between the
/// two snapshots is the list of files the command modified.
final class GitDiffTracker {
    /// Serializes access to baselineFiles (snapshot and changedFiles may race on concurrent queues).
    private let lock = NSLock()
    /// The set of dirty/untracked files at the time of the snapshot.
    private var baselineFiles: Set<String>?
    private var snapshotDirectory: String?

    /// Capture the current git dirty state as the baseline.
    /// Call this at command start (OSC 133 C).
    func snapshot(directory: String) {
        let files = currentDirtyFiles(in: directory)
        lock.lock()
        snapshotDirectory = directory
        baselineFiles = files
        lock.unlock()
    }

    /// Compute which files changed since the snapshot.
    /// Call this at command finish (OSC 133 D). Returns file paths
    /// relative to the git root, or an empty array if not in a git repo.
    func changedFiles(directory: String) -> [String] {
        let current = currentDirtyFiles(in: directory)
        lock.lock()
        let baseline = baselineFiles
        baselineFiles = nil
        snapshotDirectory = nil
        lock.unlock()
        guard let baseline else { return Array(current).sorted() }
        // symmetricDifference catches both:
        // - Files dirty now that weren't before (newly modified/created)
        // - Files that were dirty but are now clean (committed or reverted)
        let changed = current.symmetricDifference(baseline)
        return Array(changed).sorted()
    }

    /// Returns `git diff --stat` summary for a specific file (e.g., "3 insertions(+), 1 deletion(-)").
    func diffStat(file: String, in directory: String) -> String {
        let output = runGit(args: ["diff", "--stat", "--", file], in: directory)
        // Last line of --stat is the summary: " 1 file changed, 3 insertions(+), 1 deletion(-)"
        guard let lastLine = output.components(separatedBy: "\n").last(where: { $0.contains("changed") }) else {
            // Try staged diff
            let staged = runGit(args: ["diff", "--cached", "--stat", "--", file], in: directory)
            return staged.components(separatedBy: "\n").last(where: { $0.contains("changed") })?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        return lastLine.trimmingCharacters(in: .whitespaces)
    }

    /// Returns the set of dirty + untracked file paths from `git status --porcelain`.
    /// Each entry is a relative path like "src/main.swift".
    private func currentDirtyFiles(in directory: String) -> Set<String> {
        let output = runGit(args: ["status", "--porcelain"], in: directory)
        guard !output.isEmpty else { return [] }

        var files = Set<String>()
        for line in output.components(separatedBy: "\n") {
            // git status --porcelain format: "XY filename" (2-char status + space + path)
            guard line.count > 3 else { continue }
            let path = String(line.dropFirst(3))
            // Handle renames: "R  old -> new"
            if let arrowRange = path.range(of: " -> ") {
                files.insert(String(path[arrowRange.upperBound...]))
            } else {
                files.insert(path)
            }
        }
        return files
    }

    private func runGit(args: [String], in directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args
        process.environment = ["GIT_TERMINAL_PROMPT": "0"]

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
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)

        // Read stdout BEFORE waitUntilExit to avoid deadlock when the pipe
        // buffer fills (git blocks on write, we block on wait → both stuck).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
