import Chau7Core
import Foundation

public struct Chau7CLIResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct Chau7CLIRunner {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let currentDirectory: String

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    public func run(arguments: [String]) -> Chau7CLIResult {
        guard let command = arguments.first else {
            return success(usage)
        }

        switch command {
        case "skills":
            return runSkills(Array(arguments.dropFirst()))
        case "-h", "--help", "help":
            return success(usage)
        case "--version", "version":
            return success("Chau7CLI skills phase 9\n")
        default:
            return failure("Unknown command: \(command)\n\n\(usage)")
        }
    }

    private func runSkills(_ arguments: [String]) -> Chau7CLIResult {
        guard let subcommand = arguments.first else {
            return success(skillsUsage)
        }

        let remaining = Array(arguments.dropFirst())
        switch subcommand {
        case "list":
            return runSkillsList(remaining)
        case "doctor":
            return runSkillsDoctor(remaining)
        case "install":
            return runSkillsInstall(remaining, mode: .install)
        case "update":
            return runSkillsInstall(remaining, mode: .update)
        case "sync":
            return runSkillsInstall(remaining, mode: .sync)
        case "uninstall":
            return runSkillsUninstall(remaining)
        case "validate":
            return runSkillsValidate(remaining)
        case "diff":
            return runSkillsDiff(remaining)
        case "-h", "--help", "help":
            return success(skillsUsage)
        default:
            return failure("Unknown skills command: \(subcommand)\n\n\(skillsUsage)")
        }
    }

    private func runSkillsList(_ arguments: [String]) -> Chau7CLIResult {
        do {
            let options = try parseOptions(arguments)
            let sources = try selectedSources(options)
            let width = skillColumnWidth(sources.map(\.id.rawValue))
            var lines = ["Chau7 Skills", ""]
            for source in sources {
                let issues = Chau7SkillValidator.validate(source: source, fileManager: fileManager)
                lines.append("- \(padded(source.id.rawValue, width: width)) \(sourceLabel(source)) \(sourceStatus(for: issues))")
            }
            return success(lines.joined(separator: "\n") + "\n")
        } catch {
            return failure(error.localizedDescription + "\n")
        }
    }

    private func runSkillsDoctor(_ arguments: [String]) -> Chau7CLIResult {
        do {
            let options = try parseOptions(arguments)
            let sources = try selectedSources(options)
            let width = skillColumnWidth(sources.map(\.id.rawValue))
            var lines = ["Chau7 Skills", "", "Sources:"]

            for source in sources {
                let issues = Chau7SkillValidator.validate(source: source, fileManager: fileManager)
                lines.append("- \(padded(source.id.rawValue, width: width)) \(sourceLabel(source)) \(sourceStatus(for: issues))")
            }

            for provider in options.providers {
                lines.append("")
                lines.append(targetGroupTitle(provider: provider, options: options))
                for source in sources {
                    let plan = try installPlan(source: source, provider: provider, options: options)
                    lines.append("- \(padded(source.id.rawValue, width: width)) \(displayState(plan.state))")
                }
            }

            return success(lines.joined(separator: "\n") + "\n")
        } catch {
            return failure(error.localizedDescription + "\n")
        }
    }

    private func runSkillsValidate(_ arguments: [String]) -> Chau7CLIResult {
        do {
            let options = try parseOptions(arguments, allowPathSubject: true)
            let sources: [Chau7SkillSource]
            if let subject = options.subject, subject != "all", subject.contains("/") {
                let root = resolvePath(subject)
                sources = [
                    Chau7SkillSource(
                        id: Chau7SkillID(URL(fileURLWithPath: root).lastPathComponent),
                        kind: .external,
                        rootDirectory: root
                    )
                ]
            } else {
                sources = try selectedSources(options)
            }

            let width = skillColumnWidth(sources.map(\.id.rawValue))
            var lines = ["Chau7 Skills Validate", ""]
            var hasErrors = false
            for source in sources {
                let issues = Chau7SkillValidator.validate(source: source, fileManager: fileManager)
                hasErrors = hasErrors || hasBlockingIssue(issues)
                lines.append("- \(padded(source.id.rawValue, width: width)) \(sourceStatus(for: issues))")
                for issue in issues {
                    lines.append("  \(issue.severity.rawValue): \(issue.code) \(issue.path ?? "")")
                }
            }
            return Chau7CLIResult(exitCode: hasErrors ? 1 : 0, stdout: lines.joined(separator: "\n") + "\n")
        } catch {
            return failure(error.localizedDescription + "\n")
        }
    }

