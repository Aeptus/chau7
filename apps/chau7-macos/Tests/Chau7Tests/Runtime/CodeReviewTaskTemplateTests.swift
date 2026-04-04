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
