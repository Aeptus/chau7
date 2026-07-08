import Foundation

public struct Chau7SkillID: Codable, Hashable, Identifiable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var id: String {
        rawValue
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Chau7SkillSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case bundled
        case user
        case repo
        case external

        public var id: String {
            rawValue
        }
    }

    public var id: Chau7SkillID
    public var kind: Kind
    public var rootDirectory: String
    public var version: String?

    public init(
        id: Chau7SkillID,
        kind: Kind,
        rootDirectory: String,
        version: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.rootDirectory = rootDirectory.chau7SkillRemovingTrailingSlashes()
        self.version = version
    }

    public var skillMarkdownPath: String {
        "\(rootDirectory)/SKILL.md"
    }

    public var scriptsDirectory: String {
        "\(rootDirectory)/scripts"
    }

    public var referencesDirectory: String {
        "\(rootDirectory)/references"
    }

    public var assetsDirectory: String {
        "\(rootDirectory)/assets"
    }
}

public struct Chau7SkillProvider: Codable, Hashable, Identifiable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public static let claude = Chau7SkillProvider("claude")
    public static let codex = Chau7SkillProvider("codex")
    public static let gemini = Chau7SkillProvider("gemini")

    public static let known: [Chau7SkillProvider] = [.claude, .codex, .gemini]

    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var id: String {
        rawValue
    }

    public var description: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .gemini:
            return "Gemini"
        default:
            return rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum Chau7SkillInstallScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case user
    case repo

    public var id: String {
        rawValue
    }
}

public struct Chau7SkillInstallTarget: Codable, Equatable, Identifiable, Sendable {
    public var skillID: Chau7SkillID
    public var provider: Chau7SkillProvider
    public var scope: Chau7SkillInstallScope
    public var rootDirectory: String

    public init(
        skillID: Chau7SkillID,
        provider: Chau7SkillProvider,
        scope: Chau7SkillInstallScope,
        rootDirectory: String
    ) {
        self.skillID = skillID
        self.provider = provider
        self.scope = scope
        self.rootDirectory = rootDirectory.chau7SkillRemovingTrailingSlashes()
    }

    public var id: String {
        "\(provider.rawValue):\(scope.rawValue):\(skillID.rawValue)"
    }

    public var skillDirectory: String {
        "\(rootDirectory)/\(skillID.rawValue)"
    }

    public var skillMarkdownPath: String {
        "\(skillDirectory)/SKILL.md"
    }

    public var manifestPath: String {
        "\(skillDirectory)/.chau7-skill.json"
    }
}

public enum Chau7SkillInstallState: String, Codable, CaseIterable, Identifiable, Sendable {
    case missing
    case installed
    case stale
    case modified
    case broken
    case unmanagedConflict = "unmanaged_conflict"
    case unsupportedProvider = "unsupported_provider"
    case invalidSource = "invalid_source"

    public var id: String {
        rawValue
    }
}

public struct Chau7SkillFileHash: Codable, Hashable, Sendable, CustomStringConvertible {
    public var algorithm: String
    public var value: String

    public init(algorithm: String = "sha256", value: String) {
        self.algorithm = algorithm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            self.init(algorithm: String(parts[0]), value: String(parts[1]))
        } else {
            self.init(value: rawValue)
        }
    }

    public var rawValue: String {
        "\(algorithm):\(value)"
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Chau7SkillManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let managerName = "chau7"

    public var schemaVersion: Int
    public var managedBy: String
    public var skillID: Chau7SkillID
    public var skillVersion: String?
    public var provider: Chau7SkillProvider
    public var scope: Chau7SkillInstallScope
    public var sourcePath: String?
    public var sourceHash: Chau7SkillFileHash
    public var installedAt: String
    public var files: [String: Chau7SkillFileHash]

    public init(
        schemaVersion: Int = Chau7SkillManifest.currentSchemaVersion,
        managedBy: String = Chau7SkillManifest.managerName,
        skillID: Chau7SkillID,
        skillVersion: String? = nil,
        provider: Chau7SkillProvider,
        scope: Chau7SkillInstallScope,
        sourcePath: String? = nil,
        sourceHash: Chau7SkillFileHash,
        installedAt: String,
        files: [String: Chau7SkillFileHash]
    ) {
        self.schemaVersion = schemaVersion
        self.managedBy = managedBy
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.provider = provider
        self.scope = scope
        self.sourcePath = sourcePath
        self.sourceHash = sourceHash
        self.installedAt = installedAt
        self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case managedBy = "managed_by"
        case skillID = "skill_id"
        case skillVersion = "skill_version"
        case provider
        case scope
        case sourcePath = "source_path"
        case sourceHash = "source_hash"
        case installedAt = "installed_at"
        case files
    }
}

public struct Chau7SkillValidationIssue: Codable, Equatable, Identifiable, Sendable {
    public enum Severity: String, Codable, CaseIterable, Identifiable, Sendable {
        case warning
        case error

        public var id: String {
            rawValue
        }
    }

    public var severity: Severity
    public var code: String
    public var message: String
    public var path: String?

    public init(
        severity: Severity,
        code: String,
        message: String,
        path: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.path = path
    }

    public var id: String {
        [severity.rawValue, code, path ?? "", message].joined(separator: ":")
    }
}

public struct Chau7SkillInstallPlan: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Identifiable, Sendable {
        case install
        case update
        case noOp = "no_op"
        case refuse

        public var id: String {
            rawValue
        }
    }

    public var source: Chau7SkillSource?
    public var target: Chau7SkillInstallTarget
    public var state: Chau7SkillInstallState
    public var action: Action
    public var issues: [Chau7SkillValidationIssue]
    public var requiresConfirmation: Bool

    public init(
        source: Chau7SkillSource?,
        target: Chau7SkillInstallTarget,
        state: Chau7SkillInstallState,
        action: Action,
        issues: [Chau7SkillValidationIssue] = [],
        requiresConfirmation: Bool = false
    ) {
        self.source = source
        self.target = target
        self.state = state
        self.action = action
        self.issues = issues
        self.requiresConfirmation = requiresConfirmation
    }
}

private extension String {
    func chau7SkillRemovingTrailingSlashes() -> String {
        var value = self
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
