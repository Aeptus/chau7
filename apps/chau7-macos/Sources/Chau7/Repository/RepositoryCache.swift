import Foundation
import Chau7Core

enum RepositoryResolutionResult {
    /// A repository model is available. Check `model.accessLevel` to distinguish
    /// live (full git I/O) from cached (identity-only, no git process spawning).
    case repository(RepositoryModel, access: ProtectedPathAccessSnapshot)
    /// Access is blocked and no known identity exists for this path.
    case blocked(access: ProtectedPathAccessSnapshot)
    /// Confirmed not a git repository.
    case notRepository(access: ProtectedPathAccessSnapshot)
}

/// Singleton cache mapping directory paths to shared RepositoryModel instances.
/// Deduplicates git queries: once a repo root is known, subdirectory lookups
/// are pure string prefix checks with zero process spawning.
final class RepositoryCache {
    static let shared = RepositoryCache()

    private let queue = DispatchQueue(label: "com.chau7.repository-cache", qos: .utility)
    private let gitRunner: ([String], String) -> String
    private let recentRepoRecorder: (String) -> Void
    private let refreshDelay: TimeInterval

    /// Canonical root path → shared model
    private var models: [String: RepositoryModel] = [:]
    /// Exact queried path → canonical root path
    private var resolvedRootsByPath: [String: String] = [:]

    /// Directories confirmed to NOT be inside a git repo (negative cache)
    private var nonGitPaths: Set<String> = []

    init(
        gitRunner: @escaping ([String], String) -> String = GitDiffTracker.runGit,
        recentRepoRecorder: @escaping (String) -> Void = { FeatureSettings.shared.recordRecentRepo($0) },
        refreshDelay: TimeInterval = 0.1
    ) {
        self.gitRunner = gitRunner
        self.recentRepoRecorder = recentRepoRecorder
        self.refreshDelay = refreshDelay
    }

    /// Resolve a directory path to its RepositoryModel.
    /// Returns nil (via completion) if the path is not inside a git repo.
    /// Cache hits are instant (no git process). Completion always on main.
    func resolve(path: String, completion: @escaping (RepositoryModel?) -> Void) {
        resolveDetailed(path: path) { result in
            if case .repository(let model, _) = result, model.isLive {
                completion(model)
            } else {
                completion(nil)
            }
        }
    }

    func resolveDetailed(path: String, completion: @escaping (RepositoryResolutionResult) -> Void) {
        let normalized = URL(fileURLWithPath: path).standardized.path
        let access = ProtectedPathPolicy.liveAccessSnapshot(forPath: normalized)
        let knownIdentity = KnownRepoIdentityStore.shared.resolveIdentity(forPath: normalized)

        if !access.canProbeLive {
            if let knownIdentity, access.canUseKnownIdentity {
                let model = queue.sync { cachedModelForIdentity(knownIdentity) }
                DispatchQueue.main.async {
                    completion(.repository(model, access: access))
                }
            } else {
                DispatchQueue.main.async {
                    completion(.blocked(access: access))
                }
            }
            return
        }

        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(.notRepository(access: access)) }
                return
            }

            // Negative cache hit
            if nonGitPaths.contains(normalized) {
                DispatchQueue.main.async { completion(.notRepository(access: access)) }
                return
            }

            if let root = resolvedRootsByPath[normalized],
               let model = models[root] {
                model.refreshBranch()
                DispatchQueue.main.async { completion(.repository(model, access: access)) }
                return
            }

            var bestMatch: (root: String, model: RepositoryModel)?
            for (root, model) in models {
                if normalized == root || normalized.hasPrefix(root + "/") {
                    if bestMatch == nil || root.count > bestMatch!.root.count {
                        bestMatch = (root, model)
                    }
                }
            }

            let output = gitRunner(["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"], normalized)

            let lines = output
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !lines.isEmpty else {
                if let bestMatch {
                    resolvedRootsByPath[normalized] = bestMatch.root
                    bestMatch.model.refreshBranch()
                    DispatchQueue.main.async { completion(.repository(bestMatch.model, access: access)) }
                    return
                }
                // Not a git repo — cache the negative result
                nonGitPaths.insert(normalized)
                DispatchQueue.main.async { completion(.notRepository(access: access)) }
                return
            }

            let root = lines[0]
            let branch = lines.count > 1 ? lines[1] : nil
            let canonicalRoot = URL(fileURLWithPath: root).standardized.path

            // Reuse existing model if already cached (race between concurrent resolves)
            let model: RepositoryModel
            if let existing = models[canonicalRoot] {
                model = existing
                if model.branch != branch {
                    DispatchQueue.main.async { model.branch = branch }
                }
            } else {
                model = RepositoryModel(
                    rootPath: canonicalRoot,
                    branch: branch,
                    gitRunner: gitRunner,
                    refreshDelay: refreshDelay
                )
                models[canonicalRoot] = model
                resolvedRootsByPath[canonicalRoot] = canonicalRoot
                // Load persisted metadata and record as recent repo (first discovery)
                model.loadMetadata()
                DispatchQueue.main.async {
                    KnownRepoIdentityStore.shared.record(rootPath: canonicalRoot, branch: branch)
                    self.recentRepoRecorder(canonicalRoot)
                }
            }
            resolvedRootsByPath[normalized] = canonicalRoot
            KnownRepoIdentityStore.shared.record(rootPath: canonicalRoot, branch: branch)

            DispatchQueue.main.async { completion(.repository(model, access: access)) }
        }
    }

    /// Synchronous lookup — returns a model only if the root path is already cached.
    func cachedModel(forRoot rootPath: String) -> RepositoryModel? {
        let canonical = URL(fileURLWithPath: rootPath).standardized.path
        return queue.sync { models[canonical] }
    }

    /// Promote a cached model to live access (e.g. after security-scoped bookmark grant).
    /// If the model was cached, it transitions to live and refreshes its git state.
    func promoteCachedModel(forRoot rootPath: String) {
        let canonical = URL(fileURLWithPath: rootPath).standardized.path
        queue.async { [weak self] in
            self?.models[canonical]?.promoteToLive()
        }
    }

    /// Returns (or creates) a cached-access model for a known identity.
    /// Must be called on `queue`. Reuses an existing model if one is already
    /// cached for this root path, preserving any branch data it may have.
    private func cachedModelForIdentity(_ identity: KnownRepoIdentity) -> RepositoryModel {
        let canonical = URL(fileURLWithPath: identity.rootPath).standardized.path
        if let existing = models[canonical] {
            // Promote branch if identity has newer data than the model
            if existing.branch == nil, let branch = identity.lastKnownBranch {
                DispatchQueue.main.async { existing.branch = branch }
            }
            return existing
        }
        let model = RepositoryModel(
            rootPath: canonical,
            branch: identity.lastKnownBranch,
            accessLevel: .cached,
            gitRunner: gitRunner,
            refreshDelay: refreshDelay
        )
        models[canonical] = model
        resolvedRootsByPath[canonical] = canonical
        return model
    }

    /// Clear the negative cache (e.g. after user grants protected folder access).
    func resetNegativeCache() {
        queue.async { [weak self] in
            self?.nonGitPaths.removeAll()
        }
    }

    /// Number of cached repos (for diagnostics).
    var cachedRepoCount: Int {
        queue.sync { models.count }
    }
}
