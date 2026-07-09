import Foundation

public struct Chau7SkillInstalledSnapshot: Codable, Equatable, Sendable {
    public var targetExists: Bool
    public var manifest: Chau7SkillManifest?
    public var fileHashes: [String: Chau7SkillFileHash]
    public var issues: [Chau7SkillValidationIssue]

    public init(
        targetExists: Bool,
        manifest: Chau7SkillManifest? = nil,
        fileHashes: [String: Chau7SkillFileHash] = [:],
        issues: [Chau7SkillValidationIssue] = []
    ) {
        self.targetExists = targetExists
        self.manifest = manifest
        self.fileHashes = fileHashes
        self.issues = issues
    }
}

public enum Chau7SkillInstallPlanner {
    public static func plan(
        source: Chau7SkillSource,
        target: Chau7SkillInstallTarget,
        sourceFileHashes: [String: Chau7SkillFileHash],
        sourceValidationIssues: [Chau7SkillValidationIssue],
        providerDetection: Chau7SkillProviderDetection,
        installed: Chau7SkillInstalledSnapshot
    ) -> Chau7SkillInstallPlan {
        if hasBlockingSourceIssue(sourceValidationIssues) {
            return Chau7SkillInstallPlan(
                source: source,
                target: target,
                state: .invalidSource,
                action: .refuse,
                issues: sourceValidationIssues
            )
        }

        if !providerDetection.isAvailable {
            return Chau7SkillInstallPlan(
                source: source,
                target: target,
                state: .unsupportedProvider,
                action: .refuse,
                issues: [
                    Chau7SkillValidationIssue(
                        severity: .error,
                        code: "unsupported-provider",
                        message: "\(providerDetection.provider.displayName) is not available for skill installs.",
                        path: providerDetection.providerRoot
                    )
                ]
            )
        }

        guard installed.targetExists else {
            return Chau7SkillInstallPlan(
                source: source,
                target: target,
                state: .missing,
                action: .install
            )
        }

        if !installed.issues.isEmpty {
            return Chau7SkillInstallPlan(
                source: source,
                target: target,
                state: .broken,
                action: .refuse,
                issues: installed.issues
            )
        }

        guard let manifest = installed.manifest else {
            return Chau7SkillInstallPlan(
                source: source,
                target: target,
                state: .unmanagedConflict,
                action: .refuse,
                issues: [
                    Chau7SkillValidationIssue(
                        severity: .error,
                        code: "unmanaged-conflict",
                        message: "Target skill directory exists but is not managed by Chau7.",
                        path: target.skillDirectory
                    )
                ],
                requiresConfirmation: true
            )
        }

        let sourceHash = Chau7SkillManifestHashing.sourceHash(for: sourceFileHashes)
        if installedFilesWereEdited(manifest: manifest, installedFileHashes: installed.fileHashes) {
            return Chau7SkillInstallPlan(
                source: source,
                target: target,
                state: .modified,
                action: .refuse,
                issues: [
                    Chau7SkillValidationIssue(
                        severity: .warning,
                        code: "installed-files-modified",
                        message: "Installed skill files differ from the Chau7 manifest.",
                        path: target.skillDirectory
                    )
                ],
                requiresConfirmation: true
            )
        }

        if manifest.sourceHash == sourceHash {
            return Chau7SkillInstallPlan(
                source: source,
                target: target,
                state: .installed,
                action: .noOp
            )
        }

        return Chau7SkillInstallPlan(
            source: source,
            target: target,
            state: .stale,
            action: .update
        )
    }

    private static func hasBlockingSourceIssue(_ issues: [Chau7SkillValidationIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    private static func installedFilesWereEdited(
        manifest: Chau7SkillManifest,
        installedFileHashes: [String: Chau7SkillFileHash]
    ) -> Bool {
        manifest.files != installedFileHashes
    }
}
