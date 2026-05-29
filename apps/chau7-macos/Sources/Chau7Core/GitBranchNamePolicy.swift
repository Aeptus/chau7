import Foundation

public enum GitBranchNamePolicy {
    public static func displayName(from rawBranch: String?) -> String? {
        guard let branch = rawBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty,
              !isDetachedHead(branch)
        else {
            return nil
        }
        return branch
    }

    public static func isDetachedHead(_ rawBranch: String?) -> Bool {
        rawBranch?.trimmingCharacters(in: .whitespacesAndNewlines) == "HEAD"
    }
}
