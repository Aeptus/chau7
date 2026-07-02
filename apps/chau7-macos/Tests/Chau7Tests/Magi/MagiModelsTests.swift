import XCTest
@testable import Chau7Core

final class MagiModelsTests: XCTestCase {
    func testDefaultConfigMatchesProtocolDecisions() {
        let config = MagiConfig()

        XCTAssertEqual(config.defaultCouncilID, "magi")
        XCTAssertEqual(config.defaultReasoning, .max)
        XCTAssertEqual(config.fallbackStrategy, .duplicate)
        XCTAssertTrue(config.webAccessAllowed)
        XCTAssertTrue(config.evidenceRequiresApproval)
        XCTAssertTrue(config.deadlockExtraRoundEnabled)
        XCTAssertTrue(config.vetoBlocksVerdict)
    }

    func testRunIDIsStableForInjectedInputs() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "12345678-1234-1234-1234-123456789abc"))
        let id = MagiRunID.make(
            date: Date(timeIntervalSince1970: 100),
            uuid: uuid
        )

        XCTAssertEqual(id, "magi-1970-01-01T000140000z-12345678")
    }

    func testDefaultCouncilUsesOriginalMemberNamesAndEqualWeights() {
        let council = MagiCouncil.defaultMagi(members: [
            .melchior: MagiMemberConfiguration(provider: "claude", modelClass: .strongest),
            .balthasar: MagiMemberConfiguration(provider: "codex", modelClass: .strongest),
            .casper: MagiMemberConfiguration(provider: "gemini", modelClass: .balanced)
        ])

        XCTAssertEqual(council.id, "magi")
        XCTAssertEqual(council.members.map(\.id), [.melchior, .balthasar, .casper])
        XCTAssertEqual(council.members.map(\.persona.displayName), ["Melchior", "Balthasar", "Casper"])
        XCTAssertTrue(council.hasDefaultMemberSet)
        XCTAssertTrue(council.members.allSatisfy { $0.weight == 1.0 })
        XCTAssertTrue(council.members.allSatisfy(\.persona.isUserEditable))
    }

    func testRoundSharePolicyKeepsIndependentRoundIsolated() {
        XCTAssertEqual(MagiRoundKind.independentAnalysis.sharePolicy, .isolated)
        XCTAssertEqual(MagiRoundKind.crossExamination.sharePolicy, .completedOutputsOnly)
        XCTAssertEqual(MagiRoundKind.revision.sharePolicy, .completedOutputsOnly)
        XCTAssertEqual(MagiRoundKind.vote.sharePolicy, .completedOutputsOnly)
        XCTAssertEqual(MagiRoundKind.evidenceCollection.sharePolicy, .approvedEvidenceOnly)
    }

    func testEvidenceRequestDefaultsToPendingApproval() {
        let request = MagiEvidenceRequest(
            id: "evidence-1",
            memberID: .balthasar,
            roundID: "round-2",
            priority: .high,
            reason: "Need test results before voting.",
            requiredEvidence: ["test_status"]
        )

        XCTAssertEqual(request.status, .pendingApproval)
        XCTAssertEqual(request.memberID, .balthasar)
        XCTAssertEqual(request.requiredEvidence, ["test_status"])
    }

    func testEvidenceCollectorV1SetMatchesPhaseSixContract() {
        XCTAssertEqual(
            MagiEvidenceCollectorKind.v1.map(\.rawValue),
            [
                "local.git_status",
                "local.git_diff",
                "local.repo_search",
                "local.file_read",
                "local.command",
                "web.query"
            ]
        )
    }

    func testPhaseSevenVerdictKindContract() {
        XCTAssertEqual(
            MagiVerdictKind.allCases.map(\.rawValue),
            [
                "APPROVE",
                "REJECT",
                "CONDITIONAL",
                "NEED_EVIDENCE",
                "DEADLOCK",
                "ESCALATE",
                "BLOCKED_BY_VETO",
                "SELECT",
                "RANK",
                "NO_CONSENSUS"
            ]
        )
    }

    func testQuestionKindInferenceSeparatesEngineeringAndGenericQuestions() {
        XCTAssertEqual(
            MagiQuestionKind.infer(from: "Should we merge this pull request?"),
            .engineering
        )
        XCTAssertEqual(
            MagiQuestionKind.infer(from: "What is the best Final Fantasy?"),
            .generic
        )
    }

    func testVetoBlocksMajorityVerdict() {
        let votes = [
            MagiVote(id: "vote-1", memberID: .melchior, choice: "Final Fantasy VII", confidence: 0.8, rationale: "Systems impact."),
            MagiVote(id: "vote-2", memberID: .balthasar, choice: "Final Fantasy X", confidence: 0.7, rationale: "Emotional closure."),
            MagiVote(id: "vote-3", memberID: .casper, choice: "Final Fantasy VII", confidence: 0.9, rationale: "Cultural impact.")
        ]
        let veto = MagiVeto(
            id: "veto-1",
            memberID: .balthasar,
            reason: "The answer violates the active persona veto policy."
        )

        let verdict = MagiDecisionResolver.resolve(votes: votes, vetoes: [veto])

        XCTAssertEqual(verdict.kind, .blockedByVeto)
        XCTAssertNil(verdict.decision)
        XCTAssertEqual(verdict.vetoes, [veto])
    }

    func testEngineeringMajorityUsesApproveRejectStyleVerdict() {
        let votes = [
            MagiVote(id: "vote-1", memberID: .melchior, verdictKind: .approve, choice: "Merge after CI stays green.", confidence: 0.8, rationale: "The diff is contained."),
            MagiVote(id: "vote-2", memberID: .balthasar, verdictKind: .reject, choice: "Do not merge.", confidence: 0.7, rationale: "Rollback is unclear."),
            MagiVote(id: "vote-3", memberID: .casper, verdictKind: .approve, choice: "Merge; the UX risk is acceptable.", confidence: 0.9, rationale: "The change is understandable.")
        ]

        let verdict = MagiDecisionResolver.resolve(votes: votes, questionKind: .engineering)

        XCTAssertEqual(verdict.kind, .approve)
        XCTAssertEqual(verdict.decision, "Merge after CI stays green.")
        XCTAssertEqual(verdict.consensusScore, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(verdict.confidence, 0.85, accuracy: 0.001)
    }

    func testEngineeringResolverInfersRejectFromLegacyVoteText() {
        let votes = [
            MagiVote(id: "vote-1", memberID: .melchior, choice: "Do not merge", confidence: 0.8, rationale: "Missing tests."),
            MagiVote(id: "vote-2", memberID: .balthasar, choice: "REJECT", confidence: 0.7, rationale: "Operational risk."),
            MagiVote(id: "vote-3", memberID: .casper, choice: "Merge", confidence: 0.9, rationale: "The direction is good.")
        ]

        let verdict = MagiDecisionResolver.resolve(votes: votes, questionKind: .engineering)

        XCTAssertEqual(verdict.kind, .reject)
        XCTAssertEqual(verdict.consensusScore, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertFalse(verdict.requiresAdditionalRound)
    }

    func testMajorityVoteSelectsWinningChoice() {
        let votes = [
            MagiVote(id: "vote-1", memberID: .melchior, choice: "Final Fantasy VII", confidence: 0.8, rationale: "Systems impact."),
            MagiVote(id: "vote-2", memberID: .balthasar, choice: "Final Fantasy X", confidence: 0.7, rationale: "Emotional closure."),
            MagiVote(id: "vote-3", memberID: .casper, choice: "final fantasy vii", confidence: 1.0, rationale: "Cultural impact.")
        ]

        let verdict = MagiDecisionResolver.resolve(votes: votes)

        XCTAssertEqual(verdict.kind, .select)
        XCTAssertEqual(verdict.decision, "Final Fantasy VII")
        XCTAssertEqual(verdict.consensusScore, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(verdict.confidence, 0.9, accuracy: 0.001)
        XCTAssertFalse(verdict.requiresAdditionalRound)
    }

    func testGenericMajorityCanReturnRankVerdict() {
        let ranking = "1. Final Fantasy VI; 2. Final Fantasy VII; 3. Final Fantasy X"
        let votes = [
            MagiVote(id: "vote-1", memberID: .melchior, verdictKind: .rank, choice: ranking, confidence: 0.8, rationale: "Systems impact."),
            MagiVote(id: "vote-2", memberID: .balthasar, verdictKind: .select, choice: "Final Fantasy X", confidence: 0.7, rationale: "Emotional closure."),
            MagiVote(id: "vote-3", memberID: .casper, verdictKind: .rank, choice: ranking, confidence: 0.9, rationale: "Cultural impact.")
        ]

        let verdict = MagiDecisionResolver.resolve(votes: votes)

        XCTAssertEqual(verdict.kind, .rank)
        XCTAssertEqual(verdict.decision, ranking)
        XCTAssertEqual(verdict.consensusScore, 2.0 / 3.0, accuracy: 0.001)
    }

    func testDeadlockRequestsExtraRoundWhenEnabled() {
        let votes = [
            MagiVote(id: "vote-1", memberID: .melchior, choice: "Final Fantasy VI", confidence: 0.8, rationale: "Systems impact."),
            MagiVote(id: "vote-2", memberID: .balthasar, choice: "Final Fantasy X", confidence: 0.7, rationale: "Emotional closure."),
            MagiVote(id: "vote-3", memberID: .casper, choice: "Final Fantasy VII", confidence: 0.9, rationale: "Cultural impact.")
        ]

        let verdict = MagiDecisionResolver.resolve(votes: votes)

        XCTAssertEqual(verdict.kind, .deadlock)
        XCTAssertTrue(verdict.requiresAdditionalRound)
        XCTAssertEqual(verdict.consensusScore, 1.0 / 3.0, accuracy: 0.001)
    }

    func testDeadlockBecomesNoConsensusWhenExtraRoundIsDisabled() {
        let votes = [
            MagiVote(id: "vote-1", memberID: .melchior, choice: "Final Fantasy VI", confidence: 0.8, rationale: "Systems impact."),
            MagiVote(id: "vote-2", memberID: .balthasar, choice: "Final Fantasy X", confidence: 0.7, rationale: "Emotional closure."),
            MagiVote(id: "vote-3", memberID: .casper, choice: "Final Fantasy VII", confidence: 0.9, rationale: "Cultural impact.")
        ]
        let policy = MagiResolutionPolicy(deadlockExtraRoundEnabled: false)

        let verdict = MagiDecisionResolver.resolve(votes: votes, policy: policy)

        XCTAssertEqual(verdict.kind, .noConsensus)
        XCTAssertFalse(verdict.requiresAdditionalRound)
    }

    func testRunStateMachineStartsCompletesAndFailsWithUsefulMetadata() {
        var run = MagiRun(
            id: "run-1",
            question: "What is the best Final Fantasy?",
            council: MagiCouncil.defaultMagi(members: [:]),
            status: .running
        )

        let startedAt = Date(timeIntervalSince1970: 100)
        let completedAt = Date(timeIntervalSince1970: 120)
        let failedAt = Date(timeIntervalSince1970: 140)

        let round = MagiRunStateMachine.startRound(
            &run,
            id: "round-1",
            index: 1,
            kind: .independentAnalysis,
            at: startedAt
        )
        MagiRunStateMachine.completeRound(&run, id: round.id, at: completedAt)
        MagiRunStateMachine.markFailed(
            &run,
            category: .malformedJSON,
            stage: "round-1-position",
            message: "Invalid JSON",
            at: failedAt
        )

        XCTAssertEqual(run.rounds.count, 1)
        XCTAssertEqual(run.rounds[0].completedAt, completedAt)
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.completedAt, failedAt)
        XCTAssertEqual(run.metadata["failure_category"], "malformed_json")
        XCTAssertEqual(run.metadata["failure_stage"], "round-1-position")
        XCTAssertEqual(run.metadata["error"], "Invalid JSON")
        XCTAssertEqual(run.metadata["last_checkpoint"], "failed:round-1-position")
    }

    func testRunStateMachineMarksInterruptedSeparatelyFromFailed() {
        var run = MagiRun(
            id: "run-2",
            question: "What is the best Final Fantasy?",
            council: MagiCouncil.defaultMagi(members: [:]),
            status: .running
        )

        MagiRunStateMachine.markInterrupted(&run, stage: "final vote", at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(run.status, .interrupted)
        XCTAssertEqual(run.metadata["failure_category"], "interrupted")
        XCTAssertEqual(run.metadata["failure_stage"], "final vote")
        XCTAssertEqual(run.metadata["last_checkpoint"], "interrupted:final vote")
    }

    func testRunStateMachineRecordsDeniedEvidenceCount() {
        var run = MagiRun(
            id: "run-3",
            question: "What is the best Final Fantasy?",
            council: MagiCouncil.defaultMagi(members: [:])
        )

        MagiRunStateMachine.recordDeniedEvidenceCount(2, in: &run)

        XCTAssertEqual(run.metadata["evidence_denied_count"], "2")
        XCTAssertEqual(run.metadata["evidence_denied"], "true")
    }

    func testArtifactBundleUsesRepoRootWhenAvailable() {
        let root = MagiArtifactBundle.rootDirectory(
            runID: "run-1",
            repositoryRoot: "/repo",
            homeDirectory: "/home/user"
        )
        let bundle = MagiArtifactBundle(runID: "run-1", rootDirectory: root)

        XCTAssertEqual(bundle.rootDirectory, "/repo/.chau7/magi/runs/run-1")
        XCTAssertEqual(bundle.decisionMarkdownPath, "/repo/.chau7/magi/runs/run-1/decision.md")
        XCTAssertEqual(bundle.decisionJSONPath, "/repo/.chau7/magi/runs/run-1/decision.json")
        XCTAssertEqual(bundle.transcriptJSONLPath, "/repo/.chau7/magi/runs/run-1/transcript.jsonl")
        XCTAssertEqual(bundle.graphJSONPath, "/repo/.chau7/magi/runs/run-1/graph.json")
        XCTAssertEqual(bundle.replayJSONLPath, "/repo/.chau7/magi/runs/run-1/replay.jsonl")
        XCTAssertEqual(bundle.shareHTMLPath, "/repo/.chau7/magi/runs/run-1/share.html")
        XCTAssertEqual(bundle.technicalLogPath, "/repo/.chau7/magi/runs/run-1/technical.jsonl")
    }

    func testArtifactBundleRequiredFilesMatchPhaseEightContract() {
        let bundle = MagiArtifactBundle(runID: "run-1", rootDirectory: "/repo/.chau7/magi/runs/run-1")

        XCTAssertEqual(
            MagiArtifactBundle.requiredFileNames,
            [
                "decision.md",
                "decision.json",
                "transcript.jsonl",
                "graph.json",
                "replay.jsonl",
                "share.html"
            ]
        )
        XCTAssertEqual(
            bundle.requiredPaths,
            [
                "/repo/.chau7/magi/runs/run-1/decision.md",
                "/repo/.chau7/magi/runs/run-1/decision.json",
                "/repo/.chau7/magi/runs/run-1/transcript.jsonl",
                "/repo/.chau7/magi/runs/run-1/graph.json",
                "/repo/.chau7/magi/runs/run-1/replay.jsonl",
                "/repo/.chau7/magi/runs/run-1/share.html"
            ]
        )
    }

    func testArtifactBundleFallsBackToHomeDirectoryOutsideRepo() {
        let root = MagiArtifactBundle.rootDirectory(
            runID: "run-2",
            repositoryRoot: nil,
            homeDirectory: "/home/user"
        )

        XCTAssertEqual(root, "/home/user/.chau7/magi/runs/run-2")
    }

    func testRunIsCodable() throws {
        let council = MagiCouncil.defaultMagi(members: [
            .melchior: MagiMemberConfiguration(provider: "claude", modelClass: .strongest),
            .balthasar: MagiMemberConfiguration(provider: "codex", modelClass: .strongest),
            .casper: MagiMemberConfiguration(provider: "gemini", modelClass: .balanced)
        ])
        let run = MagiRun(
            id: "run-1",
            question: "What is the best Final Fantasy?",
            council: council,
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 200),
            rounds: [
                MagiRound(
                    id: "round-1",
                    index: 1,
                    kind: .independentAnalysis,
                    startedAt: Date(timeIntervalSince1970: 101),
                    completedAt: Date(timeIntervalSince1970: 120)
                )
            ],
            evidenceRequests: [
                MagiEvidenceRequest(
                    id: "evidence-1",
                    memberID: .melchior,
                    roundID: "round-1",
                    priority: .high,
                    reason: "Need repo evidence.",
                    requiredEvidence: ["git status"],
                    proposedCollectors: ["local.git_status"],
                    status: .fulfilled
                )
            ],
            rawTranscripts: [
                MagiRawTranscript(
                    id: "raw-1",
                    memberID: .melchior,
                    roundID: "round-1",
                    stage: "position",
                    tabID: "tab_1",
                    output: "raw transcript",
                    capturedAt: Date(timeIntervalSince1970: 150),
                    parseError: nil,
                    repairAttempted: false,
                    repairSucceeded: false
                )
            ],
            finalVerdict: MagiVerdict(kind: .select, decision: "Final Fantasy VII", consensusScore: 2.0 / 3.0)
        )

        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(MagiRun.self, from: data)

        XCTAssertEqual(decoded, run)
    }
}
