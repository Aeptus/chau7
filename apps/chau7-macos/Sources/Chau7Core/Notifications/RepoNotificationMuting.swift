import Foundation

/// Per-repo notification muting (B9): one check silences every surface for
/// events belonging to a muted repository. A mute is either indefinite
/// (`snoozeUntil == nil`) or a snooze that expires on its own.
public struct RepoMute: Codable, Equatable, Sendable {
    /// Nil = muted until explicitly unmuted; otherwise muted while
    /// `now < snoozeUntil`.
    public var snoozeUntil: Date?

    public init(snoozeUntil: Date? = nil) {
        self.snoozeUntil = snoozeUntil
    }

    public func isActive(now: Date) -> Bool {
        guard let snoozeUntil else { return true }
        return now < snoozeUntil
    }
}

public enum RepoNotificationMuting {

    /// True when the event belongs to a muted repo: its `repoPath` equals a
    /// muted root, or its `directory` is at/under one.
    public static func isMuted(
        repoPath: String?,
        directory: String?,
        mutedRepos: [String: RepoMute],
        now: Date = Date()
    ) -> Bool {
        guard !mutedRepos.isEmpty else { return false }
        for (root, mute) in mutedRepos where mute.isActive(now: now) {
            if let repoPath, repoPath == root { return true }
            if let directory, directory == root || directory.hasPrefix(root + "/") { return true }
        }
        return false
    }

    /// Drop expired snoozes so the settings dictionary can't accrete stale
    /// entries.
    public static func pruned(_ mutedRepos: [String: RepoMute], now: Date = Date()) -> [String: RepoMute] {
        mutedRepos.filter { $0.value.isActive(now: now) }
    }
}
