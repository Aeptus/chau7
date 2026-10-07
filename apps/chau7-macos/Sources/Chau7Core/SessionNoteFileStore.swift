import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Creates only app-owned descendants of an existing repository directory.
/// Descriptor-relative operations cannot recreate a removed repository root.
public enum SessionNoteFileStore {
    public static func isRepositoryRoot(_ repoRoot: String) -> Bool {
        let descriptor = openRepositoryRoot(repoRoot)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return true
    }

    /// Select by focus precedence before checking availability. A stale focused
    /// root must not redirect a note into another split's repository.
    public static func repositoryRoot(from candidates: [String?]) -> String? {
        guard let selected = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }), isRepositoryRoot(selected) else { return nil }
        return URL(fileURLWithPath: selected).standardized.path
    }

    public static func prepare(repoRoot: String, tabID: UUID) -> String? {
        prepare(repoRoot: repoRoot, tabID: tabID, beforeCreatingDirectories: {})
    }

    public static func existing(repoRoot: String, tabID: UUID) -> String? {
        withNoteDirectory(repoRoot: repoRoot, tabID: tabID, create: false) { directory, path in
            let file = openat(
                directory,
                SessionNoteAttachmentLocator.fileName,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard file >= 0 else { return nil }
            defer { close(file) }
            return isRegularFile(file) ? path : nil
        }
    }

    /// The hook makes deletion between validation and creation deterministic in tests.
    static func prepare(
        repoRoot: String,
        tabID: UUID,
        beforeCreatingDirectories: () -> Void
    ) -> String? {
        withNoteDirectory(
            repoRoot: repoRoot, tabID: tabID, create: true,
            beforeCreatingDirectories: beforeCreatingDirectories
        ) { directory, path in
            let file = openat(
                directory,
                SessionNoteAttachmentLocator.fileName,
                O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                0o600
            )
            guard file >= 0 else { return nil }
            defer { close(file) }
            // No O_TRUNC: preparing an existing note must preserve its contents.
            return isRegularFile(file) ? path : nil
        }
    }

    private static func withNoteDirectory(
        repoRoot: String,
        tabID: UUID,
        create: Bool,
        beforeCreatingDirectories: () -> Void = {},
        body: (Int32, String) -> String?
    ) -> String? {
        let rootPath = URL(fileURLWithPath: repoRoot).standardized.path
        let root = openRepositoryRoot(rootPath)
        guard root >= 0 else { return nil }
        var descriptors = [root]
        defer { for descriptor in descriptors.reversed() {
            close(descriptor)
        } }
        guard stillNamesRepository(rootPath, descriptor: root) else { return nil }
        beforeCreatingDirectories()

        var directory = root
        let components = SessionNoteAttachmentLocator.relativeDirectory.split(separator: "/").map(String.init)
            + [tabID.uuidString.lowercased()]
        for component in components {
            if create, mkdirat(directory, component, 0o700) != 0, errno != EEXIST {
                return nil
            }
            let child = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard child >= 0 else { return nil }
            descriptors.append(child)
            directory = child
        }
        let path = SessionNoteAttachmentLocator.filePath(repoRoot: rootPath, tabID: tabID)
        guard let result = body(directory, path), stillNamesRepository(rootPath, descriptor: root),
              stillNamesDirectories(components, descriptors: descriptors) else {
            return nil
        }
        return result
    }

    private static func stillNamesDirectories(_ components: [String], descriptors: [Int32]) -> Bool {
        for (index, component) in components.enumerated() {
            var opened = stat()
            var named = stat()
            guard fstat(descriptors[index + 1], &opened) == 0,
                  fstatat(descriptors[index], component, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { return false }
        }
        return true
    }

    private static func openRepositoryRoot(_ path: String) -> Int32 {
        let root = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { return -1 }
        guard hasGitMarker(root) else {
            close(root)
            return -1
        }
        return root
    }

    private static func hasGitMarker(_ root: Int32) -> Bool {
        var marker = stat()
        guard fstatat(root, ".git", &marker, 0) == 0 else { return false }
        let kind = marker.st_mode & mode_t(S_IFMT)
        return kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG)
    }

    private static func stillNamesRepository(_ path: String, descriptor: Int32) -> Bool {
        var opened = stat()
        var named = stat()
        return fstat(descriptor, &opened) == 0 && lstat(path, &named) == 0
            && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
            && hasGitMarker(descriptor)
    }

    private static func isRegularFile(_ descriptor: Int32) -> Bool {
        var value = stat()
        return fstat(descriptor, &value) == 0 && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
}
