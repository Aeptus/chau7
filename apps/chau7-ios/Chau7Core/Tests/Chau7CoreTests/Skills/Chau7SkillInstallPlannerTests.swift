import XCTest
@testable import Chau7Core

final class Chau7SkillInstallPlannerTests: XCTestCase {
    func testMissingTargetPlansInstall() {
        let plan = makePlan(installed: Chau7SkillInstalledSnapshot(targetExists: false))

        XCTAssertEqual(plan.state, Chau7SkillInstallState.missing)
        XCTAssertEqual(plan.action, Chau7SkillInstallPlan.Action.install)
        XCTAssertFalse(plan.requiresConfirmation)
    }

    func testInstalledWithSameSourceHashPlansNoOp() {
        let files = fileHashes(["SKILL.md": "skill"])
        let manifest = makeManifest(sourceFiles: files, installedFiles: files)

        let plan = makePlan(
            sourceFileHashes: files,
            installed: Chau7SkillInstalledSnapshot(
                targetExists: true,
                manifest: manifest,
                fileHashes: files
            )
        )

        XCTAssertEqual(plan.state, Chau7SkillInstallState.installed)
        XCTAssertEqual(plan.action, Chau7SkillInstallPlan.Action.noOp)
    }

    func testManagedOlderSourceHashPlansUpdateWhenInstalledFilesAreUntouched() {
        let installedFiles = fileHashes(["SKILL.md": "old"])
        let currentSourceFiles = fileHashes(["SKILL.md": "new"])
        let manifest = makeManifest(sourceFiles: installedFiles, installedFiles: installedFiles)

        let plan = makePlan(
            sourceFileHashes: currentSourceFiles,
            installed: Chau7SkillInstalledSnapshot(
                targetExists: true,
                manifest: manifest,
                fileHashes: installedFiles
            )
        )

        XCTAssertEqual(plan.state, Chau7SkillInstallState.stale)
        XCTAssertEqual(plan.action, Chau7SkillInstallPlan.Action.update)
    }

    func testManagedButEditedInstalledFilesPlansModified() {
        let sourceFiles = fileHashes(["SKILL.md": "source"])
        let installedFilesAtInstallTime = fileHashes(["SKILL.md": "source"])
        let editedInstalledFiles = fileHashes(["SKILL.md": "edited"])
        let manifest = makeManifest(
            sourceFiles: sourceFiles,
            installedFiles: installedFilesAtInstallTime
        )

        let plan = makePlan(
            sourceFileHashes: sourceFiles,
            installed: Chau7SkillInstalledSnapshot(
                targetExists: true,
                manifest: manifest,
                fileHashes: editedInstalledFiles
            )
        )

        XCTAssertEqual(plan.state, Chau7SkillInstallState.modified)
        XCTAssertEqual(plan.action, Chau7SkillInstallPlan.Action.refuse)
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertEqual(plan.issues.map { $0.code }, ["installed-files-modified"])
    }

    func testModifiedInstalledFilesWinOverAvailableSourceUpdate() {
        let oldSourceFiles = fileHashes(["SKILL.md": "old"])
        let newSourceFiles = fileHashes(["SKILL.md": "new"])
        let editedInstalledFiles = fileHashes(["SKILL.md": "edited"])
        let manifest = makeManifest(sourceFiles: oldSourceFiles, installedFiles: oldSourceFiles)

        let plan = makePlan(
            sourceFileHashes: newSourceFiles,
            installed: Chau7SkillInstalledSnapshot(
                targetExists: true,
                manifest: manifest,
                fileHashes: editedInstalledFiles
            )
        )

        XCTAssertEqual(plan.state, Chau7SkillInstallState.modified)
        XCTAssertEqual(plan.action, Chau7SkillInstallPlan.Action.refuse)
        XCTAssertTrue(plan.requiresConfirmation)
    }

    func testTargetExistsWithoutManifestPlansUnmanagedConflict() {
        let plan = makePlan(
            installed: Chau7SkillInstalledSnapshot(
                targetExists: true,
                manifest: nil,
                fileHashes: fileHashes(["SKILL.md": "local"])
            )
        )

        XCTAssertEqual(plan.state, Chau7SkillInstallState.unmanagedConflict)
        XCTAssertEqual(plan.action, Chau7SkillInstallPlan.Action.refuse)
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertEqual(plan.issues.map { $0.code }, ["unmanaged-conflict"])
    }

