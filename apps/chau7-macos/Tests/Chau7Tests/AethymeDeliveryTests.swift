import XCTest
@testable import Chau7Core

final class AethymeDeliveryTests: XCTestCase {
    func testTargetRoundTripsReservedSessionCharacters() {
        let target = AethymeDeliveryTarget(tabID: "tab-17", aiSessionID: "codex/session?one")
        XCTAssertEqual(AethymeDeliveryTarget(opaqueValue: target.opaqueValue), target)
    }

    func testClaimDecodesBrokerSnakeCaseEnvelope() throws {
        let json = #"""
        {
          "adapter": "chau7",
          "worker": "chau7-123",
          "delivery": {
            "item": { "id": 7, "generation": 3 },
            "subscription": {
              "id": 9,
              "target": "chau7://tab/tab-17?session=codex-42",
              "policy": "review_and_push"
            },
            "watch": {
              "id": 11,
              "canonical_repository": "example/project",
              "pr_number": 52,
              "head_sha": "0123456789012345678901234567890123456789"
            },
            "batch": {
              "id": 13,
              "head_sha": "0123456789012345678901234567890123456789"
            },
            "prompt": "Review metadata only"
          }
        }
        """#

        let report = try JSONDecoder().decode(AethymeDeliveryClaimReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.delivery?.item.id, 7)
        XCTAssertEqual(report.delivery?.item.generation, 3)
        XCTAssertEqual(report.delivery?.subscription.policy, .reviewAndPush)
        XCTAssertEqual(report.delivery?.watch.canonicalRepository, "example/project")
        XCTAssertEqual(report.delivery?.watch.prNumber, 52)
    }

    func testReadyRequiresExactIdentityRepositoryAndIdlePrompt() {
        let target = AethymeDeliveryTarget(tabID: "tab-17", aiSessionID: "codex-42")
        let tab = snapshot()
        XCTAssertEqual(
            AethymeDeliveryReadinessPolicy.evaluate(
                target: target,
                tab: tab,
                repositoryRoot: "/tmp/project"
            ),
            .ready
        )
    }

    func testBusyAndUnavailableSurfacesRetry() {
        let target = AethymeDeliveryTarget(tabID: "tab-17", aiSessionID: "codex-42")
        for status in ["running", "waitingForInput", "approvalRequired", "stuck", "exited"] {
            XCTAssertEqual(
                AethymeDeliveryReadinessPolicy.evaluate(
                    target: target,
                    tab: snapshot(status: status),
                    repositoryRoot: "/tmp/project"
                ),
                .retry(errorCode: "target_tab_busy")
            )
        }
        XCTAssertEqual(
            AethymeDeliveryReadinessPolicy.evaluate(
                target: target,
                tab: nil,
                repositoryRoot: "/tmp/project"
            ),
            .retry(errorCode: "target_tab_missing")
        )
        XCTAssertEqual(
            AethymeDeliveryReadinessPolicy.evaluate(
                target: target,
                tab: snapshot(isAtPrompt: false),
                repositoryRoot: "/tmp/project"
            ),
            .retry(errorCode: "target_not_at_prompt")
        )
        XCTAssertEqual(
            AethymeDeliveryReadinessPolicy.evaluate(
                target: target,
                tab: snapshot(hasPendingInput: true),
                repositoryRoot: "/tmp/project"
            ),
            .retry(errorCode: "target_has_pending_input")
        )
    }

    func testIdentityAndRepositoryMismatchFailClosed() {
        let target = AethymeDeliveryTarget(tabID: "tab-17", aiSessionID: "codex-42")
        XCTAssertEqual(
            AethymeDeliveryReadinessPolicy.evaluate(
                target: target,
                tab: snapshot(aiSessionID: "codex-other"),
                repositoryRoot: "/tmp/project"
            ),
            .failed(errorCode: "target_session_mismatch")
        )
        XCTAssertEqual(
            AethymeDeliveryReadinessPolicy.evaluate(
                target: target,
                tab: snapshot(repositoryRoot: "/tmp/other"),
                repositoryRoot: "/tmp/project"
            ),
            .failed(errorCode: "target_repository_mismatch")
        )
    }

    func testCommandArgumentsDoNotUseAShell() {
        XCTAssertEqual(
            AethymeDeliveryCommand.claim(worker: "chau7-123"),
            [
                "broker", "deliveries", "claim", "--adapter", "chau7",
                "--worker", "chau7-123", "--seconds", "120", "--json"
            ]
        )
        XCTAssertEqual(
            AethymeDeliveryCommand.complete(
                id: 7,
                worker: "chau7-123",
                generation: 3,
                outcome: "retry",
                errorCode: "target_tab_busy"
            ).suffix(5),
            ["--outcome", "retry", "--error-code", "target_tab_busy", "--json"]
        )
    }

    func testPendingInputTracksOnlyTheUnsubmittedPromptFragment() {
        XCTAssertEqual(
            AethymePendingInputPolicy.nextFragment(
                existing: nil,
                input: "review ",
                isAtPrompt: true
            ),
            "review "
        )
        XCTAssertEqual(
            AethymePendingInputPolicy.nextFragment(
                existing: "review ",
                input: "this\nnext",
                isAtPrompt: true
            ),
            "next"
        )
        XCTAssertNil(
            AethymePendingInputPolicy.nextFragment(
                existing: "review this",
                input: "\r",
                isAtPrompt: true
            )
        )
        XCTAssertNil(
            AethymePendingInputPolicy.nextFragment(
                existing: "stale",
                input: "interactive",
                isAtPrompt: false
            )
        )
    }

    private func snapshot(
        aiSessionID: String? = "codex-42",
        repositoryRoot: String? = "/tmp/project",
        status: String = "idle",
        isAtPrompt: Bool = true,
        hasPendingInput: Bool = false
    ) -> AethymeDeliveryTabSnapshot {
        AethymeDeliveryTabSnapshot(
            tabID: "tab-17",
            aiSessionID: aiSessionID,
            aiProvider: "codex",
            repositoryRoot: repositoryRoot,
            status: status,
            isAtPrompt: isAtPrompt,
            hasPendingInput: hasPendingInput
        )
    }
}
