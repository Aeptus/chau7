import XCTest
@testable import Chau7Core

final class Chau7SkillInstallerTests: XCTestCase {
    func testMissingTargetInstallsStagedCopyAndDoesNotMutateSource() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }

        let result = try install(fixture: fixture)

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.missing)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.installed)
        XCTAssertTrue(result.didMutate)
        XCTAssertNil(result.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.skillMarkdownPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.manifestPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.rootDirectory + "/.chau7-skill.json"))

        let manifest = try readManifest(at: fixture.target.manifestPath)
        XCTAssertEqual(manifest.managedBy, "chau7")
        XCTAssertEqual(manifest.skillID, "chau7-magi")
        XCTAssertEqual(manifest.provider, .claude)
        XCTAssertEqual(manifest.scope, .user)
        XCTAssertEqual(manifest.sourcePath, fixture.source.rootDirectory)
        XCTAssertEqual(
            manifest.sourceHash,
            try Chau7SkillManifestHashing.sourceHash(rootDirectory: fixture.source.rootDirectory)
        )
        XCTAssertEqual(
            manifest.files,
            try Chau7SkillManifestHashing.managedFileHashes(rootDirectory: fixture.source.rootDirectory)
        )
    }

    func testSameManagedInstallPlansNoOpWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }

        _ = try install(fixture: fixture)
        let result = try install(fixture: fixture)

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.installed)
        XCTAssertEqual(result.initialPlan.action, Chau7SkillInstallPlan.Action.noOp)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.installed)
        XCTAssertFalse(result.didMutate)
        XCTAssertNil(result.backupPath)
    }

    func testUnmanagedConflictRefusesWithoutForce() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try write("local unmanaged", to: URL(fileURLWithPath: fixture.target.skillMarkdownPath))

        let result = try install(fixture: fixture)

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.unmanagedConflict)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.unmanagedConflict)
        XCTAssertFalse(result.didMutate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.manifestPath))
        XCTAssertEqual(
            try String(contentsOfFile: fixture.target.skillMarkdownPath, encoding: .utf8),
            "local unmanaged"
        )
    }

    func testForceUnmanagedConflictReplacesTargetAndBacksItUp() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try write("local unmanaged", to: URL(fileURLWithPath: fixture.target.skillMarkdownPath))

        let result = try install(fixture: fixture, force: true)

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.unmanagedConflict)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.installed)
        XCTAssertTrue(result.didMutate)
        let backupPath = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(
            try String(contentsOfFile: "\(backupPath)/SKILL.md", encoding: .utf8),
            "local unmanaged"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.manifestPath))
        XCTAssertEqual(
            try String(contentsOfFile: fixture.target.skillMarkdownPath, encoding: .utf8),
            fixture.skillMarkdown
        )
    }

    func testForeignManifestIsUnmanagedConflictAndCanBeForced() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try write("foreign managed", to: URL(fileURLWithPath: fixture.target.skillMarkdownPath))
        try writeManifest(
            Chau7SkillManifest(
                managedBy: "another-tool",
                skillID: fixture.source.id,
                skillVersion: "1.0.0",
                provider: .claude,
                scope: .user,
                sourcePath: fixture.source.rootDirectory,
                sourceHash: try Chau7SkillManifestHashing.sourceHash(rootDirectory: fixture.source.rootDirectory),
                installedAt: "2026-07-09T12:00:00Z",
                files: try Chau7SkillManifestHashing.managedFileHashes(rootDirectory: fixture.source.rootDirectory)
            ),
            to: fixture.target.manifestPath
        )

        let refused = try install(fixture: fixture)

        XCTAssertEqual(refused.initialPlan.state, Chau7SkillInstallState.unmanagedConflict)
        XCTAssertEqual(refused.finalState, Chau7SkillInstallState.unmanagedConflict)
        XCTAssertFalse(refused.didMutate)
        XCTAssertEqual(
            try String(contentsOfFile: fixture.target.skillMarkdownPath, encoding: .utf8),
            "foreign managed"
        )

        let forced = try install(fixture: fixture, force: true)

        XCTAssertEqual(forced.initialPlan.state, Chau7SkillInstallState.unmanagedConflict)
        XCTAssertEqual(forced.finalState, Chau7SkillInstallState.installed)
        XCTAssertTrue(forced.didMutate)
        XCTAssertEqual(
            try String(contentsOfFile: fixture.target.skillMarkdownPath, encoding: .utf8),
            fixture.skillMarkdown
        )
        XCTAssertEqual(try readManifest(at: fixture.target.manifestPath).managedBy, "chau7")
    }

    func testStaleManagedInstallUpdatesAndBacksUpExistingTarget() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        _ = try install(fixture: fixture)

        try writeSkill(
            name: "chau7-magi",
            description: "Updated skill.",
            body: "Updated instructions.",
            to: URL(fileURLWithPath: fixture.source.rootDirectory)
        )

        let result = try install(fixture: fixture)

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.stale)
        XCTAssertEqual(result.initialPlan.action, Chau7SkillInstallPlan.Action.update)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.installed)
        XCTAssertTrue(result.didMutate)
        let backupPath = try XCTUnwrap(result.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(backupPath)/.chau7-skill.json"))
        XCTAssertTrue(
            try String(contentsOfFile: "\(backupPath)/SKILL.md", encoding: .utf8)
                .contains("Test skill.")
        )
        XCTAssertTrue(
            try String(contentsOfFile: fixture.target.skillMarkdownPath, encoding: .utf8)
                .contains("Updated skill.")
        )
        XCTAssertEqual(try replacementRollbackDirectories(for: fixture), [])
    }

    func testReplacementFailureRestoresExistingTarget() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        _ = try install(fixture: fixture)

        try writeSkill(
            name: "chau7-magi",
            description: "Updated skill.",
            body: "Updated instructions.",
            to: URL(fileURLWithPath: fixture.source.rootDirectory)
        )
        let fileManager = FailingSecondMoveFileManager()

        XCTAssertThrowsError(
            try Chau7SkillInstaller.install(
                source: fixture.source,
                target: fixture.target,
                providerDetection: availableProvider(root: fixture.providerRoot),
                options: options(fixture: fixture),
                fileManager: fileManager
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.manifestPath))
        XCTAssertTrue(
            try String(contentsOfFile: fixture.target.skillMarkdownPath, encoding: .utf8)
                .contains("Test skill.")
        )
        XCTAssertFalse(
            try String(contentsOfFile: fixture.target.skillMarkdownPath, encoding: .utf8)
                .contains("Updated skill.")
        )
        XCTAssertEqual(try replacementRollbackDirectories(for: fixture), [])
    }

    func testEditedManagedInstallRefusesWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        _ = try install(fixture: fixture)
        try write("locally edited", to: URL(fileURLWithPath: fixture.target.skillMarkdownPath))

        let result = try install(fixture: fixture, force: true)

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.modified)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.modified)
        XCTAssertFalse(result.didMutate)
        XCTAssertNil(result.backupPath)
        XCTAssertEqual(
            try String(contentsOfFile: fixture.target.skillMarkdownPath, encoding: .utf8),
            "locally edited"
        )
    }

    func testInvalidSourceRefusesWithoutCreatingTarget() throws {
        let fixture = try makeFixture(writeSourceSkill: false)
        defer { remove(fixture.root) }

        let result = try install(fixture: fixture)

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.invalidSource)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.invalidSource)
        XCTAssertFalse(result.didMutate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.skillDirectory))
    }

    func testUnsupportedProviderRefusesWithoutCreatingTarget() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }

        let result = try Chau7SkillInstaller.install(
            source: fixture.source,
            target: fixture.target,
            providerDetection: unavailableProvider(root: fixture.providerRoot),
            options: options(fixture: fixture)
        )

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.unsupportedProvider)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.unsupportedProvider)
        XCTAssertFalse(result.didMutate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.skillDirectory))
    }

    func testStagedValidationFailureDoesNotMutateSourceOrTarget() throws {
        let fixture = try makeFixture(targetSkillID: "different-skill")
        defer { remove(fixture.root) }

        let result = try install(fixture: fixture)

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.missing)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.invalidSource)
        XCTAssertFalse(result.didMutate)
        XCTAssertEqual(result.issues.map { $0.code }, ["directory-name-mismatch"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.skillDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.rootDirectory + "/.chau7-skill.json"))
    }

    func testBrokenExistingManifestRefuses() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try write(fixture.skillMarkdown, to: URL(fileURLWithPath: fixture.target.skillMarkdownPath))
        try write("{not json", to: URL(fileURLWithPath: fixture.target.manifestPath))

        let result = try install(fixture: fixture, force: true)

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.broken)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.broken)
        XCTAssertFalse(result.didMutate)
        XCTAssertEqual(result.issues.map { $0.code }, ["broken-manifest"])
    }

    func testMismatchedManagedManifestRefusesWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try write(fixture.skillMarkdown, to: URL(fileURLWithPath: fixture.target.skillMarkdownPath))
        try writeManifest(
            Chau7SkillManifest(
                skillID: "other-skill",
                skillVersion: "1.0.0",
                provider: .claude,
                scope: .user,
                sourcePath: fixture.source.rootDirectory,
                sourceHash: try Chau7SkillManifestHashing.sourceHash(rootDirectory: fixture.source.rootDirectory),
                installedAt: "2026-07-09T12:00:00Z",
                files: try Chau7SkillManifestHashing.managedFileHashes(rootDirectory: fixture.source.rootDirectory)
            ),
            to: fixture.target.manifestPath
        )

        let result = try install(fixture: fixture, force: true)

        XCTAssertEqual(result.initialPlan.state, Chau7SkillInstallState.broken)
        XCTAssertEqual(result.finalState, Chau7SkillInstallState.broken)
        XCTAssertFalse(result.didMutate)
        XCTAssertEqual(result.issues.map { $0.code }, ["manifest-skill-id-mismatch"])
        XCTAssertEqual(
            try String(contentsOfFile: fixture.target.skillMarkdownPath, encoding: .utf8),
            fixture.skillMarkdown
        )
    }

    private struct Fixture {
        var root: URL
        var source: Chau7SkillSource
        var target: Chau7SkillInstallTarget
        var providerRoot: String
        var tempRoot: String
        var backupRoot: String
        var skillMarkdown: String
    }

    private func makeFixture(
        targetSkillID: Chau7SkillID = "chau7-magi",
        writeSourceSkill: Bool = true
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-skill-installer-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source/chau7-magi", isDirectory: true)
        let homeRoot = root.appendingPathComponent("home", isDirectory: true)
        let tempRoot = root.appendingPathComponent("tmp", isDirectory: true)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let skillMarkdown: String
        if writeSourceSkill {
            skillMarkdown = try writeSkill(
                name: "chau7-magi",
                description: "Test skill.",
                body: "Instructions.",
                to: sourceRoot
            )
        } else {
            skillMarkdown = ""
        }

        let source = Chau7SkillSource(
            id: "chau7-magi",
            kind: .bundled,
            rootDirectory: sourceRoot.path,
            version: "1.0.0"
        )
        let target = ClaudeSkillInstallTargetResolver.userTarget(
            skillID: targetSkillID,
            homeDirectory: homeRoot.path
        )
        return Fixture(
            root: root,
            source: source,
            target: target,
            providerRoot: homeRoot.appendingPathComponent(".claude", isDirectory: true).path,
            tempRoot: tempRoot.path,
            backupRoot: backupRoot.path,
            skillMarkdown: skillMarkdown
        )
    }

    @discardableResult
    private func writeSkill(
        name: String,
        description: String,
        body: String,
        to root: URL
    ) throws -> String {
        let skillMarkdown = """
        ---
        name: \(name)
        description: \(description)
        ---

        \(body)
        """
        try write(skillMarkdown, to: root.appendingPathComponent("SKILL.md"))
        try write("reference", to: root.appendingPathComponent("references/context.md"))
        return skillMarkdown
    }

    private func install(
        fixture: Fixture,
        force: Bool = false
    ) throws -> Chau7SkillInstallResult {
        try Chau7SkillInstaller.install(
            source: fixture.source,
            target: fixture.target,
            providerDetection: availableProvider(root: fixture.providerRoot),
            options: options(fixture: fixture, force: force)
        )
    }

    private func options(
        fixture: Fixture,
        force: Bool = false
    ) -> Chau7SkillInstallerOptions {
        Chau7SkillInstallerOptions(
            force: force,
            installedAt: "2026-07-09T12:00:00Z",
            temporaryDirectoryRoot: fixture.tempRoot,
            backupDirectoryRoot: fixture.backupRoot
        )
    }

    private func availableProvider(root: String) -> Chau7SkillProviderDetection {
        Chau7SkillProviderDetection(
            provider: .claude,
            isAvailable: true,
            reasons: [.explicitlyRequested],
            providerRoot: root,
            executableName: "claude"
        )
    }

    private func unavailableProvider(root: String) -> Chau7SkillProviderDetection {
        Chau7SkillProviderDetection(
            provider: .claude,
            isAvailable: false,
            reasons: [],
            providerRoot: root,
            executableName: "claude"
        )
    }

    private func readManifest(at path: String) throws -> Chau7SkillManifest {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Chau7SkillManifest.self, from: data)
    }

    private func writeManifest(_ manifest: Chau7SkillManifest, to path: String) throws {
        try Chau7SkillManifestHashing.manifestData(manifest)
            .write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    private func replacementRollbackDirectories(for fixture: Fixture) throws -> [String] {
        let targetParent = URL(fileURLWithPath: fixture.target.skillDirectory, isDirectory: true)
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: targetParent.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: targetParent.path)
            .filter { $0.hasPrefix(".chau7-skill-replace-") }
            .sorted()
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class FailingSecondMoveFileManager: FileManager {
    private var moveCount = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        if moveCount == 2 {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
