import XCTest
@testable import Chau7Core

final class MagiFirstRunTests: XCTestCase {
    func testDefaultSelectionsUseSupportedProvidersAndMaxReasoning() {
        let selections = MagiFirstRunPlanner.defaultSelections()

        XCTAssertEqual(selections[.melchior]?.provider, .codex)
        XCTAssertEqual(selections[.balthasar]?.provider, .claude)
        XCTAssertEqual(selections[.casper]?.provider, .gemini)
        XCTAssertTrue(selections.values.allSatisfy { $0.modelClass == .balanced })
        XCTAssertTrue(selections.values.allSatisfy { $0.reasoning == .max })
    }

    func testSharedSelectionsApplyOneProviderAndClassToEveryMember() {
        let selections = MagiFirstRunPlanner.sharedSelections(
            provider: .claude,
            modelClass: .strongest
        )

        XCTAssertEqual(Set(selections.keys), Set(MagiMemberID.allCases))
        XCTAssertTrue(selections.values.allSatisfy { $0.provider == .claude })
        XCTAssertTrue(selections.values.allSatisfy { $0.modelClass == .strongest })
        XCTAssertTrue(selections.values.allSatisfy { $0.reasoning == .max })
    }

    func testFirstRunPromptTextRendersNumberedChoices() {
        XCTAssertEqual(
            MagiFirstRunPromptText.providerChoiceLines(defaultValue: .claude),
            [
                "Provider choices",
                "  1. codex",
                "  2. claude",
                "  3. gemini",
                "Default: claude"
            ]
        )

        XCTAssertEqual(
            MagiFirstRunPromptText.modelClassChoiceLines(defaultValue: .strongest),
            [
                "Class choices",
                "  1. fast",
                "  2. balanced",
                "  3. strongest",
                "Default: strongest"
            ]
        )
    }

    func testFirstRunConfigUsesSelections() {
        let selections: [MagiMemberID: MagiFirstRunMemberSelection] = [
            .melchior: MagiFirstRunMemberSelection(memberID: .melchior, provider: .codex, modelClass: .fast),
            .balthasar: MagiFirstRunMemberSelection(memberID: .balthasar, provider: .claude, modelClass: .strongest),
            .casper: MagiFirstRunMemberSelection(memberID: .casper, provider: .gemini, modelClass: .balanced)
        ]

        let config = MagiFirstRunPlanner.config(from: selections)

        XCTAssertEqual(config.members[.melchior]?.provider, "codex")
        XCTAssertEqual(config.members[.melchior]?.modelClass, .fast)
        XCTAssertEqual(config.members[.balthasar]?.provider, "claude")
        XCTAssertEqual(config.members[.balthasar]?.modelClass, .strongest)
        XCTAssertEqual(config.members[.casper]?.provider, "gemini")
        XCTAssertEqual(config.members[.casper]?.reasoning, .max)
        XCTAssertEqual(config.fallbackStrategy, .duplicate)
    }

    func testFallbackDuplicationUsesFirstPassingSelectedProvider() {
        let selections: [MagiMemberID: MagiFirstRunMemberSelection] = [
            .melchior: MagiFirstRunMemberSelection(memberID: .melchior, provider: .codex, modelClass: .fast),
            .balthasar: MagiFirstRunMemberSelection(memberID: .balthasar, provider: .claude, modelClass: .strongest),
            .casper: MagiFirstRunMemberSelection(memberID: .casper, provider: .gemini, modelClass: .balanced)
        ]
        let results = [
            MagiProviderDryRunResult(provider: .codex, passed: false),
            MagiProviderDryRunResult(provider: .claude, passed: true),
            MagiProviderDryRunResult(provider: .gemini, passed: false)
        ]

        let plan = MagiFirstRunPlanner.fallbackPlan(selections: selections, dryRunResults: results)
        XCTAssertEqual(
            plan,
            MagiFallbackDuplicationPlan(
                replacementProvider: .claude,
                failedProviders: [.codex, .gemini],
                affectedMembers: [.melchior, .casper]
            )
        )

        let updated = MagiFirstRunPlanner.applyingFallbackDuplication(plan!, to: selections)
        XCTAssertEqual(updated[.melchior]?.provider, .claude)
        XCTAssertEqual(updated[.melchior]?.modelClass, .fast)
        XCTAssertEqual(updated[.balthasar]?.provider, .claude)
        XCTAssertEqual(updated[.casper]?.provider, .claude)
        XCTAssertEqual(updated[.casper]?.modelClass, .balanced)
    }

