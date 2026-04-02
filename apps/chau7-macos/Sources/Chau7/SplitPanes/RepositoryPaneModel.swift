import Foundation

/// Observable model for the Repository Pane — provides full git operations.
///
/// All git commands run on a background queue via injectable `gitRunner`
/// (defaults to `GitDiffTracker.runGit`). State is published on the main
/// thread. Errors surface inline via `lastError`.
///
/// Follows the same pattern as `DiffViewerModel`: injectable runner,
/// background execution, `@Published` state, token-based cancellation.
final class RepositoryPaneModel: ObservableObject, Identifiable {
    let id = UUID()

    // MARK: - Dependencies

    private let gitRunner: ([String], String) -> String
    private let gitRunnerWithStatus: ([String], String) -> GitDiffTracker.GitResult
    private let loadQueue = DispatchQueue(label: "com.chau7.repo-pane", qos: .userInitiated)

    // MARK: - Configuration

    @Published var directory: String?

    // MARK: - Branch State

    @Published var currentBranch: String?
    @Published var branches: [String] = []
    @Published var remoteBranches: [String] = []
    @Published var branchDetails: [String: BranchDetail] = [:]
    @Published var aheadBehind: (ahead: Int, behind: Int)?

    // MARK: - File Status

    @Published var stagedFiles: [FileStatus] = []
    @Published var unstagedFiles: [FileStatus] = []
    @Published var untrackedFiles: [String] = []
    @Published var conflictedFiles: [String] = []

    // MARK: - Commit

    @Published var commitMessage = ""
    @Published var isAmend = false

    // MARK: - History

    @Published var commits: [CommitEntry] = []
    var commitLogLimit = 50

    // MARK: - Stash

    @Published var stashes: [StashEntry] = []

    // MARK: - History Search

    @Published var historySearchText = ""

    var filteredCommits: [CommitEntry] {
        guard !historySearchText.isEmpty else { return commits }
        let query = historySearchText.lowercased()
        return commits.filter {
            $0.message.lowercased().contains(query)
                || $0.author.lowercased().contains(query)
                || $0.shortHash.lowercased().contains(query)
        }
    }

    // MARK: - Conventional Commit Prefixes

    static let commitPrefixes = ["feat", "fix", "docs", "style", "refactor", "test", "chore"]

    func applyPrefix(_ prefix: String) {
        let trimmed = commitMessage.trimmingCharacters(in: .whitespaces)
        // Don't add if already prefixed
        if trimmed.hasPrefix(prefix + ":") || trimmed.hasPrefix(prefix + "(") { return }
        commitMessage = prefix + ": " + trimmed
    }

    var hasConventionalPrefix: Bool {
        let trimmed = commitMessage.trimmingCharacters(in: .whitespaces).lowercased()
        return Self.commitPrefixes.contains(where: { trimmed.hasPrefix($0 + ":") || trimmed.hasPrefix($0 + "(") })
    }

    // MARK: - General State

    @Published var isLoading = false
    @Published var lastError: String?
    @Published var operationInProgress: String?
    var lastRefreshDate: Date?

    /// Display name derived from directory.
    var repoName: String {
        guard let dir = directory else { return "Repository" }
        return URL(fileURLWithPath: dir).lastPathComponent
    }

    /// For pane header pattern compatibility.
    var fileName: String {
        repoName
    }

    // MARK: - Init

    init(
        gitRunner: @escaping ([String], String) -> String = GitDiffTracker.runGit,
        gitRunnerWithStatus: @escaping ([String], String) -> GitDiffTracker.GitResult = GitDiffTracker.runGitWithStatus
    ) {
        self.gitRunner = gitRunner
        self.gitRunnerWithStatus = gitRunnerWithStatus
    }

    // MARK: - Lifecycle

    func load(directory: String) {
        self.directory = directory
        // Restore persisted commit message draft
        commitMessage = UserDefaults.standard.string(forKey: "repoPaneDraft.\(directory)") ?? ""
        refreshAll()
    }

