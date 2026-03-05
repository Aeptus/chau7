import Foundation
import AppKit

enum ProtectedPathPolicy {
    private static let protectedRoots: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Downloads",
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Library",
            "/Applications",
            "/System",
            "/Library"
        ]
    }()

    /// TCC-protected roots that should use explicit security-scoped bookmarks.
    /// We intentionally avoid "probing" these roots in background code because
    /// repeated probes can trigger prompt loops.
    private static let bookmarkRequiredRoots: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Downloads",
            "\(home)/Desktop",
            "\(home)/Documents"
        ]
    }()

    static func shouldSkipAutoAccess(path: String) -> Bool {
        guard let root = protectedRoot(for: path) else {
            return false
        }
        guard FeatureSettings.shared.allowProtectedFolderAccess else {
            return true
        }
        return !ensureAccess(for: root, source: "auto")
    }

    @MainActor
    static func requestAccessToProtectedFolders() {
        guard FeatureSettings.shared.allowProtectedFolderAccess else { return }

        let panel = NSOpenPanel()
        panel.title = "Grant Protected Folder Access"
        panel.message = "Select folders like Downloads/Desktop/Documents for background repo detection."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK else {
            Log.info("ProtectedPathPolicy: grant dialog canceled")
            return
        }

        var grantedRoots: [String] = []
        var ignoredPaths: [String] = []
        for url in panel.urls {
            guard let root = protectedRoot(for: url.path) else {
                ignoredPaths.append(url.path)
                continue
            }

            do {
                let bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                persistBookmark(bookmark, for: root)
                if startAccessingBookmark(for: root, source: "grant") {
                    grantedRoots.append(root)
                }
            } catch {
                Log.warn("ProtectedPathPolicy: failed to create bookmark for \(root): \(error)")
            }
        }

        if !ignoredPaths.isEmpty {
            Log.info("ProtectedPathPolicy: ignored non-protected selections: \(ignoredPaths.joined(separator: ", "))")
        }
        if !grantedRoots.isEmpty {
            Log.info("ProtectedPathPolicy: granted roots -> \(grantedRoots.joined(separator: ", "))")
        } else {
            Log.warn("ProtectedPathPolicy: no protected roots granted from selection")
        }
    }

    static func resetAccessChecks() {
        stateQueue.sync {
            for (_, url) in activeSecurityURLs {
                url.stopAccessingSecurityScopedResource()
            }
            activeSecurityURLs.removeAll()
            checkedRoots.removeAll()
            deniedRoots.removeAll()
            deniedUntilByRoot.removeAll()
            lastDecisionByRoot.removeAll()
        }
    }

    private static let stateQueue = DispatchQueue(label: "com.chau7.protected-path-policy")
    private static let defaults = UserDefaults.standard
    private static let bookmarksDefaultsKey = "protectedPathPolicy.securityScopedBookmarksByRoot.v1"
    private static let denyCooldown: TimeInterval = 300
    private static var checkedRoots: Set<String> = []
    private static var deniedRoots: Set<String> = []
    private static var deniedUntilByRoot: [String: Date] = [:]
    private static var activeSecurityURLs: [String: URL] = [:]
    private static var bookmarksByRoot: [String: Data] = {
        (defaults.dictionary(forKey: bookmarksDefaultsKey) as? [String: Data]) ?? [:]
    }()
    private static var lastDecisionByRoot: [String: Bool] = [:]

    private static func protectedRoot(for path: String) -> String? {
        let normalized = URL(fileURLWithPath: path).standardized.path
        for root in protectedRoots {
            if normalized == root || normalized.hasPrefix(root + "/") {
                return root
            }
        }
        return nil
    }

    private static func ensureAccess(for root: String, source: String) -> Bool {
        stateQueue.sync {
            if let cachedURL = activeSecurityURLs[root], cachedURL.path.hasPrefix(root) {
                emitDecisionLogIfNeeded(root: root, allowed: true, source: source, reason: "activeScope")
                return true
            }

            if let deniedUntil = deniedUntilByRoot[root], Date() < deniedUntil {
                emitDecisionLogIfNeeded(root: root, allowed: false, source: source, reason: "cooldown")
                return false
            }

            if startAccessingBookmark(for: root, source: source) {
                emitDecisionLogIfNeeded(root: root, allowed: true, source: source, reason: "bookmark")
                return true
            }

            if bookmarkRequiredRoots.contains(root) {
                markDenied(root: root, source: source, reason: "bookmarkRequired")
                return false
            }

            if deniedRoots.contains(root) {
                emitDecisionLogIfNeeded(root: root, allowed: false, source: source, reason: "deniedCache")
                return false
            }
            if checkedRoots.contains(root) {
                emitDecisionLogIfNeeded(root: root, allowed: true, source: source, reason: "checkedCache")
                return true
            }
            checkedRoots.insert(root)
            if canAccess(root) {
                emitDecisionLogIfNeeded(root: root, allowed: true, source: source, reason: "directCheck")
                return true
            }
            markDenied(root: root, source: source, reason: "directCheckDenied")
            return false
        }
    }

    private static func startAccessingBookmark(for root: String, source: String) -> Bool {
        guard let bookmarkData = bookmarksByRoot[root] else { return false }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            bookmarksByRoot.removeValue(forKey: root)
            persistBookmarks()
            Log.warn("ProtectedPathPolicy: failed to resolve bookmark for \(root), removed")
            return false
        }

        if isStale {
            do {
                let refreshed = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                bookmarksByRoot[root] = refreshed
                persistBookmarks()
                Log.info("ProtectedPathPolicy: refreshed stale bookmark for \(root)")
            } catch {
                Log.warn("ProtectedPathPolicy: failed to refresh stale bookmark for \(root): \(error)")
            }
        }

        guard url.startAccessingSecurityScopedResource() else {
            Log.warn("ProtectedPathPolicy: startAccessingSecurityScopedResource failed for \(root) (source=\(source))")
            return false
        }

        activeSecurityURLs[root] = url
        checkedRoots.insert(root)
        deniedRoots.remove(root)
        deniedUntilByRoot.removeValue(forKey: root)
        return true
    }

    private static func persistBookmark(_ data: Data, for root: String) {
        stateQueue.sync {
            bookmarksByRoot[root] = data
            persistBookmarks()
            deniedRoots.remove(root)
            deniedUntilByRoot.removeValue(forKey: root)
        }
    }

    private static func persistBookmarks() {
        defaults.set(bookmarksByRoot, forKey: bookmarksDefaultsKey)
    }

    private static func markDenied(root: String, source: String, reason: String) {
        deniedRoots.insert(root)
        deniedUntilByRoot[root] = Date().addingTimeInterval(denyCooldown)
        emitDecisionLogIfNeeded(root: root, allowed: false, source: source, reason: reason)
    }

    private static func emitDecisionLogIfNeeded(root: String, allowed: Bool, source: String, reason: String) {
        let previous = lastDecisionByRoot[root]
        if previous == allowed { return }
        lastDecisionByRoot[root] = allowed
        let verdict = allowed ? "allow" : "skip"
        Log.info("ProtectedPathPolicy: \(verdict) root=\(root) source=\(source) reason=\(reason)")
    }

    private static func canAccess(_ path: String) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return true
        } catch let error as NSError {
            // Only treat permission errors as denied; not-found means the path
            // doesn't exist yet, which shouldn't permanently deny access.
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                return false
            }
            if error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES) {
                return false
            }
            // Path doesn't exist or other non-permission error — treat as accessible
            return true
        }
    }
}
