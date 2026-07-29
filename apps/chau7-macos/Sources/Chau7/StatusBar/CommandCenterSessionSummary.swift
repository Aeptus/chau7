import Foundation
import Chau7Core

// MARK: - Command Center Session Summary

struct CommandCenterSessionSummary: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case waitingInput
        case approvalRequired
        case stuck

        var attentionKind: TabAttentionKind {
            switch self {
            case .waitingInput:
                return .waitingForInput
            case .approvalRequired:
                return .approvalRequired
            case .running, .stuck:
                return .none
            }
        }

        var dashboardAgentState: DashboardAgentState {
            switch self {
            case .approvalRequired:
                return .awaitingApproval
            case .waitingInput:
                return .waitingInput
            case .running, .stuck:
                return .busy
            }
        }
    }

    let id: String
    let tabID: UUID
    let paneID: UUID
    let title: String
    let appName: String
    let directory: String?
    let lastActivity: Date
    let state: State

    var tabTarget: TabTarget {
        TabTarget(tool: appName, directory: directory, tabID: tabID)
    }

    var directoryName: String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let standardized = URL(fileURLWithPath: trimmed).standardized.path
        let name = URL(fileURLWithPath: standardized).lastPathComponent
        return name.isEmpty ? standardized : name
    }

    var contextLabel: String? {
        if let directoryName,
           directoryName.caseInsensitiveCompare(title) != .orderedSame {
            return directoryName
        }
        return nil
    }

    var needsAttention: Bool {
        state.attentionKind.isInteractive
    }

    static func displayName(for session: TerminalSessionModel) -> String {
        if let appName = session.aiDisplayAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appName.isEmpty {
            return appName
        }
        if let provider = session.effectiveAIProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return provider.capitalized
        }
        return L("statusBar.aiSession", "AI Session")
    }

    static func state(for status: CommandStatus) -> State? {
        switch TabAttentionKind.fromStatus(status.rawValue) {
        case .approvalRequired:
            return .approvalRequired
        case .waitingForInput:
            return .waitingInput
        case .none:
            break
        }

        switch DashboardAgentState(commandStatus: status, isAtPrompt: false) {
        case .busy where status == .running:
            return .running
        case .busy where status == .stuck:
            return .stuck
        case .ready, .busy, .awaitingApproval, .waitingInput, .interrupted, .failed, .stopped, .starting:
            return nil
        }
    }

    static func collectLiveSessions(in overlayModel: OverlayTabsModel?) -> [CommandCenterSessionSummary] {
        guard let overlayModel else { return [] }

        return collectLiveSessions(in: [overlayModel])
    }

    static func collectLiveSessions(in overlayModels: [OverlayTabsModel]) -> [CommandCenterSessionSummary] {
        overlayModels
            .flatMap(\.tabs)
            .flatMap { tab -> [CommandCenterSessionSummary] in
                tab.splitController.terminalSessions.compactMap { paneID, session in
                    guard session.aiDisplayAppName != nil ||
                        session.effectiveAIProvider != nil ||
                        session.effectiveAISessionId != nil else {
                        return nil
                    }
                    guard let state = state(for: session.effectiveStatus) else {
                        return nil
                    }

                    let appName = displayName(for: session)
                    let shellTitle = L("tab.shell", "Shell")
                    let editorTitle = L("tab.editor", "Editor")
                    let resolvedTitle = TabTitleFormatter.resolvedTitle(
                        customTitle: tab.customTitle,
                        aiDisplayAppName: appName,
                        devServerName: session.devServer?.name,
                        customTitleOnly: FeatureSettings.shared.customTitleOnly,
                        shellFallback: shellTitle
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    let title: String
                    if !resolvedTitle.isEmpty,
                       resolvedTitle.caseInsensitiveCompare(shellTitle) != .orderedSame,
                       resolvedTitle.caseInsensitiveCompare(editorTitle) != .orderedSame,
                       resolvedTitle.caseInsensitiveCompare(appName) != .orderedSame {
                        title = resolvedTitle
                    } else {
                        let directoryName = URL(fileURLWithPath: session.currentDirectory).lastPathComponent
                        title = directoryName.isEmpty ? appName : directoryName
                    }

                    let directory = session.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                    return CommandCenterSessionSummary(
                        id: "\(tab.id.uuidString):\(paneID.uuidString)",
                        tabID: tab.id,
                        paneID: paneID,
                        title: title,
                        appName: appName,
                        directory: directory.isEmpty ? nil : directory,
                        lastActivity: max(session.lastActivityDate, tab.createdAt),
                        state: state
                    )
                }
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }
}
