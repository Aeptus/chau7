import Foundation

/// Classifies whether an incoming provider event may still target a tab's
/// current display session.
///
/// Hook payloads can carry a tab UUID long after that tab has been reused for
/// another AI provider. The stamped UUID remains useful for a new invocation
/// of the *same* provider, but it must not override a different provider that
/// is visibly active in the tab now.
public enum AISessionBindingState: Equatable, Sendable {
    case matching
    case available
    case conflicting(activeProvider: String)
}

public enum AISessionBindingPolicy {
    public static func classify(
        incomingProvider: String,
        incomingSessionID: String?,
        records: [TabRouteRecord]
    ) -> AISessionBindingState {
        let normalizedIncomingProvider = AIResumeParser.normalizeProviderName(incomingProvider)
            ?? incomingProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedIncomingSessionID = TabRoutingIndex.normalizedSessionID(incomingSessionID)
        let displayRecords = records.filter(\.isDisplaySession)

        for record in displayRecords {
            guard let activeAppName = record.activeAppName,
                  let activeProvider = AIResumeParser.normalizeProviderName(activeAppName),
                  activeProvider != normalizedIncomingProvider else {
                continue
            }
            return .conflicting(activeProvider: activeProvider)
        }

        if let normalizedIncomingSessionID,
           displayRecords.contains(where: {
               TabRoutingIndex.normalizedSessionID($0.sessionID) == normalizedIncomingSessionID
           }) {
            return .matching
        }

        return .available
    }
}
