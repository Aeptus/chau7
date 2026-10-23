import Foundation

public enum RepoGroupInheritance {
    public static func inheritedGroupID(
        selectedRepoGroupID: String?,
        startDirectory: String?
    ) -> String? {
        guard let selectedRepoGroupID else { return nil }
        guard let startDirectory else { return nil }

        let repoRoot = URL(fileURLWithPath: selectedRepoGroupID)
            .standardized.path
        let directory = URL(fileURLWithPath: startDirectory)
            .standardized.path

        guard !repoRoot.isEmpty, !directory.isEmpty else {
            return nil
        }

        if directory == repoRoot || directory.hasPrefix(repoRoot + "/") {
            return repoRoot
        }

        return nil
    }
}
