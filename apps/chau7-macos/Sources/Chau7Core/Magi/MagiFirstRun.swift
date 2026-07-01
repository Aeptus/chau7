import Foundation

// MARK: - First-Run Selection

public struct MagiFirstRunMemberSelection: Codable, Equatable, Sendable {
    public var memberID: MagiMemberID
    public var provider: MagiProviderID
    public var modelClass: MagiModelClass
    public var reasoning: MagiReasoningLevel

    public init(
        memberID: MagiMemberID,
        provider: MagiProviderID,
        modelClass: MagiModelClass = .balanced,
        reasoning: MagiReasoningLevel = .max
    ) {
        self.memberID = memberID
        self.provider = provider
        self.modelClass = modelClass
        self.reasoning = reasoning
    }
}

public struct MagiProviderDryRunResult: Codable, Equatable, Sendable {
    public var provider: MagiProviderID
    public var passed: Bool
    public var detail: String

    public init(provider: MagiProviderID, passed: Bool, detail: String = "") {
        self.provider = provider
        self.passed = passed
        self.detail = detail
    }
}

public struct MagiFallbackDuplicationPlan: Codable, Equatable, Sendable {
    public var replacementProvider: MagiProviderID
    public var failedProviders: [MagiProviderID]
    public var affectedMembers: [MagiMemberID]

    public init(
        replacementProvider: MagiProviderID,
        failedProviders: [MagiProviderID],
        affectedMembers: [MagiMemberID]
    ) {
        self.replacementProvider = replacementProvider
        self.failedProviders = failedProviders
        self.affectedMembers = affectedMembers
    }
}

public enum MagiFirstRunPlanner {
    public static func defaultSelections() -> [MagiMemberID: MagiFirstRunMemberSelection] {
        [
            .melchior: MagiFirstRunMemberSelection(memberID: .melchior, provider: .codex),
            .balthasar: MagiFirstRunMemberSelection(memberID: .balthasar, provider: .claude),
            .casper: MagiFirstRunMemberSelection(memberID: .casper, provider: .gemini)
        ]
    }

    public static func config(from selections: [MagiMemberID: MagiFirstRunMemberSelection]) -> MagiConfig {
        let defaults = defaultSelections()
        let members = MagiMemberID.allCases.reduce(into: [MagiMemberID: MagiMemberConfiguration]()) { result, memberID in
            let selection = selections[memberID]
                ?? defaults[memberID]
                ?? MagiFirstRunMemberSelection(memberID: memberID, provider: .codex)
            result[memberID] = MagiMemberConfiguration(
                provider: selection.provider.rawValue,
                modelClass: selection.modelClass,
                reasoning: selection.reasoning
            )
        }

        return MagiConfig(
            defaultReasoning: .max,
            fallbackStrategy: .duplicate,
            webAccessAllowed: true,
            evidenceRequiresApproval: true,
            deadlockExtraRoundEnabled: true,
            vetoBlocksVerdict: true,
            members: members
        )
    }

    public static func fallbackPlan(
        selections: [MagiMemberID: MagiFirstRunMemberSelection],
        dryRunResults: [MagiProviderDryRunResult]
    ) -> MagiFallbackDuplicationPlan? {
        let resultByProvider = dryRunResults.reduce(into: [MagiProviderID: MagiProviderDryRunResult]()) { result, dryRun in
            result[dryRun.provider] = dryRun
        }
        let orderedSelections = MagiMemberID.allCases.compactMap { selections[$0] }
        let selectedProviders = Set(orderedSelections.map(\.provider))

        let failedProviders = MagiProviderID.allCases.filter { provider in
            selectedProviders.contains(provider) && resultByProvider[provider]?.passed != true
        }

        guard !failedProviders.isEmpty else { return nil }

        guard let replacementProvider = orderedSelections.first(where: { resultByProvider[$0.provider]?.passed == true })?.provider else {
            return nil
        }

        let failedProviderSet = Set(failedProviders)
        let affectedMembers = MagiMemberID.allCases.filter { memberID in
            guard let selection = selections[memberID] else { return false }
            return failedProviderSet.contains(selection.provider)
        }

        guard !affectedMembers.isEmpty else { return nil }

        return MagiFallbackDuplicationPlan(
            replacementProvider: replacementProvider,
            failedProviders: failedProviders,
            affectedMembers: affectedMembers
        )
    }

