import Foundation
import Chau7Core

/// Simplest backend: raw command passthrough with no turn semantics.
///
/// Use for arbitrary shell commands where the orchestrator manages
/// the interaction loop manually via `tab_send_input`.
struct GenericShellBackend: AgentBackend {

    let name = "shell"

    func launchCommand(config: SessionConfig) -> String {
        // For shell backend, the command is provided via args
        let cmd = ShellEscaping.escapeArguments(config.args)
        return prependingEnvironment(cmd, config.environment)
    }

    func formatPromptInput(_ prompt: String, context: String?) -> String {
        // Raw passthrough — just send the text
        return prompt + "\n"
    }

    var resumeProviderKey: String? {
        nil
    }
}
