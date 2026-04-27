import Foundation

public enum SessionNoteAttachmentLocator {
    public static let relativeDirectory = ".chau7/sessions"
    public static let fileName = "note.md"

    public static func filePath(repoRoot: String, tabID: UUID) -> String {
        let normalizedRoot = URL(fileURLWithPath: repoRoot).standardized.path
        return URL(fileURLWithPath: normalizedRoot)
            .appendingPathComponent(relativeDirectory, isDirectory: true)
            .appendingPathComponent(tabID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
            .path
    }

    public static func isSessionNotePath(_ path: String) -> Bool {
        let normalized = path
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        return normalized.contains("/.chau7/sessions/")
            && normalized.hasSuffix("/\(fileName)")
    }
}
