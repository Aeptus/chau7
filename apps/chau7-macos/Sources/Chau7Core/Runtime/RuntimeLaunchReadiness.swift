import Foundation

public struct RuntimeLaunchReadinessSnapshot: Sendable, Equatable {
    public let shellLoading: Bool
    public let isAtPrompt: Bool
    public let effectiveStatus: String
    public let rawStatus: String
    public let activeApp: String?
    public let rawActiveApp: String?
    public let aiProvider: String?
    public let activeRunProvider: String?
    public let processNames: [String]

    public init(
        shellLoading: Bool,
        isAtPrompt: Bool,
        effectiveStatus: String,
        rawStatus: String,
        activeApp: String?,
        rawActiveApp: String?,
        aiProvider: String?,
        activeRunProvider: String?,
        processNames: [String]
    ) {
        self.shellLoading = shellLoading
        self.isAtPrompt = isAtPrompt
        self.effectiveStatus = effectiveStatus
        self.rawStatus = rawStatus
        self.activeApp = activeApp
        self.rawActiveApp = rawActiveApp
        self.aiProvider = aiProvider
        self.activeRunProvider = activeRunProvider
        self.processNames = processNames
    }
}

public enum RuntimeLaunchReadiness {
    public static func isReady(
        snapshot: RuntimeLaunchReadinessSnapshot,
        backendName: String,
        purpose: String? = nil
    ) -> Bool {
        guard !requiresShellLoadCompletion(for: purpose) || !snapshot.shellLoading else {
            return false
        }
        guard launchSignalsMatchBackend(snapshot, backendName: backendName) else {
            return false
        }
        if snapshot.isAtPrompt {
            return true
        }
        return statusLooksInteractive(snapshot)
    }

    private static func statusLooksInteractive(_ snapshot: RuntimeLaunchReadinessSnapshot) -> Bool {
        let candidates = [snapshot.effectiveStatus, snapshot.rawStatus].map(normalizeStatusToken)
        return candidates.contains(where: {
            ["idle", "done", "running", "approvalrequired", "waitingforinput", "stuck"].contains($0)
        })
    }

    private static func launchSignalsMatchBackend(_ snapshot: RuntimeLaunchReadinessSnapshot, backendName: String) -> Bool {
        let normalizedBackend = backendName.lowercased()
        let signals = [
            snapshot.activeRunProvider,
            snapshot.aiProvider,
            snapshot.rawActiveApp,
            snapshot.activeApp
        ].compactMap { $0?.lowercased() }

        if signals.contains(where: { $0.contains(normalizedBackend) }) {
            return true
        }

        return snapshot.processNames.contains { processName in
            processName.lowercased().contains(normalizedBackend)
        }
    }

    private static func requiresShellLoadCompletion(for purpose: String?) -> Bool {
        purpose?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "code_review"
    }

    private static func normalizeStatusToken(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}
