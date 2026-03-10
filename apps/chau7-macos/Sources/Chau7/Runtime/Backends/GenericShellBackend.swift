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
        let envPrefix = config.environment.map { "\($0.key)=\(shellEscape($0.value))" }.joined(separator: " ")
        let cmd = config.args.joined(separator: " ")
        if !envPrefix.isEmpty && !cmd.isEmpty {
            return envPrefix + " " + cmd
        }
        return cmd
    }

    func formatPromptInput(_ prompt: String, context: String?) -> String {
        // Raw passthrough — just send the text
        return prompt + "\n"
    }

    var resumeProviderKey: String? { nil }

    private func shellEscape(_ value: String) -> String {
        if value.rangeOfCharacter(from: .init(charactersIn: " \"'$\\`!#&|;(){}[]<>?*~")) != nil {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
