import Chau7Core
import XCTest
@testable import MagiCLI

final class MagiCLIRuntimeTests: XCTestCase {
    func testCollectPendingParsedCollectsFinishedMembersWhileFirstMemberHangs() throws {
        let runID = "run-1"
        let roundID = "round-1"
        let client = FakeMagiMCPClient()
        client.runtimeEvents = [
            runtimeEvent(
                tabID: "tab_balthasar",
                message: positionBlock(
                    runID: runID,
                    roundID: roundID,
                    memberID: .balthasar,
                    position: "Final Fantasy VI"
                )
            ),
            runtimeEvent(
                tabID: "tab_casper",
                message: positionBlock(
                    runID: runID,
                    roundID: roundID,
                    memberID: .casper,
                    position: "Final Fantasy IX"
                )
            )
        ]
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var orchestrator = makeOrchestrator(client: client, root: root)
        orchestrator.roundTimeoutSeconds = 0.02
        orchestrator.normalTailPollIntervalSeconds = 60
        let technicalLog = MagiTechnicalLog(
            path: root.appendingPathComponent("technical.jsonl").path,
            runID: runID,
            fileManager: .default
        )
        var parsedMemberIDs: [MagiMemberID] = []

        XCTAssertThrowsError(
            try orchestrator.collectPendingParsed(
                runID: runID,
                roundID: roundID,
                stageKind: .position,
                stage: "independent analysis",
                sessions: [
                    memberTab(.melchior, tabID: "tab_melchior"),
                    memberTab(.balthasar, tabID: "tab_balthasar"),
                    memberTab(.casper, tabID: "tab_casper")
                ],
                repositoryRoot: nil,
                startedAt: Date(),
                technicalLog: technicalLog,
                recordCapture: { _ in },
                parse: { session, output, markers in
                    try MagiTranscriptParser.parsePosition(
                        memberID: session.member.id,
                        roundID: roundID,
                        output: output,
                        markers: markers
                    )
                },
                onParsed: { session, _ in
                    parsedMemberIDs.append(session.member.id)
                }
            ) as [MagiPosition]
        ) { error in
            guard case let MagiMCPOrchestratorError.timedOut(_, member, _) = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
            XCTAssertEqual(member, "Melchior")
        }

        XCTAssertEqual(parsedMemberIDs, [.balthasar, .casper])
    }

    func testPromptEchoMarkersDoNotTriggerStableRepair() {
        let markers = MagiProtocolMarkers(
            runID: "run-1",
            roundID: "round-1",
            memberID: .melchior,
            stage: .position
        )
        let echoedPrompt = """
        Begin marker name: \(markers.begin)
        End marker name: \(markers.end)
        """
        let capture = MagiMCPOrchestrator.MagiPolledOutput(
            terminalOutput: echoedPrompt,
            eventMessages: [],
            eventError: nil,
            tabStatus: MagiMCPTabStatus(status: "ready", canAcceptExec: true, isAtPrompt: true),
            tabStatusError: nil,
            terminalReadMode: .fullStable
        )
        let orchestrator = makeOrchestrator(client: FakeMagiMCPClient(), root: temporaryDirectory())

        XCTAssertTrue(orchestrator.shouldTreatAsEchoedPromptMarkers(echoedPrompt, markers: markers))
        XCTAssertFalse(orchestrator.shouldRunStableRepair(
            MagiTranscriptParseError.missingBlock(begin: markers.begin, end: markers.end),
            capture: capture,
            output: echoedPrompt,
            markers: markers,
            elapsed: 30
        ))
    }

    func testCollectorNonzeroExitCreatesFailedPacketAndClosesTab() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = FakeMagiMCPClient()
        client.createdTabID = "collector_tab"
        client.tabOutputs["collector_tab"] = "permission denied\nMAGI_COLLECTOR_DONE_request_1_collector_1:13\n"
        let orchestrator = makeOrchestrator(client: client, root: root)
        let request = evidenceRequest(
            id: "request-1",
            proposedCollectors: ["local.command:printf no"]
        )
        let command = try XCTUnwrap(MagiEvidenceCollectorPlanner.commands(for: request).first)
        let technicalLog = MagiTechnicalLog(
            path: root.appendingPathComponent("technical.jsonl").path,
            runID: "run-collector",
            fileManager: .default
        )

