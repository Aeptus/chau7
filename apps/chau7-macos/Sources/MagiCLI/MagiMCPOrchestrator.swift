import Chau7Core
import Foundation

enum MagiMCPOrchestratorError: Error, LocalizedError {
    case launchFailed(member: String, reason: String)
    case missingToolField(tool: String, field: String)
    case timedOut(stage: String, member: String, lastError: String?)
    case parseFailedAfterRepair(stage: String, member: String, lastError: String?)
    case evidenceApprovalRequiredNonInteractive
    case mcpContractUnsupported(message: String)
    case interrupted(stage: String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(member, reason):
            return "Could not launch \(member): \(reason)"
        case let .missingToolField(tool, field):
            return "Chau7 MCP tool \(tool) did not return required field \(field)."
        case let .timedOut(stage, member, lastError):
            if let lastError {
                return "Timed out waiting for \(member) during \(stage). Last parse error: \(lastError)"
            }
            return "Timed out waiting for \(member) during \(stage)."
        case let .parseFailedAfterRepair(stage, member, lastError):
            if let lastError {
                return "Could not parse \(member)'s structured output during \(stage) after one repair attempt: \(lastError)"
            }
            return "Could not parse \(member)'s structured output during \(stage) after one repair attempt."
        case .evidenceApprovalRequiredNonInteractive:
            return "Evidence collection requires approval, but this terminal is not interactive."
        case let .mcpContractUnsupported(message):
            return message
        case let .interrupted(stage):
            return "MAGI run interrupted during \(stage)."
        }
    }
}

struct MagiMCPOrchestrator {
    var client: MagiMCPToolCalling
    var paths: MagiCLIPaths
    var fileManager: FileManager = .default
    var isInteractive: Bool
    var readLine: () -> String? = { Swift.readLine(strippingNewline: true) }
    var printLine: (String) -> Void = { FileHandle.standardOutput.writeLine($0) }
    var printRaw: (String) -> Void = { FileHandle.standardOutput.writeText($0) }
    var isInterrupted: () -> Bool = { false }
    var roundTimeoutSeconds: TimeInterval = 900
    var repairTimeoutSeconds: TimeInterval = 120
    var collectorTimeoutSeconds: TimeInterval = 120
    var launchTimeoutMs = 60000
    var launchMemberThrottleSeconds: TimeInterval = 0.6
    var progressPulseSeconds: TimeInterval = 10
    var progressFrameSeconds: TimeInterval = 0.12
    var idleRepairGraceSeconds: TimeInterval = 12
    var normalOutputTailLines = 240
    var fullOutputLines = 10000
    var normalTailPollIntervalSeconds: TimeInterval = 4
    var repairTranscriptMaxCharacters = MagiPromptBuilder.defaultRepairTranscriptMaxCharacters
    var terminalStyle = MagiRunTerminalStyle()
    var processingLines = MagiCouncilArtFile.defaultProcessingLines

