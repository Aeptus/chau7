import XCTest
@testable import Chau7Core

final class CodexFeedbackDetectionTests: XCTestCase {
    func testParsesStructuredRequestUserInput() throws {
        let arguments = #"{"questions":[{"header":"Delivery","id":"delivery","question":"Which delivery model?","options":[{"label":"Adapter layer (Recommended)","description":"Decoupled"},{"label":"Direct broker call","description":"Coupled"}]}]}"#
        let line = try rolloutLine(payload: [
            "type": "function_call",
            "name": "request_user_input",
            "call_id": "call_123",
            "arguments": arguments
        ])

        XCTAssertEqual(
            CodexRolloutFeedbackParser.parse(line: line),
            .structuredPrompt(CodexFeedbackPrompt(
                callID: "call_123",
                message: "Which delivery model?",
                optionLabels: ["Adapter layer (Recommended)", "Direct broker call"]
            ))
        )
    }

    func testParsesStructuredPromptResolution() throws {
        let line = try rolloutLine(payload: [
            "type": "function_call_output",
            "call_id": "call_123",
            "output": #"{"answers":{"delivery":{"answers":["Adapter layer (Recommended)"]}}}"#
        ])

        XCTAssertEqual(
            CodexRolloutFeedbackParser.parse(line: line),
            .toolCallCompleted(
                callID: "call_123",
                output: #"{"answers":{"delivery":{"answers":["Adapter layer (Recommended)"]}}}"#
            )
        )
    }

    func testRecognizesUnavailableStructuredInputWithoutTreatingItAsPending() {
        XCTAssertTrue(CodexRolloutFeedbackParser.isUnavailableOutput(
            "request_user_input is unavailable in Default mode"
        ))
        XCTAssertTrue(CodexRolloutFeedbackParser.isUnavailableOutput(
            "This request requires Plan mode"
        ))
        XCTAssertFalse(CodexRolloutFeedbackParser.isUnavailableOutput(
            #"{"answers":{"delivery":{"answers":["Adapter layer"]}}}"#
        ))
    }

    func testIgnoresUnrelatedRolloutRecords() throws {
        let command = try rolloutLine(payload: [
            "type": "function_call",
            "name": "exec_command",
            "call_id": "call_123",
            "arguments": #"{"cmd":"swift test"}"#
        ])
        XCTAssertNil(CodexRolloutFeedbackParser.parse(line: command))
        XCTAssertNil(CodexRolloutFeedbackParser.parse(line: "not json"))
    }

    func testDetectsExplicitNumberedChoiceEnding() throws {
        let message = """
        Five findings are actionable.

        Recommended commit grouping:

        - #1 supply-chain cache correctness
        - #2 deterministic Pages builds
        - #3 webhook observability
        - #4 local Channels environment
        - #5 onboarding documentation

        Tell me `all` or the numbers you want addressed.
        """

        let proposal = try XCTUnwrap(CodexFeedbackProposalClassifier.detect(in: message))
        XCTAssertEqual(proposal.optionLabels.count, 5)
        XCTAssertEqual(proposal.optionLabels.first, "supply-chain cache correctness")
        XCTAssertEqual(proposal.message, "Tell me all or the numbers you want addressed.")
        XCTAssertEqual(CodexFeedbackProposalClassifier.assess(in: message)?.confidence, .high)
    }

    func testDirectTerminalQuestionIsMediumConfidenceAttention() throws {
        let message = """
        The migration is ready and tests pass.

        Should I apply it to the remaining workspaces?
        """

        let assessment = try XCTUnwrap(CodexFeedbackProposalClassifier.assess(in: message))
        XCTAssertEqual(assessment.confidence, .medium)
        XCTAssertTrue(assessment.shouldRequestAttention)
        XCTAssertEqual(assessment.evidence, ["direct_terminal_question"])
        XCTAssertNotNil(CodexFeedbackProposalClassifier.detect(in: message))
    }

    func testConversationalTerminalQuestionStaysLowConfidence() throws {
        let message = """
        This architecture follows the existing adapter pattern.

        Does that explanation make sense?
        """

        let assessment = try XCTUnwrap(CodexFeedbackProposalClassifier.assess(in: message))
        XCTAssertEqual(assessment.confidence, .low)
        XCTAssertFalse(assessment.shouldRequestAttention)
        XCTAssertNil(CodexFeedbackProposalClassifier.detect(in: message))
    }

    func testDetectsFrenchInlineChoices() throws {
        let message = """
        Il reste enfin le mapping :

        Abonnement OpenAI → équipe ?
        Abonnement Anthropic → équipe ?

        Les choix possibles sont `research_development`, `sales_marketing` et `general_administrative`.
        """

        let proposal = try XCTUnwrap(CodexFeedbackProposalClassifier.detect(in: message))
        XCTAssertEqual(
            proposal.optionLabels,
            ["research_development", "sales_marketing", "general_administrative"]
        )
    }

    func testDetectsTwoRecommendationsAwaitingConfirmation() throws {
        let message = """
        Il reste deux décisions paramétriques.

        1. Amortissement du développement continu
        Je recommande un amortissement linéaire sur 3 ans.

        2. Clé cloud R&D/COGS
        Je recommande une moyenne des 3 derniers mois.

        Ces deux recommandations restent TBD tant que tu ne les confirmes pas.
        """

        let proposal = try XCTUnwrap(CodexFeedbackProposalClassifier.detect(in: message))
        XCTAssertEqual(proposal.optionLabels.count, 2)
    }

    func testDoesNotClassifyOrdinaryRecommendationList() {
        let message = """
        Recommended architecture:
        1. Run a metadata job.
        2. Store scores immediately.
        3. Queue repository analysis.

        This gives every tool an initial score quickly. Changes remain uncommitted.
        """

        XCTAssertNil(CodexFeedbackProposalClassifier.detect(in: message))
    }

    func testDoesNotClassifyCompletedAnswerThatMentionsOptions() {
        let message = """
        Implemented the selected option and verified all tests.

        The documentation explains how users can choose a deployment model later.
        Worktree is clean.
        """

        XCTAssertNil(CodexFeedbackProposalClassifier.detect(in: message))
    }

    private func rolloutLine(payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-07-31T10:00:00Z",
            "type": "response_item",
            "payload": payload
        ], options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
