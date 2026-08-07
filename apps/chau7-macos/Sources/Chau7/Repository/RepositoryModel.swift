import Foundation
import Chau7Core

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
                notifyBranchObservers(branch)
            }
        }
    }

    /// Whether this model has live git access or is operating from cached identity.
    /// Observable so UI updates when a cached model is promoted to live.
    var accessLevel: AccessLevel

    var metadata: RepoMetadata = .empty
    var stats: RepoStats?

    /// Branch-change listeners registered by sessions sharing this repo model.
    /// Kept out of observation so callback fanout does not become part of SwiftUI
    /// dependency tracking.
    @ObservationIgnored private var branchObservers: [UUID: (String?) -> Void] = [:]

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
    @ObservationIgnored private var lastStatsRefreshAt: Date?
    @ObservationIgnored private var statsRefreshInFlight = false
    @ObservationIgnored private var statsDirty = true
    @ObservationIgnored private var statsInvalidationGeneration: UInt64 = 0
    @ObservationIgnored private static let gitQueue = DispatchQueue(label: "com.chau7.repository.git", qos: .utility)
    @ObservationIgnored private static let metadataQueue = DispatchQueue(label: "com.chau7.repository.metadata", qos: .utility)
    @ObservationIgnored private static let statsQueue = DispatchQueue(label: "com.chau7.repository.stats", qos: .utility)
    @ObservationIgnored private let gitRunner: ([String], String) -> String
    @ObservationIgnored private let identityRecorder: (String, String?, Bool) -> Void
    @ObservationIgnored private let refreshDelay: TimeInterval
    @ObservationIgnored private let statsTTL: TimeInterval
    @ObservationIgnored private let statsLoader: (String) -> RepoStats?
    @ObservationIgnored private let now: () -> Date

    init(
        rootPath: String,
        branch: String? = nil,
        accessLevel: AccessLevel = .live,
        gitRunner: @escaping ([String], String) -> String = GitDiffTracker.runGit,
        identityRecorder: @escaping (String, String?, Bool) -> Void = { rootPath, branch, preserveExistingBranch in
            KnownRepoIdentityStore.shared.record(
                rootPath: rootPath,
                branch: branch,
                preserveExistingBranch: preserveExistingBranch
            )
        },
        refreshDelay: TimeInterval = 0.1,
        statsTTL: TimeInterval = 30,
        statsLoader: @escaping (String) -> RepoStats? = { RepoStatsProvider.stats(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.id = rootPath
        self.rootPath = rootPath
        self.branch = GitBranchNamePolicy.displayName(from: branch)
        self.accessLevel = accessLevel
        self.gitRunner = gitRunner
        self.identityRecorder = identityRecorder
        self.refreshDelay = refreshDelay
        self.statsTTL = max(0, statsTTL)
        self.statsLoader = statsLoader
        self.now = now
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
                let newBranch = GitBranchNamePolicy.displayName(from: output)
                let preserveExistingBranch = !GitBranchNamePolicy.isDetachedHead(output)
                DispatchQueue.main.async {
                    guard let self else { return }
                    let branchChanged = self.branch != newBranch
                    if branchChanged {
                        self.branch = newBranch
                    }
                    if branchChanged || !preserveExistingBranch {
                        self.identityRecorder(root, newBranch, preserveExistingBranch)
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
    /// Also loads per-repo injection rules from `.chau7/injection.json`.
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
            // Also discover per-repo injection rules
            InjectionRuleStore.shared.loadLocalRule(repoRoot: root)
        }
    }

    /// Refresh computed stats when the cached snapshot is missing, dirty, or
    /// older than `statsTTL`. Concurrent requests coalesce into one load.
    /// The last successful snapshot remains visible while a refresh is running.
    func refreshStatsIfNeeded(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !statsRefreshInFlight else { return }

        let refreshRequestedAt = now()
        if !force,
           !statsDirty,
           stats != nil,
           let lastStatsRefreshAt,
           refreshRequestedAt.timeIntervalSince(lastStatsRefreshAt) < statsTTL {
            return
        }

        statsRefreshInFlight = true
        let invalidationGenerationAtStart = statsInvalidationGeneration
        let root = rootPath
        let loader = statsLoader
        Self.statsQueue.async { [weak self] in
            let computed = loader(root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.statsRefreshInFlight = false
                guard let computed else {
                    // Preserve the last-known snapshot and retry on next demand.
                    self.statsDirty = true
                    return
                }
                self.stats = computed
                self.lastStatsRefreshAt = self.now()
                // An event may invalidate the cache while SQLite is still
                // assembling this snapshot. Do not let an older completion
                // erase that newer invalidation.
                self.statsDirty = self.statsInvalidationGeneration != invalidationGenerationAtStart
            }
        }
    }

    /// Mark the snapshot stale without discarding it. The next hover/request
    /// performs the refresh, avoiding eager database work after every event.
    func invalidateStats() {
        dispatchPrecondition(condition: .onQueue(.main))
        statsInvalidationGeneration &+= 1
        statsDirty = true
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

    /// Registers a branch observer and returns a token that can later be used
    /// to remove it. Calls are funneled through the main queue so session
    /// wiring remains safe even if teardown happens off-main.
    @discardableResult
    func addBranchObserver(_ observer: @escaping (String?) -> Void) -> UUID {
        let register = { () -> UUID in
            let id = UUID()
            self.branchObservers[id] = observer
            return id
        }
        if Thread.isMainThread {
            return register()
        }
        return DispatchQueue.main.sync(execute: register)
    }

    func removeBranchObserver(_ id: UUID?) {
        guard let id else { return }
        let remove: () -> Void = {
            _ = self.branchObservers.removeValue(forKey: id)
        }
        if Thread.isMainThread {
            remove()
        } else {
            DispatchQueue.main.sync(execute: remove)
        }
    }

    private func notifyBranchObservers(_ branch: String?) {
        let observers = Array(branchObservers.values)
        for observer in observers {
            observer(branch)
        }
    }
}
