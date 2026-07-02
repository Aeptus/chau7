import XCTest
@testable import Chau7Core

final class MagiArtifactsTests: XCTestCase {
    func testReplayJSONLUsesTimelineEvents() {
        let replay = MagiRunArtifactRenderer.replayJSONL(for: sampleRun())

        XCTAssertTrue(replay.contains(#""type":"run""#))
        XCTAssertTrue(replay.contains(#""type":"round""#))
        XCTAssertTrue(replay.contains(#""type":"position""#))
        XCTAssertTrue(replay.contains(#""type":"vote""#))
        XCTAssertTrue(replay.contains(#""type":"verdict""#))
        XCTAssertTrue(replay.contains("Final Fantasy VI"))
    }

    func testTerminalReplayRendersReadableTimelineFromRun() {
        let output = MagiTerminalReplayRenderer.render(
            run: sampleRun(),
            replayJSONL: nil
        )

        XCTAssertTrue(output.contains("MAGI Replay"))
        XCTAssertTrue(output.contains("Run: run-1"))
        XCTAssertTrue(output.contains("[Round 1] Independent analysis"))
        XCTAssertTrue(output.contains("Melchior position: Final Fantasy VI"))
        XCTAssertTrue(output.contains("Casper vote: [SELECT] Final Fantasy VI"))
        XCTAssertTrue(output.contains("Decision: Final Fantasy VI"))
    }

    func testTerminalReplayRendersLegacyJSONLWithoutRun() {
        let jsonl = """
        {"type":"position","member_id":"melchior","round_id":"round-1","recommendation":"Final Fantasy VI","summary":"Legacy line"}
        {"type":"vote","member_id":"casper","verdict_kind":"SELECT","choice":"Final Fantasy VI","rationale":"Legacy vote"}
        {"type":"verdict","kind":"SELECT","decision":"Final Fantasy VI","consensus":"0.67","confidence":"0.85"}

        """

        let output = MagiTerminalReplayRenderer.render(run: nil, replayJSONL: jsonl)

        XCTAssertTrue(output.contains("Melchior position: Final Fantasy VI"))
        XCTAssertTrue(output.contains("Casper vote: [SELECT] Final Fantasy VI"))
        XCTAssertTrue(output.contains("Kind: SELECT"))
        XCTAssertTrue(output.contains("Decision: Final Fantasy VI"))
    }

    func testShareHTMLIsLocalOnlyAndEscapesRunText() {
        let run = sampleRun(question: "What is <script>alert('x')</script> best?")
        let html = MagiRunArtifactRenderer.shareHTML(for: run)

        XCTAssertTrue(html.contains("MAGI local share"))
        XCTAssertTrue(html.contains("No hosted upload in v1"))
        XCTAssertTrue(html.contains("What is &lt;script&gt;alert('x')&lt;/script&gt; best?"))
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("Final Fantasy VI"))
    }

    func testGraphJSONIncludesRunAndVerdictNodes() throws {
        let data = try XCTUnwrap(MagiRunArtifactRenderer.graphJSON(for: sampleRun()).data(using: .utf8))
        let graph = try JSONDecoder().decode(MagiDecisionGraph.self, from: data)

        XCTAssertTrue(graph.nodes.contains { $0.id == "run-1" && $0.kind == "run" })
        XCTAssertTrue(graph.nodes.contains { $0.id == "run-1-verdict" && $0.kind == "verdict" })
        XCTAssertTrue(graph.edges.contains { $0.sourceID == "run-1" && $0.targetID == "round-1" })
        XCTAssertTrue(graph.edges.contains { $0.sourceID == "run-1" && $0.targetID == "run-1-verdict" })
    }

    func testArtifactStoreWritesCompleteBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("magi-artifacts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var run = sampleRun()
        run.artifactBundle = MagiArtifactBundle(runID: run.id, rootDirectory: root.path)

        let bundle = try MagiRunArtifactStore.write(run: run)

        XCTAssertTrue(MagiRunArtifactStore.isComplete(bundle))
        XCTAssertEqual(MagiRunArtifactStore.missingRequiredPaths(in: bundle), [])
        for path in bundle.requiredPaths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        }
    }

    func testFailedRunArtifactsIncludeFailureMetadata() {
        var run = sampleRun()
        MagiRunStateMachine.markFailed(
            &run,
            category: .mcpSocketMissing,
            stage: "mcp-preflight",
            message: "Chau7 MCP socket was not found.",
            at: Date(timeIntervalSince1970: 300)
        )

        let markdown = MagiRunArtifactRenderer.decisionMarkdown(for: run)
        let replay = MagiRunArtifactRenderer.replayJSONL(for: run)
        let terminal = MagiTerminalReplayRenderer.render(run: run, replayJSONL: nil)
        let html = MagiRunArtifactRenderer.shareHTML(for: run)

        XCTAssertTrue(markdown.contains("## Failure"))
        XCTAssertTrue(markdown.contains("Category: mcp_socket_missing"))
        XCTAssertTrue(replay.contains(#""type":"failure""#))
        XCTAssertTrue(terminal.contains("Failure"))
        XCTAssertTrue(terminal.contains("Category: mcp_socket_missing"))
        XCTAssertTrue(html.contains("<h2>Failure</h2>"))
    }

    func testTerminalReplayRendersFailureFromReplayJSONLWithoutDecisionJSON() {
        let replayJSONL = """
        {"type":"run","run_id":"run-9","status":"failed","detail":"What is the best Final Fantasy?"}
        {"type":"failure","status":"failed","category":"malformed_json","stage":"final vote","error":"Invalid MAGI JSON block"}

        """

        let output = MagiTerminalReplayRenderer.render(run: nil, replayJSONL: replayJSONL)

        XCTAssertTrue(output.contains("Run: run-9"))
        XCTAssertTrue(output.contains("Failure"))
        XCTAssertTrue(output.contains("Category: malformed_json"))
        XCTAssertTrue(output.contains("Error: Invalid MAGI JSON block"))
    }

    private func sampleRun(question: String = "What is the best Final Fantasy?") -> MagiRun {
        let council = MagiCouncil.defaultMagi(members: [
            .melchior: MagiMemberConfiguration(provider: "claude", modelClass: .strongest),
            .balthasar: MagiMemberConfiguration(provider: "codex", modelClass: .balanced),
            .casper: MagiMemberConfiguration(provider: "gemini", modelClass: .fast)
        ])
        let rounds = [
            MagiRound(
                id: "round-1",
                index: 1,
                kind: .independentAnalysis,
                startedAt: Date(timeIntervalSince1970: 100),
                completedAt: Date(timeIntervalSince1970: 120)
            ),
            MagiRound(
                id: "round-4",
                index: 4,
                kind: .vote,
                startedAt: Date(timeIntervalSince1970: 200),
                completedAt: Date(timeIntervalSince1970: 220)
            )
        ]
        let positions = [
            MagiPosition(
                id: "position-1",
                memberID: .melchior,
                roundID: "round-1",
                recommendation: "Final Fantasy VI",
                summary: "Best ensemble and strongest structure.",
                confidence: 0.82
            )
        ]
        let votes = [
            MagiVote(
                id: "vote-1",
                memberID: .melchior,
                verdictKind: .select,
                choice: "Final Fantasy VI",
                confidence: 0.82,
                rationale: "Best ensemble."
            ),
            MagiVote(
                id: "vote-2",
                memberID: .balthasar,
                verdictKind: .select,
                choice: "Final Fantasy X",
                confidence: 0.74,
                rationale: "Best ending."
            ),
            MagiVote(
                id: "vote-3",
                memberID: .casper,
                verdictKind: .select,
                choice: "Final Fantasy VI",
                confidence: 0.88,
                rationale: "Best cast."
            )
        ]

        return MagiRun(
            id: "run-1",
            question: question,
            council: council,
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 90),
            completedAt: Date(timeIntervalSince1970: 230),
            rounds: rounds,
            positions: positions,
            finalVerdict: MagiVerdict(
                kind: .select,
                decision: "Final Fantasy VI",
                consensusScore: 2.0 / 3.0,
                confidence: 0.85,
                votes: votes,
                rationale: "Majority reached."
            )
        )
    }
}