    private enum InstallMode {
        case install
        case update
        case sync
    }

    private func runSkillsInstall(_ arguments: [String], mode: InstallMode) -> Chau7CLIResult {
        do {
            let options = try parseOptions(arguments)
            let sources = try selectedSources(options)
            let title: String
            switch mode {
            case .install:
                title = "Chau7 Skills Install"
            case .update:
                title = "Chau7 Skills Update"
            case .sync:
                title = "Chau7 Skills Sync"
            }

            var lines = [title, ""]
            var failed = false
            for provider in options.providers {
                lines.append(targetGroupTitle(provider: provider, options: options))
                for source in sources {
                    let plan = try installPlan(source: source, provider: provider, options: options)
                    let result: Chau7SkillInstallResult?
                    switch mode {
                    case .install:
                        result = try runInstaller(source: source, provider: provider, options: options)
                    case .update:
                        result = plan.state == .stale
                            ? try runInstaller(source: source, provider: provider, options: options)
                            : nil
                    case .sync:
                        result = [.missing, .stale, .unmanagedConflict].contains(plan.state)
                            ? try runInstaller(source: source, provider: provider, options: options)
                            : nil
                    }

                    let finalState = result?.finalState ?? plan.state
                    failed = failed || shouldFailCommand(finalState)
                    lines.append("- \(source.id.rawValue) \(displayState(finalState))")
                    if let backupPath = result?.backupPath {
                        lines.append("  backup: \(backupPath)")
                    }
                    for issue in result?.issues ?? plan.issues {
                        lines.append("  \(issue.severity.rawValue): \(issue.code) \(issue.path ?? "")")
                    }
                }
                lines.append("")
            }

            return Chau7CLIResult(exitCode: failed ? 1 : 0, stdout: lines.joined(separator: "\n"))
        } catch {
            return failure(error.localizedDescription + "\n")
        }
    }

    private func runSkillsUninstall(_ arguments: [String]) -> Chau7CLIResult {
        do {
            let options = try parseOptions(arguments)
            let sources = try selectedSources(options)
            var lines = ["Chau7 Skills Uninstall", ""]
            var failed = false

            for provider in options.providers {
                lines.append(targetGroupTitle(provider: provider, options: options))
                for source in sources {
                    let target = target(for: source.id, provider: provider, options: options)
                    let plan = try installPlan(source: source, provider: provider, options: options)
                    let final: String
                    if plan.state == .missing {
                        final = "missing"
                    } else if canUninstall(plan.state, force: options.force) {
                        try fileManager.removeItem(atPath: target.skillDirectory)
                        final = "uninstalled"
                    } else {
                        failed = true
                        final = "refused \(displayState(plan.state))"
                    }
                    lines.append("- \(source.id.rawValue) \(final)")
                }
                lines.append("")
            }

            return Chau7CLIResult(exitCode: failed ? 1 : 0, stdout: lines.joined(separator: "\n"))
        } catch {
            return failure(error.localizedDescription + "\n")
        }
    }

    private func runSkillsDiff(_ arguments: [String]) -> Chau7CLIResult {
        do {
            let options = try parseOptions(arguments)
            let sources = try selectedSources(options)
            var lines = ["Chau7 Skills Diff", ""]
            var failed = false

            for provider in options.providers {
                lines.append(targetGroupTitle(provider: provider, options: options))
                for source in sources {
                    let target = target(for: source.id, provider: provider, options: options)
                    let plan = try installPlan(source: source, provider: provider, options: options)
                    let snapshot = try Chau7SkillInstallInspector.installedSnapshot(target: target, fileManager: fileManager)
                    let sourceHashes = try sourceFileHashes(source)
                    let sourceHash = Chau7SkillManifestHashing.sourceHash(for: sourceHashes)
                    lines.append("- \(source.id.rawValue) \(displayState(plan.state))")
                    lines.append("  source_hash: \(sourceHash.rawValue)")
                    if let manifest = snapshot.manifest {
                        lines.append("  installed_source_hash: \(manifest.sourceHash.rawValue)")
                        lines.append("  installed_files: \(snapshot.fileHashes == manifest.files ? "unchanged" : "modified")")
                    } else {
                        lines.append("  installed_source_hash: none")
                    }
                    failed = failed || [.modified, .unmanagedConflict, .broken, .invalidSource, .unsupportedProvider].contains(plan.state)
                }
                lines.append("")
            }

            return Chau7CLIResult(exitCode: failed ? 1 : 0, stdout: lines.joined(separator: "\n"))
        } catch {
            return failure(error.localizedDescription + "\n")
        }
    }

