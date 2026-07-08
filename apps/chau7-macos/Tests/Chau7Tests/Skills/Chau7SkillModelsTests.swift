import XCTest
@testable import Chau7Core

final class Chau7SkillModelsTests: XCTestCase {
    func testSkillIDTrimsWhitespaceAndEncodesAsString() throws {
        let id = Chau7SkillID("  chau7-magi\n")

        XCTAssertEqual(id.rawValue, "chau7-magi")
        XCTAssertEqual(id.id, "chau7-magi")
        XCTAssertEqual(id.description, "chau7-magi")

        let encoded = try JSONEncoder().encode(id)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"chau7-magi\"")
        XCTAssertEqual(try JSONDecoder().decode(Chau7SkillID.self, from: encoded), id)
    }

    func testProviderNormalizesCaseAndKeepsFutureProvidersRepresentable() throws {
        let provider = Chau7SkillProvider("  FutureAI ")

        XCTAssertEqual(provider.rawValue, "futureai")
        XCTAssertEqual(provider.displayName, "futureai")
        XCTAssertEqual(Chau7SkillProvider.claude.displayName, "Claude")
        XCTAssertEqual(Chau7SkillProvider.codex.displayName, "Codex")

        let encoded = try JSONEncoder().encode(provider)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"futureai\"")
        XCTAssertEqual(try JSONDecoder().decode(Chau7SkillProvider.self, from: encoded), provider)
    }

    func testSourceComputesStandardAgentSkillPaths() {
        let source = Chau7SkillSource(
            id: "chau7-mcp",
            kind: .bundled,
            rootDirectory: "/app/Resources/Skills/chau7-mcp/",
            version: "1.0.0"
        )

        XCTAssertEqual(source.rootDirectory, "/app/Resources/Skills/chau7-mcp")
        XCTAssertEqual(source.skillMarkdownPath, "/app/Resources/Skills/chau7-mcp/SKILL.md")
        XCTAssertEqual(source.scriptsDirectory, "/app/Resources/Skills/chau7-mcp/scripts")
        XCTAssertEqual(source.referencesDirectory, "/app/Resources/Skills/chau7-mcp/references")
        XCTAssertEqual(source.assetsDirectory, "/app/Resources/Skills/chau7-mcp/assets")
    }

    func testInstallTargetComputesProviderMaterializedPaths() {
        let target = Chau7SkillInstallTarget(
            skillID: "repo-review",
            provider: .claude,
            scope: .repo,
            rootDirectory: "/repo/.claude/skills/"
        )

        XCTAssertEqual(target.id, "claude:repo:repo-review")
        XCTAssertEqual(target.rootDirectory, "/repo/.claude/skills")
        XCTAssertEqual(target.skillDirectory, "/repo/.claude/skills/repo-review")
        XCTAssertEqual(target.skillMarkdownPath, "/repo/.claude/skills/repo-review/SKILL.md")
        XCTAssertEqual(target.manifestPath, "/repo/.claude/skills/repo-review/.chau7-skill.json")
    }

    func testInstallStateRawValuesMatchLifecycleContract() {
        XCTAssertEqual(
            Chau7SkillInstallState.allCases.map(\.rawValue),
            [
                "missing",
                "installed",
                "stale",
                "modified",
                "broken",
                "unmanaged_conflict",
                "unsupported_provider",
                "invalid_source"
            ]
        )
    }

    func testFileHashEncodesAsAlgorithmPrefixedString() throws {
        let hash = Chau7SkillFileHash(value: "abc123")

        XCTAssertEqual(hash.rawValue, "sha256:abc123")
        XCTAssertEqual(Chau7SkillFileHash(rawValue: "sha512:def456").algorithm, "sha512")
        XCTAssertEqual(Chau7SkillFileHash(rawValue: "legacy").rawValue, "sha256:legacy")

        let encoded = try JSONEncoder().encode(hash)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"sha256:abc123\"")
        XCTAssertEqual(try JSONDecoder().decode(Chau7SkillFileHash.self, from: encoded), hash)
    }

    func testManifestUsesStableSnakeCaseKeysAndStringValues() throws {
        let manifest = Chau7SkillManifest(
            skillID: "chau7-magi",
            skillVersion: "1.0.0",
            provider: .codex,
            scope: .user,
            sourcePath: "/Users/me/.chau7/skills/source/chau7-magi",
            sourceHash: Chau7SkillFileHash(value: "source"),
            installedAt: "2026-07-08T12:00:00Z",
            files: [
                "SKILL.md": Chau7SkillFileHash(value: "skill")
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["managed_by"] as? String, "chau7")
        XCTAssertEqual(object["skill_id"] as? String, "chau7-magi")
        XCTAssertEqual(object["skill_version"] as? String, "1.0.0")
        XCTAssertEqual(object["provider"] as? String, "codex")
        XCTAssertEqual(object["scope"] as? String, "user")
        XCTAssertEqual(object["source_hash"] as? String, "sha256:source")
        XCTAssertEqual((object["files"] as? [String: String])?["SKILL.md"], "sha256:skill")
        XCTAssertEqual(try JSONDecoder().decode(Chau7SkillManifest.self, from: data), manifest)
    }

    func testInstallPlanCarriesDecisionInputs() {
        let target = Chau7SkillInstallTarget(
            skillID: "chau7-mcp",
            provider: .claude,
            scope: .user,
            rootDirectory: "/Users/me/.claude/skills"
        )
        let issue = Chau7SkillValidationIssue(
            severity: .error,
            code: "missing-skill-md",
            message: "SKILL.md is required.",
            path: "/tmp/chau7-mcp"
        )
        let plan = Chau7SkillInstallPlan(
            source: nil,
            target: target,
            state: .invalidSource,
            action: .refuse,
            issues: [issue],
            requiresConfirmation: false
        )

        XCTAssertEqual(plan.target, target)
        XCTAssertEqual(plan.state, .invalidSource)
        XCTAssertEqual(plan.action, .refuse)
        XCTAssertEqual(plan.issues, [issue])
        XCTAssertFalse(plan.requiresConfirmation)
        XCTAssertEqual(issue.id, "error:missing-skill-md:/tmp/chau7-mcp:SKILL.md is required.")
    }
}
