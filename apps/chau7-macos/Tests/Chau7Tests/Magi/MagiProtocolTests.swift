import XCTest
@testable import Chau7Core

final class MagiProtocolTests: XCTestCase {
    func testIndependentPromptForbidsSiblingTabAccess() {
        let member = MagiMember(
            id: .melchior,
            persona: MagiPersona.defaultPersonasByID[.melchior]!,
            provider: "codex",
            modelClass: .strongest,
            reasoning: .max
        )

        let prompt = MagiPromptBuilder.independentAnalysisPrompt(
            runID: "run-1",
            roundID: "round-1",
            question: "What is the best Final Fantasy?",
            member: member
        )

        XCTAssertTrue(prompt.contains("Do not inspect other MAGI tabs or sibling agents."))
        XCTAssertTrue(prompt.contains("Begin marker name: MAGI_RUN_1_ROUND_1_MELCHIOR_POSITION_BEGIN"))
        XCTAssertTrue(prompt.contains("End marker name: MAGI_RUN_1_ROUND_1_MELCHIOR_POSITION_END"))
        XCTAssertTrue(prompt.contains(#""member": "melchior""#))
        XCTAssertTrue(prompt.contains(#""round": 1"#))
        XCTAssertTrue(prompt.contains(#""position": "your answer""#))
        XCTAssertTrue(prompt.contains("web.query:<query>"))
        XCTAssertFalse(prompt.contains("local.git_diff_stat"))
        XCTAssertFalse(prompt.contains("local.shell"))

        let markers = MagiProtocolMarkers(
            runID: "run-1",
            roundID: "round-1",
            memberID: .melchior,
            stage: .position
        )
        XCTAssertEqual(MagiTranscriptParser.blockCandidates(in: prompt, markers: markers), [])
    }

    func testParsePositionUsesLatestValidMarkedJSONBlock() throws {
        let markers = MagiProtocolMarkers(
            runID: "run-1",
            roundID: "round-1",
            memberID: .melchior,
            stage: .position
        )
        let output = """
        The prompt mentioned \(markers.begin)
        this is instructional text, not JSON
        \(markers.end)

        \(markers.begin)
        {
          "member": "melchior",
          "round": 1,
          "position": "Final Fantasy VII",
          "summary": "Best blend of systems, story, and cultural impact.",
          "confidence": 0.82,
          "evidence_requests": [
            {
              "priority": "high",
              "reason": "Need current repo status before a merge decision.",
              "required_evidence": ["git status"],
              "proposed_collectors": ["local.git_status"]
            }
          ],
          "veto": null
        }
        \(markers.end)
        """

        let position = try MagiTranscriptParser.parsePosition(
            memberID: .melchior,
            roundID: "round-1",
            output: output,
            markers: markers
        )

        XCTAssertEqual(position.recommendation, "Final Fantasy VII")
        XCTAssertEqual(position.confidence, 0.82, accuracy: 0.001)
        XCTAssertEqual(position.evidenceRequests.count, 1)
        XCTAssertEqual(position.evidenceRequests[0].proposedCollectors, ["local.git_status"])
    }

    func testParseCritiquesAndEvidenceRequests() throws {
        let markers = MagiProtocolMarkers(
            runID: "run-1",
            roundID: "round-2",
            memberID: .casper,
            stage: .critique
        )
        let output = """
        \(markers.begin)
        {
          "member": "casper",
          "round": 2,
          "critiques": [
            {
              "target_member_id": "melchior",
              "agreements": ["Strong technical framing"],
              "disagreements": ["Too narrow on human impact"],
              "missing_evidence": ["user preference"],
              "evidence_requests": [
                {
                  "priority": "medium",
                  "reason": "Need a user preference signal.",
                  "required_evidence": ["preference"],
                  "proposed_collectors": ["local.command:printf preference"]
                }
              ]
            }
          ],
          "evidence_requests": []
        }
        \(markers.end)
        """

        let result = try MagiTranscriptParser.parseCritiques(
            criticMemberID: .casper,
            roundID: "round-2",
            output: output,
            markers: markers
        )

        XCTAssertEqual(result.critiques.count, 1)
        XCTAssertEqual(result.critiques[0].targetMemberID, .melchior)
        XCTAssertEqual(result.evidenceRequests.count, 1)
        XCTAssertEqual(result.evidenceRequests[0].priority, .medium)
    }

    func testParseVoteWithBlockingVeto() throws {
        let markers = MagiProtocolMarkers(
            runID: "run-1",
            roundID: "round-4",
            memberID: .balthasar,
            stage: .vote
        )
        let output = """
        \(markers.begin)
        {
          "member": "balthasar",
          "round": 4,
          "verdict": "REJECT",
          "vote": "Do not merge",
          "confidence": 0.9,
          "rationale": "The risk is not reversible.",
          "veto": {
            "reason": "Blocking safety condition from persona file.",
            "scope": "run",
            "blocks_verdict": true
          }
        }
        \(markers.end)
        """

        let result = try MagiTranscriptParser.parseVote(
            memberID: .balthasar,
            roundID: "round-4",
            output: output,
            markers: markers
        )

        XCTAssertEqual(result.vote.choice, "Do not merge")
        XCTAssertEqual(result.vote.verdictKind, .reject)
        XCTAssertEqual(result.vote.rawOutput, output)
        XCTAssertEqual(result.veto?.memberID, .balthasar)
        XCTAssertEqual(result.veto?.blocksVerdict, true)
    }

    func testParseVoteAcceptsLegacyBlockWithoutVerdict() throws {
        let markers = MagiProtocolMarkers(
            runID: "run-1",
            roundID: "round-4",
            memberID: .melchior,
            stage: .vote
        )
        let output = """
        \(markers.begin)
        {
          "member": "melchior",
          "round": 4,
          "vote": "Final Fantasy VI",
          "confidence": 0.82,
          "rationale": "Best blend of systems and ensemble.",
          "veto": null
        }
        \(markers.end)
        """

        let result = try MagiTranscriptParser.parseVote(
            memberID: .melchior,
            roundID: "round-4",
            output: output,
            markers: markers
        )

        XCTAssertNil(result.vote.verdictKind)
        XCTAssertEqual(result.vote.choice, "Final Fantasy VI")
    }

    func testFinalVotePromptIncludesQuestionKindVerdictContract() {
        let member = MagiMember(
            id: .melchior,
            persona: MagiPersona.defaultPersonasByID[.melchior]!,
            provider: "codex"
        )

        let prompt = MagiPromptBuilder.finalVotePrompt(
            runID: "run-1",
            roundID: "round-4",
            member: member,
            councilPacket: "packet",
            critiques: [],
            evidencePackets: [],
            questionKind: .engineering
        )

        XCTAssertTrue(prompt.contains("Verdict mode: engineering."))
        XCTAssertTrue(prompt.contains("verdict must be one of: APPROVE, REJECT, CONDITIONAL, NEED_EVIDENCE, ESCALATE"))
        XCTAssertTrue(prompt.contains(#""verdict": "APPROVE""#))
        XCTAssertTrue(prompt.contains("JSON keys: member, round, verdict, vote, confidence, rationale, veto."))
    }

    func testParserRejectsWrongMemberInStructuredBlock() {
        let markers = MagiProtocolMarkers(
            runID: "run-1",
            roundID: "round-1",
            memberID: .melchior,
            stage: .position
        )
        let output = """
        \(markers.begin)
        {
          "member": "casper",
          "round": 1,
          "position": "Final Fantasy VI",
          "summary": "Strong ensemble.",
          "confidence": 0.8,
          "evidence_requests": [],
          "veto": null
        }
        \(markers.end)
        """

        XCTAssertThrowsError(
            try MagiTranscriptParser.parsePosition(
                memberID: .melchior,
                roundID: "round-1",
                output: output,
                markers: markers
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("expected member melchior"))
        }
    }

    func testParserReportsMalformedJSONBlock() {
        let markers = MagiProtocolMarkers(
            runID: "run-1",
            roundID: "round-1",
            memberID: .melchior,
            stage: .position
        )
        let output = """
        \(markers.begin)
        {"member": "melchior", "round": 1,
        \(markers.end)
        """

        XCTAssertThrowsError(
            try MagiTranscriptParser.parsePosition(
                memberID: .melchior,
                roundID: "round-1",
                output: output,
                markers: markers
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid MAGI JSON block"))
        }
    }

    func testRepairPromptIncludesRawTranscriptAndRequiredContract() {
        let member = MagiMember(
            id: .melchior,
            persona: MagiPersona.defaultPersonasByID[.melchior]!,
            provider: "codex"
        )

        let prompt = MagiPromptBuilder.repairPrompt(
            runID: "run-1",
            roundID: "round-1",
            member: member,
            stage: .position,
            parseError: "Missing block",
            rawTranscript: "Raw answer was Final Fantasy VI."
        )

        XCTAssertTrue(prompt.contains("MAGI structured output repair"))
        XCTAssertTrue(prompt.contains("Required member:\nmelchior"))
        XCTAssertTrue(prompt.contains("Required round:\n1"))
        XCTAssertTrue(prompt.contains("Raw answer was Final Fantasy VI."))

        let markers = MagiProtocolMarkers(
            runID: "run-1",
            roundID: "round-1",
            memberID: .melchior,
            stage: .position
        )
        XCTAssertEqual(MagiTranscriptParser.blockCandidates(in: prompt, markers: markers), [])
    }

    func testPersonaFileParserUsesUserEditablePrompt() {
        let content = """
        # Melchior

        member_id: melchior
        display_name: Melchior
        lens: Custom lens
        editable: true

        ## Operating Prompt

        Custom operating prompt.

        ## Veto Policy

        Custom veto policy.
        """

        let persona = MagiPersonaFileParser.parse(memberID: .melchior, content: content)

        XCTAssertEqual(persona.lens, "Custom lens")
        XCTAssertEqual(persona.prompt, "Custom operating prompt.")
        XCTAssertEqual(persona.vetoPolicy, "Custom veto policy.")
    }

    func testCollectorPlannerMapsKnownAndApprovedCommands() {
        let request = MagiEvidenceRequest(
            id: "request-1",
            memberID: .melchior,
            roundID: "round-2",
            priority: .high,
            reason: "Need local evidence.",
            requiredEvidence: ["status", "diff", "custom", "web"],
            proposedCollectors: [
                "local.git_status",
                "local.git_diff",
                "local.repo_search:MAGI",
                "local.file_read:Package.swift",
                "local.command:printf ok",
                "web.query:Swift structured output parsing"
            ]
        )

        let commands = MagiEvidenceCollectorPlanner.commands(for: request)

        XCTAssertEqual(
            commands.map(\.collectorKind),
            [
                .localGitStatus,
                .localGitDiff,
                .localRepoSearch,
                .localFileRead,
                .localCommand,
                .webQuery
            ]
        )
        XCTAssertEqual(
            commands.dropLast().map(\.command),
            [
                "git status --short",
                "git diff --color=never",
                "rg -n --hidden --glob '!.git/*' -- 'MAGI' . | head -200",
                "sed -n '1,240p' 'Package.swift'",
                "printf ok"
            ]
        )
        XCTAssertEqual(commands[5].payload, "Swift structured output parsing")
        XCTAssertTrue(commands[5].usesWeb)
        XCTAssertTrue(commands[5].command.contains("duckduckgo.com/html/?q="))
        XCTAssertTrue(commands[5].command.contains("MAGI_WEB_QUERY='Swift structured output parsing'"))
    }

    func testCollectorPlannerDoesNotTreatLocalShellAliasAsV1Collector() {
        let request = MagiEvidenceRequest(
            id: "request-2",
            memberID: .balthasar,
            roundID: "round-2",
            priority: .medium,
            reason: "Need unsupported collector coverage.",
            requiredEvidence: ["custom"],
            proposedCollectors: ["local.shell:printf no"]
        )

        let command = MagiEvidenceCollectorPlanner.commands(for: request).first

        XCTAssertEqual(command?.collectorKind, .unsupported)
        XCTAssertEqual(command?.payload, "local.shell:printf no")
        XCTAssertEqual(command?.requiresMCPCommandPermission, false)
    }
}