    func testTargetWithBrokenManagedMetadataPlansBroken() {
        let issue = Chau7SkillValidationIssue(
            severity: .error,
            code: "broken-manifest",
            message: ".chau7-skill.json could not be decoded.",
            path: "/Users/me/.claude/skills/chau7-magi/.chau7-skill.json"
        )

        let plan = makePlan(
            installed: Chau7SkillInstalledSnapshot(
                targetExists: true,
                manifest: nil,
                fileHashes: fileHashes(["SKILL.md": "local"]),
                issues: [issue]
            )
        )

        XCTAssertEqual(plan.state, Chau7SkillInstallState.broken)
        XCTAssertEqual(plan.action, Chau7SkillInstallPlan.Action.refuse)
        XCTAssertEqual(plan.issues, [issue])
    }

    func testSourceErrorPlansInvalidSourceBeforeTargetChecks() {
        let issue = Chau7SkillValidationIssue(
            severity: .error,
            code: "missing-skill-md",
            message: "SKILL.md is required.",
            path: "/tmp/chau7-magi/SKILL.md"
        )

        let plan = makePlan(
            sourceValidationIssues: [issue],
            installed: Chau7SkillInstalledSnapshot(targetExists: false)
        )

        XCTAssertEqual(plan.state, Chau7SkillInstallState.invalidSource)
        XCTAssertEqual(plan.action, Chau7SkillInstallPlan.Action.refuse)
        XCTAssertEqual(plan.issues, [issue])
    }

    func testSourceWarningsDoNotBlockPlanning() {
        let issue = Chau7SkillValidationIssue(
            severity: .warning,
            code: "unknown-directory",
            message: "Unknown skill directory.",
            path: "/tmp/chau7-magi/tmp"
        )

        let plan = makePlan(
            sourceValidationIssues: [issue],
            installed: Chau7SkillInstalledSnapshot(targetExists: false)
        )

        XCTAssertEqual(plan.state, Chau7SkillInstallState.missing)
        XCTAssertEqual(plan.action, Chau7SkillInstallPlan.Action.install)
        XCTAssertTrue(plan.issues.isEmpty)
    }

    func testUnsupportedProviderPlansUnsupportedProvider() {
        let plan = makePlan(
            providerDetection: unavailableProvider(),
            installed: Chau7SkillInstalledSnapshot(targetExists: false)
        )

        XCTAssertEqual(plan.state, Chau7SkillInstallState.unsupportedProvider)
        XCTAssertEqual(plan.action, Chau7SkillInstallPlan.Action.refuse)
        XCTAssertEqual(plan.issues.map { $0.code }, ["unsupported-provider"])
    }

    private func makePlan(
        sourceFileHashes: [String: Chau7SkillFileHash]? = nil,
        sourceValidationIssues: [Chau7SkillValidationIssue] = [],
        providerDetection: Chau7SkillProviderDetection? = nil,
        installed: Chau7SkillInstalledSnapshot
    ) -> Chau7SkillInstallPlan {
        Chau7SkillInstallPlanner.plan(
            source: source,
            target: target,
            sourceFileHashes: sourceFileHashes ?? fileHashes(["SKILL.md": "skill"]),
            sourceValidationIssues: sourceValidationIssues,
            providerDetection: providerDetection ?? availableProvider(),
            installed: installed
        )
    }

    private var source: Chau7SkillSource {
        Chau7SkillSource(
            id: "chau7-magi",
            kind: .bundled,
            rootDirectory: "/Users/me/.chau7/skills/source/chau7-magi",
            version: "1.0.0"
        )
    }

    private var target: Chau7SkillInstallTarget {
        ClaudeSkillInstallTargetResolver.userTarget(
            skillID: "chau7-magi",
            homeDirectory: "/Users/me"
        )
    }

    private func makeManifest(
        sourceFiles: [String: Chau7SkillFileHash],
        installedFiles: [String: Chau7SkillFileHash]
    ) -> Chau7SkillManifest {
        Chau7SkillManifest(
            skillID: "chau7-magi",
            skillVersion: "1.0.0",
            provider: .claude,
            scope: .user,
            sourcePath: "/Users/me/.chau7/skills/source/chau7-magi",
            sourceHash: Chau7SkillManifestHashing.sourceHash(for: sourceFiles),
            installedAt: "2026-07-09T12:00:00Z",
            files: installedFiles
        )
    }

    private func fileHashes(_ entries: [String: String]) -> [String: Chau7SkillFileHash] {
        entries.mapValues { Chau7SkillFileHash(value: $0) }
    }

    private func availableProvider() -> Chau7SkillProviderDetection {
        Chau7SkillProviderDetection(
            provider: .claude,
            isAvailable: true,
            reasons: [.explicitlyRequested],
            providerRoot: "/Users/me/.claude",
            executableName: "claude"
        )
    }

    private func unavailableProvider() -> Chau7SkillProviderDetection {
        Chau7SkillProviderDetection(
            provider: .claude,
            isAvailable: false,
            reasons: [],
            providerRoot: "/Users/me/.claude",
            executableName: "claude"
        )
    }
}