        let packet = try orchestrator.runCollector(
            command: command,
            request: request,
            technicalLog: technicalLog
        )

        XCTAssertEqual(packet.metadata["collection_status"], "failed")
        XCTAssertEqual(packet.metadata["exit_status"], "13")
        XCTAssertTrue(packet.summary.contains("collector failed with exit status 13"))
        XCTAssertEqual(client.closedTabs, ["collector_tab"])
    }

    func testCollectorTimeoutStillClosesCollectorTab() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = FakeMagiMCPClient()
        client.createdTabID = "collector_timeout_tab"
        client.tabOutputs["collector_timeout_tab"] = "still running"
        var orchestrator = makeOrchestrator(client: client, root: root)
        orchestrator.collectorTimeoutSeconds = 0.02
        let request = evidenceRequest(
            id: "request-timeout",
            proposedCollectors: ["local.command:sleep 30"]
        )
        let command = try XCTUnwrap(MagiEvidenceCollectorPlanner.commands(for: request).first)
        let technicalLog = MagiTechnicalLog(
            path: root.appendingPathComponent("technical.jsonl").path,
            runID: "run-timeout",
            fileManager: .default
        )

        XCTAssertThrowsError(
            try orchestrator.runCollector(
                command: command,
                request: request,
                technicalLog: technicalLog
            )
        ) { error in
            guard case MagiMCPOrchestratorError.timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }
        XCTAssertEqual(client.closedTabs, ["collector_timeout_tab"])
    }

    func testReplayFallsBackToReplayJSONLWhenDecisionJSONIsStale() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = "stale-replay"
        let bundle = MagiArtifactBundle(
            runID: runID,
            rootDirectory: root.appendingPathComponent(".chau7/magi/runs/\(runID)").path
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: bundle.rootDirectory),
            withIntermediateDirectories: true
        )
        try "{not-json".write(toFile: bundle.decisionJSONPath, atomically: true, encoding: .utf8)
        try """
        {"type":"run","run_id":"stale-replay","status":"failed","detail":"stale"}
        {"type":"failure","status":"failed","category":"partial_artifacts","stage":"share","error":"decision json stale"}

        """.write(toFile: bundle.replayJSONLPath, atomically: true, encoding: .utf8)
        let runner = MagiCLIRunner(paths: MagiCLIPaths(homeDirectory: root.path, currentDirectory: root.path))

        XCTAssertEqual(runner.runReplay(runID: runID), .success)
    }

    func testShareUsesExistingShareHTMLWhenDecisionJSONIsStale() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = "stale-share"
        let bundle = MagiArtifactBundle(
            runID: runID,
            rootDirectory: root.appendingPathComponent(".chau7/magi/runs/\(runID)").path
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: bundle.rootDirectory),
            withIntermediateDirectories: true
        )
        try "{not-json".write(toFile: bundle.decisionJSONPath, atomically: true, encoding: .utf8)
        try "<!doctype html><title>existing</title>".write(toFile: bundle.shareHTMLPath, atomically: true, encoding: .utf8)
        let runner = MagiCLIRunner(paths: MagiCLIPaths(homeDirectory: root.path, currentDirectory: root.path))

        XCTAssertEqual(runner.runShare(runID: runID), .success)
    }

    private func makeOrchestrator(
        client: FakeMagiMCPClient,
        root: URL
    ) -> MagiMCPOrchestrator {
        MagiMCPOrchestrator(
            client: client,
            paths: MagiCLIPaths(homeDirectory: root.path, currentDirectory: root.path),
            fileManager: .default,
            isInteractive: false,
            readLine: { nil },
            printLine: { _ in },
            printRaw: { _ in },
            isInterrupted: { false },
            terminalStyle: MagiRunTerminalStyle(environment: ["TERM": "xterm"], stdoutIsTTY: true)
        )
    }

    private func memberTab(_ memberID: MagiMemberID, tabID: String) -> MagiMemberTab {
        MagiMemberTab(
            member: MagiMember(
                id: memberID,
                persona: MagiPersona(memberID: memberID, lens: "test", prompt: "test"),
                provider: "codex"
            ),
            tabID: tabID
        )
    }

    private func evidenceRequest(id: String, proposedCollectors: [String]) -> MagiEvidenceRequest {
        MagiEvidenceRequest(
            id: id,
            memberID: .melchior,
            roundID: "round-2",
            priority: .high,
            reason: "Need evidence.",
            requiredEvidence: ["evidence"],
            proposedCollectors: proposedCollectors,
            status: .approved
        )
    }

    private func positionBlock(
        runID: String,
        roundID: String,
        memberID: MagiMemberID,
        position: String
    ) -> String {
        let markers = MagiProtocolMarkers(
            runID: runID,
            roundID: roundID,
            memberID: memberID,
            stage: .position
        )
        return """
        \(markers.begin)
        {
          "member": "\(memberID.rawValue)",
          "round": 1,
          "position": "\(position)",
          "summary": "parsed",
          "confidence": 0.8,
          "evidence_requests": [],
          "veto": null
        }
        \(markers.end)
        """
    }

    private func runtimeEvent(tabID: String, message: String) -> MagiMCPRuntimeEvent {
        MagiMCPRuntimeEvent(
            type: "ai_event",
            tabID: tabID,
            detail: MagiMCPRuntimeEventDetail(
                eventType: "agent-turn-complete",
                message: message
            )
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("magi-cli-tests-\(UUID().uuidString)")
    }
}

