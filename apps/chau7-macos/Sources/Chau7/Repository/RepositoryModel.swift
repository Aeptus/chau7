import Foundation
import Combine

/// Shared observable model for a single git repository.
/// One instance per unique git root path, shared across all tabs in that repo.
/// Branch changes publish to all subscribers automatically.
final class RepositoryModel: ObservableObject, Identifiable {
    let id: String
    let rootPath: String

    @Published var branch: String?
    @Published var metadata: RepoMetadata = .empty
    @Published var stats: RepoStats?

    /// Display name derived from root path (e.g. "Chau7")
    var repoName: String {
        URL(fileURLWithPath: rootPath).lastPathComponent
    }

    private var refreshWorkItem: DispatchWorkItem?
    private var saveWorkItem: DispatchWorkItem?
    private static let gitQueue = DispatchQueue(label: "com.chau7.repository.git", qos: .utility)
    private static let metadataQueue = DispatchQueue(label: "com.chau7.repository.metadata", qos: .utility)
    private let gitRunner: ([String], String) -> String
    private let refreshDelay: TimeInterval

    init(
        rootPath: String,
        branch: String? = nil,
        gitRunner: @escaping ([String], String) -> String = GitDiffTracker.runGit,
        refreshDelay: TimeInterval = 0.1
    ) {
        self.id = rootPath
        self.rootPath = rootPath
        self.branch = branch
        self.gitRunner = gitRunner
        self.refreshDelay = refreshDelay
    }

    /// Refresh the branch name from git. Coalesces rapid calls via work item cancellation.
    /// Safe to call from any thread — all state mutations happen on gitQueue.
    func refreshBranch() {
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
                    }
                }
            }
            refreshWorkItem = work
            Self.gitQueue.asyncAfter(deadline: .now() + refreshDelay, execute: work)
        }
    }

    // MARK: - Repo Metadata

    /// Load metadata from `.chau7/metadata.json` asynchronously.
    /// Publishes on main thread when done. Safe to call from any thread.
    func loadMetadata() {
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
