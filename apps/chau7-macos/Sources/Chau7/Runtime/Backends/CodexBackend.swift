import Foundation
import Chau7Core

/// Backend adapter for OpenAI Codex CLI.
struct CodexBackend: AgentBackend {

    let name = "codex"

    func launchCommand(config: SessionConfig) -> String {
        var parts = ["codex"]

        if let model = config.model {
            parts.append("--model")
            parts.append(model)
        }

        parts.append(contentsOf: config.args)

        let envPrefix = config.environment.map { "\($0.key)=\(shellEscape($0.value))" }.joined(separator: " ")
        if !envPrefix.isEmpty {
            return envPrefix + " " + parts.joined(separator: " ")
        }
        return parts.joined(separator: " ")
    }

    func formatPromptInput(_ prompt: String, context: String?) -> String {
        // Codex reads from stdin similarly
        if let context, !context.isEmpty {
            return "\(context)\n\n\(prompt)\n"
        }
        return prompt + "\n"
    }

    var resumeProviderKey: String? { nil } // Codex doesn't support resume

    private func shellEscape(_ value: String) -> String {
        if value.rangeOfCharacter(from: .init(charactersIn: " \"'$\\`!#&|;(){}[]<>?*~")) != nil {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
