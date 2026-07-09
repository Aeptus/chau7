import XCTest
@testable import Chau7Core

final class Chau7SkillValidatorTests: XCTestCase {
    func testValidMinimalAgentSkillPasses() throws {
        let skill = try makeSkill(
            name: "repo-review",
            skillMarkdown: """
            ---
            name: repo-review
            description: Review repository changes with project-specific context.
            ---

            Use this skill when reviewing code in this repository.
            """
        )
        defer { remove(skill.root) }

        XCTAssertEqual(Chau7SkillValidator.validate(rootDirectory: skill.root.path), [])
    }

    func testFolderMustExist() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-skill-\(UUID().uuidString)")
            .path

        XCTAssertEqual(
            Chau7SkillValidator.validate(rootDirectory: path).map(\.code),
            ["missing-folder"]
        )
    }

    func testSkillPathMustBeFolder() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-skill-folder-\(UUID().uuidString)")
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)
        defer { remove(file) }

        XCTAssertEqual(
            Chau7SkillValidator.validate(rootDirectory: file.path).map(\.code),
            ["skill-path-not-folder"]
        )
    }

    func testSkillMarkdownIsRequired() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-skill-md-\(UUID().uuidString)")
            .appendingPathComponent("repo-review")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { remove(root) }

        XCTAssertEqual(
            Chau7SkillValidator.validate(rootDirectory: root.path).map(\.code),
            ["missing-skill-md"]
        )
    }

    func testYamlFrontmatterIsRequiredAndMustClose() throws {
        let missing = try makeSkill(
            name: "missing-frontmatter",
            skillMarkdown: """
            # Missing frontmatter
            """
        )
        defer { remove(missing.root) }

        let unterminated = try makeSkill(
            name: "unterminated-frontmatter",
            skillMarkdown: """
            ---
            name: unterminated-frontmatter
            description: Missing the closing delimiter.
            """
        )
        defer { remove(unterminated.root) }

        XCTAssertEqual(
            Chau7SkillValidator.validate(rootDirectory: missing.root.path).map(\.code),
            ["missing-frontmatter"]
        )
        XCTAssertEqual(
            Chau7SkillValidator.validate(rootDirectory: unterminated.root.path).map(\.code),
            ["unterminated-frontmatter"]
        )
    }

    func testNameAndDescriptionAreRequired() throws {
        let skill = try makeSkill(
            name: "missing-fields",
            skillMarkdown: """
            ---
            allowed-tools: Bash(chau7 *)
            ---

            Missing shared required fields.
            """
        )
        defer { remove(skill.root) }

        XCTAssertEqual(
            Chau7SkillValidator.validate(rootDirectory: skill.root.path).map(\.code),
            ["missing-name", "missing-description"]
        )
    }

    func testNameMustBeLowercaseKebabCase() {
        let valid = [
            "a",
            "skill",
            "skill-1",
            "repo-review",
            "chau7-mcp"
        ]
        let invalid = [
            "",
            "Repo-Review",
            "repo_review",
            "repo review",
            "-repo-review",
            "repo-review-",
            "repo--review",
            "repo.review"
        ]

        XCTAssertTrue(valid.allSatisfy(Chau7SkillValidator.isValidSkillName))
        XCTAssertFalse(invalid.contains(where: Chau7SkillValidator.isValidSkillName))
    }

    func testDirectoryNameMustMatchFrontmatterName() throws {
        let skill = try makeSkill(
            name: "folder-name",
            skillMarkdown: """
            ---
            name: declared-name
            description: Directory name mismatch.
            ---
            """
        )
        defer { remove(skill.root) }

        XCTAssertEqual(
            Chau7SkillValidator.validate(rootDirectory: skill.root.path).map(\.code),
            ["directory-name-mismatch"]
        )
    }

    func testUnknownAndProviderSpecificFrontmatterIsAllowed() throws {
        let skill = try makeSkill(
            name: "provider-fields",
            skillMarkdown: """
            ---
            name: provider-fields
            description: Skill with provider-specific metadata.
            allowed-tools: Bash(magi *)
            model: opus
            context: terminal
            x-provider-field: should-pass
            ---

            Provider-specific frontmatter is not part of shared validation.
            """
        )
        defer { remove(skill.root) }

        XCTAssertEqual(Chau7SkillValidator.validate(rootDirectory: skill.root.path), [])
    }

    func testOptionalStandardFoldersAreAllowedWhenDirectories() throws {
        let skill = try makeSkill(
            name: "with-folders",
            skillMarkdown: """
            ---
            name: with-folders
            description: Uses optional Agent Skills folders.
            ---
            """
        )
        defer { remove(skill.root) }

        for directory in ["scripts", "references", "assets"] {
            try FileManager.default.createDirectory(
                at: skill.root.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }

        XCTAssertEqual(Chau7SkillValidator.validate(rootDirectory: skill.root.path), [])
    }

    func testOptionalStandardFoldersCannotBeFiles() throws {
        let skill = try makeSkill(
            name: "bad-folders",
            skillMarkdown: """
            ---
            name: bad-folders
            description: Has invalid optional folder paths.
            ---
            """
        )
        defer { remove(skill.root) }

        try "not a directory".write(
            to: skill.root.appendingPathComponent("scripts"),
            atomically: true,
            encoding: .utf8
        )
        try "not a directory".write(
            to: skill.root.appendingPathComponent("assets"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            Set(Chau7SkillValidator.validate(rootDirectory: skill.root.path).map(\.code)),
            ["optional-path-not-directory"]
        )
        XCTAssertEqual(Chau7SkillValidator.validate(rootDirectory: skill.root.path).count, 2)
    }

    func testValidateSourceUsesSourceRootDirectory() throws {
        let skill = try makeSkill(
            name: "source-validation",
            skillMarkdown: """
            ---
            name: source-validation
            description: Validate through source wrapper.
            ---
            """
        )
        defer { remove(skill.root) }

        let source = Chau7SkillSource(
            id: "source-validation",
            kind: .external,
            rootDirectory: "\(skill.root.path)/"
        )

        XCTAssertEqual(Chau7SkillValidator.validate(source: source), [])
    }

    private func makeSkill(name: String, skillMarkdown: String) throws -> (container: URL, root: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-skill-validator-\(UUID().uuidString)")
        let root = container.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try skillMarkdown.write(
            to: root.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return (container, root)
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
