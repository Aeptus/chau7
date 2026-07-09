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
}