    // swiftlint:disable:next function_body_length
    func run(question: String, config: MagiConfig, mode: MagiQuestionKind? = nil) throws -> MagiRun {
        let runID = MagiRunID.make()
        let council = try loadCouncil(config: config)
        let questionKindSelection = questionModeSelection(question: question, override: mode)
        let questionKind = questionKindSelection.kind
        let repositoryRoot = paths.repositoryRoot(fileManager: fileManager)
        let artifactRoot = paths.runRoot(runID: runID, repositoryRoot: repositoryRoot)
        let artifactBundle = MagiArtifactBundle(runID: runID, rootDirectory: artifactRoot)
        let technicalLog = MagiTechnicalLog(
            path: artifactBundle.technicalLogPath,
            runID: runID,
            fileManager: fileManager
        )
        var run = MagiRun(
            id: runID,
            question: question,
            council: council,
            status: .running,
            artifactBundle: artifactBundle,
            metadata: [
                "mcp_socket": mcpSocketPath,
                "evidence_policy": config.evidencePolicy.rawValue,
                "web_access_allowed": String(config.webAccessAllowed),
                "question_kind": questionKind.rawValue,
                "question_kind_source": mode == nil ? "inferred" : "explicit",
                "question_kind_reason": questionKindSelection.reason,
                "auto_close_agent_tabs": String(config.autoCloseAgentTabs),
                "verdict_defaults": "majority,equal_weights,one_extra_round_on_deadlock,veto_blocks",
                "artifact_root": artifactRoot,
                "technical_log": artifactBundle.technicalLogPath,
                "artifact_scope": repositoryRoot == nil ? "global" : "repository",
                "repository_root": repositoryRoot ?? ""
            ]
        )
        MagiRunStateMachine.checkpoint(&run, stage: "initialized")
        technicalLog.record(
            "run_initialized",
            stage: "initialized",
            fields: [
                "artifact_root": artifactRoot,
                "question_kind": questionKind.rawValue,
                "question_kind_source": mode == nil ? "inferred" : "explicit",
                "question_kind_reason": questionKindSelection.reason,
                "member_count": String(council.members.count)
            ]
        )

        var sessions: [MagiMemberTab] = []
        do {
            try writeCheckpoint(&run, stage: "initialized", technicalLog: technicalLog)
            try throwIfInterrupted(stage: "startup")

            printLine("RUN \(runID)")
            printLine(statusLine("MODE", modeStatusText(selection: questionKindSelection, explicit: mode != nil)))
            printLine(statusLine("COUNCIL", "boot sequence accepted"))

            let round1 = MagiRunStateMachine.startRound(
                &run,
                id: "round-1",
                index: 1,
                kind: .independentAnalysis
            )
            try writeCheckpoint(&run, stage: "round-1-started", technicalLog: technicalLog)

            announceStage("PHASE 0 // COUNCIL ONLINE", "Three isolated agents enter the chamber.")
            technicalLog.record("council_launch_started", stage: "launch")
            for member in council.members {
                try throwIfInterrupted(stage: "launching council")
                let prompt = MagiPromptBuilder.independentAnalysisPrompt(
                    runID: runID,
                    roundID: round1.id,
                    question: question,
                    member: member
                )
                technicalLog.record(
                    "member_launch_started",
                    stage: "launch",
                    memberID: member.id,
                    fields: [
                        "provider": member.provider,
                        "model_class": member.modelClass.rawValue,
                        "reasoning": member.reasoning.rawValue
                    ]
                )
                let tabID = try launchMember(member, prompt: prompt, technicalLog: technicalLog)
                printLine(memberLine(member, "linked to \(tabID)", state: .ready))
                sessions.append(MagiMemberTab(member: member, tabID: tabID))
                Thread.sleep(forTimeInterval: launchMemberThrottleSeconds)
            }
            run.metadata["member_tab_count"] = String(sessions.count)
            for session in sessions {
                run.metadata["member_tab_\(session.member.id.rawValue)"] = session.tabID
                run.metadata["member_tab_title_\(session.member.id.rawValue)"] = MagiTabTitleFormatter.title(
                    memberID: session.member.id,
                    displayName: session.member.persona.displayName
                )
            }
            run.metadata["member_tabs"] = sessions
                .map { "\($0.member.id.rawValue)=\($0.tabID)" }
                .joined(separator: ",")
            run.metadata["member_tab_titles"] = sessions
                .map {
                    let title = MagiTabTitleFormatter.title(
                        memberID: $0.member.id,
                        displayName: $0.member.persona.displayName
                    )
                    return "\($0.member.id.rawValue)=\(title)"
                }
                .joined(separator: ",")
            technicalLog.record(
                "council_launch_completed",
                stage: "launch",
                fields: [
                    "member_tab_count": String(sessions.count),
                    "member_tabs": run.metadata["member_tabs"] ?? ""
                ]
            )
            try writeCheckpoint(&run, stage: "council-launched", technicalLog: technicalLog)

            announceStage("PHASE 1 // PRIVATE POSITIONS", "Each member answers alone. No sibling tabs. No cross-talk.")
            let positions = try collectPendingParsed(
                runID: runID,
                roundID: round1.id,
                stageKind: .position,
                stage: "independent analysis",
                sessions: sessions,
                repositoryRoot: repositoryRoot,
                startedAt: round1.startedAt,
                technicalLog: technicalLog,
                recordCapture: { run.rawTranscripts.append($0) },
                parse: { session, output, markers in
                    try MagiTranscriptParser.parsePosition(
                        memberID: session.member.id,
                        roundID: round1.id,
                        output: output,
                        markers: markers
                    )
                },
                onParsed: { session, position in
                    let detail = "position sealed (confidence \(String(format: "%.2f", position.confidence)))"
                    printLine(memberLine(session.member, detail, state: .done))
                    run.positions.append(position)
                    try writeCheckpoint(&run, stage: "round-1-\(session.member.id.rawValue)-position", technicalLog: technicalLog)
                }
            )
            MagiRunStateMachine.completeRound(&run, id: round1.id)
            try writeCheckpoint(&run, stage: "round-1-completed", technicalLog: technicalLog)

            let councilPacket = MagiPromptBuilder.councilPacket(
                runID: runID,
                question: question,
                positions: positions
            )

            let round2 = MagiRunStateMachine.startRound(
                &run,
                id: "round-2",
                index: 2,
                kind: .crossExamination
            )
            try writeCheckpoint(&run, stage: "round-2-started", technicalLog: technicalLog)

            announceStage("PHASE 2 // CROSS-EXAMINATION", "Positions are revealed. The council challenges itself.")
            for session in sessions {
                try throwIfInterrupted(stage: "cross-examination")
                let prompt = MagiPromptBuilder.critiquePrompt(
                    runID: runID,
                    roundID: round2.id,
                    member: session.member,
                    councilPacket: councilPacket
                )
                try sendPrompt(
                    prompt,
                    to: session.tabID,
                    stage: "cross-examination",
                    memberID: session.member.id,
                    technicalLog: technicalLog
                )
            }

            var evidenceRequests = positions.flatMap(\.evidenceRequests)
            let critiqueResults = try collectPendingParsed(
                runID: runID,
                roundID: round2.id,
                stageKind: .critique,
                stage: "cross-examination",
                sessions: sessions,
                repositoryRoot: repositoryRoot,
                startedAt: round2.startedAt,
                technicalLog: technicalLog,
                recordCapture: { run.rawTranscripts.append($0) },
                parse: { session, output, markers in
                    try MagiTranscriptParser.parseCritiques(
                        criticMemberID: session.member.id,
                        roundID: round2.id,
                        output: output,
                        markers: markers
                    )
                },
                onParsed: { session, result in
                    printLine(memberLine(session.member, "\(result.critiques.count) challenge(s) entered", state: .done))
                    run.critiques.append(contentsOf: result.critiques)
                    try writeCheckpoint(&run, stage: "round-2-\(session.member.id.rawValue)-critique", technicalLog: technicalLog)
                }
            )
            let critiques = critiqueResults.flatMap(\.critiques)
            evidenceRequests.append(contentsOf: critiqueResults.flatMap(\.evidenceRequests))
            MagiRunStateMachine.completeRound(&run, id: round2.id)
            try writeCheckpoint(&run, stage: "round-2-completed", technicalLog: technicalLog)

            let reviewedRequests = try reviewEvidenceRequests(evidenceRequests, config: config)
            run.evidenceRequests.append(contentsOf: reviewedRequests)
            let deniedCount = reviewedRequests.filter { $0.status == .denied }.count
            MagiRunStateMachine.recordDeniedEvidenceCount(deniedCount, in: &run)
            let approvedRequests = reviewedRequests.filter { $0.status == .approved }
            if !approvedRequests.isEmpty {
                run.status = .waitingForEvidenceApproval
            }
            try writeCheckpoint(&run, stage: "evidence-reviewed", technicalLog: technicalLog)

            let round3 = MagiRunStateMachine.startRound(
                &run,
                id: "round-3",
                index: 3,
                kind: .evidenceCollection
            )
            try writeCheckpoint(&run, stage: "round-3-started", technicalLog: technicalLog)
            let evidencePackets = try collectEvidence(
                for: approvedRequests,
                config: config,
                technicalLog: technicalLog
            )
            run.evidencePackets.append(contentsOf: evidencePackets)
            markEvidenceRequestsFromPackets(evidencePackets, in: &run)
            if !approvedRequests.isEmpty {
                let admittedCount = evidencePackets.filter { $0.metadata["collection_status"] == "fulfilled" }.count
                let failedCount = evidencePackets.filter { $0.metadata["collection_status"] == "failed" }.count
                if failedCount > 0 {
                    announceStep("\(admittedCount) fact packet(s) admitted; \(failedCount) collector(s) failed.")
                } else {
                    announceStep("\(admittedCount) fact packet(s) admitted into deliberation.")
                }
            }
            run.status = .running
            MagiRunStateMachine.completeRound(&run, id: round3.id)
            try writeCheckpoint(&run, stage: "round-3-completed", technicalLog: technicalLog)

            let round4 = MagiRunStateMachine.startRound(
                &run,
                id: "round-4",
                index: 4,
                kind: .vote
            )
            try writeCheckpoint(&run, stage: "round-4-started", technicalLog: technicalLog)

            announceStage("PHASE 4 // FINAL VOTE", "Arguments and approved facts are sealed into each ballot.")
            for session in sessions {
                try throwIfInterrupted(stage: "final vote")
                let prompt = MagiPromptBuilder.finalVotePrompt(
                    runID: runID,
                    roundID: round4.id,
                    member: session.member,
                    councilPacket: councilPacket,
                    critiques: critiques,
                    evidencePackets: evidencePackets,
                    questionKind: questionKind
                )
                try sendPrompt(
                    prompt,
                    to: session.tabID,
                    stage: "final vote",
                    memberID: session.member.id,
                    technicalLog: technicalLog
                )
            }

            var voteResults = try collectVotes(
                runID: runID,
                roundID: round4.id,
                sessions: sessions,
                stageName: "final vote",
                repositoryRoot: repositoryRoot,
                technicalLog: technicalLog,
                recordCapture: { run.rawTranscripts.append($0) }
            )
            MagiRunStateMachine.completeRound(&run, id: round4.id)
            try writeCheckpoint(&run, stage: "round-4-votes-collected", technicalLog: technicalLog)
            let positionRoundVetoes = positions.compactMap(\.veto)
            var resolutionVetoes = MagiVetoResolutionScope.finalResolutionVetoes(
                positionRoundVetoes: positionRoundVetoes,
                voteRoundVetoes: voteResults.vetoes
            )

            var policy = MagiResolutionPolicy(
                majorityThreshold: council.majorityThreshold,
                deadlockExtraRoundEnabled: config.deadlockExtraRoundEnabled,
                vetoBlocksVerdict: config.vetoBlocksVerdict
            )
            var verdict = MagiDecisionResolver.resolve(
                votes: voteResults.votes,
                vetoes: resolutionVetoes,
                policy: policy,
                questionKind: questionKind
            )

            if verdict.requiresAdditionalRound {
                run.metadata["deadlock_extra_round"] = "true"
                let extraRound = MagiRunStateMachine.startRound(
                    &run,
                    id: "round-5",
                    index: 5,
                    kind: .extraDeliberation
                )
                try writeCheckpoint(&run, stage: "round-5-started", technicalLog: technicalLog)
                announceStage("PHASE 5 // DEADLOCK DELIBERATION", "The first ballot did not settle. One more round opens.")
                for session in sessions {
                    try throwIfInterrupted(stage: "extra deliberation")
                    let prompt = MagiPromptBuilder.extraRoundPrompt(
                        runID: runID,
                        roundID: extraRound.id,
                        member: session.member,
                        question: question,
                        votes: voteResults.votes,
                        vetoes: resolutionVetoes,
                        questionKind: questionKind
                    )
                    try sendPrompt(
                        prompt,
                        to: session.tabID,
                        stage: "extra deliberation",
                        memberID: session.member.id,
                        technicalLog: technicalLog
                    )
                }

                voteResults = try collectVotes(
                    runID: runID,
                    roundID: extraRound.id,
                    sessions: sessions,
                    stageName: "extra deliberation",
                    repositoryRoot: repositoryRoot,
                    technicalLog: technicalLog,
                    recordCapture: { run.rawTranscripts.append($0) }
                )
                resolutionVetoes = MagiVetoResolutionScope.finalResolutionVetoes(
                    positionRoundVetoes: positionRoundVetoes,
                    voteRoundVetoes: voteResults.vetoes
                )
                policy.deadlockExtraRoundEnabled = false
                verdict = MagiDecisionResolver.resolve(
                    votes: voteResults.votes,
                    vetoes: resolutionVetoes,
                    policy: policy,
                    questionKind: questionKind
                )
                MagiRunStateMachine.completeRound(&run, id: extraRound.id)
                try writeCheckpoint(&run, stage: "round-5-votes-collected", technicalLog: technicalLog)
            }

            run.finalVerdict = verdict
            run.metadata["verdict_kind"] = verdict.kind.rawValue
            if verdict.kind == .blockedByVeto {
                run.metadata["blocking_veto"] = "true"
            }
            if verdict.kind == .deadlock || verdict.kind == .noConsensus {
                run.metadata["no_consensus"] = "true"
            }
            run.status = .completed
            run.completedAt = Date()

            let bundle = try writeCheckpoint(&run, stage: "completed", technicalLog: technicalLog)

            printFinalVerdict(verdict, bundle: bundle, technicalLog: technicalLog)

            closeMemberTabs(
                sessions,
                config: config,
                technicalLog: technicalLog,
                outcome: "completed"
            )
            return run
        } catch {
            let category = failureCategory(for: error)
            technicalLog.record(
                "run_failed",
                stage: failureStage(for: error),
                level: "error",
                message: error.localizedDescription,
                fields: ["category": category.rawValue]
            )
            if category == .interrupted {
                MagiRunStateMachine.markInterrupted(
                    &run,
                    stage: failureStage(for: error),
                    message: error.localizedDescription
                )
            } else {
                MagiRunStateMachine.markFailed(
                    &run,
                    category: category,
                    stage: failureStage(for: error),
                    message: error.localizedDescription
                )
            }
            if let bundle = try? writeCheckpoint(&run, stage: run.status.rawValue, technicalLog: technicalLog) {
                printLine("")
                printLine(run.status == .interrupted ? "Interrupted" : "Failed")
                printLine(error.localizedDescription)
                printLine("Artifacts: \(bundle.rootDirectory)")
                printLine("Technical log: \(technicalLog.path)")
            } else {
                printLine("")
                printLine(run.status == .interrupted ? "Interrupted" : "Failed")
                printLine(error.localizedDescription)
                printLine("Artifacts: unavailable")
                printLine("Technical log: \(technicalLog.path)")
            }
            closeMemberTabs(
                sessions,
                config: config,
                technicalLog: technicalLog,
                outcome: run.status.rawValue,
                allowMCPCalls: shouldAttemptMemberTabCleanup(after: category)
            )
            throw error
        }
    }
}