    public static func applyingFallbackDuplication(
        _ plan: MagiFallbackDuplicationPlan,
        to selections: [MagiMemberID: MagiFirstRunMemberSelection]
    ) -> [MagiMemberID: MagiFirstRunMemberSelection] {
        var updated = selections
        for memberID in plan.affectedMembers {
            guard var selection = updated[memberID] else { continue }
            selection.provider = plan.replacementProvider
            updated[memberID] = selection
        }
        return updated
    }
}

// MARK: - Config TOML

public enum MagiConfigFileError: Equatable, LocalizedError, Sendable {
    case invalidValue(field: String, value: String, allowed: [String])

    public var errorDescription: String? {
        switch self {
        case let .invalidValue(field, value, allowed):
            let allowedValues = allowed.joined(separator: ", ")
            return "Invalid MAGI config value for \(field): \(value). Allowed values: \(allowedValues)."
        }
    }
}

public enum MagiConfigTOMLCodec {
    public static func encode(_ config: MagiConfig) -> String {
        var lines: [String] = [
            "# MAGI Configuration",
            "# Generated by Chau7. Edit providers, classes, and personas as needed.",
            "",
            "schema_version = \(config.schemaVersion)",
            "default_council_id = \"\(escape(config.defaultCouncilID))\"",
            "default_reasoning = \"\(config.defaultReasoning.rawValue)\"",
            "fallback_strategy = \"\(config.fallbackStrategy.rawValue)\"",
            "web_access_allowed = \(config.webAccessAllowed)",
            "evidence_requires_approval = \(config.evidenceRequiresApproval)",
            "deadlock_extra_round_enabled = \(config.deadlockExtraRoundEnabled)",
            "veto_blocks_verdict = \(config.vetoBlocksVerdict)",
            ""
        ]

        for memberID in MagiMemberID.allCases {
            let member = config.members[memberID] ?? MagiMemberConfiguration(provider: "unconfigured")
            lines.append("[members.\(memberID.rawValue)]")
            lines.append("provider = \"\(escape(member.provider))\"")
            lines.append("class = \"\(member.modelClass.rawValue)\"")
            lines.append("reasoning = \"\(member.reasoning.rawValue)\"")
            if let modelName = member.modelName, !modelName.isEmpty {
                lines.append("model = \"\(escape(modelName))\"")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public static func decode(_ content: String) throws -> MagiConfig {
        let raw = ConfigFileParser.parseRaw(content)
        let global = raw["__global__"] ?? [:]

        let defaultReasoning = try enumValue(
            MagiReasoningLevel.self,
            rawValue: string(global["default_reasoning"]),
            defaultValue: .max,
            field: "default_reasoning"
        )
        let fallbackStrategy = try enumValue(
            MagiFallbackStrategy.self,
            rawValue: string(global["fallback_strategy"]) ?? string(global["fallback"]),
            defaultValue: .duplicate,
            field: "fallback_strategy"
        )

        var members: [MagiMemberID: MagiMemberConfiguration] = [:]
        for memberID in MagiMemberID.allCases {
            guard let section = raw["members.\(memberID.rawValue)"] else { continue }
            guard let provider = string(section["provider"]), !provider.isEmpty else { continue }

            let modelClass = try enumValue(
                MagiModelClass.self,
                rawValue: string(section["class"]) ?? string(section["model_class"]),
                defaultValue: .balanced,
                field: "members.\(memberID.rawValue).class"
            )
            let reasoning = try enumValue(
                MagiReasoningLevel.self,
                rawValue: string(section["reasoning"]),
                defaultValue: defaultReasoning,
                field: "members.\(memberID.rawValue).reasoning"
            )

            members[memberID] = MagiMemberConfiguration(
                provider: provider,
                modelClass: modelClass,
                reasoning: reasoning,
                modelName: string(section["model"]) ?? string(section["model_name"])
            )
        }

        return MagiConfig(
            schemaVersion: int(global["schema_version"]) ?? MagiConfig.currentSchemaVersion,
            defaultCouncilID: string(global["default_council_id"]) ?? "magi",
            defaultReasoning: defaultReasoning,
            fallbackStrategy: fallbackStrategy,
            webAccessAllowed: bool(global["web_access_allowed"]) ?? bool(global["web"]) ?? true,
            evidenceRequiresApproval: bool(global["evidence_requires_approval"]) ?? true,
            deadlockExtraRoundEnabled: bool(global["deadlock_extra_round_enabled"]) ?? bool(global["deadlock_extra_round"]) ?? true,
            vetoBlocksVerdict: bool(global["veto_blocks_verdict"]) ?? bool(global["veto_blocks"]) ?? true,
            members: members
        )
    }

    private static func enumValue<T: RawRepresentable & CaseIterable>(
        _: T.Type,
        rawValue: String?,
        defaultValue: T,
        field: String
    ) throws -> T where T.RawValue == String, T.AllCases: Collection {
        guard let rawValue, !rawValue.isEmpty else { return defaultValue }
        guard let value = T(rawValue: rawValue) else {
            throw MagiConfigFileError.invalidValue(
                field: field,
                value: rawValue,
                allowed: T.allCases.map(\.rawValue)
            )
        }
        return value
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let int = value as? Int { return String(int) }
        if let double = value as? Double { return String(double) }
        if let bool = value as? Bool { return String(bool) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            switch string.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - Persona Files

public enum MagiPersonaFile {
    public static func fileName(for memberID: MagiMemberID) -> String {
        "\(memberID.rawValue).md"
    }

    public static func defaultFiles() -> [MagiMemberID: String] {
        MagiMemberID.allCases.reduce(into: [MagiMemberID: String]()) { result, memberID in
            let persona = MagiPersona.defaultPersonasByID[memberID] ?? MagiPersona(
                memberID: memberID,
                lens: "General MAGI council judgment.",
                prompt: "Evaluate the question through this member's configured judgment lens."
            )
            result[memberID] = content(for: persona)
        }
    }

    public static func content(for persona: MagiPersona) -> String {
        let vetoPolicy = persona.vetoPolicy ?? "Define rare blocking conditions for this member. A veto blocks the final verdict."
        return """
        # \(persona.displayName)

        member_id: \(persona.memberID.rawValue)
        display_name: \(persona.displayName)
        lens: \(persona.lens)
        editable: \(persona.isUserEditable)

        ## Operating Prompt

        \(persona.prompt)

        ## Veto Policy

        \(vetoPolicy)
        """
    }
}

// MARK: - Installation

public struct MagiFirstRunInstallResult: Equatable, Sendable {
    public var createdPaths: [String]
    public var skippedPaths: [String]

    public init(createdPaths: [String] = [], skippedPaths: [String] = []) {
        self.createdPaths = createdPaths
        self.skippedPaths = skippedPaths
    }
}

public enum MagiFirstRunInstaller {
    public static func isConfigured(paths: MagiCLIPaths, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: paths.globalConfigPath)
    }

    public static func missingPersonaFiles(paths: MagiCLIPaths, fileManager: FileManager = .default) -> [MagiMemberID] {
        MagiMemberID.allCases.filter { memberID in
            !fileManager.fileExists(atPath: paths.personaPath(for: memberID))
        }
    }

    @discardableResult
    public static func install(
        config: MagiConfig,
        paths: MagiCLIPaths,
        fileManager: FileManager = .default,
        overwrite: Bool = false
    ) throws -> MagiFirstRunInstallResult {
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: paths.globalRoot),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: paths.globalPersonaDirectory),
            withIntermediateDirectories: true
        )

        var createdPaths: [String] = []
        var skippedPaths: [String] = []

        try write(
            MagiConfigTOMLCodec.encode(config),
            to: paths.globalConfigPath,
            fileManager: fileManager,
            overwrite: overwrite,
            createdPaths: &createdPaths,
            skippedPaths: &skippedPaths
        )

        for memberID in MagiMemberID.allCases {
            let personaContent = MagiPersonaFile.defaultFiles()[memberID] ?? MagiPersonaFile.content(
                for: MagiPersona(
                    memberID: memberID,
                    lens: "General MAGI council judgment.",
                    prompt: "Evaluate the question through this member's configured judgment lens."
                )
            )
            try write(
                personaContent,
                to: paths.personaPath(for: memberID),
                fileManager: fileManager,
                overwrite: overwrite,
                createdPaths: &createdPaths,
                skippedPaths: &skippedPaths
            )
        }

        return MagiFirstRunInstallResult(createdPaths: createdPaths, skippedPaths: skippedPaths)
    }

    private static func write(
        _ content: String,
        to path: String,
        fileManager: FileManager,
        overwrite: Bool,
        createdPaths: inout [String],
        skippedPaths: inout [String]
    ) throws {
        if fileManager.fileExists(atPath: path), !overwrite {
            skippedPaths.append(path)
            return
        }

        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        createdPaths.append(path)
    }
}
