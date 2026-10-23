import Foundation

public enum RepositoryRootLocator {
    public static func repositoryRoot(
        startingAt directory: String,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var path = (trimmed as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            path = (path as NSString).deletingLastPathComponent
        }

        while true {
            let marker = (path as NSString).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: marker) {
                return path
            }

            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty {
                return nil
            }
            path = parent
        }
    }
}
