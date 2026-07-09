import XCTest
@testable import Chau7CLI
@testable import Chau7Core

final class Chau7CLISkillsTests: XCTestCase {
    func testSkillsDoctorReportsSourcesAndProviderUserStates() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }

        try install(skillID: "chau7-magi", provider: .codex, fixture: fixture)
        try writeSkill(id: "chau7-magi", description: "MAGI v2.", body: "Updated.", sourceRoot: fixture.sourceRoot)
        try install(skillID: "chau7-magi", provider: .claude, fixture: fixture)
        try write("local unmanaged", to: codexTarget(skillID: "chau7-mcp", fixture: fixture).appendingPathComponent("SKILL.md"))

        let result = runner(fixture).run(arguments: [
            "skills", "doctor",
            "--source-root", fixture.sourceRoot.path,
            "--home", fixture.home.path
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.stdout,
            """
            Chau7 Skills

            Sources:
            - chau7-magi bundled valid
            - chau7-mcp  bundled valid

            Claude user:
            - chau7-magi installed
            - chau7-mcp  missing

            Codex user:
            - chau7-magi stale
            - chau7-mcp  unmanaged conflict
            """
            + "\n"
        )
    }

    func testSkillsListShowsBundledSourceValidity() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }

        let result = runner(fixture).run(arguments: [
            "skills", "list",
            "--source-root", fixture.sourceRoot.path
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("- chau7-magi bundled valid"))
        XCTAssertTrue(result.stdout.contains("- chau7-mcp  bundled valid"))
    }

    func testSkillsValidateCanValidateBuiltInsAndSpecificPath() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }

        let all = runner(fixture).run(arguments: [
            "skills", "validate",
            "--source-root", fixture.sourceRoot.path
        ])
        XCTAssertEqual(all.exitCode, 0)
        XCTAssertTrue(all.stdout.contains("chau7-magi valid"))
        XCTAssertTrue(all.stdout.contains("chau7-mcp  valid"))

        let onePath = runner(fixture).run(arguments: [
            "skills", "validate",
            fixture.sourceRoot.appendingPathComponent("chau7-magi").path
        ])
        XCTAssertEqual(onePath.exitCode, 0)
        XCTAssertTrue(onePath.stdout.contains("chau7-magi valid"))
    }

    func testSkillsInstallInstallsSelectedProviderTargets() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }

        let result = runner(fixture).run(arguments: [
            "skills", "install", "chau7-magi",
            "--provider", "claude",
            "--source-root", fixture.sourceRoot.path,
            "--home", fixture.home.path
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Claude user:"))
        XCTAssertTrue(result.stdout.contains("- chau7-magi installed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeTarget(skillID: "chau7-magi", fixture: fixture).appendingPathComponent(".chau7-skill.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexTarget(skillID: "chau7-magi", fixture: fixture).path))
    }

    func testSkillsUpdateUpdatesOnlyStaleManagedInstalls() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }

        try install(skillID: "chau7-magi", provider: .claude, fixture: fixture)
        try writeSkill(id: "chau7-magi", description: "MAGI v2.", body: "Updated.", sourceRoot: fixture.sourceRoot)

        let result = runner(fixture).run(arguments: [
            "skills", "update", "chau7-magi",
            "--provider", "claude",
            "--source-root", fixture.sourceRoot.path,
            "--home", fixture.home.path
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("- chau7-magi installed"))
        XCTAssertTrue(result.stdout.contains("backup:"))
        XCTAssertTrue(
            try String(contentsOf: claudeTarget(skillID: "chau7-magi", fixture: fixture).appendingPathComponent("SKILL.md"), encoding: .utf8)
                .contains("MAGI v2.")
        )
    }

    func testSkillsUninstallRemovesManagedInstall() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try install(skillID: "chau7-magi", provider: .claude, fixture: fixture)

        let result = runner(fixture).run(arguments: [
            "skills", "uninstall", "chau7-magi",
            "--provider", "claude",
            "--source-root", fixture.sourceRoot.path,
            "--home", fixture.home.path
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("- chau7-magi uninstalled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeTarget(skillID: "chau7-magi", fixture: fixture).path))
    }

    func testSkillsDiffReportsStaleStateAndHashes() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try install(skillID: "chau7-magi", provider: .codex, fixture: fixture)
        try writeSkill(id: "chau7-magi", description: "MAGI v2.", body: "Updated.", sourceRoot: fixture.sourceRoot)

        let result = runner(fixture).run(arguments: [
            "skills", "diff", "chau7-magi",
            "--provider", "codex",
            "--source-root", fixture.sourceRoot.path,
            "--home", fixture.home.path
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("- chau7-magi stale"))
        XCTAssertTrue(result.stdout.contains("source_hash: sha256:"))
        XCTAssertTrue(result.stdout.contains("installed_source_hash: sha256:"))
        XCTAssertTrue(result.stdout.contains("installed_files: unchanged"))
    }

    func testSkillsSyncInstallsMissingAndUpdatesStale() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try install(skillID: "chau7-magi", provider: .claude, fixture: fixture)
        try writeSkill(id: "chau7-magi", description: "MAGI v2.", body: "Updated.", sourceRoot: fixture.sourceRoot)

        let result = runner(fixture).run(arguments: [
            "skills", "sync", "all",
            "--provider", "claude",
            "--source-root", fixture.sourceRoot.path,
            "--home", fixture.home.path
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("- chau7-magi installed"))
        XCTAssertTrue(result.stdout.contains("- chau7-mcp installed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeTarget(skillID: "chau7-mcp", fixture: fixture).appendingPathComponent(".chau7-skill.json").path))
    }

    func testSkillsInstallRefusesUnmanagedConflictUnlessForced() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try write("local unmanaged", to: codexTarget(skillID: "chau7-mcp", fixture: fixture).appendingPathComponent("SKILL.md"))

        let refused = runner(fixture).run(arguments: [
            "skills", "install", "chau7-mcp",
            "--provider", "codex",
            "--source-root", fixture.sourceRoot.path,
            "--home", fixture.home.path
        ])
        XCTAssertEqual(refused.exitCode, 1)
        XCTAssertTrue(refused.stdout.contains("- chau7-mcp unmanaged conflict"))

        let forced = runner(fixture).run(arguments: [
            "skills", "install", "chau7-mcp",
            "--provider", "codex",
            "--source-root", fixture.sourceRoot.path,
            "--home", fixture.home.path,
            "--force"
        ])
        XCTAssertEqual(forced.exitCode, 0)
        XCTAssertTrue(forced.stdout.contains("- chau7-mcp installed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexTarget(skillID: "chau7-mcp", fixture: fixture).appendingPathComponent(".chau7-skill.json").path))
    }

    private struct Fixture {
        var root: URL
        var sourceRoot: URL
        var home: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-cli-skills-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Resources/Skills", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try writeSkill(id: "chau7-magi", description: "MAGI skill.", body: "MAGI instructions.", sourceRoot: sourceRoot)
        try writeSkill(id: "chau7-mcp", description: "MCP skill.", body: "MCP instructions.", sourceRoot: sourceRoot)
        return Fixture(root: root, sourceRoot: sourceRoot, home: home)
    }

    private func runner(_ fixture: Fixture) -> Chau7CLIRunner {
        Chau7CLIRunner(
            environment: [
                "CHAU7_SKILLS_SOURCE_ROOT": fixture.sourceRoot.path,
                "CHAU7_HOME": fixture.home.path,
                "PATH": ""
            ],
            currentDirectory: fixture.root.path
        )
    }

    private func install(skillID: Chau7SkillID, provider: Chau7SkillProvider, fixture: Fixture) throws {
        let source = Chau7SkillSource(
            id: skillID,
            kind: .bundled,
            rootDirectory: fixture.sourceRoot.appendingPathComponent(skillID.rawValue).path,
            version: "1.0.0"
        )
        let target: Chau7SkillInstallTarget = provider == .claude
            ? ClaudeSkillInstallTargetResolver.userTarget(skillID: skillID, homeDirectory: fixture.home.path)
            : CodexSkillInstallTargetResolver.userTarget(skillID: skillID, homeDirectory: fixture.home.path)
        _ = try Chau7SkillInstaller.install(
            source: source,
            target: target,
            providerDetection: Chau7SkillProviderDetection(
                provider: provider,
                isAvailable: true,
                reasons: [.explicitlyRequested],
                providerRoot: fixture.home.appendingPathComponent(".\(provider.rawValue)").path,
                executableName: provider.rawValue
            ),
            options: Chau7SkillInstallerOptions(
                installedAt: "2026-07-09T12:00:00Z",
                temporaryDirectoryRoot: fixture.root.appendingPathComponent("tmp").path,
                backupDirectoryRoot: fixture.root.appendingPathComponent("backups").path
            )
        )
    }

    @discardableResult
    private func writeSkill(
        id: String,
        description: String,
        body: String,
        sourceRoot: URL
    ) throws -> String {
        let root = sourceRoot.appendingPathComponent(id, isDirectory: true)
        let markdown = """
        ---
        name: \(id)
        description: \(description)
        ---

        \(body)
        """
        try write(markdown, to: root.appendingPathComponent("SKILL.md"))
        return markdown
    }

    private func claudeTarget(skillID: Chau7SkillID, fixture: Fixture) -> URL {
        URL(fileURLWithPath: ClaudeSkillInstallTargetResolver.userTarget(
            skillID: skillID,
            homeDirectory: fixture.home.path
        ).skillDirectory)
    }

    private func codexTarget(skillID: Chau7SkillID, fixture: Fixture) -> URL {
        URL(fileURLWithPath: CodexSkillInstallTargetResolver.userTarget(
            skillID: skillID,
            homeDirectory: fixture.home.path
        ).skillDirectory)
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
