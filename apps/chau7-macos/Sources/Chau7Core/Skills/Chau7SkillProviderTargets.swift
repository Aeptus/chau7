import Foundation

public enum Chau7SkillProviderDetectionReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case providerRootExists = "provider_root_exists"
    case providerCLIExists = "provider_cli_exists"
    case explicitlyRequested = "explicitly_requested"

    public var id: String {
        rawValue
    }
}

public struct Chau7SkillProviderDetection: Codable, Equatable, Sendable {
    public var provider: Chau7SkillProvider
    public var isAvailable: Bool
    public var reasons: [Chau7SkillProviderDetectionReason]
    public var providerRoot: String
    public var executableName: String

    public init(
        provider: Chau7SkillProvider,
        isAvailable: Bool,
        reasons: [Chau7SkillProviderDetectionReason],
        providerRoot: String,
        executableName: String
    ) {
        self.provider = provider
        self.isAvailable = isAvailable
        self.reasons = reasons
        self.providerRoot = providerRoot.chau7SkillRemovingTrailingSlashes()
        self.executableName = executableName
    }
}

public enum ClaudeSkillInstallTargetResolver {
    public static func userRoot(homeDirectory: String) -> String {
        Chau7SkillProviderTargetResolving.userRoot(
            homeDirectory: homeDirectory,
            providerDirectoryName: ".claude"
        )
    }

    public static func repoRoot(repositoryRoot: String) -> String {
        Chau7SkillProviderTargetResolving.repoRoot(
            repositoryRoot: repositoryRoot,
            providerDirectoryName: ".claude"
        )
    }

    public static func userTarget(skillID: Chau7SkillID, homeDirectory: String) -> Chau7SkillInstallTarget {
        Chau7SkillInstallTarget(
            skillID: skillID,
            provider: .claude,
            scope: .user,
            rootDirectory: userRoot(homeDirectory: homeDirectory)
        )
    }

    public static func repoTarget(skillID: Chau7SkillID, repositoryRoot: String) -> Chau7SkillInstallTarget {
        Chau7SkillInstallTarget(
            skillID: skillID,
            provider: .claude,
            scope: .repo,
            rootDirectory: repoRoot(repositoryRoot: repositoryRoot)
        )
    }

    public static func detect(
        homeDirectory: String,
        environmentPATH: String = ShellLaunchEnvironment.preferredPATH(),
        explicitlyRequested: Bool = false,
        fileManager: FileManager = .default
    ) -> Chau7SkillProviderDetection {
        Chau7SkillProviderTargetResolving.detect(
            provider: .claude,
            providerRoot: "\(homeDirectory.chau7SkillRemovingTrailingSlashes())/.claude",
            executableName: "claude",
            environmentPATH: environmentPATH,
            explicitlyRequested: explicitlyRequested,
            fileManager: fileManager
        )
    }
}

public enum CodexSkillInstallTargetResolver {
    public static func userRoot(homeDirectory: String) -> String {
        Chau7SkillProviderTargetResolving.userRoot(
            homeDirectory: homeDirectory,
            providerDirectoryName: ".codex"
        )
    }

    public static func repoRoot(repositoryRoot: String) -> String {
        Chau7SkillProviderTargetResolving.repoRoot(
            repositoryRoot: repositoryRoot,
            providerDirectoryName: ".codex"
        )
    }

    public static func userTarget(skillID: Chau7SkillID, homeDirectory: String) -> Chau7SkillInstallTarget {
        Chau7SkillInstallTarget(
            skillID: skillID,
            provider: .codex,
            scope: .user,
            rootDirectory: userRoot(homeDirectory: homeDirectory)
        )
    }

    public static func repoTarget(skillID: Chau7SkillID, repositoryRoot: String) -> Chau7SkillInstallTarget {
        Chau7SkillInstallTarget(
            skillID: skillID,
            provider: .codex,
            scope: .repo,
            rootDirectory: repoRoot(repositoryRoot: repositoryRoot)
        )
    }

    public static func detect(
        homeDirectory: String,
        environmentPATH: String = ShellLaunchEnvironment.preferredPATH(),
        explicitlyRequested: Bool = false,
        fileManager: FileManager = .default
    ) -> Chau7SkillProviderDetection {
        Chau7SkillProviderTargetResolving.detect(
            provider: .codex,
            providerRoot: "\(homeDirectory.chau7SkillRemovingTrailingSlashes())/.codex",
            executableName: "codex",
            environmentPATH: environmentPATH,
            explicitlyRequested: explicitlyRequested,
            fileManager: fileManager
        )
    }
}

private enum Chau7SkillProviderTargetResolving {
    static func userRoot(homeDirectory: String, providerDirectoryName: String) -> String {
        "\(homeDirectory.chau7SkillRemovingTrailingSlashes())/\(providerDirectoryName)/skills"
    }

    static func repoRoot(repositoryRoot: String, providerDirectoryName: String) -> String {
        "\(repositoryRoot.chau7SkillRemovingTrailingSlashes())/\(providerDirectoryName)/skills"
    }

    static func detect(
        provider: Chau7SkillProvider,
        providerRoot: String,
        executableName: String,
        environmentPATH: String,
        explicitlyRequested: Bool,
        fileManager: FileManager
    ) -> Chau7SkillProviderDetection {
        var reasons: [Chau7SkillProviderDetectionReason] = []
        let normalizedProviderRoot = providerRoot.chau7SkillRemovingTrailingSlashes()

        if directoryExists(atPath: normalizedProviderRoot, fileManager: fileManager) {
            reasons.append(.providerRootExists)
        }
        if executableExists(named: executableName, environmentPATH: environmentPATH, fileManager: fileManager) {
            reasons.append(.providerCLIExists)
        }
        if explicitlyRequested {
            reasons.append(.explicitlyRequested)
        }

        return Chau7SkillProviderDetection(
            provider: provider,
            isAvailable: !reasons.isEmpty,
            reasons: reasons,
            providerRoot: normalizedProviderRoot,
            executableName: executableName
        )
    }

    private static func directoryExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func executableExists(
        named executableName: String,
        environmentPATH: String,
        fileManager: FileManager
    ) -> Bool {
        for rawEntry in environmentPATH.split(separator: ":", omittingEmptySubsequences: false) {
            let entry = String(rawEntry).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            let path = URL(fileURLWithPath: entry).appendingPathComponent(executableName).path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            if fileManager.isExecutableFile(atPath: path) {
                return true
            }
        }
        return false
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
