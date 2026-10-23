import Foundation

public enum AIResumeOwnership {
    public struct Metadata: Equatable {
        public let provider: String?
        public let sessionId: String?

        public init(provider: String?, sessionId: String?) {
            self.provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    /// Identifier for a session claim during dedup. Provider and sessionId
    /// are paired so two tabs that happen to share a session UUID across
    /// different tools (e.g. a Codex UUIDv7 mis-routed to a Claude tab)
    /// don't trigger a false collision that strips the legitimate tab's
    /// resume metadata.
    public struct ClaimedSession: Hashable, Sendable {
        public let provider: String
        public let sessionId: String

        public init(provider: String, sessionId: String) {
            self.provider = provider
            self.sessionId = sessionId
        }
    }

    public static func sanitizeForPersistence(
        provider: String?,
        sessionId: String?,
        claimedSessions: Set<ClaimedSession>
    ) -> Metadata {
        let metadata = Metadata(provider: provider, sessionId: sessionId)
        guard let sessionId = metadata.sessionId,
              let provider = metadata.provider else {
            return metadata
        }
        let claim = ClaimedSession(provider: provider, sessionId: sessionId)
        guard !claimedSessions.contains(claim) else {
            return Metadata(provider: metadata.provider, sessionId: nil)
        }
        return metadata
    }

    public static func sanitizeForRestore(
        sequence metadata: [Metadata]
    ) -> [Metadata] {
        var claimedSessions = Set<ClaimedSession>()
        return metadata.map { item in
            let sanitized = sanitizeForPersistence(
                provider: item.provider,
                sessionId: item.sessionId,
                claimedSessions: claimedSessions
            )
            if let sessionId = sanitized.sessionId, let provider = sanitized.provider {
                claimedSessions.insert(ClaimedSession(provider: provider, sessionId: sessionId))
            }
            return sanitized
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
