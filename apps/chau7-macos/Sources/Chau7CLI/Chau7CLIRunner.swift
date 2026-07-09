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
            return success("Chau7CLI skills phase 8\n")
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
                lines.append("- \(padded(source.id.rawValue, width: width)) bundled \(sourceStatus(for: issues))")
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
                lines.append("- \(padded(source.id.rawValue, width: width)) bundled \(sourceStatus(for: issues))")
            }

            for provider in options.providers {
                lines.append("")
                lines.append("\(provider.displayName) user:")
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
                let root = expandTilde(subject)
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
                lines.append("\(provider.displayName) user:")
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
                lines.append("\(provider.displayName) user:")
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
                lines.append("\(provider.displayName) user:")
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
        var providers: [Chau7SkillProvider]
        var subject: String?
        var force: Bool
    }

    private func parseOptions(_ arguments: [String], allowPathSubject: Bool = false) throws -> SkillsOptions {
        var sourceRoot = environment["CHAU7_SKILLS_SOURCE_ROOT"] ?? defaultSourceRoot()
        var homeDirectory = environment["CHAU7_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
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
                sourceRoot = arguments[index]
            case "--home":
                index += 1
                guard index < arguments.count else { throw CLIError("Missing value for --home") }
                homeDirectory = arguments[index]
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

        return SkillsOptions(
            sourceRoot: expandTilde(sourceRoot),
            homeDirectory: expandTilde(homeDirectory),
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

    private func selectedSources(_ options: SkillsOptions) throws -> [Chau7SkillSource] {
        let ids: [String]
        if let subject = options.subject, subject != "all" {
            ids = [subject]
        } else {
            ids = try availableSkillIDs(sourceRoot: options.sourceRoot)
        }
        return ids.map {
            Chau7SkillSource(
                id: Chau7SkillID($0),
                kind: .bundled,
                rootDirectory: URL(fileURLWithPath: options.sourceRoot, isDirectory: true)
                    .appendingPathComponent($0, isDirectory: true)
                    .path,
                version: "1.0.0"
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
            providerDetection: providerDetection(provider: provider, homeDirectory: options.homeDirectory),
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
            providerDetection: providerDetection(provider: provider, homeDirectory: options.homeDirectory),
            options: Chau7SkillInstallerOptions(
                force: options.force,
                temporaryDirectoryRoot: "\(options.homeDirectory)/.chau7/tmp/skills",
                backupDirectoryRoot: "\(options.homeDirectory)/.chau7/backups/skills"
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
            return ClaudeSkillInstallTargetResolver.userTarget(skillID: skillID, homeDirectory: options.homeDirectory)
        case .codex:
            return CodexSkillInstallTargetResolver.userTarget(skillID: skillID, homeDirectory: options.homeDirectory)
        default:
            return Chau7SkillInstallTarget(
                skillID: skillID,
                provider: provider,
                scope: .user,
                rootDirectory: "\(options.homeDirectory)/.\(provider.rawValue)/skills"
            )
        }
    }

    private func providerDetection(provider: Chau7SkillProvider, homeDirectory: String) -> Chau7SkillProviderDetection {
        let path = environment["PATH"] ?? ""
        switch provider {
        case .claude:
            return ClaudeSkillInstallTargetResolver.detect(
                homeDirectory: homeDirectory,
                environmentPATH: path,
                explicitlyRequested: true,
                fileManager: fileManager
            )
        case .codex:
            return CodexSkillInstallTargetResolver.detect(
                homeDirectory: homeDirectory,
                environmentPATH: path,
                explicitlyRequested: true,
                fileManager: fileManager
            )
        default:
            return Chau7SkillProviderDetection(
                provider: provider,
                isAvailable: true,
                reasons: [.explicitlyRequested],
                providerRoot: "\(homeDirectory)/.\(provider.rawValue)",
                executableName: provider.rawValue
            )
        }
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

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return home
        }
        return home + String(path.dropFirst())
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
          chau7-cli skills list [--source-root PATH]
          chau7-cli skills doctor [--source-root PATH] [--home PATH]
          chau7-cli skills install [skill-id|all] [--provider claude|codex|all] [--home PATH] [--force]
          chau7-cli skills update [skill-id|all] [--provider claude|codex|all] [--home PATH]
          chau7-cli skills uninstall [skill-id|all] [--provider claude|codex|all] [--home PATH] [--force]
          chau7-cli skills validate [skill-id|all|PATH] [--source-root PATH]
          chau7-cli skills diff [skill-id|all] [--provider claude|codex|all] [--home PATH]
          chau7-cli skills sync [skill-id|all] [--provider claude|codex|all] [--home PATH] [--force]
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