    private struct SkillsOptions {
        var sourceRoot: String
        var homeDirectory: String
        var repositoryRoot: String
        var scope: Chau7SkillInstallScope
        var providers: [Chau7SkillProvider]
        var subject: String?
        var force: Bool
    }

    private func parseOptions(_ arguments: [String], allowPathSubject: Bool = false) throws -> SkillsOptions {
        var explicitSourceRoot: String?
        var homeDirectory = environment["CHAU7_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        var explicitRepositoryRoot = environment["CHAU7_REPO_ROOT"]
        var scope: Chau7SkillInstallScope = .user
        var providers: [Chau7SkillProvider] = [.claude, .codex]
        var subject: String?
        var force = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--source-root":
                index += 1
                guard index < arguments.count else { throw CLIError("Missing value for --source-root") }
                explicitSourceRoot = arguments[index]
            case "--home":
                index += 1
                guard index < arguments.count else { throw CLIError("Missing value for --home") }
                homeDirectory = arguments[index]
            case "--repo":
                index += 1
                guard index < arguments.count else { throw CLIError("Missing value for --repo") }
                explicitRepositoryRoot = arguments[index]
            case "--scope":
                index += 1
                guard index < arguments.count else { throw CLIError("Missing value for --scope") }
                scope = try parseScope(arguments[index])
            case "--provider":
                index += 1
                guard index < arguments.count else { throw CLIError("Missing value for --provider") }
                providers = try parseProviders(arguments[index])
            case "--force":
                force = true
            default:
                if argument.hasPrefix("--") {
                    throw CLIError("Unknown option: \(argument)")
                }
                if subject == nil {
                    subject = argument
                } else if allowPathSubject {
                    subject = [subject, argument].compactMap { $0 }.joined(separator: " ")
                } else {
                    throw CLIError("Unexpected argument: \(argument)")
                }
            }
            index += 1
        }

        let resolvedHome = resolvePath(homeDirectory)
        let repositoryRoot = explicitRepositoryRoot.map(resolvePath) ?? repositoryRoot(from: resolvePath(currentDirectory))
        let sourceRoot = explicitSourceRoot
            ?? (scope == .repo
                ? "\(repositoryRoot)/.chau7/skills"
                : environment["CHAU7_SKILLS_SOURCE_ROOT"] ?? defaultSourceRoot())

