import Chau7Core

extension TerminalSessionModel {
    /// Whether destructive scrollback compaction must be disabled for this
    /// session. Process-tree identity remains the strongest signal, but restore
    /// metadata and authoritative lifecycle state close the gap before that
    /// signal arrives.
    var shouldProtectTerminalUIState: Bool {
        let candidateNames = [liveAgentName, activeAppName, aiDisplayAppName, effectiveAIProvider]
        let isKnownTerminalUI = candidateNames.compactMap { $0 }.contains {
            AIToolRegistry.usesTerminalUIHeuristics(forName: $0)
        }
        guard isKnownTerminalUI else { return false }

        if liveAgentName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if activeAppName != nil, !aiDetection.isRestored {
            return true
        }
        if isRestoreBootstrapPending {
            return true
        }

        switch effectiveStatus {
        case .running, .waitingForInput, .approvalRequired, .stuck:
            return true
        case .idle, .done, .exited:
            return false
        }
    }
}
