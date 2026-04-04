import XCTest
@testable import Chau7Core

final class CodeReviewTaskTemplateTests: XCTestCase {
    func testPromptIncludesCommitRangeAndConstraints() {
        let prompt = CodeReviewTaskTemplate.prompt(
            baseCommit: "abc123",
            headCommit: "def456",
            extraInstructions: "Focus on auth changes."
        )

        XCTAssertTrue(prompt.contains("abc123..def456"))
        XCTAssertTrue(prompt.contains("Do not edit files"))
        XCTAssertTrue(prompt.contains("Focus on auth changes."))
    }

    func testPromptForStagedDiffIncludesFilesAndPatch() {
        let prompt = CodeReviewTaskTemplate.promptForStagedDiff(
            stagedFiles: ["Sources/App.swift", "Tests/AppTests.swift"],
            diff: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            @@ -1 +1 @@
            -old
            +new
            """,
            extraInstructions: "Focus on staged logic only."
        )

        XCTAssertTrue(prompt.contains("Review the staged changes that are about to be committed."))
        XCTAssertTrue(prompt.contains("- Sources/App.swift"))
        XCTAssertTrue(prompt.contains("```diff"))
        XCTAssertTrue(prompt.contains("Focus on staged logic only."))
        XCTAssertTrue(prompt.contains("Do not speculate about unstaged changes."))
    }

    func testResultSchemaRequiresFindingsAndRecommendations() {
        let schema = CodeReviewTaskTemplate.resultSchema
        let errors = StructuredResultExtractor.validate(
            value: .object([
                "summary": .string("ok"),
                "confidence": .string("high")
            ]),
            schema: schema
        )

        XCTAssertTrue(errors.contains("$.findings is required"))
        XCTAssertTrue(errors.contains("$.recommendations is required"))
    }
}
