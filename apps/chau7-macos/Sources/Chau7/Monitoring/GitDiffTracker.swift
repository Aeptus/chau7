import Foundation

/// Tracks files changed between two points in time using git diff.
///
/// Usage: call `snapshot(directory:)` when a command starts, then
/// `changedFiles(directory:)` when it finishes. The diff between the
/// two snapshots is the list of files the command modified.
final class GitDiffTracker {
    /// The set of dirty/untracked files at the time of the snapshot.
    private var baselineFiles: Set<String>?
    private var snapshotDirectory: String?

    /// Capture the current git dirty state as the baseline.
    /// Call this at command start (OSC 133 C).
    func snapshot(directory: String) {
        snapshotDirectory = directory
        baselineFiles = currentDirtyFiles(in: directory)
    }

    /// Compute which files changed since the snapshot.
    /// Call this at command finish (OSC 133 D). Returns file paths
    /// relative to the git root, or an empty array if not in a git repo.
    func changedFiles(directory: String) -> [String] {
        let current = currentDirtyFiles(in: directory)
        guard let baseline = baselineFiles else { return Array(current).sorted() }
        // Files that are dirty now but weren't at snapshot time = newly changed
        // Also include files that were dirty but changed status (modified→deleted, etc.)
        let newOrChanged = current.subtracting(baseline)
        baselineFiles = nil
        snapshotDirectory = nil
        return Array(newOrChanged).sorted()
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
            process.waitUntilExit()
        } catch {
            return ""
        }

        guard process.terminationStatus == 0 else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
