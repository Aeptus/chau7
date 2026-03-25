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

    init(rootPath: String, branch: String? = nil) {
        self.id = rootPath
        self.rootPath = rootPath
        self.branch = branch
    }

    /// Refresh the branch name from git. Coalesces rapid calls via work item cancellation.
    /// Safe to call from any thread — result delivered on main.
    func refreshBranch() {
        refreshWorkItem?.cancel()
        let root = rootPath
        let work = DispatchWorkItem { [weak self] in
            let output = GitDiffTracker.runGit(args: ["rev-parse", "--abbrev-ref", "HEAD"], in: root)
            let newBranch = output.isEmpty ? nil : output
            DispatchQueue.main.async {
                guard let self else { return }
                if self.branch != newBranch {
                    self.branch = newBranch
                }
            }
        }
        refreshWorkItem = work
        Self.gitQueue.async(execute: work)
    }
}
