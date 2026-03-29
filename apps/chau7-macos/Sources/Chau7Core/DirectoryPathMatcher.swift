import Foundation

public enum DirectoryPathMatcher {
    /// Returns a rank describing how closely two directory paths match.
    /// `0` means exact match, `1` means one directory is nested inside the other,
    /// and `nil` means unrelated.
    public static func bidirectionalPrefixRank(targetPath: String, candidatePath: String) -> Int? {
        let target = URL(fileURLWithPath: targetPath).standardized.path
        let candidate = URL(fileURLWithPath: candidatePath).standardized.path
        guard !target.isEmpty, !candidate.isEmpty else { return nil }
        if target == candidate {
            return 0
        }
        if target.hasPrefix(candidate + "/") || candidate.hasPrefix(target + "/") {
            return 1
        }
        return nil
    }
}