private final class FakeMagiMCPClient: MagiMCPToolCalling {
    var runtimeEvents: [MagiMCPRuntimeEvent] = []
    var tabOutputs: [String: String] = [:]
    var createdTabID = "tab_collector"
    var closedTabs: [String] = []
    var execRequests: [MagiMCPTabExecRequest] = []

    func agentLaunch(_: MagiMCPAgentLaunchRequest) throws -> MagiMCPAgentLaunchResponse {
        MagiMCPAgentLaunchResponse(agents: [])
    }

    func renameTab(_: MagiMCPTabRenameRequest) throws {}

    func tabOutput(_ request: MagiMCPTabOutputRequest) throws -> MagiMCPTabOutputResponse {
        MagiMCPTabOutputResponse(output: tabOutputs[request.tabID] ?? "")
    }

    func tabStatus(_ request: MagiMCPTabStatusRequest) throws -> MagiMCPTabStatus {
        _ = request
        return MagiMCPTabStatus(status: "ready", canAcceptExec: true, isAtPrompt: true)
    }

    func sendInput(_: MagiMCPTabInputRequest) throws -> MagiMCPTabSendInputResponse {
        MagiMCPTabSendInputResponse(ok: "true")
    }

    func submitPrompt(_: MagiMCPTabSubmitPromptRequest) throws -> MagiMCPTabSubmitPromptResponse {
        MagiMCPTabSubmitPromptResponse(ok: "true", enterCount: "1")
    }

    func closeTab(_ request: MagiMCPTabCloseRequest) throws {
        closedTabs.append(request.tabID)
    }

    func runtimeEvents(_: MagiMCPRuntimeEventsRequest) throws -> MagiMCPRuntimeEventsResponse {
        MagiMCPRuntimeEventsResponse(events: runtimeEvents)
    }

    func repoEvents(_: MagiMCPRepoGetEventsRequest) throws -> MagiMCPRepoEventsResponse {
        MagiMCPRepoEventsResponse(events: [])
    }

    func createTab(_: MagiMCPTabCreateRequest) throws -> MagiMCPTabCreateResponse {
        MagiMCPTabCreateResponse(tabID: createdTabID)
    }

    func waitReady(_: MagiMCPTabWaitReadyRequest) throws -> MagiMCPTabWaitReadyResponse {
        MagiMCPTabWaitReadyResponse(canAcceptExec: true)
    }

    func exec(_ request: MagiMCPTabExecRequest) throws {
        execRequests.append(request)
    }
}
