import Foundation

public struct MagiProviderCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var providerID: MagiProviderID?
    public var resolvedModel: String?
    public var resolvedReasoning: String?
    public var usesRawCommand: Bool

    public init(
        executable: String,
        arguments: [String] = [],
        providerID: MagiProviderID? = nil,
        resolvedModel: String? = nil,
        resolvedReasoning: String? = nil,
        usesRawCommand: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.providerID = providerID
        self.resolvedModel = resolvedModel
        self.resolvedReasoning = resolvedReasoning
        self.usesRawCommand = usesRawCommand
    }

    public var commandLine: String {
        if usesRawCommand {
            return executable
        }
        return ([executable] + arguments)
            .map(MagiProviderCommandBuilder.shellQuotedArgument)
            .joined(separator: " ")
    }
}

public enum MagiProviderCommandBuilder {
    public static func command(for member: MagiMember) -> MagiProviderCommand {
        let provider = member.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let providerID = MagiProviderID(rawValue: provider.lowercased()) else {
            return MagiProviderCommand(executable: provider, usesRawCommand: true)
        }

        let model = resolvedModel(
            provider: providerID,
            modelClass: member.modelClass,
            explicitModelName: member.modelName
        )

        switch providerID {
        case .codex:
            let reasoning = codexReasoningEffort(member.reasoning)
            return MagiProviderCommand(
                executable: providerID.rawValue,
                arguments: modelArguments(flag: "--model", model: model)
                    + ["-c", "model_reasoning_effort=\"\(reasoning)\""],
                providerID: providerID,
                resolvedModel: model,
                resolvedReasoning: reasoning
            )
        case .claude:
            let reasoning = claudeEffort(member.reasoning)
            return MagiProviderCommand(
                executable: providerID.rawValue,
                arguments: modelArguments(flag: "--model", model: model)
                    + ["--effort", reasoning],
                providerID: providerID,
                resolvedModel: model,
                resolvedReasoning: reasoning
            )
        case .gemini:
            return MagiProviderCommand(
                executable: providerID.rawValue,
                arguments: modelArguments(flag: "--model", model: model),
                providerID: providerID,
                resolvedModel: model,
                resolvedReasoning: nil
            )
        }
    }

    public static func commandLine(for member: MagiMember) -> String {
        command(for: member).commandLine
    }

    public static func resolvedModel(
        provider: MagiProviderID,
        modelClass: MagiModelClass,
        explicitModelName: String?
    ) -> String {
        if let explicitModelName = explicitModelName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitModelName.isEmpty {
            return explicitModelName
        }

        switch provider {
        case .codex:
            switch modelClass {
            case .fast:
                return "gpt-5.4-mini"
            case .balanced:
                return "gpt-5.4"
            case .strongest:
                return "gpt-5.5"
            }
        case .claude:
            switch modelClass {
            case .fast:
                return "fable"
            case .balanced:
                return "sonnet"
            case .strongest:
                return "opus"
            }
        case .gemini:
            switch modelClass {
            case .fast:
                return "gemini-2.5-flash-lite"
            case .balanced:
                return "gemini-2.5-flash"
            case .strongest:
                return "gemini-2.5-pro"
            }
        }
    }

    public static func shellQuotedArgument(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safePattern = #"^[A-Za-z0-9_@%+=:,./-]+$"#
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func modelArguments(flag: String, model: String) -> [String] {
        [flag, model]
    }

    private static func codexReasoningEffort(_ reasoning: MagiReasoningLevel) -> String {
        switch reasoning {
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .max:
            return "xhigh"
        }
    }

    private static func claudeEffort(_ reasoning: MagiReasoningLevel) -> String {
        switch reasoning {
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .max:
            return "max"
        }
    }
}
