import Foundation
import Combine

/// Shared observable model for a single git repository.
/// One instance per unique git root path, shared across all tabs in that repo.
/// Branch changes publish to all subscribers automatically.
final class RepositoryModel: ObservableObject, Identifiable {
    let id: String
    let rootPath: String

    @Published var branch: String?

    /// Display name derived from root path (e.g. "Chau7")
    var repoName: String {
        URL(fileURLWithPath: rootPath).lastPathComponent
    }

    private var refreshWorkItem: DispatchWorkItem?
    private static let gitQueue = DispatchQueue(label: "com.chau7.repository.git", qos: .utility)
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
            self.refreshWorkItem?.cancel()
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
            self.refreshWorkItem = work
            Self.gitQueue.asyncAfter(deadline: .now() + self.refreshDelay, execute: work)
        }
    }
}
