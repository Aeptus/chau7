import XCTest
@testable import Chau7Core

final class RuntimeDelegationPolicyTests: XCTestCase {
    func testValidateStartRejectsExceededTurnBudget() {
        let policy = RuntimeDelegationPolicy(maxTurns: 1)
        XCTAssertEqual(
            policy.validateStart(turnCount: 2, elapsedMs: 0, delegationDepth: 0),
            "Session exceeded max_turns 1."
        )
    }

    func testValidateChildCreationRejectsDisallowedDelegation() {
        let policy = RuntimeDelegationPolicy(allowChildDelegation: false, maxDelegationDepth: 0)
        XCTAssertEqual(
            policy.validateChildCreation(childDelegationDepth: 1),
            "Session policy disallows child delegation."
        )
    }

    func testValidateToolRejectsBlockedTool() {
        let policy = RuntimeDelegationPolicy(blockedTools: ["Bash"])
        XCTAssertEqual(
            policy.validateTool("Bash"),
            "Tool 'Bash' is blocked by session policy."
        )
    }
}
