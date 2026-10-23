import CryptoKit
import XCTest
@testable import Chau7Core

final class Chau7SkillManifestHashingTests: XCTestCase {
    func testManagedFileHashesExcludeManifestAndDSStore() throws {
        let skill = try makeSkill(name: "chau7-magi")
        defer { remove(skill.container) }

        try write("reference", to: skill.root.appendingPathComponent("references/context.md"))
        try write("script", to: skill.root.appendingPathComponent("scripts/run.sh"))
        try write("managed metadata", to: skill.root.appendingPathComponent(".chau7-skill.json"))
        try write("finder metadata", to: skill.root.appendingPathComponent(".DS_Store"))

        let hashes = try Chau7SkillManifestHashing.managedFileHashes(rootDirectory: skill.root.path)

        XCTAssertEqual(
            hashes.keys.sorted(),
            [
                "SKILL.md",
                "references/context.md",
                "scripts/run.sh"
            ]
        )
        XCTAssertEqual(hashes["SKILL.md"], expectedHash(for: skill.skillMarkdown))
        XCTAssertEqual(hashes["references/context.md"], expectedHash(for: "reference"))
        XCTAssertEqual(hashes["scripts/run.sh"], expectedHash(for: "script"))
        XCTAssertNil(hashes[".chau7-skill.json"])
        XCTAssertNil(hashes[".DS_Store"])
    }

    func testSourceHashIsDeterministicAcrossFileDictionaryOrdering() {
        let filesA: [String: Chau7SkillFileHash] = [
            "SKILL.md": Chau7SkillFileHash(value: "a"),
            "references/context.md": Chau7SkillFileHash(value: "b"),
            "scripts/run.sh": Chau7SkillFileHash(value: "c")
        ]
        let filesB: [String: Chau7SkillFileHash] = [
            "scripts/run.sh": Chau7SkillFileHash(value: "c"),
            "SKILL.md": Chau7SkillFileHash(value: "a"),
            "references/context.md": Chau7SkillFileHash(value: "b")
        ]

        XCTAssertEqual(
            Chau7SkillManifestHashing.sourceHash(for: filesA),
            Chau7SkillManifestHashing.sourceHash(for: filesB)
        )
    }

    func testSourceHashIncludesRelativePathNotJustFileContent() {
        let first = Chau7SkillManifestHashing.sourceHash(for: [
            "references/a.md": Chau7SkillFileHash(value: "same")
        ])
        let renamed = Chau7SkillManifestHashing.sourceHash(for: [
            "references/b.md": Chau7SkillFileHash(value: "same")
        ])

        XCTAssertNotEqual(first, renamed)
    }

    func testManifestUsesSourceAndTargetMetadata() throws {
        let skill = try makeSkill(name: "chau7-mcp", version: "1.0.0")
        defer { remove(skill.container) }

        let source = Chau7SkillSource(
            id: "chau7-mcp",
            kind: .user,
            rootDirectory: skill.root.path,
            version: "1.0.0"
        )
        let target = ClaudeSkillInstallTargetResolver.userTarget(
            skillID: "chau7-mcp",
            homeDirectory: "/Users/me"
        )

        let manifest = try Chau7SkillManifestHashing.manifest(
            source: source,
            target: target,
            installedAt: "2026-07-08T12:00:00Z"
        )

        XCTAssertEqual(manifest.managedBy, "chau7")
        XCTAssertEqual(manifest.skillID, "chau7-mcp")
        XCTAssertEqual(manifest.skillVersion, "1.0.0")
        XCTAssertEqual(manifest.provider, .claude)
        XCTAssertEqual(manifest.scope, .user)
        XCTAssertEqual(manifest.sourcePath, skill.root.path)
        XCTAssertEqual(manifest.installedAt, "2026-07-08T12:00:00Z")
        XCTAssertEqual(manifest.files, try Chau7SkillManifestHashing.managedFileHashes(rootDirectory: skill.root.path))
        XCTAssertEqual(manifest.sourceHash, Chau7SkillManifestHashing.sourceHash(for: manifest.files))
    }

    func testManifestDataUsesDeterministicSnakeCaseJSON() throws {
        let manifest = Chau7SkillManifest(
            skillID: "chau7-magi",
            skillVersion: "1.0.0",
            provider: .claude,
            scope: .user,
            sourcePath: "~/.chau7/skills/source/chau7-magi",
            sourceHash: Chau7SkillFileHash(value: "source"),
            installedAt: "2026-07-08T12:00:00Z",
            files: [
                "SKILL.md": Chau7SkillFileHash(value: "skill")
            ]
        )

        let data = try Chau7SkillManifestHashing.manifestData(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["managed_by"] as? String, "chau7")
        XCTAssertEqual(object["skill_id"] as? String, "chau7-magi")
        XCTAssertEqual(object["skill_version"] as? String, "1.0.0")
        XCTAssertEqual(object["provider"] as? String, "claude")
        XCTAssertEqual(object["scope"] as? String, "user")
        XCTAssertEqual(object["source_path"] as? String, "~/.chau7/skills/source/chau7-magi")
        XCTAssertEqual(object["source_hash"] as? String, "sha256:source")
        XCTAssertEqual((object["files"] as? [String: String])?["SKILL.md"], "sha256:skill")
        XCTAssertEqual(try JSONDecoder().decode(Chau7SkillManifest.self, from: data), manifest)
    }

    func testWriteManifestCreatesTargetManifestFile() throws {
        let skill = try makeSkill(name: "chau7-magi", version: "1.0.0")
        defer { remove(skill.container) }

        let target = CodexSkillInstallTargetResolver.repoTarget(
            skillID: "chau7-magi",
            repositoryRoot: skill.container.appendingPathComponent("repo").path
        )
        let manifest = try Chau7SkillManifestHashing.manifest(
            source: Chau7SkillSource(
                id: "chau7-magi",
                kind: .bundled,
                rootDirectory: skill.root.path,
                version: "1.0.0"
            ),
            target: target,
            installedAt: "2026-07-08T12:00:00Z"
        )

        try Chau7SkillManifestHashing.writeManifest(manifest, to: target)

        let data = try Data(contentsOf: URL(fileURLWithPath: target.manifestPath))
        XCTAssertEqual(try JSONDecoder().decode(Chau7SkillManifest.self, from: data), manifest)
    }

    func testHashDataReturnsSHA256Hex() {
        XCTAssertEqual(
            Chau7SkillManifestHashing.hash(Data("hello".utf8)).rawValue,
            "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    private func makeSkill(name: String, version: String? = nil) throws -> (
        container: URL,
        root: URL,
        skillMarkdown: String
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-skill-manifest-hashing-\(UUID().uuidString)")
        let root = container.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let versionLine = version.map { "version: \($0)\n" } ?? ""
        let skillMarkdown = """
        ---
        name: \(name)
        description: Test skill.
        \(versionLine)---

        Instructions.
        """
        try write(skillMarkdown, to: root.appendingPathComponent("SKILL.md"))
        return (container, root, skillMarkdown)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func expectedHash(for content: String) -> Chau7SkillFileHash {
        let digest = SHA256.hash(data: Data(content.utf8))
        return Chau7SkillFileHash(value: digest.map { String(format: "%02x", $0) }.joined())
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
