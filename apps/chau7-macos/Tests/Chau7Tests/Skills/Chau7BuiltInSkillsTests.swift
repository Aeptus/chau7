import XCTest
@testable import Chau7Core

final class Chau7SkillBuiltInSkillsTests: XCTestCase {
    func testBuiltInSkillsValidateAgainstSharedAgentSkillsContract() throws {
        for skillID in ["chau7-magi", "chau7-mcp"] {
            let root = packageRoot()
                .appendingPathComponent("Resources/Skills/\(skillID)", isDirectory: true)

            XCTAssertEqual(
                Chau7SkillValidator.validate(rootDirectory: root.path),
                [],
                "\(skillID) should be a valid Agent Skill"
            )
        }
    }

    func testBuiltInMagiSkillContainsRequiredOperatingGuidance() throws {
        let content = try skillMarkdown("chau7-magi")

        XCTAssertTrue(content.contains("Use MAGI when"))
        XCTAssertTrue(content.contains("magi ask"))
        XCTAssertTrue(content.contains("Never fake council output"))
        XCTAssertTrue(content.contains("direct answer"))
        XCTAssertTrue(content.contains("magi replay <run-id>"))
        XCTAssertTrue(content.contains("magi share <run-id>"))
        XCTAssertTrue(content.contains("decision.json"))
        XCTAssertTrue(content.contains("technical.jsonl"))
    }

    func testBuiltInMCPSkillContainsRequiredSafetyGuidance() throws {
        let content = try skillMarkdown("chau7-mcp")

        XCTAssertTrue(content.contains("Chau7 MCP lets agents control"))
        XCTAssertTrue(content.contains("Safe Orchestration"))
        XCTAssertTrue(content.contains("Permission Boundaries"))
        XCTAssertTrue(content.contains("Logs And Diagnostics"))
        XCTAssertTrue(content.contains("~/Library/Logs/Chau7.log"))
        XCTAssertTrue(content.contains("Do not kill, restart, force-quit, or relaunch the Chau7 app"))
    }

    func testBuildAppCopiesRawBuiltInSkillsIntoAppBundle() throws {
        let buildApp = packageRoot().appendingPathComponent("Scripts/build-app.sh")
        let content = try String(contentsOf: buildApp, encoding: .utf8)

        XCTAssertTrue(content.contains("$ROOT_DIR/Resources/Skills"))
        XCTAssertTrue(content.contains("$CONTENTS/Resources/Skills"))
        XCTAssertTrue(content.contains("Copied built-in skills"))
    }

    private func skillMarkdown(_ skillID: String) throws -> String {
        let url = packageRoot()
            .appendingPathComponent("Resources/Skills/\(skillID)/SKILL.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func packageRoot() -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}
