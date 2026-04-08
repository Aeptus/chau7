import Foundation

public enum KnownRepoRootResolver {
    public static func resolve(
        currentDirectory: String,
        preferredRepoRoot: String?,
        recentRepoRoots: [String]
    ) -> String? {
        let directory = URL(fileURLWithPath: currentDirectory).standardized.path
        guard !directory.isEmpty else { return nil }

        if let preferred = preferredRepoRoot {
            let normalizedPreferred = URL(fileURLWithPath: preferred).standardized.path
            if directory == normalizedPreferred || directory.hasPrefix(normalizedPreferred + "/") {
                return normalizedPreferred
            }
        }

        let normalizedRoots = recentRepoRoots
            .map { URL(fileURLWithPath: $0).standardized.path }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        for root in normalizedRoots {
            if directory == root || directory.hasPrefix(root + "/") {
                return root
            }
        }

        return nil
    }
}
