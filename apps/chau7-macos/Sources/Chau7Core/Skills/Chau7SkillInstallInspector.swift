import Foundation

public enum Chau7SkillInstallInspector {
    public static func installedSnapshot(
        target: Chau7SkillInstallTarget,
        fileManager: FileManager = .default
    ) throws -> Chau7SkillInstalledSnapshot {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.skillDirectory, isDirectory: &isDirectory) else {
            return Chau7SkillInstalledSnapshot(targetExists: false)
        }

        let fileHashes = isDirectory.boolValue
            ? try Chau7SkillManifestHashing.managedFileHashes(
                rootDirectory: target.skillDirectory,
                fileManager: fileManager
            )
            : [:]

        guard fileManager.fileExists(atPath: target.manifestPath) else {
            return Chau7SkillInstalledSnapshot(
                targetExists: true,
                manifest: nil,
                fileHashes: fileHashes
            )
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.manifestPath))
            let manifest = try JSONDecoder().decode(Chau7SkillManifest.self, from: data)
            guard manifest.managedBy == Chau7SkillManifest.managerName else {
                return Chau7SkillInstalledSnapshot(
                    targetExists: true,
                    manifest: nil,
                    fileHashes: fileHashes
                )
            }
            let issues = manifestTargetIssues(manifest, target: target)
            guard issues.isEmpty else {
                return Chau7SkillInstalledSnapshot(
                    targetExists: true,
                    manifest: nil,
                    fileHashes: fileHashes,
                    issues: issues
                )
            }
            return Chau7SkillInstalledSnapshot(
                targetExists: true,
                manifest: manifest,
                fileHashes: fileHashes
            )
        } catch {
            return Chau7SkillInstalledSnapshot(
                targetExists: true,
                manifest: nil,
                fileHashes: fileHashes,
                issues: [
                    Chau7SkillValidationIssue(
                        severity: .error,
                        code: "broken-manifest",
                        message: ".chau7-skill.json could not be decoded.",
                        path: target.manifestPath
                    )
                ]
            )
        }
    }

    private static func manifestTargetIssues(
        _ manifest: Chau7SkillManifest,
        target: Chau7SkillInstallTarget
    ) -> [Chau7SkillValidationIssue] {
        var issues: [Chau7SkillValidationIssue] = []

        if manifest.skillID != target.skillID {
            issues.append(
                Chau7SkillValidationIssue(
                    severity: .error,
                    code: "manifest-skill-id-mismatch",
                    message: ".chau7-skill.json skill_id does not match the install target.",
                    path: target.manifestPath
                )
            )
        }
        if manifest.provider != target.provider {
            issues.append(
                Chau7SkillValidationIssue(
                    severity: .error,
                    code: "manifest-provider-mismatch",
                    message: ".chau7-skill.json provider does not match the install target.",
                    path: target.manifestPath
                )
            )
        }
        if manifest.scope != target.scope {
            issues.append(
                Chau7SkillValidationIssue(
                    severity: .error,
                    code: "manifest-scope-mismatch",
                    message: ".chau7-skill.json scope does not match the install target.",
                    path: target.manifestPath
                )
            )
        }

        return issues
    }
}
