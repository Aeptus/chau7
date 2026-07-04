import Foundation

public struct MagiCouncilMemberConfiguration: Codable, Equatable, Sendable {
    public var personaFile: String
    public var provider: String
    public var modelClass: MagiModelClass
    public var reasoning: MagiReasoningLevel
    public var modelName: String?
    public var weight: Double

    public init(
        personaFile: String,
        provider: String,
        modelClass: MagiModelClass = .balanced,
        reasoning: MagiReasoningLevel = .max,
        modelName: String? = nil,
        weight: Double = 1.0
    ) {
        self.personaFile = personaFile
        self.provider = provider
        self.modelClass = modelClass
        self.reasoning = reasoning
        self.modelName = modelName
        self.weight = max(0, weight)
    }

    public var memberConfiguration: MagiMemberConfiguration {
        MagiMemberConfiguration(
            provider: provider,
            modelClass: modelClass,
            reasoning: reasoning,
            modelName: modelName
        )
    }

    public mutating func applyProviderConfiguration(_ configuration: MagiMemberConfiguration) {
        provider = configuration.provider
        modelClass = configuration.modelClass
        reasoning = configuration.reasoning
        modelName = configuration.modelName
    }
}

public struct MagiCouncilConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var councilID: String
    public var displayName: String
    public var majorityThreshold: Int
    public var members: [MagiMemberID: MagiCouncilMemberConfiguration]

    public init(
        schemaVersion: Int = MagiCouncilConfiguration.currentSchemaVersion,
        councilID: String = "magi",
        displayName: String = "MAGI",
        majorityThreshold: Int = 2,
        members: [MagiMemberID: MagiCouncilMemberConfiguration] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.councilID = councilID
        self.displayName = displayName
        self.majorityThreshold = max(1, majorityThreshold)
        self.members = members
    }

    public var memberProviderConfigurations: [MagiMemberID: MagiMemberConfiguration] {
        members.mapValues(\.memberConfiguration)
    }

    public static func defaultMagi(
        councilID: String = "magi",
        displayName: String = "MAGI",
        majorityThreshold: Int = 2,
        members providerConfigurations: [MagiMemberID: MagiMemberConfiguration],
        defaultReasoning: MagiReasoningLevel = .max
    ) -> MagiCouncilConfiguration {
        var memberConfigurations: [MagiMemberID: MagiCouncilMemberConfiguration] = [:]
        for memberID in MagiMemberID.allCases {
            let provider = providerConfigurations[memberID] ?? MagiMemberConfiguration(
                provider: "unconfigured",
                reasoning: defaultReasoning
            )
            memberConfigurations[memberID] = MagiCouncilMemberConfiguration(
                personaFile: MagiPersonaFile.fileName(for: memberID),
                provider: provider.provider,
                modelClass: provider.modelClass,
                reasoning: provider.reasoning,
                modelName: provider.modelName,
                weight: 1.0
            )
        }
        return MagiCouncilConfiguration(
            councilID: councilID,
            displayName: displayName,
            majorityThreshold: majorityThreshold,
            members: memberConfigurations
        )
    }

    public func updatingMemberProviderConfigurations(
        _ providerConfigurations: [MagiMemberID: MagiMemberConfiguration]
    ) -> MagiCouncilConfiguration {
        var updated = self
        for memberID in MagiMemberID.allCases {
            guard let providerConfiguration = providerConfigurations[memberID] else { continue }
            if updated.members[memberID] == nil {
                updated.members[memberID] = MagiCouncilMemberConfiguration(
                    personaFile: MagiPersonaFile.fileName(for: memberID),
                    provider: providerConfiguration.provider,
                    modelClass: providerConfiguration.modelClass,
                    reasoning: providerConfiguration.reasoning,
                    modelName: providerConfiguration.modelName
                )
            } else {
                updated.members[memberID]?.applyProviderConfiguration(providerConfiguration)
            }
        }
        return updated
    }
}

