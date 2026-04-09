import Foundation

/// Shared observable model for a single git repository.
/// One instance per unique git root path, shared across all tabs in that repo.
/// Branch changes publish to all subscribers automatically.
///
/// A model exists for every *known* repo — including repos in protected directories
/// where live git probing is blocked. The `accessLevel` property distinguishes
/// live models (full git access) from cached models (identity only, no git I/O).
@Observable
final class RepositoryModel: Identifiable {
    /// Whether this model has live git access or is operating from cached identity.
    enum AccessLevel: String, Codable, Equatable {
        /// Full git probing active — branch refreshes, metadata loads, etc.
        case live
        /// Known identity only — no git I/O. Branch is seeded from persisted data
        /// and will not auto-refresh until access is granted.
        case cached
    }

    let id: String
    let rootPath: String

    var branch: String? {
        didSet {
            if branch != oldValue {
                onBranchChange?(branch)
            }
        }
    }

    /// Whether this model has live git access or is operating from cached identity.
    /// Observable so UI updates when a cached model is promoted to live.
    var accessLevel: AccessLevel

    var metadata: RepoMetadata = .empty
    var stats: RepoStats?

    /// Callback invoked on main thread when `branch` changes.
    /// TerminalSessionModel sets this to receive branch updates without Combine.
    @ObservationIgnored var onBranchChange: ((String?) -> Void)?

    /// Display name derived from root path (e.g. "Chau7")
    var repoName: String {
        URL(fileURLWithPath: rootPath).lastPathComponent
    }

    /// Whether this model can perform git I/O operations.
    var isLive: Bool {
        accessLevel == .live
    }

    @ObservationIgnored private var refreshWorkItem: DispatchWorkItem?
    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?
    @ObservationIgnored private static let gitQueue = DispatchQueue(label: "com.chau7.repository.git", qos: .utility)
    @ObservationIgnored private static let metadataQueue = DispatchQueue(label: "com.chau7.repository.metadata", qos: .utility)
    @ObservationIgnored private let gitRunner: ([String], String) -> String
    @ObservationIgnored private let identityRecorder: (String, String?) -> Void
    @ObservationIgnored private let refreshDelay: TimeInterval

    init(
        rootPath: String,
        branch: String? = nil,
        accessLevel: AccessLevel = .live,
        gitRunner: @escaping ([String], String) -> String = GitDiffTracker.runGit,
        identityRecorder: @escaping (String, String?) -> Void = { rootPath, branch in
            KnownRepoIdentityStore.shared.record(rootPath: rootPath, branch: branch)
        },
        refreshDelay: TimeInterval = 0.1
    ) {
        self.id = rootPath
        self.rootPath = rootPath
        self.branch = branch
        self.accessLevel = accessLevel
        self.gitRunner = gitRunner
        self.identityRecorder = identityRecorder
        self.refreshDelay = refreshDelay
    }

    /// Refresh the branch name from git. Coalesces rapid calls via work item cancellation.
    /// Safe to call from any thread — all state mutations happen on gitQueue.
    /// No-op for cached models (no git I/O available).
    func refreshBranch() {
        guard accessLevel == .live else { return }
        let root = rootPath
        Self.gitQueue.async { [weak self] in
            guard let self else { return }
            refreshWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                let output = self?.gitRunner(["rev-parse", "--abbrev-ref", "HEAD"], root) ?? ""
                let newBranch = output.isEmpty ? nil : output
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.branch != newBranch {
                        self.branch = newBranch
                        self.identityRecorder(root, newBranch)
                    }
                }
            }
            refreshWorkItem = work
            Self.gitQueue.asyncAfter(deadline: .now() + refreshDelay, execute: work)
        }
    }

    // MARK: - Repo Metadata

    /// Promote a cached model to live access. Called when security-scoped access
    /// is granted and the model can now perform git I/O.
    /// Must be called on the main thread (mutates observable state).
    func promoteToLive() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard accessLevel == .cached else { return }
        accessLevel = .live
        refreshBranch()
        loadMetadata()
    }

    /// Load metadata from `.chau7/metadata.json` asynchronously.
    /// Publishes on main thread when done. Safe to call from any thread.
    /// No-op for cached models (protected path may block filesystem reads).
    func loadMetadata() {
        guard accessLevel == .live else { return }
        let root = rootPath
        Self.metadataQueue.async { [weak self] in
            let loaded = RepoMetadataStore.load(repoRoot: root)
            DispatchQueue.main.async {
                guard let self, self.metadata != loaded else { return }
                self.metadata = loaded
            }
        }
    }

    /// Refresh computed stats from both SQLite stores. Call on demand
    /// (hover card, debug console, MCP tool) — not on every tab switch.
    func refreshStats() {
        let root = rootPath
        Self.metadataQueue.async { [weak self] in
            let computed = RepoStatsProvider.stats(for: root)
            DispatchQueue.main.async {
                self?.stats = computed
            }
        }
    }

    /// Replace metadata wholesale and schedule a debounced save.
    func updateMetadata(_ new: RepoMetadata) {
        var updated = new
        updated.updatedAt = Date()
        metadata = updated
        scheduleSave()
    }

    func setDescription(_ desc: String?) {
        metadata.description = desc
        metadata.updatedAt = Date()
        scheduleSave()
    }

    func addLabel(_ label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !metadata.labels.contains(trimmed) else { return }
        metadata.labels.append(trimmed)
        metadata.updatedAt = Date()
        scheduleSave()
    }

    func removeLabel(_ label: String) {
        metadata.labels.removeAll { $0 == label }
        metadata.updatedAt = Date()
        scheduleSave()
    }

    func toggleFavoriteFile(_ relativePath: String) {
        if let idx = metadata.favoriteFiles.firstIndex(of: relativePath) {
            metadata.favoriteFiles.remove(at: idx)
        } else {
            metadata.favoriteFiles.append(relativePath)
        }
        metadata.updatedAt = Date()
        scheduleSave()
    }

    private func scheduleSave() {
        let root = rootPath
        let snapshot = metadata
        saveWorkItem?.cancel()
        let work = DispatchWorkItem {
            RepoMetadataStore.save(snapshot, repoRoot: root)
        }
        saveWorkItem = work
        Self.metadataQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
