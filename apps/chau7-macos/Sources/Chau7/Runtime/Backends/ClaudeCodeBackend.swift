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
        return prependingEnvironment(command, config.environment)
    }

    var resumeProviderKey: String? {
        "claude"
    }

    var launchReadinessStrategy: AgentLaunchReadinessStrategy {
        .interactiveAgent
    }

}