    func testFallbackDuplicationIsUnavailableWhenAllSelectedProvidersFail() {
        let selections = MagiFirstRunPlanner.defaultSelections()
        let results = [
            MagiProviderDryRunResult(provider: .codex, passed: false),
            MagiProviderDryRunResult(provider: .claude, passed: false),
            MagiProviderDryRunResult(provider: .gemini, passed: false)
        ]

        XCTAssertNil(MagiFirstRunPlanner.fallbackPlan(selections: selections, dryRunResults: results))
    }

    func testConfigTOMLCodecRoundTripsFirstRunConfig() throws {
        let config = MagiFirstRunPlanner.config(from: [
            .melchior: MagiFirstRunMemberSelection(memberID: .melchior, provider: .codex, modelClass: .fast),
            .balthasar: MagiFirstRunMemberSelection(memberID: .balthasar, provider: .claude, modelClass: .strongest),
            .casper: MagiFirstRunMemberSelection(memberID: .casper, provider: .gemini, modelClass: .balanced)
        ])

        let content = MagiConfigTOMLCodec.encode(config)
        let decoded = try MagiConfigTOMLCodec.decode(content)

        XCTAssertTrue(content.contains("[members.melchior]"))
        XCTAssertTrue(content.contains("provider = \"codex\""))
        XCTAssertTrue(content.contains("class = \"strongest\""))
        XCTAssertEqual(decoded, config)
    }

    func testConfigTOMLCodecRejectsInvalidClass() {
        let content = """
        schema_version = 1

        [members.melchior]
        provider = "codex"
        class = "largest"
        reasoning = "max"
        """

        XCTAssertThrowsError(try MagiConfigTOMLCodec.decode(content)) { error in
            XCTAssertEqual(
                error as? MagiConfigFileError,
                .invalidValue(field: "members.melchior.class", value: "largest", allowed: ["fast", "balanced", "strongest"])
            )
        }
    }

    func testInstallerCreatesConfigAndPersonaFiles() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = MagiCLIPaths(homeDirectory: home.path, currentDirectory: "/repo")
        let config = MagiFirstRunPlanner.config(from: MagiFirstRunPlanner.defaultSelections())

        let result = try MagiFirstRunInstaller.install(config: config, paths: paths)

        XCTAssertEqual(result.createdPaths.count, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.globalConfigPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.personaPath(for: .melchior)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.personaPath(for: .balthasar)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.personaPath(for: .casper)))
        XCTAssertEqual(MagiFirstRunInstaller.missingPersonaFiles(paths: paths), [])

        let decoded = try MagiConfigTOMLCodec.decode(String(contentsOfFile: paths.globalConfigPath, encoding: .utf8))
        XCTAssertEqual(decoded, config)

        let melchior = try String(contentsOfFile: paths.personaPath(for: .melchior), encoding: .utf8)
        XCTAssertTrue(melchior.contains("# Melchior"))
        XCTAssertTrue(melchior.contains("## Veto Policy"))
    }

    func testInstallerDoesNotOverwriteExistingFilesByDefault() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = MagiCLIPaths(homeDirectory: home.path, currentDirectory: "/repo")
        let config = MagiFirstRunPlanner.config(from: MagiFirstRunPlanner.defaultSelections())
        try MagiFirstRunInstaller.install(config: config, paths: paths)

        try "custom-config".write(toFile: paths.globalConfigPath, atomically: true, encoding: .utf8)
        try "custom-persona".write(toFile: paths.personaPath(for: .casper), atomically: true, encoding: .utf8)

        let result = try MagiFirstRunInstaller.install(config: config, paths: paths)

        XCTAssertEqual(result.createdPaths, [])
        XCTAssertEqual(result.skippedPaths.count, 4)
        XCTAssertEqual(try String(contentsOfFile: paths.globalConfigPath, encoding: .utf8), "custom-config")
        XCTAssertEqual(try String(contentsOfFile: paths.personaPath(for: .casper), encoding: .utf8), "custom-persona")
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("magi-first-run-\(UUID().uuidString)")
    }
}
