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

    public static func sanitizeForPersistence(
        provider: String?,
        sessionId: String?,
        claimedSessionIds: Set<String>
    ) -> Metadata {
        let metadata = Metadata(provider: provider, sessionId: sessionId)
        guard let sessionId = metadata.sessionId else {
            return metadata
        }
        guard !claimedSessionIds.contains(sessionId) else {
            return Metadata(provider: metadata.provider, sessionId: nil)
        }
        return metadata
    }

    public static func sanitizeForRestore(
        sequence metadata: [Metadata]
    ) -> [Metadata] {
        var claimedSessionIds = Set<String>()
        return metadata.map { item in
            let sanitized = sanitizeForPersistence(
                provider: item.provider,
                sessionId: item.sessionId,
                claimedSessionIds: claimedSessionIds
            )
            if let sessionId = sanitized.sessionId {
                claimedSessionIds.insert(sessionId)
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