        return SkillsOptions(
            sourceRoot: resolvePath(sourceRoot),
            homeDirectory: resolvedHome,
            repositoryRoot: repositoryRoot,
            scope: scope,
            providers: providers,
            subject: subject,
            force: force
        )
    }

    private func parseProviders(_ value: String) throws -> [Chau7SkillProvider] {
        switch value.lowercased() {
        case "all":
            return [.claude, .codex]
        case "claude":
            return [.claude]
        case "codex":
            return [.codex]
        default:
            throw CLIError("Unsupported provider: \(value)")
        }
    }

    private func parseScope(_ value: String) throws -> Chau7SkillInstallScope {
        switch value.lowercased() {
        case "user":
            return .user
        case "repo":
            return .repo
        default:
            throw CLIError("Unsupported scope: \(value)")
        }
    }

    private func selectedSources(_ options: SkillsOptions) throws -> [Chau7SkillSource] {
        let ids: [String]
        if let subject = options.subject, subject != "all" {
            ids = [subject]
        } else {
            ids = try availableSkillIDs(sourceRoot: options.sourceRoot)
        }
        let sourceKind: Chau7SkillSource.Kind = options.scope == .repo ? .repo : .bundled
        let sourceVersion: String? = options.scope == .repo ? nil : "1.0.0"
        return ids.map {
            Chau7SkillSource(
                id: Chau7SkillID($0),
                kind: sourceKind,
                rootDirectory: URL(fileURLWithPath: options.sourceRoot, isDirectory: true)
                    .appendingPathComponent($0, isDirectory: true)
                    .path,
                version: sourceVersion
            )
        }
    }

    private func availableSkillIDs(sourceRoot: String) throws -> [String] {
        let rootURL = URL(fileURLWithPath: sourceRoot, isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let ids = contents.compactMap { url -> String? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            guard fileManager.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else { return nil }
            return url.lastPathComponent
        }
        let preferred = ["chau7-magi", "chau7-mcp"].filter { ids.contains($0) }
        return preferred + ids.sorted().filter { !preferred.contains($0) }
    }

    private func installPlan(
        source: Chau7SkillSource,
        provider: Chau7SkillProvider,
        options: SkillsOptions
    ) throws -> Chau7SkillInstallPlan {
        let sourceIssues = Chau7SkillValidator.validate(source: source, fileManager: fileManager)
        let hashes = hasBlockingIssue(sourceIssues) ? [:] : try sourceFileHashes(source)
        let target = target(for: source.id, provider: provider, options: options)
        let snapshot = try Chau7SkillInstallInspector.installedSnapshot(target: target, fileManager: fileManager)
        return Chau7SkillInstallPlanner.plan(
            source: source,
            target: target,
            sourceFileHashes: hashes,
            sourceValidationIssues: sourceIssues,
            providerDetection: providerDetection(provider: provider, options: options),
            installed: snapshot
        )
    }

    private func runInstaller(
        source: Chau7SkillSource,
        provider: Chau7SkillProvider,
        options: SkillsOptions
    ) throws -> Chau7SkillInstallResult {
        try Chau7SkillInstaller.install(
            source: source,
            target: target(for: source.id, provider: provider, options: options),
            providerDetection: providerDetection(provider: provider, options: options),
            options: Chau7SkillInstallerOptions(
                force: options.force,
                temporaryDirectoryRoot: "\(skillStateRoot(options))/.chau7/tmp/skills",
                backupDirectoryRoot: "\(skillStateRoot(options))/.chau7/backups/skills"
            ),
            fileManager: fileManager
        )
    }

    private func target(
        for skillID: Chau7SkillID,
        provider: Chau7SkillProvider,
        options: SkillsOptions
    ) -> Chau7SkillInstallTarget {
        switch provider {
        case .claude:
            if options.scope == .repo {
                return ClaudeSkillInstallTargetResolver.repoTarget(
                    skillID: skillID,
                    repositoryRoot: options.repositoryRoot
                )
            }
            return ClaudeSkillInstallTargetResolver.userTarget(
                skillID: skillID,
                homeDirectory: options.homeDirectory
            )
        case .codex:
            if options.scope == .repo {
                return CodexSkillInstallTargetResolver.repoTarget(
                    skillID: skillID,
                    repositoryRoot: options.repositoryRoot
                )
            }
            return CodexSkillInstallTargetResolver.userTarget(
                skillID: skillID,
                homeDirectory: options.homeDirectory
            )
        default:
            let root = options.scope == .repo ? options.repositoryRoot : options.homeDirectory
            return Chau7SkillInstallTarget(
                skillID: skillID,
                provider: provider,
                scope: options.scope,
                rootDirectory: "\(root)/.\(provider.rawValue)/skills"
            )
        }
    }

    private func providerDetection(
        provider: Chau7SkillProvider,
        options: SkillsOptions
    ) -> Chau7SkillProviderDetection {
        let path = environment["PATH"] ?? ""
        var reasons: [Chau7SkillProviderDetectionReason] = []
        let providerRoot = providerRoot(provider: provider, options: options)
        if directoryExists(atPath: providerRoot) {
            reasons.append(.providerRootExists)
        }
        if executableExists(named: provider.rawValue, environmentPATH: path) {
            reasons.append(.providerCLIExists)
        }
        reasons.append(.explicitlyRequested)

        return Chau7SkillProviderDetection(
            provider: provider,
            isAvailable: true,
            reasons: reasons,
            providerRoot: providerRoot,
            executableName: provider.rawValue
        )
    }

    private func sourceFileHashes(_ source: Chau7SkillSource) throws -> [String: Chau7SkillFileHash] {
        try Chau7SkillManifestHashing.managedFileHashes(
            rootDirectory: source.rootDirectory,
            fileManager: fileManager
        )
    }

    private func defaultSourceRoot() -> String {
        if let bundleRoot = Bundle.main.resourceURL?.appendingPathComponent("Skills").path,
           fileManager.fileExists(atPath: bundleRoot) {
            return bundleRoot
        }

        var current = URL(fileURLWithPath: currentDirectory, isDirectory: true).standardizedFileURL
        while current.path != "/" {
            let candidates = [
                current.appendingPathComponent("Resources/Skills", isDirectory: true),
                current.appendingPathComponent("apps/chau7-macos/Resources/Skills", isDirectory: true)
            ]
            for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            current.deleteLastPathComponent()
        }

        return URL(fileURLWithPath: currentDirectory, isDirectory: true)
            .appendingPathComponent("Resources/Skills", isDirectory: true)
            .path
    }

    private func resolvePath(_ path: String) -> String {
        let expanded = expandTilde(path)
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return URL(fileURLWithPath: currentDirectory, isDirectory: true)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }

    private func repositoryRoot(from startPath: String) -> String {
        let normalizedStart = (startPath as NSString).standardizingPath
        var current = normalizedStart
        while true {
            if fileManager.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || current == "/" {
                return normalizedStart
            }
            current = parent
        }
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return home
        }
        return home + String(path.dropFirst())
    }

    private func skillStateRoot(_ options: SkillsOptions) -> String {
        options.scope == .repo ? options.repositoryRoot : options.homeDirectory
    }

    private func providerRoot(provider: Chau7SkillProvider, options: SkillsOptions) -> String {
        "\(skillStateRoot(options))/.\(provider.rawValue)"
    }

    private func targetGroupTitle(provider: Chau7SkillProvider, options: SkillsOptions) -> String {
        "\(provider.displayName) \(options.scope.rawValue):"
    }

    private func sourceLabel(_ source: Chau7SkillSource) -> String {
        source.kind.rawValue
    }

    private func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func executableExists(named executableName: String, environmentPATH: String) -> Bool {
        for directory in environmentPATH.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executableName)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }

    private func sourceStatus(for issues: [Chau7SkillValidationIssue]) -> String {
        hasBlockingIssue(issues) ? "invalid" : "valid"
    }

    private func hasBlockingIssue(_ issues: [Chau7SkillValidationIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    private func shouldFailCommand(_ state: Chau7SkillInstallState) -> Bool {
        [.modified, .unmanagedConflict, .unsupportedProvider, .invalidSource, .broken].contains(state)
    }

    private func canUninstall(_ state: Chau7SkillInstallState, force: Bool) -> Bool {
        switch state {
        case .installed, .stale:
            return true
        case .modified, .unmanagedConflict, .broken:
            return force
        case .missing, .unsupportedProvider, .invalidSource:
            return false
        }
    }

    private func displayState(_ state: Chau7SkillInstallState) -> String {
        switch state {
        case .missing:
            return "missing"
        case .installed:
            return "installed"
        case .stale:
            return "stale"
        case .modified:
            return "modified"
        case .broken:
            return "broken"
        case .unmanagedConflict:
            return "unmanaged conflict"
        case .unsupportedProvider:
            return "unsupported provider"
        case .invalidSource:
            return "invalid source"
        }
    }

    private func skillColumnWidth(_ ids: [String]) -> Int {
        max(0, ids.map(\.count).max() ?? 0)
    }

    private func padded(_ value: String, width: Int) -> String {
        value + String(repeating: " ", count: max(0, width - value.count))
    }

    private func success(_ stdout: String) -> Chau7CLIResult {
        Chau7CLIResult(exitCode: 0, stdout: stdout)
    }

    private func failure(_ stderr: String) -> Chau7CLIResult {
        Chau7CLIResult(exitCode: 1, stderr: stderr)
    }

    private var usage: String {
        """
        Chau7CLI

        Usage:
          chau7-cli skills <command>

        \(skillsUsage)
        """
    }

    private var skillsUsage: String {
        """
        Skills commands:
          chau7-cli skills list [--scope user|repo] [--source-root PATH] [--repo PATH]
          chau7-cli skills doctor [--scope user|repo] [--source-root PATH] [--home PATH] [--repo PATH]
          chau7-cli skills install [skill-id|all] [--scope user|repo] [--provider claude|codex|all] [--home PATH] [--repo PATH] [--force]
          chau7-cli skills update [skill-id|all] [--scope user|repo] [--provider claude|codex|all] [--home PATH] [--repo PATH]
          chau7-cli skills uninstall [skill-id|all] [--scope user|repo] [--provider claude|codex|all] [--home PATH] [--repo PATH] [--force]
          chau7-cli skills validate [skill-id|all|PATH] [--scope user|repo] [--source-root PATH] [--repo PATH]
          chau7-cli skills diff [skill-id|all] [--scope user|repo] [--provider claude|codex|all] [--home PATH] [--repo PATH]
          chau7-cli skills sync [skill-id|all] [--scope user|repo] [--provider claude|codex|all] [--home PATH] [--repo PATH] [--force]

        Repo scope defaults:
          source: <repo>/.chau7/skills/<skill-id>
          targets: <repo>/.claude/skills/<skill-id>, <repo>/.codex/skills/<skill-id>
        """
    }
}

private struct CLIError: LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
