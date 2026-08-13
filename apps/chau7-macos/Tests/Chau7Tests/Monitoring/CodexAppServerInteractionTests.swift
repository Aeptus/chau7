import XCTest
@testable import Chau7Core

final class CodexAppServerInteractionTests: XCTestCase {
    func testParsesRequestUserInputWithSharedPromptShape() throws {
        let line = #"{"id":42,"method":"tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-2","questions":[{"question":"Pick a rollout strategy","options":[{"label":"Gradual"},{"label":"Immediate"}]}]}}"#

        let interaction = try XCTUnwrap(CodexAppServerInteractionParser.parse(line: line))
        XCTAssertEqual(interaction.requestID, "42")
        XCTAssertEqual(interaction.kind, .userInput)
        XCTAssertEqual(interaction.phase, .requested)
        XCTAssertEqual(interaction.threadID, "thread-1")
        XCTAssertEqual(interaction.turnID, "turn-2")
        XCTAssertEqual(interaction.prompt?.message, "Pick a rollout strategy")
        XCTAssertEqual(interaction.prompt?.optionLabels, ["Gradual", "Immediate"])
    }

    func testParsesApprovalRequestAndResolution() throws {
        let request = try XCTUnwrap(CodexAppServerInteractionParser.parse(
            line: #"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1"}}"#
        ))
        let resolution = try XCTUnwrap(CodexAppServerInteractionParser.parse(
            line: #"{"method":"serverRequest/resolved","params":{"requestId":"approval-1","threadId":"thread-1","turnId":"turn-1"}}"#
        ))

        XCTAssertEqual(request.kind, .approval)
        XCTAssertEqual(request.phase, .requested)
        XCTAssertEqual(resolution.requestID, "approval-1")
        XCTAssertNil(resolution.kind)
        XCTAssertEqual(resolution.phase, .resolved)
    }

    func testTrackerPreservesOtherPendingInteractionOnResolution() {
        var tracker = CodexAppServerInteractionTracker()
        let approval = CodexAppServerInteraction(
            requestID: "approval",
            kind: .approval,
            phase: .requested
        )
        let input = CodexAppServerInteraction(
            requestID: "input",
            kind: .userInput,
            phase: .requested
        )
        _ = tracker.consume(approval)
        _ = tracker.consume(input)

        let outcome = tracker.consume(CodexAppServerInteraction(
            requestID: "approval",
            kind: nil,
            phase: .resolved
        ))
        XCTAssertEqual(outcome.resolvedKind, .approval)
        XCTAssertEqual(outcome.pendingKinds, [.userInput])
    }
}
