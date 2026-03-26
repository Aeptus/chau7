import Foundation
import Chau7Core

/// Backend adapter for Claude Code CLI.
///
/// Leverages `ClaudeCodeMonitor.onEvent` for structured events instead of
/// parsing terminal output. Maps `ClaudeSessionInfo.SessionState` to
/// `RuntimeSessionStateMachine.Trigger`.
struct ClaudeCodeBackend: AgentBackend {

    let name = "claude"

    func launchCommand(config: SessionConfig) -> String {
        var parts = ["claude"]

        if let resumeID = config.resumeSessionID {
            parts.append("--resume")
            parts.append(resumeID)
        }

        if let model = config.model {
            parts.append("--model")
            parts.append(model)
        }

        parts.append(contentsOf: config.args)
        let command = ShellEscaping.escapeArguments(parts)

        // Prepend environment variables
        let envPrefix = config.environment.map { "\($0.key)=\(shellEscape($0.value))" }.joined(separator: " ")
        if !envPrefix.isEmpty {
            return envPrefix + " " + command
        }
        return command
    }

    func formatPromptInput(_ prompt: String, context: String?) -> String {
        // Claude Code reads prompts from stdin, terminated by newline
        if let context, !context.isEmpty {
            return "\(context)\n\n\(prompt)\n"
        }
        return prompt + "\n"
    }

    var resumeProviderKey: String? {
        "claude"
    }

    // MARK: - State Mapping

    /// Maps Claude Code monitor session states to runtime triggers.
    static func trigger(from sessionState: ClaudeCodeMonitor.ClaudeSessionInfo.SessionState) -> RuntimeSessionStateMachine.Trigger? {
        switch sessionState {
        case .active, .responding:
            return nil // stay in .busy — no transition needed
        case .waitingPermission:
            return .approvalNeeded
        case .waitingInput:
            return .turnCompleted
        case .idle:
            return .turnCompleted
        case .closed:
            return .tabClosed
        }
    }

    // MARK: - Private

    private func shellEscape(_ value: String) -> String {
        if value.rangeOfCharacter(from: .init(charactersIn: " \"'$\\`!#&|;(){}[]<>?*~")) != nil {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
