import Foundation
import Chau7Core

/// A concrete AI session identity observed from a tool history monitor and ready
/// to be adopted by the terminal tab that owns the matching cwd/session.
struct HistorySessionAdoptionRequest: Equatable {
    enum Reason: String, Equatable {
        case historyEntry
        case stateChange
        case idle
    }

    let toolName: String
    let providerKey: String
    let displayName: String
    let sessionId: String
    let directory: String?
    let tabID: UUID?
    let observedAt: Date
    let state: HistorySessionState?
    let reason: Reason

    init?(
        toolName: String,
        sessionId: String,
        directory: String?,
        tabID: UUID?,
        observedAt: Date,
        state: HistorySessionState?,
        reason: Reason
    ) {
        let trimmedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTool.isEmpty,
              AIResumeParser.isValidSessionId(trimmedSessionId) else {
            return nil
        }

        let providerKey = AIToolRegistry.resumeProviderKey(for: trimmedTool)
            ?? AIResumeParser.normalizeProviderName(trimmedTool)
            ?? trimmedTool.lowercased()
        let toolDefinition = AIToolRegistry.allTools.first { $0.resumeProviderKey == providerKey }
        let displayName = toolDefinition?.displayName ?? trimmedTool

        self.toolName = trimmedTool
        self.providerKey = providerKey
        self.displayName = displayName
        self.sessionId = trimmedSessionId
        self.directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.tabID = tabID
        self.observedAt = observedAt
        self.state = state
        self.reason = reason
    }

    var canReplaceDifferentStoredSession: Bool {
        reason == .historyEntry || state == .active
    }

    var shouldMarkSessionInactive: Bool {
        state == .idle || state == .closed
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
