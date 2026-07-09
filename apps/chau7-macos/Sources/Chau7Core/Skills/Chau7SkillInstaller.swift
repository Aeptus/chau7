import Foundation

public struct Chau7SkillInstallerOptions: Codable, Equatable, Sendable {
    public var force: Bool
    public var installedAt: String
    public var temporaryDirectoryRoot: String?
    public var backupDirectoryRoot: String?

    public init(
        force: Bool = false,
        installedAt: String = Chau7SkillInstallerOptions.defaultInstalledAt(),
        temporaryDirectoryRoot: String? = nil,
        backupDirectoryRoot: String? = nil
    ) {
        self.force = force
        self.installedAt = installedAt
        self.temporaryDirectoryRoot = temporaryDirectoryRoot?.chau7SkillRemovingTrailingSlashes()
        self.backupDirectoryRoot = backupDirectoryRoot?.chau7SkillRemovingTrailingSlashes()
    }

    public static func defaultInstalledAt() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public struct Chau7SkillInstallResult: Codable, Equatable, Sendable {
    public var initialPlan: Chau7SkillInstallPlan
    public var finalState: Chau7SkillInstallState
    public var didMutate: Bool
    public var backupPath: String?
    public var manifest: Chau7SkillManifest?
    public var issues: [Chau7SkillValidationIssue]

    public init(
        initialPlan: Chau7SkillInstallPlan,
        finalState: Chau7SkillInstallState,
        didMutate: Bool,
        backupPath: String? = nil,
        manifest: Chau7SkillManifest? = nil,
        issues: [Chau7SkillValidationIssue] = []
    ) {
        self.initialPlan = initialPlan
        self.finalState = finalState
        self.didMutate = didMutate
        self.backupPath = backupPath
        self.manifest = manifest
        self.issues = issues
    }
}

public enum Chau7SkillInstaller {
    public static func install(
        source: Chau7SkillSource,
        target: Chau7SkillInstallTarget,
        providerDetection: Chau7SkillProviderDetection,
        options: Chau7SkillInstallerOptions = Chau7SkillInstallerOptions(),
        fileManager: FileManager = .default
    ) throws -> Chau7SkillInstallResult {
        let sourceIssues = Chau7SkillValidator.validate(source: source, fileManager: fileManager)
        let sourceFileHashes = hasBlockingIssue(sourceIssues)
            ? [:]
            : try Chau7SkillManifestHashing.managedFileHashes(
                rootDirectory: source.rootDirectory,
                fileManager: fileManager
            )
        let installed = try Chau7SkillInstallInspector.installedSnapshot(
            target: target,
            fileManager: fileManager
        )
        let initialPlan = Chau7SkillInstallPlanner.plan(
            source: source,
            target: target,
            sourceFileHashes: sourceFileHashes,
            sourceValidationIssues: sourceIssues,
            providerDetection: providerDetection,
            installed: installed
        )

        if initialPlan.action == .noOp {
            return Chau7SkillInstallResult(
                initialPlan: initialPlan,
                finalState: .installed,
                didMutate: false,
                manifest: installed.manifest
            )
        }

        if initialPlan.action == .refuse, !(options.force && initialPlan.state == .unmanagedConflict) {
            return Chau7SkillInstallResult(
                initialPlan: initialPlan,
                finalState: initialPlan.state,
                didMutate: false,
                manifest: installed.manifest,
                issues: initialPlan.issues
            )
        }

        let stagingContainer = try makeStagingContainer(options: options, fileManager: fileManager)
        defer { try? fileManager.removeItem(at: stagingContainer) }

        let stagedSkillURL = stagingContainer.appendingPathComponent(target.skillID.rawValue, isDirectory: true)
        try fileManager.copyItem(
            at: URL(fileURLWithPath: source.rootDirectory, isDirectory: true),
            to: stagedSkillURL
        )

        let manifest = Chau7SkillManifest(
            skillID: source.id,
            skillVersion: source.version,
            provider: target.provider,
            scope: target.scope,
            sourcePath: source.rootDirectory,
            sourceHash: Chau7SkillManifestHashing.sourceHash(for: sourceFileHashes),
            installedAt: options.installedAt,
            files: sourceFileHashes
        )
        try writeManifest(manifest, toSkillDirectory: stagedSkillURL)

        let stagedIssues = Chau7SkillValidator.validate(rootDirectory: stagedSkillURL.path, fileManager: fileManager)
        if hasBlockingIssue(stagedIssues) {
            return Chau7SkillInstallResult(
                initialPlan: initialPlan,
                finalState: .invalidSource,
                didMutate: false,
                manifest: manifest,
                issues: stagedIssues
            )
        }

        let backupPath = try backupExistingTargetIfNeeded(
            target: target,
            shouldBackup: installed.targetExists,
            options: options,
            fileManager: fileManager
        )

        let targetURL = URL(fileURLWithPath: target.skillDirectory, isDirectory: true)
        try replaceTargetWithRollback(
            stagedSkillURL: stagedSkillURL,
            targetURL: targetURL,
            fileManager: fileManager
        )

        let finalSnapshot = try Chau7SkillInstallInspector.installedSnapshot(
            target: target,
            fileManager: fileManager
        )
        let finalPlan = Chau7SkillInstallPlanner.plan(
            source: source,
            target: target,
            sourceFileHashes: sourceFileHashes,
            sourceValidationIssues: [],
            providerDetection: providerDetection,
            installed: finalSnapshot
        )

        return Chau7SkillInstallResult(
            initialPlan: initialPlan,
            finalState: finalPlan.state,
            didMutate: true,
            backupPath: backupPath,
            manifest: manifest,
            issues: finalPlan.issues
        )
    }

