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

        if config.autoApprove {
            parts.append("--dangerously-skip-permissions")
        }

        if let model = config.model {
            parts.append("--model")
            parts.append(model)
        }

        parts.append(contentsOf: config.args)
        let command = ShellEscaping.escapeArguments(parts)

        // Prepend environment variables
        let envPrefix = ShellEscaping.escapeEnvironmentAssignments(config.environment)
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

    var launchReadinessStrategy: AgentLaunchReadinessStrategy {
        .interactiveAgent
    }

}
