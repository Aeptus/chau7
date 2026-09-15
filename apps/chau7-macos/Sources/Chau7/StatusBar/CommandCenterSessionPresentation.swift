import Foundation

// MARK: - Command Center Session Presentation

struct CommandCenterSessionPresentation: Equatable {
    enum Tone: Equatable {
        case running
        case approvalRequired
        case waitingInput
        case stuck
    }

    let symbolName: String
    let description: String
    let tone: Tone
    let needsAttention: Bool

    static func presentation(for state: CommandCenterSessionSummary.State) -> CommandCenterSessionPresentation {
        switch state {
        case .running:
            return CommandCenterSessionPresentation(
                symbolName: "gearshape.2",
                description: L("statusBar.session.working", "Working"),
                tone: .running,
                needsAttention: false
            )
        case .approvalRequired:
            return CommandCenterSessionPresentation(
                symbolName: "hand.raised",
                description: L("statusBar.session.approvalRequired", "Approval required"),
                tone: .approvalRequired,
                needsAttention: true
            )
        case .waitingInput:
            return CommandCenterSessionPresentation(
                symbolName: "bubble.left.and.exclamationmark.bubble.right",
                description: L("statusBar.session.waitingInput", "Waiting for input"),
                tone: .waitingInput,
                needsAttention: true
            )
        case .stuck:
            return CommandCenterSessionPresentation(
                symbolName: "exclamationmark.triangle",
                description: L("statusBar.session.stuck", "No recent output"),
                tone: .stuck,
                needsAttention: false
            )
        }
    }
}