    private static func writeManifest(
        _ manifest: Chau7SkillManifest,
        toSkillDirectory skillDirectoryURL: URL
    ) throws {
        let manifestURL = skillDirectoryURL.appendingPathComponent(".chau7-skill.json")
        try Chau7SkillManifestHashing.manifestData(manifest).write(to: manifestURL, options: [.atomic])
    }

    private static func makeStagingContainer(
        options: Chau7SkillInstallerOptions,
        fileManager: FileManager
    ) throws -> URL {
        let root = URL(
            fileURLWithPath: options.temporaryDirectoryRoot ?? fileManager.temporaryDirectory.path,
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let container = root.appendingPathComponent("chau7-skill-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    private static func backupExistingTargetIfNeeded(
        target: Chau7SkillInstallTarget,
        shouldBackup: Bool,
        options: Chau7SkillInstallerOptions,
        fileManager: FileManager
    ) throws -> String? {
        guard shouldBackup else { return nil }

        let backupRoot = options.backupDirectoryRoot
            ?? "\(target.rootDirectory)/.chau7-backups"
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: backupRoot, isDirectory: true),
            withIntermediateDirectories: true
        )

        let baseName = "\(target.skillID.rawValue)-\(safePathComponent(options.installedAt))"
        var candidate = URL(fileURLWithPath: backupRoot, isDirectory: true)
            .appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = URL(fileURLWithPath: backupRoot, isDirectory: true)
                .appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        try fileManager.copyItem(
            at: URL(fileURLWithPath: target.skillDirectory, isDirectory: true),
            to: candidate
        )
        return candidate.path
    }

    private static func replaceTargetWithRollback(
        stagedSkillURL: URL,
        targetURL: URL,
        fileManager: FileManager
    ) throws {
        let parentURL = targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        var rollbackURL: URL?
        if fileManager.fileExists(atPath: targetURL.path) {
            let moveAsideURL = parentURL
                .appendingPathComponent(".chau7-skill-replace-\(UUID().uuidString)", isDirectory: true)
            try fileManager.moveItem(at: targetURL, to: moveAsideURL)
            rollbackURL = moveAsideURL
        }

        do {
            try fileManager.moveItem(at: stagedSkillURL, to: targetURL)
            if let rollbackURL {
                try? fileManager.removeItem(at: rollbackURL)
            }
        } catch {
            if let rollbackURL {
                try? restoreRollbackTarget(
                    rollbackURL: rollbackURL,
                    targetURL: targetURL,
                    fileManager: fileManager
                )
            }
            throw error
        }
    }

    private static func restoreRollbackTarget(
        rollbackURL: URL,
        targetURL: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        if fileManager.fileExists(atPath: rollbackURL.path) {
            try fileManager.moveItem(at: rollbackURL, to: targetURL)
        }
    }

    private static func hasBlockingIssue(_ issues: [Chau7SkillValidationIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    private static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(
            value.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? Character(scalar) : "-"
            }
        )
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
