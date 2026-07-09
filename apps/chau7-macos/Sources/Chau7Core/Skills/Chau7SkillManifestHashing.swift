import CryptoKit
import Foundation

public enum Chau7SkillManifestHashing {
    public static let excludedManagedFileNames: Set<String> = [
        ".chau7-skill.json",
        ".DS_Store"
    ]

    public static func managedFileHashes(
        rootDirectory: String,
        fileManager: FileManager = .default
    ) throws -> [String: Chau7SkillFileHash] {
        let normalizedRoot = rootDirectory.chau7SkillRemovingTrailingSlashes()
        let rootURL = URL(fileURLWithPath: normalizedRoot, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return [:]
        }

        var hashes: [String: Chau7SkillFileHash] = [:]
        for case let url as URL in enumerator {
            let fileName = url.lastPathComponent
            if excludedManagedFileNames.contains(fileName) {
                continue
            }

            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if resourceValues.isDirectory == true {
                continue
            }
            guard resourceValues.isRegularFile == true else {
                continue
            }

            let relativePath = relativePath(for: url, rootURL: rootURL)
            let data = try Data(contentsOf: url)
            hashes[relativePath] = hash(data)
        }

        return hashes
    }

    public static func sourceHash(for files: [String: Chau7SkillFileHash]) -> Chau7SkillFileHash {
        var hasher = SHA256()
        for relativePath in files.keys.sorted() {
            guard let fileHash = files[relativePath] else { continue }
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(fileHash.rawValue.utf8))
            hasher.update(data: Data([0]))
        }
        return Chau7SkillFileHash(value: hexString(for: hasher.finalize()))
    }

    public static func sourceHash(
        rootDirectory: String,
        fileManager: FileManager = .default
    ) throws -> Chau7SkillFileHash {
        try sourceHash(for: managedFileHashes(rootDirectory: rootDirectory, fileManager: fileManager))
    }

    public static func manifest(
        source: Chau7SkillSource,
        target: Chau7SkillInstallTarget,
        installedAt: String,
        sourcePath: String? = nil,
        fileManager: FileManager = .default
    ) throws -> Chau7SkillManifest {
        let files = try managedFileHashes(rootDirectory: source.rootDirectory, fileManager: fileManager)
        return Chau7SkillManifest(
            skillID: source.id,
            skillVersion: source.version,
            provider: target.provider,
            scope: target.scope,
            sourcePath: sourcePath ?? source.rootDirectory,
            sourceHash: sourceHash(for: files),
            installedAt: installedAt,
            files: files
        )
    }

    public static func manifestData(_ manifest: Chau7SkillManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    public static func writeManifest(
        _ manifest: Chau7SkillManifest,
        to target: Chau7SkillInstallTarget,
        fileManager: FileManager = .default
    ) throws {
        let manifestURL = URL(fileURLWithPath: target.manifestPath)
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try manifestData(manifest).write(to: manifestURL, options: [.atomic])
    }

    public static func hash(_ data: Data) -> Chau7SkillFileHash {
        Chau7SkillFileHash(value: hexString(for: SHA256.hash(data: data)))
    }

    private static func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path.chau7SkillRemovingTrailingSlashes()
        let filePath = fileURL.standardizedFileURL.path
        let prefix = "\(rootPath)/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return fileURL.lastPathComponent
    }

    private static func hexString<D: Sequence>(for digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
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
