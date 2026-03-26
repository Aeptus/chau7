import Foundation

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
        let normalized = URL(fileURLWithPath: path).standardized.path

        // Protected paths: no git query
        if ProtectedPathPolicy.shouldSkipAutoAccess(path: normalized) {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Negative cache hit
            if self.nonGitPaths.contains(normalized) {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            if let root = self.resolvedRootsByPath[normalized],
               let model = self.models[root] {
                model.refreshBranch()
                DispatchQueue.main.async { completion(model) }
                return
            }

            var bestMatch: (root: String, model: RepositoryModel)?
            for (root, model) in self.models {
                if normalized == root || normalized.hasPrefix(root + "/") {
                    if bestMatch == nil || root.count > bestMatch!.root.count {
                        bestMatch = (root, model)
                    }
                }
            }

            let output = self.gitRunner(["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"], normalized)

            let lines = output
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !lines.isEmpty else {
                if let bestMatch {
                    self.resolvedRootsByPath[normalized] = bestMatch.root
                    bestMatch.model.refreshBranch()
                    DispatchQueue.main.async { completion(bestMatch.model) }
                    return
                }
                // Not a git repo — cache the negative result
                self.nonGitPaths.insert(normalized)
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let root = lines[0]
            let branch = lines.count > 1 ? lines[1] : nil
            let canonicalRoot = URL(fileURLWithPath: root).standardized.path

            // Reuse existing model if already cached (race between concurrent resolves)
            let model: RepositoryModel
            if let existing = self.models[canonicalRoot] {
                model = existing
                if model.branch != branch {
                    DispatchQueue.main.async { model.branch = branch }
                }
            } else {
                model = RepositoryModel(
                    rootPath: canonicalRoot,
                    branch: branch,
                    gitRunner: self.gitRunner,
                    refreshDelay: self.refreshDelay
                )
                self.models[canonicalRoot] = model
                self.resolvedRootsByPath[canonicalRoot] = canonicalRoot
                // Load persisted metadata and record as recent repo (first discovery)
                model.loadMetadata()
                DispatchQueue.main.async {
                    self.recentRepoRecorder(canonicalRoot)
                }
            }
            self.resolvedRootsByPath[normalized] = canonicalRoot

            DispatchQueue.main.async { completion(model) }
        }
    }

    /// Synchronous lookup — returns a model only if the root path is already cached.
    func cachedModel(forRoot rootPath: String) -> RepositoryModel? {
        let canonical = URL(fileURLWithPath: rootPath).standardized.path
        return queue.sync { models[canonical] }
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