public enum MagiCouncilConfigurationStore {
    public static func load(
        for config: MagiConfig,
        paths: MagiCLIPaths,
        fileManager: FileManager = .default
    ) throws -> MagiCouncilConfiguration {
        let path = paths.councilConfigPath(for: config.defaultCouncilID)
        guard fileManager.fileExists(atPath: path) else {
            return defaultCouncil(for: config)
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return try MagiCouncilConfigTOMLCodec.decode(content, fallbackCouncilID: config.defaultCouncilID)
    }

    public static func save(
        _ council: MagiCouncilConfiguration,
        paths: MagiCLIPaths,
        fileManager: FileManager = .default
    ) throws {
        let path = paths.councilConfigPath(for: council.councilID)
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: paths.globalCouncilDirectory),
            withIntermediateDirectories: true
        )
        try MagiCouncilConfigTOMLCodec.encode(council).write(
            to: URL(fileURLWithPath: path),
            atomically: true,
            encoding: .utf8
        )
    }

    public static func defaultCouncil(for config: MagiConfig) -> MagiCouncilConfiguration {
        MagiCouncilConfiguration.defaultMagi(
            councilID: config.defaultCouncilID,
            displayName: config.defaultCouncilID.uppercased(),
            members: config.members,
            defaultReasoning: config.defaultReasoning
        )
    }
}

public enum MagiCouncilConfigTOMLCodec {
    public static func encode(_ council: MagiCouncilConfiguration) -> String {
        var lines: [String] = [
            "# MAGI Council Configuration",
            "# Stores council-specific members, persona mapping, and model bindings.",
            "",
            "schema_version = \(council.schemaVersion)",
            "council_id = \"\(escape(council.councilID))\"",
            "display_name = \"\(escape(council.displayName))\"",
            "majority_threshold = \(council.majorityThreshold)",
            ""
        ]

        for memberID in MagiMemberID.allCases {
            let member = council.members[memberID] ?? MagiCouncilMemberConfiguration(
                personaFile: MagiPersonaFile.fileName(for: memberID),
                provider: "unconfigured"
            )
            lines.append("[members.\(memberID.rawValue)]")
            lines.append("persona = \"\(escape(member.personaFile))\"")
            lines.append("provider = \"\(escape(member.provider))\"")
            lines.append("class = \"\(member.modelClass.rawValue)\"")
            lines.append("reasoning = \"\(member.reasoning.rawValue)\"")
            if let modelName = member.modelName, !modelName.isEmpty {
                lines.append("model = \"\(escape(modelName))\"")
            }
            if member.weight != 1.0 {
                lines.append("weight = \(member.weight)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public static func decode(_ content: String, fallbackCouncilID: String = "magi") throws -> MagiCouncilConfiguration {
        let raw = ConfigFileParser.parseRaw(content)
        let global = raw["__global__"] ?? [:]
        let defaultReasoning = try enumValue(
            MagiReasoningLevel.self,
            rawValue: string(global["default_reasoning"]),
            defaultValue: .max,
            field: "default_reasoning"
        )
        var members: [MagiMemberID: MagiCouncilMemberConfiguration] = [:]

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
            members[memberID] = MagiCouncilMemberConfiguration(
                personaFile: string(section["persona"]) ?? MagiPersonaFile.fileName(for: memberID),
                provider: provider,
                modelClass: modelClass,
                reasoning: reasoning,
                modelName: string(section["model"]) ?? string(section["model_name"]),
                weight: double(section["weight"]) ?? 1.0
            )
        }

        return MagiCouncilConfiguration(
            schemaVersion: int(global["schema_version"]) ?? MagiCouncilConfiguration.currentSchemaVersion,
            councilID: string(global["council_id"]) ?? fallbackCouncilID,
            displayName: string(global["display_name"]) ?? "MAGI",
            majorityThreshold: int(global["majority_threshold"]) ?? 2,
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
        if let string = string(value) { return Int(string) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = string(value) { return Double(string) }
        return nil
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
