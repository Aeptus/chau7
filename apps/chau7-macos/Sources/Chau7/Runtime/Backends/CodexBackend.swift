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
        return prependingEnvironment(command, config.environment)
    }

    var resumeProviderKey: String? {
        "codex"
    }

    var launchReadinessStrategy: AgentLaunchReadinessStrategy {
        .interactiveAgent
    }
}
