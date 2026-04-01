import Foundation

public struct TerminalPromptNotificationContext: Equatable, Sendable {
    public let previousStatus: String
    public let hasOwnerTab: Bool
    public let runtimeOwnsTab: Bool
    public let providerID: String?
    public let providerIsRestored: Bool
    public let hasPendingPrefillInput: Bool
    public let suppressUntilNextUserCommand: Bool
    public let commandLooksLikeResume: Bool
    public let observedAIRoundTrip: Bool
    public let sessionID: String?

    public init(
        previousStatus: String,
        hasOwnerTab: Bool,
        runtimeOwnsTab: Bool,
        providerID: String?,
        providerIsRestored: Bool,
        hasPendingPrefillInput: Bool,
        suppressUntilNextUserCommand: Bool,
        commandLooksLikeResume: Bool,
        observedAIRoundTrip: Bool,
        sessionID: String?
    ) {
        self.previousStatus = previousStatus
        self.hasOwnerTab = hasOwnerTab
        self.runtimeOwnsTab = runtimeOwnsTab
        self.providerID = providerID
        self.providerIsRestored = providerIsRestored
        self.hasPendingPrefillInput = hasPendingPrefillInput
        self.suppressUntilNextUserCommand = suppressUntilNextUserCommand
        self.commandLooksLikeResume = commandLooksLikeResume
        self.observedAIRoundTrip = observedAIRoundTrip
        self.sessionID = sessionID
    }
}

public enum TerminalPromptNotificationAdapter {
    private static let supportedStatuses: Set<String> = ["running", "stuck", "waitingForInput"]
    private static let fallbackExcludedProviders: Set<String> = ["claude"]

    public static func shouldEmitWaitingInput(from context: TerminalPromptNotificationContext) -> Bool {
        guard supportedStatuses.contains(context.previousStatus) else {
            return false
        }
        guard context.hasOwnerTab else {
            return false
        }
        guard !context.runtimeOwnsTab else {
            return false
        }
        guard let providerID = normalizedProviderID(context.providerID) else {
            return false
        }
        guard !fallbackExcludedProviders.contains(providerID) else {
            return false
        }
        guard !context.hasPendingPrefillInput else {
            return false
        }
        guard !context.suppressUntilNextUserCommand else {
            return false
        }
        guard !context.commandLooksLikeResume else {
            return false
        }
        guard context.observedAIRoundTrip else {
            return false
        }
        return true
    }

    private static func normalizedProviderID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
