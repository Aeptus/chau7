import XCTest
@testable import Chau7Core

final class Chau7SkillProviderTargetsTests: XCTestCase {
    func testClaudeUserAndRepoTargetsUseProviderNativeSkillRoots() {
        let userTarget = ClaudeSkillInstallTargetResolver.userTarget(
            skillID: "chau7-magi",
            homeDirectory: "/Users/me/"
        )
        let repoTarget = ClaudeSkillInstallTargetResolver.repoTarget(
            skillID: "repo-review",
            repositoryRoot: "/repo/project/"
        )

        XCTAssertEqual(userTarget.provider, .claude)
        XCTAssertEqual(userTarget.scope, .user)
        XCTAssertEqual(userTarget.rootDirectory, "/Users/me/.claude/skills")
        XCTAssertEqual(userTarget.skillDirectory, "/Users/me/.claude/skills/chau7-magi")

        XCTAssertEqual(repoTarget.provider, .claude)
        XCTAssertEqual(repoTarget.scope, .repo)
        XCTAssertEqual(repoTarget.rootDirectory, "/repo/project/.claude/skills")
        XCTAssertEqual(repoTarget.skillDirectory, "/repo/project/.claude/skills/repo-review")
    }

    func testCodexUserAndRepoTargetsUseProviderNativeSkillRoots() {
        let userTarget = CodexSkillInstallTargetResolver.userTarget(
            skillID: "chau7-mcp",
            homeDirectory: "/Users/me/"
        )
        let repoTarget = CodexSkillInstallTargetResolver.repoTarget(
            skillID: "repo-review",
            repositoryRoot: "/repo/project/"
        )

        XCTAssertEqual(userTarget.provider, .codex)
        XCTAssertEqual(userTarget.scope, .user)
        XCTAssertEqual(userTarget.rootDirectory, "/Users/me/.codex/skills")
        XCTAssertEqual(userTarget.skillDirectory, "/Users/me/.codex/skills/chau7-mcp")

        XCTAssertEqual(repoTarget.provider, .codex)
        XCTAssertEqual(repoTarget.scope, .repo)
        XCTAssertEqual(repoTarget.rootDirectory, "/repo/project/.codex/skills")
        XCTAssertEqual(repoTarget.skillDirectory, "/repo/project/.codex/skills/repo-review")
    }

    func testClaudeDetectionUsesProviderRoot() throws {
        let home = try temporaryDirectory()
        defer { remove(home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )

        let detection = ClaudeSkillInstallTargetResolver.detect(
            homeDirectory: home.path,
            environmentPATH: "",
            fileManager: .default
        )

        XCTAssertTrue(detection.isAvailable)
        XCTAssertEqual(detection.provider, .claude)
        XCTAssertEqual(detection.providerRoot, home.appendingPathComponent(".claude").path)
        XCTAssertEqual(detection.executableName, "claude")
        XCTAssertEqual(detection.reasons, [.providerRootExists])
    }

    func testCodexDetectionUsesExecutableOnPath() throws {
        let home = try temporaryDirectory()
        let bin = home.appendingPathComponent("bin")
        defer { remove(home) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(named: "codex", in: bin)

        let detection = CodexSkillInstallTargetResolver.detect(
            homeDirectory: home.path,
            environmentPATH: "\(bin.path):/usr/bin",
            fileManager: .default
        )

        XCTAssertTrue(detection.isAvailable)
        XCTAssertEqual(detection.provider, .codex)
        XCTAssertEqual(detection.executableName, "codex")
        XCTAssertEqual(detection.reasons, [.providerCLIExists])
    }

    func testExplicitProviderRequestMakesDetectionAvailableWithoutRootOrCLI() throws {
        let home = try temporaryDirectory()
        defer { remove(home) }

        let detection = ClaudeSkillInstallTargetResolver.detect(
            homeDirectory: home.path,
            environmentPATH: "",
            explicitlyRequested: true,
            fileManager: .default
        )

        XCTAssertTrue(detection.isAvailable)
        XCTAssertEqual(detection.reasons, [.explicitlyRequested])
    }

    func testDetectionCombinesConservativeReasonsInStableOrder() throws {
        let home = try temporaryDirectory()
        let bin = home.appendingPathComponent("bin")
        defer { remove(home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(named: "codex", in: bin)

        let detection = CodexSkillInstallTargetResolver.detect(
            homeDirectory: home.path,
            environmentPATH: bin.path,
            explicitlyRequested: true,
            fileManager: .default
        )

        XCTAssertTrue(detection.isAvailable)
        XCTAssertEqual(
            detection.reasons,
            [.providerRootExists, .providerCLIExists, .explicitlyRequested]
        )
    }

    func testDetectionIsUnavailableWithoutRootCLIOrExplicitRequest() throws {
        let home = try temporaryDirectory()
        defer { remove(home) }

        let detection = CodexSkillInstallTargetResolver.detect(
            homeDirectory: home.path,
            environmentPATH: "",
            fileManager: .default
        )

        XCTAssertFalse(detection.isAvailable)
        XCTAssertEqual(detection.reasons, [])
        XCTAssertEqual(detection.providerRoot, home.appendingPathComponent(".codex").path)
    }

    func testNonExecutablePathEntryDoesNotCountAsProviderCLI() throws {
        let home = try temporaryDirectory()
        let bin = home.appendingPathComponent("bin")
        defer { remove(home) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "not executable".write(
            to: bin.appendingPathComponent("claude"),
            atomically: true,
            encoding: .utf8
        )

        let detection = ClaudeSkillInstallTargetResolver.detect(
            homeDirectory: home.path,
            environmentPATH: bin.path,
            fileManager: .default
        )

        XCTAssertFalse(detection.isAvailable)
        XCTAssertEqual(detection.reasons, [])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-skill-provider-targets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