    /// Save commit message draft (call from view onChange).
    func persistDraft() {
        guard let dir = directory else { return }
        let trimmed = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "repoPaneDraft.\(dir)")
        } else {
            UserDefaults.standard.set(commitMessage, forKey: "repoPaneDraft.\(dir)")
        }
    }

    /// Clear persisted draft (call after successful commit).
    private func clearDraft() {
        guard let dir = directory else { return }
        UserDefaults.standard.removeObject(forKey: "repoPaneDraft.\(dir)")
    }

    /// Returns true if enough time has passed since the last refresh to avoid hammering git.
    func shouldAutoRefresh(debounceSeconds: TimeInterval = 2) -> Bool {
        guard let last = lastRefreshDate else { return true }
        return Date().timeIntervalSince(last) >= debounceSeconds
    }

    func refreshAll() {
        guard let dir = directory else { return }
        let limit = commitLogLimit // capture before dispatch
        DispatchQueue.main.async { [weak self] in
            self?.isLoading = true
            self?.lastError = nil
        }
        loadQueue.async { [weak self] in
            guard let self else { return }

            let branch = gitRunner(["rev-parse", "--abbrev-ref", "HEAD"], dir)
            let statusOutput = gitRunner(["status", "--porcelain"], dir)
            let branchOutput = gitRunner(["branch", "-v", "--list"], dir)
            let remoteBranchOutput = gitRunner(["branch", "-r"], dir)
            let aheadBehindOutput = gitRunner(["rev-list", "--count", "--left-right", "@{upstream}...HEAD"], dir)
            let logOutput = gitRunner([
                "log", "--format=%H%n%h%n%s%n%an%n%aI",
                "-\(limit)"
            ], dir)
            let stashOutput = gitRunner(["stash", "list"], dir)

            let parsed = Self.parseStatus(statusOutput)
            let (parsedBranches, parsedDetails) = Self.parseBranchesVerbose(branchOutput)
            let parsedRemoteBranches = Self.parseRemoteBranches(remoteBranchOutput)
            let parsedAheadBehind = Self.parseAheadBehind(aheadBehindOutput)
            let parsedCommits = Self.parseCommitLog(logOutput)
            let parsedStashes = Self.parseStashList(stashOutput)

            DispatchQueue.main.async {
                self.currentBranch = branch.isEmpty ? nil : branch
                self.stagedFiles = parsed.staged
                self.unstagedFiles = parsed.unstaged
                self.untrackedFiles = parsed.untracked
                self.conflictedFiles = parsed.conflicted
                self.branches = parsedBranches
                self.branchDetails = parsedDetails
                self.remoteBranches = parsedRemoteBranches
                self.aheadBehind = parsedAheadBehind
                self.commits = parsedCommits
                self.stashes = parsedStashes
                self.isLoading = false
                self.lastRefreshDate = Date()
            }
        }
    }

    // MARK: - Read Operations

    func refreshStatus() {
        guard let dir = directory else { return }
        loadQueue.async { [weak self] in
            guard let self else { return }
            let output = gitRunner(["status", "--porcelain"], dir)
            let parsed = Self.parseStatus(output)
            DispatchQueue.main.async {
                self.stagedFiles = parsed.staged
                self.unstagedFiles = parsed.unstaged
                self.untrackedFiles = parsed.untracked
                self.conflictedFiles = parsed.conflicted
            }
        }
    }

    func refreshBranches() {
        guard let dir = directory else { return }
        loadQueue.async { [weak self] in
            guard let self else { return }
            let branch = gitRunner(["rev-parse", "--abbrev-ref", "HEAD"], dir)
            let local = gitRunner(["branch", "-v", "--list"], dir)
            let remote = gitRunner(["branch", "-r"], dir)
            let ab = gitRunner(["rev-list", "--count", "--left-right", "@{upstream}...HEAD"], dir)
            let (parsedBranches, parsedDetails) = Self.parseBranchesVerbose(local)
            DispatchQueue.main.async {
                self.currentBranch = branch.isEmpty ? nil : branch
                self.branches = parsedBranches
                self.branchDetails = parsedDetails
                self.remoteBranches = Self.parseRemoteBranches(remote)
                self.aheadBehind = Self.parseAheadBehind(ab)
            }
        }
    }

    func refreshCommitLog() {
        guard let dir = directory else { return }
        let limit = commitLogLimit
        loadQueue.async { [weak self] in
            guard let self else { return }
            let output = gitRunner([
                "log", "--format=%H%n%h%n%s%n%an%n%aI",
                "-\(limit)"
            ], dir)
            let commits = Self.parseCommitLog(output)
            DispatchQueue.main.async {
                self.commits = commits
            }
        }
    }

    func loadMoreCommits() {
        commitLogLimit += 50
        refreshCommitLog()
    }

    func refreshStashes() {
        guard let dir = directory else { return }
        loadQueue.async { [weak self] in
            guard let self else { return }
            let output = gitRunner(["stash", "list"], dir)
            let stashes = Self.parseStashList(output)
            DispatchQueue.main.async {
                self.stashes = stashes
            }
        }
    }

    // MARK: - Write Operations: Staging

    func stageFile(_ path: String) {
        runWriteOp(args: ["add", "--", path], label: nil) { [weak self] in
            self?.refreshStatus()
        }
    }

    func unstageFile(_ path: String) {
        runWriteOp(args: ["restore", "--staged", "--", path], label: nil) { [weak self] in
            self?.refreshStatus()
        }
    }

    func stageAll() {
        runWriteOp(args: ["add", "-A"], label: nil) { [weak self] in
            self?.refreshStatus()
        }
    }

    func unstageAll() {
        runWriteOp(args: ["restore", "--staged", "."], label: nil) { [weak self] in
            self?.refreshStatus()
        }
    }

    // MARK: - Write Operations: Commit

    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            lastError = "Commit message cannot be empty."
            return
        }
        var args = ["commit", "-m", message]
        if isAmend { args.append("--amend") }

        runWriteOp(args: args, label: "Committing...") { [weak self] in
            self?.commitMessage = ""
            self?.isAmend = false
            self?.clearDraft()
            self?.refreshStatus()
            self?.refreshCommitLog()
        }
    }

    // MARK: - Write Operations: Branch

    func switchBranch(_ name: String) {
        runWriteOp(args: ["checkout", name], label: "Switching to \(name)...") { [weak self] in
            self?.refreshAll()
        }
    }

    func createBranch(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Branch name cannot be empty."
            return
        }
        runWriteOp(args: ["checkout", "-b", trimmed], label: "Creating \(trimmed)...") { [weak self] in
            self?.refreshAll()
        }
    }

    func deleteBranch(_ name: String) {
        runWriteOp(args: ["branch", "-d", name], label: "Deleting \(name)...") { [weak self] in
            self?.refreshBranches()
        }
    }

    // MARK: - Write Operations: Remote

    func push() {
        runWriteOp(args: ["push"], label: "Pushing...") { [weak self] in
            self?.refreshCommitLog()
        }
    }

    func pull() {
        runWriteOp(args: ["pull"], label: "Pulling...") { [weak self] in
            self?.refreshAll()
        }
    }

    // MARK: - Write Operations: Stash

    func stashSave(message: String?) {
        var args = ["stash", "push"]
        if let msg = message, !msg.isEmpty {
            args += ["-m", msg]
        }
        runWriteOp(args: args, label: "Stashing...") { [weak self] in
            self?.refreshStatus()
            self?.refreshStashes()
        }
    }

    func stashPop(index: Int) {
        // Stash indices are positional — verify the stash still exists at the expected index
        // by refreshing stashes first, then operating.
        guard let dir = directory else { return }
        let freshList = gitRunner(["stash", "list"], dir)
        let freshStashes = Self.parseStashList(freshList)
        guard index < freshStashes.count else {
            lastError = "Stash @{\(index)} no longer exists."
            return
        }
        runWriteOp(args: ["stash", "pop", "stash@{\(index)}"], label: "Popping stash...") { [weak self] in
            self?.refreshStatus()
            self?.refreshStashes()
        }
    }

    func stashDrop(index: Int) {
        guard let dir = directory else { return }
        let freshList = gitRunner(["stash", "list"], dir)
        let freshStashes = Self.parseStashList(freshList)
        guard index < freshStashes.count else {
            lastError = "Stash @{\(index)} no longer exists."
            return
        }
        runWriteOp(args: ["stash", "drop", "stash@{\(index)}"], label: "Dropping stash...") { [weak self] in
            self?.refreshStashes()
        }
    }

    // MARK: - Write Operations: Merge Conflict

    func acceptOurs(file: String) {
        runWriteOp(args: ["checkout", "--ours", "--", file], label: nil) { [weak self] in
            self?.stageFile(file)
        }
    }

    func acceptTheirs(file: String) {
        runWriteOp(args: ["checkout", "--theirs", "--", file], label: nil) { [weak self] in
            self?.stageFile(file)
        }
    }

    // MARK: - Write Operation Runner

    private func runWriteOp(args: [String], label: String?, onSuccess: @escaping () -> Void) {
        guard let dir = directory else { return }
        DispatchQueue.main.async { [weak self] in
            self?.lastError = nil
            self?.operationInProgress = label
        }
        loadQueue.async { [weak self] in
            guard let self else { return }
            let result = gitRunnerWithStatus(args, dir)
            DispatchQueue.main.async {
                self.operationInProgress = nil
                if result.succeeded {
                    onSuccess()
                } else {
                    let errMsg = result.stderr.isEmpty ? result.stdout : result.stderr
                    self.lastError = errMsg.isEmpty ? "Git command failed (exit \(result.exitCode))." : errMsg
                    Log.warn("RepoPaneModel: git \(args.joined(separator: " ")) failed: \(errMsg)")
                }
            }
        }
    }

    // MARK: - Parsing

    struct StatusParseResult {
        var staged: [FileStatus]
        var unstaged: [FileStatus]
        var untracked: [String]
        var conflicted: [String]
    }

    static func parseStatus(_ output: String) -> StatusParseResult {
        var staged: [FileStatus] = []
        var unstaged: [FileStatus] = []
        var untracked: [String] = []
        var conflicted: [String] = []

        for line in output.components(separatedBy: "\n") where line.count >= 3 {
            let x = line[line.startIndex] // index status
            let y = line[line.index(after: line.startIndex)] // work-tree status
            let path = String(line.dropFirst(3))
            let displayPath: String
            if let arrowRange = path.range(of: " -> ") {
                displayPath = String(path[arrowRange.upperBound...])
            } else {
                displayPath = path
            }

            // Untracked
            if x == "?" && y == "?" {
                untracked.append(displayPath)
                continue
            }

            // Unmerged (conflict)
            if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                conflicted.append(displayPath)
                continue
            }

            // Staged (index column)
            if x != " ", x != "?" {
                staged.append(FileStatus(
                    path: displayPath,
                    changeType: Self.changeType(from: x),
                    indexStatus: x,
                    workTreeStatus: y
                ))
            }

            // Unstaged (work-tree column)
            if y != " ", y != "?" {
                unstaged.append(FileStatus(
                    path: displayPath,
                    changeType: Self.changeType(from: y),
                    indexStatus: x,
                    workTreeStatus: y
                ))
            }
        }

        return StatusParseResult(staged: staged, unstaged: unstaged, untracked: untracked, conflicted: conflicted)
    }

    private static func changeType(from char: Character) -> FileChangeType {
        switch char {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "U": return .unmerged
        default: return .modified
        }
    }

    static func parseBranches(_ output: String) -> [String] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
    }

    /// Parse `git branch -v --list` which includes last commit per branch.
    /// Format: "* main      abc1234 Last commit message" or "  feature   def5678 Some work"
    static func parseBranchesVerbose(_ output: String) -> (names: [String], details: [String: BranchDetail]) {
        var names: [String] = []
        var details: [String: BranchDetail] = [:]
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let isCurrent = line.hasPrefix("*")
            let cleaned = isCurrent ? String(trimmed.dropFirst(2)) : trimmed

            // Skip detached HEAD entries like "(HEAD detached at abc1234)"
            if cleaned.hasPrefix("(") { continue }

            // Split on whitespace: name, hash, message...
            let parts = cleaned.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else {
                names.append(cleaned)
                continue
            }
            let name = String(parts[0])
            let hash = String(parts[1])
            let message = parts.count > 2 ? String(parts[2]) : ""
            names.append(name)
            details[name] = BranchDetail(name: name, lastCommitHash: hash, lastCommitMessage: message)
        }
        return (names, details)
    }

    /// Parse `git rev-list --count --left-right @{upstream}...HEAD`
    /// Output: "3\t5" where 3=behind, 5=ahead
    static func parseAheadBehind(_ output: String) -> (ahead: Int, behind: Int)? {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        guard parts.count == 2,
              let behind = Int(parts[0]),
              let ahead = Int(parts[1]) else { return nil }
        return (ahead: ahead, behind: behind)
    }

    static func parseRemoteBranches(_ output: String) -> [String] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("HEAD") }
    }

    static func parseCommitLog(_ output: String) -> [CommitEntry] {
        let lines = output.components(separatedBy: "\n")
        var commits: [CommitEntry] = []
        // Each commit is 5 lines: hash, shortHash, subject, author, date
        var i = 0
        while i + 4 < lines.count {
            let hash = lines[i]
            let shortHash = lines[i + 1]
            let subject = lines[i + 2]
            let author = lines[i + 3]
            let dateStr = lines[i + 4]
            i += 5

            guard !hash.isEmpty else { continue }

            let date = ISO8601DateFormatter().date(from: dateStr) ?? Date.distantPast
            commits.append(CommitEntry(
                hash: hash,
                shortHash: shortHash,
                message: subject,
                author: author,
                date: date,
                dateString: Self.relativeDate(from: date)
            ))
        }
        return commits
    }

    static func parseStashList(_ output: String) -> [StashEntry] {
        guard !output.isEmpty else { return [] }
        return output.components(separatedBy: "\n")
            .enumerated()
            .compactMap { index, line in
                guard !line.isEmpty else { return nil }
                // Format: stash@{0}: WIP on main: abc1234 message
                // Or:     stash@{0}: On develop: saving progress
                let parts = line.components(separatedBy: ": ")
                let description = parts.dropFirst().joined(separator: ": ")

                // Extract branch from "WIP on main" or "On develop"
                var branch: String?
                if parts.count >= 2 {
                    let stashType = parts[1]
                    if stashType.hasPrefix("WIP on ") {
                        branch = String(stashType.dropFirst("WIP on ".count))
                    } else if stashType.hasPrefix("On ") {
                        branch = String(stashType.dropFirst("On ".count))
                    }
                }

                return StashEntry(index: index, description: description.isEmpty ? line : description, branch: branch)
            }
    }

    private static func relativeDate(from date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        if seconds < 604_800 { return "\(seconds / 86400)d ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Supporting Types

struct FileStatus: Identifiable {
    let id = UUID()
    let path: String
    let changeType: FileChangeType
    let indexStatus: Character
    let workTreeStatus: Character
}

enum FileChangeType: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case unmerged = "U"

    var icon: String {
        switch self {
        case .modified: return "pencil"
        case .added: return "plus"
        case .deleted: return "minus"
        case .renamed: return "arrow.right"
        case .copied: return "doc.on.doc"
        case .unmerged: return "exclamationmark.triangle"
        }
    }

    var color: String {
        switch self {
        case .modified: return "orange"
        case .added: return "green"
        case .deleted: return "red"
        case .renamed: return "blue"
        case .copied: return "purple"
        case .unmerged: return "red"
        }
    }
}

struct CommitEntry: Identifiable {
    var id: String {
        hash
    }

    let hash: String
    let shortHash: String
    let message: String
    let author: String
    let date: Date
    let dateString: String
}

struct StashEntry: Identifiable {
    var id: Int {
        index
    }

    let index: Int
    let description: String
    let branch: String?

    /// Tooltip text for hover.
    var hoverText: String {
        var text = "stash@{\(index)}"
        if let branch { text += " on \(branch)" }
        text += "\n\(description)"
        return text
    }
}

struct BranchDetail {
    let name: String
    let lastCommitHash: String
    let lastCommitMessage: String

    /// Tooltip text for hover.
    var hoverText: String {
        "\(lastCommitHash) \(lastCommitMessage)"
    }
}
