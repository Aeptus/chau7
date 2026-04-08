import Foundation
import Chau7Core

/// Backend adapter for OpenAI Codex CLI.
struct CodexBackend: AgentBackend {

    let name = "codex"

    func launchCommand(config: SessionConfig) -> String {
        var parts = ["codex"]

        if let resumeID = config.resumeSessionID {
            parts.append("resume")
            parts.append(resumeID)
        }

        if config.autoApprove {
            parts.append("--full-auto")
        }

        if let model = config.model {
            parts.append("--model")
            parts.append(model)
        }

        parts.append(contentsOf: config.args)
        let command = ShellEscaping.escapeArguments(parts)

        let envPrefix = ShellEscaping.escapeEnvironmentAssignments(config.environment)
        if !envPrefix.isEmpty {
            return envPrefix + " " + command
        }
        return command
    }

    func formatPromptInput(_ prompt: String, context: String?) -> String {
        // Codex reads from stdin similarly
        if let context, !context.isEmpty {
            return "\(context)\n\n\(prompt)\n"
        }
        return prompt + "\n"
    }

    var resumeProviderKey: String? {
        "codex"
    }

    var launchReadinessStrategy: AgentLaunchReadinessStrategy {
        .interactiveAgent
    }
}
