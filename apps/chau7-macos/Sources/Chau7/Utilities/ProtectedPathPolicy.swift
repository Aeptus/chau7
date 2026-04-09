import Foundation
import AppKit
import Chau7Core

enum ProtectedPathPolicy {
    private static let protectedRoots: [String] = {
        let home = RuntimeIsolation.homePath()
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

    static func shouldSkipAutoAccess(path: String) -> Bool {
        !liveAccessSnapshot(forPath: path).canProbeLive
    }

    static func hasPersistedBookmarks() -> Bool {
        stateQueue.sync {
            !bookmarksByRoot.isEmpty
        }
    }

    static func snapshot(forPath path: String) -> ProtectedPathAccessSnapshot {
        let normalized = URL(fileURLWithPath: path).standardized.path
        guard let root = protectedRoot(for: normalized) else {
            return ProtectedPathAccessPolicy.accessSnapshot(
                root: nil,
                isProtectedPath: false,
                isFeatureEnabled: FeatureSettings.shared.allowProtectedFolderAccess,
                hasActiveScope: false,
                hasSecurityScopedBookmark: false,
                isDeniedByCooldown: false,
                hasKnownIdentity: false
            )
        }

        let hasKnownIdentity = KnownRepoIdentityStore.shared.hasKnownRepo(beneathProtectedRoot: root)
        return stateQueue.sync {
            let hasActiveScope = activeSecurityURLs[root]?.path.hasPrefix(root) ?? false
            let cooldownActive = deniedUntilByRoot[root].map { Date() < $0 } ?? false
            let hasBookmark = bookmarksByRoot[root] != nil
            let bookmarkResolveFailed = staleBookmarkRoots.contains(root)

            return ProtectedPathAccessPolicy.accessSnapshot(
                root: root,
                isProtectedPath: true,
                isFeatureEnabled: FeatureSettings.shared.allowProtectedFolderAccess,
                hasActiveScope: hasActiveScope,
                hasSecurityScopedBookmark: hasBookmark,
                isDeniedByCooldown: cooldownActive,
                hasKnownIdentity: hasKnownIdentity,
                bookmarkResolveFailed: bookmarkResolveFailed
            )
        }
    }

    static func liveAccessSnapshot(forPath path: String) -> ProtectedPathAccessSnapshot {
        let initial = snapshot(forPath: path)
        guard let root = initial.root,
              initial.state == .availableBookmarkedScope else {
            return initial
        }

        _ = ensureAutoAccess(for: root)
        return snapshot(forPath: path)
    }

    static func snapshots() -> [ProtectedPathAccessSnapshot] {
        protectedRoots.map { root in
            snapshot(forPath: root)
        }
    }

    static func protectedRootsList() -> [String] {
        protectedRoots
    }

    static func protectedRootForDiagnostics(path: String) -> String? {
        protectedRoot(for: path)
    }

    @MainActor
    static func requestAccessToProtectedFolders() {
        let panel = NSOpenPanel()
        panel.title = L("dialog.protectedAccess.title", "Grant Protected Folder Access")
        panel.message = L("dialog.protectedAccess.message", "Select folders like Downloads/Desktop/Documents for background repo detection.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = RuntimeIsolation.homeDirectory()

        guard panel.runModal() == .OK else {
            Log.info("ProtectedPathPolicy: grant dialog canceled")
            return
        }

        let result = grantAccess(forSelectedURLs: panel.urls, source: "grant")
        let grantedRoots = result.grantedRoots
        let ignoredPaths = result.ignoredPaths

        if !ignoredPaths.isEmpty {
            Log.info("ProtectedPathPolicy: ignored non-protected selections: \(ignoredPaths.joined(separator: ", "))")
        }
        if !grantedRoots.isEmpty {
            FeatureSettings.shared.allowProtectedFolderAccess = true
            Log.info("ProtectedPathPolicy: granted roots -> \(grantedRoots.joined(separator: ", "))")
        } else {
            Log.warn("ProtectedPathPolicy: no protected roots granted from selection")
        }
    }

    @MainActor
    static func ensureLiveAccessForUserInitiatedAction(path: String, actionDescription: String) -> ProtectedPathAccessSnapshot {
        let normalized = URL(fileURLWithPath: path).standardized.path
        let initial = accessSnapshotForUserInitiatedAction(path: normalized)
        guard !initial.canProbeLive,
              let root = initial.root else {
            return initial
        }
        guard initial.recommendedAction != .waitForCooldown else {
            return initial
        }

        let rootName = URL(fileURLWithPath: root).lastPathComponent
        let panel = NSOpenPanel()
        panel.title = L("dialog.protectedAccess.title", "Grant Protected Folder Access")
        panel.message = String(
            format: L(
                "dialog.protectedAccess.liveAction.message",
                "To %@, grant Chau7 access to %@."
            ),
            actionDescription,
            rootName
        )
        panel.prompt = L("dialog.protectedAccess.grantAction", "Grant Access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = RuntimeIsolation.homeDirectory()

        guard panel.runModal() == .OK else {
            Log.info("ProtectedPathPolicy: user-initiated grant canceled for root=\(root) action=\(actionDescription)")
            return recordUserInitiatedDenial(path: normalized, reason: "canceled")
        }

        let result = grantAccess(forSelectedURLs: panel.urls, source: "userAction")
        if result.grantedRoots.isEmpty {
            Log.warn("ProtectedPathPolicy: user-initiated grant did not activate root=\(root) action=\(actionDescription)")
            return recordUserInitiatedDenial(path: normalized, reason: "noGrant")
        }
        return liveAccessSnapshot(forPath: normalized)
    }

    static func accessSnapshotForUserInitiatedAction(path: String) -> ProtectedPathAccessSnapshot {
        let normalized = URL(fileURLWithPath: path).standardized.path
        let initial = liveAccessSnapshot(forPath: normalized)
        guard !initial.canProbeLive,
              let root = initial.root,
              userInitiatedCooldownActive(forRoot: root) else {
            return initial
        }

        return ProtectedPathAccessSnapshot(
            root: root,
            state: .blockedCooldown,
            canProbeLive: false,
            canUseKnownIdentity: initial.hasKnownIdentity,
            hasKnownIdentity: initial.hasKnownIdentity,
            recommendedAction: .waitForCooldown
        )
    }

    static func recordUserInitiatedDenial(path: String, reason: String) -> ProtectedPathAccessSnapshot {
        let normalized = URL(fileURLWithPath: path).standardized.path
        guard let root = protectedRoot(for: normalized) else {
            return liveAccessSnapshot(forPath: normalized)
        }
        stateQueue.sync {
            markDenied(root: root, source: "userAction", reason: reason)
        }
        return accessSnapshotForUserInitiatedAction(path: normalized)
    }

    /// Eagerly activate all persisted security-scoped bookmarks.
    /// Called at launch so git detection in protected folders works on the first check.
    /// Uses async dispatch to avoid blocking the main thread with bookmark I/O.
    static func activatePersistedBookmarks() {
        stateQueue.async {
            for root in bookmarksByRoot.keys {
                guard activeSecurityURLs[root] == nil else { continue }
                if startAccessingBookmark(for: root, source: "launch") {
                    Log.info("ProtectedPathPolicy: pre-activated bookmark for \(root)")
                }
            }
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
            staleBookmarkRoots.removeAll()
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
    private static var bookmarksByRoot: [String: Data] = (defaults.dictionary(forKey: bookmarksDefaultsKey) as? [String: Data]) ?? [:]
    private static var staleBookmarkRoots: Set<String> = []

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

    private static func ensureAutoAccess(for root: String) -> Bool {
        stateQueue.sync {
            let hasActiveScope = activeSecurityURLs[root]?.path.hasPrefix(root) ?? false
            let cooldownActive = deniedUntilByRoot[root].map { Date() < $0 } ?? false
            let hasBookmark = bookmarksByRoot[root] != nil
            let staleBookmark = staleBookmarkRoots.contains(root)

            switch ProtectedPathAccessPolicy.autoAccessDecision(
                isFeatureEnabled: FeatureSettings.shared.allowProtectedFolderAccess,
                hasActiveScope: hasActiveScope,
                hasSecurityScopedBookmark: hasBookmark,
                isDeniedByCooldown: cooldownActive,
                bookmarkResolveFailed: staleBookmark
            ) {
            case .skipFeatureDisabled:
                emitDecisionLogIfNeeded(root: root, allowed: false, source: "auto", reason: "featureDisabled")
                return false
            case .skipCooldown:
                emitDecisionLogIfNeeded(root: root, allowed: false, source: "auto", reason: "cooldown")
                return false
            case .skipStaleBookmark:
                emitDecisionLogIfNeeded(root: root, allowed: false, source: "auto", reason: "staleBookmark")
                return false
            case .skipNeedsExplicitGrant:
                emitDecisionLogIfNeeded(root: root, allowed: false, source: "auto", reason: "needsExplicitGrant")
                return false
            case .allowActiveScope:
                emitDecisionLogIfNeeded(root: root, allowed: true, source: "auto", reason: "activeScope")
                return true
            case .allowBookmarkedScope:
                if startAccessingBookmark(for: root, source: "auto") {
                    emitDecisionLogIfNeeded(root: root, allowed: true, source: "auto", reason: "bookmark")
                    return true
                }
                markDenied(root: root, source: "auto", reason: "bookmarkFailed")
                return false
            }
        }
    }

    private static func userInitiatedCooldownActive(forRoot root: String) -> Bool {
        stateQueue.sync {
            deniedUntilByRoot[root].map { Date() < $0 } ?? false
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
            staleBookmarkRoots.insert(root)
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
        staleBookmarkRoots.remove(root)
        return true
    }

    private static func persistBookmark(_ data: Data, for root: String) {
        stateQueue.sync {
            bookmarksByRoot[root] = data
            persistBookmarks()
            deniedRoots.remove(root)
            deniedUntilByRoot.removeValue(forKey: root)
            staleBookmarkRoots.remove(root)
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

    private static func grantAccess(forSelectedURLs urls: [URL], source: String) -> (grantedRoots: [String], ignoredPaths: [String]) {
        var grantedRoots: [String] = []
        var ignoredPaths: [String] = []

        for url in urls {
            guard let root = protectedRoot(for: url.path) else {
                ignoredPaths.append(url.path)
                continue
            }
            let normalizedURL = URL(fileURLWithPath: url.path).standardizedFileURL
            let expectedRootURL = URL(fileURLWithPath: root).standardizedFileURL
            guard normalizedURL.path == expectedRootURL.path else {
                ignoredPaths.append(url.path)
                Log.warn("ProtectedPathPolicy: ignoring non-root protected selection \(url.path); expected \(root)")
                continue
            }

            do {
                let bookmark = try expectedRootURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                persistBookmark(bookmark, for: root)
                if startAccessingBookmark(for: root, source: source) {
                    grantedRoots.append(root)
                }
            } catch {
                Log.warn("ProtectedPathPolicy: failed to create bookmark for \(root): \(error)")
            }
        }

        if !grantedRoots.isEmpty {
            FeatureSettings.shared.allowProtectedFolderAccess = true
        }
        return (grantedRoots, ignoredPaths)
    }

}
