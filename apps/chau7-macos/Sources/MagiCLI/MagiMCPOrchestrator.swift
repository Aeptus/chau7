import Chau7Core
import Darwin
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

    @discardableResult
    private func writeCheckpoint(
        _ run: inout MagiRun,
        stage: String,
        technicalLog: MagiTechnicalLog? = nil
    ) throws -> MagiArtifactBundle {
        MagiRunStateMachine.checkpoint(&run, stage: stage)
        if let bundle = run.artifactBundle {
            MagiRunStateMachine.recordArtifactBundle(bundle, in: &run)
        }
        technicalLog?.record(
            "checkpoint",
            stage: stage,
            fields: [
                "status": run.status.rawValue,
                "positions": String(run.positions.count),
                "critiques": String(run.critiques.count),
                "evidence_requests": String(run.evidenceRequests.count),
                "evidence_packets": String(run.evidencePackets.count)
            ]
        )

        let shouldWriteFullBundle = run.status == .completed
            || run.status == .failed
            || run.status == .interrupted
        let bundle = try writeArtifacts(run: run, fullBundle: shouldWriteFullBundle)
        if run.artifactBundle != bundle {
            MagiRunStateMachine.recordArtifactBundle(bundle, in: &run)
            return try writeArtifacts(run: run, fullBundle: shouldWriteFullBundle)
        }
        return bundle
    }

    private func writeArtifacts(run: MagiRun, fullBundle: Bool) throws -> MagiArtifactBundle {
        if fullBundle {
            return try MagiRunArtifactStore.write(run: run, fileManager: fileManager)
        }
        return try MagiRunArtifactStore.writeCheckpoint(run: run, fileManager: fileManager)
    }

    private func throwIfInterrupted(stage: String) throws {
        if isInterrupted() {
            throw MagiMCPOrchestratorError.interrupted(stage: stage)
        }
    }

    private func failureStage(for error: Error) -> String {
        switch error {
        case let MagiMCPOrchestratorError.timedOut(stage, _, _):
            return stage
        case let MagiMCPOrchestratorError.parseFailedAfterRepair(stage, _, _):
            return stage
        case let MagiMCPOrchestratorError.interrupted(stage):
            return stage
        case MagiMCPOrchestratorError.evidenceApprovalRequiredNonInteractive:
            return "evidence approval"
        case MagiMCPOrchestratorError.mcpContractUnsupported:
            return "mcp-preflight"
        case MagiMCPOrchestratorError.launchFailed:
            return "launch"
        case let MagiMCPOrchestratorError.missingToolField(tool, _):
            return tool
        default:
            return "run"
        }
    }

    private func failureCategory(for error: Error) -> MagiRunFailureCategory {
        switch error {
        case MagiMCPOrchestratorError.interrupted:
            return .interrupted
        case MagiMCPOrchestratorError.timedOut:
            return .agentTimeout
        case MagiMCPOrchestratorError.parseFailedAfterRepair:
            return .malformedJSON
        case MagiMCPOrchestratorError.evidenceApprovalRequiredNonInteractive:
            return .evidenceDenied
        case MagiMCPOrchestratorError.mcpContractUnsupported:
            return .chau7Unavailable
        case let MagiMCPOrchestratorError.launchFailed(_, reason):
            return looksLikeProviderAuthFailure(reason) ? .providerUnavailable : .tabCreationFailed
        case let MagiMCPClientError.toolError(name, message):
            if name == "agent_launch" {
                return looksLikeProviderAuthFailure(message) ? .providerUnavailable : .tabCreationFailed
            }
            return .unknown
        case MagiMCPClientError.socketMissing:
            return .mcpSocketMissing
        case MagiMCPClientError.connectFailed(_, _),
             MagiMCPClientError.readTimedOut,
             MagiMCPClientError.disconnected:
            return .chau7Unavailable
        case MagiTranscriptParseError.invalidJSON:
            return .malformedJSON
        default:
            return .unknown
        }
    }

    private func looksLikeProviderAuthFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return [
            "login",
            "logged in",
            "auth",
            "authenticate",
            "unauthorized",
            "permission denied",
            "api key",
            "token"
        ].contains { normalized.contains($0) }
    }

    private var mcpSocketPath: String {
        "\(paths.homeDirectory)/.chau7/mcp.sock"
    }

    private func announceStage(_ title: String, _ detail: String? = nil) {
        printLine("")
        printLine(terminalStyle.styled(">> \(title)", .bold, .cyan))
        if let detail {
            printLine("   \(terminalStyle.styled(detail, .dim))")
        }
    }

    private func announceStep(_ detail: String) {
        printLine("   \(terminalStyle.styled(detail, .dim))")
    }

    private func memberLine(
        _ member: MagiMember,
        _ detail: String,
        state: MagiMemberLineState = .info
    ) -> String {
        memberLine(member.id, displayName: member.persona.displayName, detail, state: state)
    }

    private func memberLine(
        _ memberID: MagiMemberID,
        _ detail: String,
        state: MagiMemberLineState = .info
    ) -> String {
        memberLine(memberID, displayName: memberID.displayName, detail, state: state)
    }

    private func memberLine(
        _ memberID: MagiMemberID,
        displayName: String,
        _ detail: String,
        state: MagiMemberLineState
    ) -> String {
        "\(memberPrefix(memberID, displayName: displayName, state: state).styled)\(detail)"
    }

    private func printMemberOutput(
        _ member: MagiMember,
        _ detail: String,
        state: MagiMemberLineState
    ) {
        let prefix = memberPrefix(member.id, displayName: member.persona.displayName, state: state)
        let availableWidth = max(32, terminalStyle.wrapColumn - prefix.visibleLength)
        let lines = MagiTerminalText.wrapped(detail, width: availableWidth)
        guard let first = lines.first else {
            printLine(prefix.styled)
            return
        }

        printLine("\(prefix.styled)\(first)")
        let continuationPrefix = String(repeating: " ", count: prefix.visibleLength)
        for line in lines.dropFirst() {
            printLine("\(continuationPrefix)\(line)")
        }
    }

    private func memberPrefix(
        _ memberID: MagiMemberID,
        displayName: String,
        state: MagiMemberLineState
    ) -> (styled: String, visibleLength: Int) {
        let label = terminalStyle.styled(displayName, .bold, accentStyle(for: memberID))
        let visible = "\(state.symbol) \(displayName)> "
        return ("\(state.symbol) \(label)> ", visible.count)
    }

    private func collectorLine(
        _ command: MagiCollectorCommand,
        _ detail: String,
        state: MagiMemberLineState
    ) -> String {
        let label = terminalStyle.styled(command.collectorKind.rawValue, .bold, .yellow)
        return "   \(state.symbol) \(label)> \(detail)"
    }

    private func statusLine(_ label: String, _ value: String) -> String {
        "\(terminalStyle.styled(label, .bold, .cyan)): \(value)"
    }

    private func printWrappedStatusLine(_ label: String, _ value: String) {
        let prefix = "\(terminalStyle.styled(label, .bold, .cyan)): "
        let visiblePrefixLength = label.count + 2
        let width = max(32, terminalStyle.wrapColumn - visiblePrefixLength)
        let lines = MagiTerminalText.wrapped(value, width: width)
        guard let first = lines.first else {
            printLine(prefix)
            return
        }
        printLine("\(prefix)\(first)")
        let continuationPrefix = String(repeating: " ", count: visiblePrefixLength)
        for line in lines.dropFirst() {
            printLine("\(continuationPrefix)\(line)")
        }
    }

    private func printWrappedMemberLine(
        _ memberID: MagiMemberID,
        _ detail: String,
        state: MagiMemberLineState
    ) {
        let prefix = memberPrefix(memberID, displayName: memberID.displayName, state: state)
        let width = max(32, terminalStyle.wrapColumn - prefix.visibleLength)
        let lines = MagiTerminalText.wrapped(detail, width: width)
        guard let first = lines.first else {
            printLine(prefix.styled)
            return
        }
        printLine("\(prefix.styled)\(first)")
        let continuationPrefix = String(repeating: " ", count: prefix.visibleLength)
        for line in lines.dropFirst() {
            printLine("\(continuationPrefix)\(line)")
        }
    }

    private func printFinalVerdict(
        _ verdict: MagiVerdict,
        bundle: MagiArtifactBundle,
        technicalLog: MagiTechnicalLog
    ) {
        announceStage("VERDICT", "The council has resolved.")
        printLine(terminalStyle.styled(verdict.kind.rawValue, .bold, verdictStyle(for: verdict.kind)))
        printWrappedStatusLine("Kind", verdict.kind.rawValue)
        printWrappedStatusLine("Decision", verdict.decision ?? "none")
        printLine(statusLine("Confidence", String(format: "%.2f", verdict.confidence)))
        if !verdict.rationale.isEmpty {
            printWrappedStatusLine("Rationale", verdict.rationale)
        }

        if verdict.votes.isEmpty {
            printLine(statusLine("Member votes", "none"))
        } else {
            printLine(statusLine("Member votes", String(verdict.votes.count)))
            for vote in verdict.votes.sorted(by: { $0.memberID.rawValue < $1.memberID.rawValue }) {
                printWrappedMemberLine(vote.memberID, memberVoteSummary(vote), state: .done)
            }
        }

        if verdict.vetoes.isEmpty {
            printLine(statusLine("Vetoes", "none"))
        } else {
            printLine(statusLine("Vetoes", String(verdict.vetoes.count)))
            for veto in verdict.vetoes.sorted(by: { $0.memberID.rawValue < $1.memberID.rawValue }) {
                printWrappedMemberLine(veto.memberID, vetoSummary(veto), state: .repair)
            }
        }

        printLine(statusLine("Artifact path", bundle.rootDirectory))
        printLine(statusLine("Technical log", technicalLog.path))
    }

    private func memberVoteSummary(_ vote: MagiVote) -> String {
        var parts: [String] = []
        if let verdictKind = vote.verdictKind {
            parts.append("verdict=\(verdictKind.rawValue)")
        }
        if let decisionID = vote.decisionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !decisionID.isEmpty {
            parts.append("decision_id=\(decisionID)")
        }
        if !vote.choice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("choice=\(vote.choice)")
        }
        if !vote.conditions.isEmpty {
            parts.append("conditions=\(vote.conditions.joined(separator: "; "))")
        }
        parts.append("confidence=\(String(format: "%.2f", vote.confidence))")
        if !vote.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("rationale=\(vote.rationale)")
        }
        return parts.joined(separator: " | ")
    }

    private func vetoSummary(_ veto: MagiVeto) -> String {
        "veto=\(veto.reason) | scope=\(veto.scope) | blocks_verdict=\(veto.blocksVerdict)"
    }

    private func questionModeSelection(
        question: String,
        override: MagiQuestionKind?
    ) -> MagiQuestionKindInference {
        if let override {
            return MagiQuestionKindInference(kind: override, reason: "explicit --mode")
        }
        return MagiQuestionKind.inferWithReason(from: question)
    }

    private func modeStatusText(selection: MagiQuestionKindInference, explicit: Bool) -> String {
        if explicit {
            return "\(selection.kind.rawValue) (explicit --mode)"
        }
        return "\(selection.kind.rawValue) (inferred: \(selection.reason))"
    }

    private func progressLine(
        member: MagiMember,
        stage: String,
        stageKind: MagiProtocolStage,
        pulse: Int,
        terminalCharacters: Int,
        eventCount: Int,
        mode: MagiProgressMode = .waiting
    ) -> String {
        let phrases = mode == .repair
            ? repairProgressPhrases + effectiveProcessingLines
            : effectiveProcessingLines
        let phrase = phrases[pulse % phrases.count]
        let checksum = String(format: "%04X", (pulse * 137 + terminalCharacters + eventCount) % 65535)
        let telemetry = "buf \(formatCharacterCount(terminalCharacters)) // evt \(eventCount) // chk \(checksum)"
        let detail = "\(stageKind.outputName.uppercased()) // \(phrase) // \(telemetry)"
        return memberLine(member, "\(stage): \(detail)", state: mode == .repair ? .repair : .working)
    }

    private var effectiveProcessingLines: [String] {
        let configured = processingLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return configured.isEmpty ? MagiCouncilArtFile.defaultProcessingLines : configured
    }

    private func renderProgressLine(
        member: MagiMember,
        stage: String,
        stageKind: MagiProtocolStage,
        pulse: Int,
        terminalCharacters: Int,
        eventCount: Int,
        mode: MagiProgressMode = .waiting
    ) {
        let line = progressLine(
            member: member,
            stage: stage,
            stageKind: stageKind,
            pulse: pulse,
            terminalCharacters: terminalCharacters,
            eventCount: eventCount,
            mode: mode
        )
        if terminalStyle.supportsDynamicOutput {
            printRaw("\r\(terminalStyle.clearLine)\(line)")
        } else {
            printLine(line)
        }
    }

    private func clearProgressLine() {
        guard terminalStyle.supportsDynamicOutput else { return }
        printRaw("\r\(terminalStyle.clearLine)")
    }

    private func sleepBeforeNextPoll(
        member: MagiMember,
        stage: String,
        stageKind: MagiProtocolStage,
        pulse: inout Int,
        terminalCharacters: Int,
        eventCount: Int,
        mode: MagiProgressMode = .waiting,
        duration: TimeInterval = 3
    ) throws {
        guard terminalStyle.supportsDynamicOutput else {
            Thread.sleep(forTimeInterval: duration)
            return
        }

        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            try throwIfInterrupted(stage: stage)
            renderProgressLine(
                member: member,
                stage: stage,
                stageKind: stageKind,
                pulse: pulse,
                terminalCharacters: terminalCharacters,
                eventCount: eventCount,
                mode: mode
            )
            pulse += 1
            Thread.sleep(forTimeInterval: min(progressFrameSeconds, max(0.01, deadline.timeIntervalSinceNow)))
        }
    }

    private func formatCharacterCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fm", Double(count) / 1_000_000)
        }
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return String(count)
    }

    private var repairProgressPhrases: [String] {
        [
            "repair requested",
            "extracting structure",
            "waiting for clean block",
            "validating contract"
        ]
    }

    private func accentStyle(for memberID: MagiMemberID) -> MagiANSIStyle {
        switch memberID {
        case .melchior:
            return .cyan
        case .balthasar:
            return .magenta
        case .casper:
            return .yellow
        }
    }

    private func verdictStyle(for kind: MagiVerdictKind) -> MagiANSIStyle {
        switch kind {
        case .approve, .select, .rank:
            return .green
        case .conditional, .needEvidence, .escalate:
            return .yellow
        case .reject, .deadlock, .blockedByVeto, .noConsensus:
            return .red
        }
    }

    private func compact(_ value: String, limit: Int = 110) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: max(0, limit - 3))
        return "\(trimmed[..<index])..."
    }

    private func loadCouncil(config: MagiConfig) throws -> MagiCouncil {
        let members = try MagiMemberID.allCases.map { memberID -> MagiMember in
            let memberConfig = config.members[memberID] ?? MagiMemberConfiguration(provider: "unconfigured")
            let personaContent = try String(contentsOfFile: paths.personaPath(for: memberID), encoding: .utf8)
            let persona = MagiPersonaFileParser.parse(memberID: memberID, content: personaContent)
            return MagiMember(
                id: memberID,
                persona: persona,
                provider: memberConfig.provider,
                modelClass: memberConfig.modelClass,
                reasoning: memberConfig.reasoning,
                modelName: memberConfig.modelName
            )
        }
        return MagiCouncil(id: config.defaultCouncilID, name: "MAGI", members: members)
    }

    private func launchMember(
        _ member: MagiMember,
        prompt: String,
        technicalLog: MagiTechnicalLog
    ) throws -> String {
        let providerCommand = MagiProviderCommandBuilder.command(for: member)
        let command = providerCommand.commandLine
        let result = try client.callTool(name: "agent_launch", arguments: [
            "directory": paths.currentDirectory,
            "agent_command": command,
            "prompt": prompt,
            "count": 1,
            "ready_timeout_ms": launchTimeoutMs
        ])

        guard let agents = result["agents"] as? [[String: Any]],
              let agent = agents.first else {
            throw MagiMCPOrchestratorError.missingToolField(tool: "agent_launch", field: "agents[0]")
        }
        guard let tabID = agent["tab_id"] as? String else {
            throw MagiMCPOrchestratorError.missingToolField(tool: "agent_launch", field: "agents[0].tab_id")
        }
        let tabTitle = renameMemberTab(
            tabID: tabID,
            member: member,
            technicalLog: technicalLog
        )
        let launchStatus = agent["status"] as? String ?? "missing"
        let promptStatus = agent["prompt"] as? String ?? "missing"
        var promptInputVisible = boolField(agent["prompt_input_visible"])
        var promptSubmitted = boolField(agent["prompt_submitted"])
        var agentRunning = boolField(agent["agent_running"])
        if agent["prompt_input_visible"] == nil,
           agent["prompt_submitted"] == nil,
           agent["agent_running"] == nil,
           promptStatus == "sent" {
            technicalLog.record(
                "member_launch_verification_fallback_started",
                stage: "launch",
                memberID: member.id,
                tabID: tabID,
                message: "agent_launch did not return prompt verification fields; querying tab output/status"
            )
            let fallback = verifyLaunchedMemberPrompt(
                tabID: tabID,
                prompt: prompt,
                member: member,
                technicalLog: technicalLog
            )
            promptInputVisible = fallback.promptInputVisible
            promptSubmitted = fallback.promptSubmitted
            agentRunning = fallback.agentRunning
        }
        technicalLog.record(
            "member_launch_result",
            stage: "launch",
            memberID: member.id,
            tabID: tabID,
            fields: [
                "provider": member.provider,
                "agent_command": command,
                "resolved_model": providerCommand.resolvedModel ?? "",
                "resolved_reasoning": providerCommand.resolvedReasoning ?? "",
                "raw_provider_command": String(providerCommand.usesRawCommand),
                "tab_title": tabTitle,
                "status": launchStatus,
                "prompt_status": promptStatus,
                "prompt_input_visible": String(promptInputVisible),
                "prompt_submitted": String(promptSubmitted),
                "agent_running": String(agentRunning)
            ]
        )
        guard (agent["status"] as? String) == "launched" else {
            throw MagiMCPOrchestratorError.launchFailed(
                member: member.persona.displayName,
                reason: agent["error"] as? String ?? "agent_launch returned \(agent)"
            )
        }
        let promptAccepted = AgentPromptInjectionPolicy.accepted(
            status: promptStatus,
            inputVisible: promptInputVisible,
            submitted: promptSubmitted,
            running: agentRunning
        )
        guard promptAccepted else {
            throw MagiMCPOrchestratorError.launchFailed(
                member: member.persona.displayName,
                reason: "provider launched in \(tabID), but Chau7 did not detect an attached agent for prompt injection"
            )
        }
        guard promptInputVisible || (promptSubmitted && agentRunning) else {
            throw MagiMCPOrchestratorError.launchFailed(
                member: member.persona.displayName,
                reason: "provider launched in \(tabID), but MAGI did not observe the prompt text in the tab before submission"
            )
        }
        guard promptSubmitted else {
            throw MagiMCPOrchestratorError.launchFailed(
                member: member.persona.displayName,
                reason: "provider launched in \(tabID), but Chau7 did not confirm prompt submission"
            )
        }
        guard agentRunning else {
            throw MagiMCPOrchestratorError.launchFailed(
                member: member.persona.displayName,
                reason: "provider launched in \(tabID), but the tab did not report a running agent after submission"
            )
        }
        return tabID
    }

    @discardableResult
    private func renameMemberTab(
        tabID: String,
        member: MagiMember,
        technicalLog: MagiTechnicalLog
    ) -> String {
        let title = MagiTabTitleFormatter.title(
            memberID: member.id,
            displayName: member.persona.displayName
        )
        do {
            _ = try client.callTool(name: "tab_rename", arguments: [
                "tab_id": tabID,
                "title": title
            ])
            technicalLog.record(
                "member_tab_renamed",
                stage: "launch",
                memberID: member.id,
                tabID: tabID,
                fields: ["title": title]
            )
        } catch {
            technicalLog.record(
                "member_tab_rename_failed",
                stage: "launch",
                level: "warning",
                memberID: member.id,
                tabID: tabID,
                message: error.localizedDescription,
                fields: ["title": title]
            )
        }
        return title
    }

    private func verifyLaunchedMemberPrompt(
        tabID: String,
        prompt: String,
        member: MagiMember,
        technicalLog: MagiTechnicalLog
    ) -> MagiLaunchVerification {
        let promptInputVisible = waitForPromptNeedle(
            tabID: tabID,
            prompt: prompt,
            timeoutSeconds: 4
        )
        let agentRunning = waitForAgentRunning(
            tabID: tabID,
            provider: member.provider,
            timeoutSeconds: 5
        )
        technicalLog.record(
            "member_launch_verification_fallback_completed",
            stage: "launch",
            memberID: member.id,
            tabID: tabID,
            fields: [
                "prompt_input_visible": String(promptInputVisible),
                "prompt_submitted": "true",
                "agent_running": String(agentRunning)
            ]
        )
        return MagiLaunchVerification(
            promptInputVisible: promptInputVisible,
            promptSubmitted: true,
            agentRunning: agentRunning
        )
    }

    private func waitForPromptNeedle(
        tabID: String,
        prompt: String,
        timeoutSeconds: TimeInterval
    ) -> Bool {
        let needles = promptVisibilityNeedles(from: prompt)
        guard !needles.isEmpty else { return true }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let bufferOutput = (try? tabOutput(tabID: tabID, source: "buffer")) ?? ""
            if needles.contains(where: { bufferOutput.contains($0) }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func waitForAgentRunning(
        tabID: String,
        provider: String,
        timeoutSeconds: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if (try? tabStatusReportsRunningAgent(tabID: tabID)) == true {
                return true
            }
            let bufferOutput = (try? tabOutput(tabID: tabID, source: "buffer")) ?? ""
            if agentOutputLooksResponsive(bufferOutput, provider: provider) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func tabStatusReportsRunningAgent(tabID: String) throws -> Bool {
        let result = try client.callTool(name: "tab_status", arguments: ["tab_id": tabID])
        if result["active_run"] is [String: Any] {
            return true
        }

        let hasAgentIdentity =
            stringField(result["active_app"]).isEmpty == false
                || stringField(result["ai_provider"]).isEmpty == false
        guard hasAgentIdentity else { return false }

        let runningStates = ["running", "waitingForInput", "approvalRequired", "stuck"]
        return ["status", "raw_status"].contains { key in
            runningStates.contains(stringField(result[key]))
        }
    }

    private func agentOutputLooksResponsive(_ output: String, provider: String) -> Bool {
        let lowercased = output.lowercased()
        var needles = [
            "openai codex",
            "queued follow-up inputs",
            "usage limit resets",
            "claude code",
            "google gemini",
            "thinking",
            "working..."
        ]

        let normalizedProvider = provider.lowercased()
        if normalizedProvider.contains("codex") {
            needles.append("gpt-")
        } else if normalizedProvider.contains("claude") {
            needles.append(contentsOf: ["sonnet", "opus", "haiku"])
        } else if normalizedProvider.contains("gemini") {
            needles.append(contentsOf: ["google gemini", "gemini cli"])
        }

        return needles.contains { lowercased.contains($0) }
    }

    private func promptVisibilityNeedles(from prompt: String) -> [String] {
        prompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
            .prefix(3)
            .map { String($0.prefix(min(80, $0.count))) }
    }

    private func sendPrompt(
        _ prompt: String,
        to tabID: String,
        stage: String,
        memberID: MagiMemberID,
        technicalLog: MagiTechnicalLog
    ) throws {
        technicalLog.record(
            "prompt_send_started",
            stage: stage,
            memberID: memberID,
            tabID: tabID,
            fields: ["characters": String(prompt.count)]
        )
        let sendResult = try client.callTool(name: "tab_send_input", arguments: [
            "tab_id": tabID,
            "input": prompt
        ])
        technicalLog.record(
            "prompt_input_sent",
            stage: stage,
            memberID: memberID,
            tabID: tabID,
            fields: ["ok": stringField(sendResult["ok"])]
        )
        Thread.sleep(forTimeInterval: 0.3)
        let submitResult = try client.callTool(name: "tab_submit_prompt", arguments: [
            "tab_id": tabID
        ])
        technicalLog.record(
            "prompt_submitted",
            stage: stage,
            memberID: memberID,
            tabID: tabID,
            fields: [
                "ok": stringField(submitResult["ok"]),
                "enter_count": stringField(submitResult["enter_count"])
            ]
        )
    }

    private enum MagiTerminalReadMode {
        case none
        case tail
        case fullStable

        var logName: String {
            switch self {
            case .none:
                return "none"
            case .tail:
                return "tail"
            case .fullStable:
                return "full_stable"
            }
        }
    }

    private func tabOutput(
        tabID: String,
        source: String = "pty_log",
        lines: Int? = nil,
        waitForStableMs: Int = 0
    ) throws -> String {
        let result = try client.callTool(name: "tab_output", arguments: [
            "tab_id": tabID,
            "lines": lines ?? normalOutputTailLines,
            "wait_for_stable_ms": waitForStableMs,
            "source": source
        ])
        guard let output = result["output"] as? String else {
            throw MagiMCPOrchestratorError.missingToolField(tool: "tab_output", field: "output")
        }
        return output
    }

    private struct MagiPolledOutput {
        var terminalOutput: String
        var eventMessages: [String]
        var eventError: String?
        var tabStatus: [String: Any]?
        var tabStatusError: String?
        var terminalReadMode: MagiTerminalReadMode

        var eventCharacters: Int {
            eventMessages.reduce(0) { $0 + $1.count }
        }

        var combinedOutput: String {
            let eventOutput = eventMessages
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            if terminalOutput.isEmpty { return eventOutput }
            if eventOutput.isEmpty { return terminalOutput }
            return "\(terminalOutput)\n\n\(eventOutput)"
        }
    }

    private func pollStructuredOutput(
        tabID: String,
        repositoryRoot: String?,
        sinceMillis: Int64?,
        terminalReadMode: MagiTerminalReadMode
    ) throws -> MagiPolledOutput {
        let eventCapture = try tabEventMessages(
            tabID: tabID,
            repositoryRoot: repositoryRoot,
            sinceMillis: sinceMillis
        )
        let terminalOutput: String
        switch terminalReadMode {
        case .none:
            terminalOutput = ""
        case .tail:
            terminalOutput = try tabOutput(
                tabID: tabID,
                lines: normalOutputTailLines,
                waitForStableMs: 0
            )
        case .fullStable:
            terminalOutput = try tabOutput(
                tabID: tabID,
                lines: fullOutputLines,
                waitForStableMs: 1000
            )
        }
        let statusCapture = tabStatusSnapshot(tabID: tabID)
        return MagiPolledOutput(
            terminalOutput: terminalOutput,
            eventMessages: eventCapture.messages,
            eventError: eventCapture.error,
            tabStatus: statusCapture.status,
            tabStatusError: statusCapture.error,
            terminalReadMode: terminalReadMode
        )
    }

    private func tabEventMessages(
        tabID: String,
        repositoryRoot: String?,
        sinceMillis: Int64?
    ) throws -> (messages: [String], error: String?) {
        let eventTypes = [
            "agent-turn-complete",
            "finished",
            "response_complete",
            "task_finished"
        ]

        var messages: [String] = []
        var errors: [String] = []

        let runtimeCapture = try runtimeEventMessages(
            tabID: tabID,
            eventTypes: eventTypes,
            sinceMillis: sinceMillis
        )
        messages.append(contentsOf: runtimeCapture.messages)
        if let error = runtimeCapture.error {
            errors.append(error)
        }

        if messages.isEmpty {
            let repoPaths = [
                repositoryRoot,
                paths.currentDirectory
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            let uniqueRepoPaths = uniqueStrings(repoPaths)

            for repoPath in uniqueRepoPaths {
                let repoCapture = try repoEventMessages(
                    repoPath: repoPath,
                    tabID: tabID,
                    eventTypes: eventTypes
                )
                messages.append(contentsOf: repoCapture.messages)
                if let error = repoCapture.error {
                    errors.append(error)
                }
                if !messages.isEmpty {
                    break
                }
            }
        }

        return (uniqueStrings(messages), errors.isEmpty ? nil : errors.joined(separator: "; "))
    }

    private func runtimeEventMessages(
        tabID: String,
        eventTypes: [String],
        sinceMillis: Int64?
    ) throws -> (messages: [String], error: String?) {
        let requestedTypes = Set(eventTypes.map { $0.lowercased() })
        do {
            var arguments: [String: Any] = ["limit": 200]
            if let sinceMillis {
                arguments["since_millis"] = sinceMillis
            }
            let result = try client.callTool(name: "chau7_runtime_events", arguments: arguments)
            guard let events = result["events"] as? [[String: Any]] else {
                throw MagiMCPOrchestratorError.missingToolField(tool: "chau7_runtime_events", field: "events")
            }
            let messages = MagiMCPEventParsing.runtimeEventMessages(
                from: events,
                tabID: tabID,
                eventTypes: Array(requestedTypes)
            )
            return (messages, nil)
        } catch let error as MagiMCPClientError {
            if case let .protocolError(message) = error,
               message.contains("unknown tool") || message.contains("Unknown tool") {
                return ([], message)
            }
            if case let .toolError(_, message) = error {
                return ([], message)
            }
            throw error
        }
    }

    private func repoEventMessages(
        repoPath: String,
        tabID: String,
        eventTypes: [String]
    ) throws -> (messages: [String], error: String?) {
        do {
            let result = try client.callTool(name: "repo_get_events", arguments: [
                "repo_path": repoPath,
                "limit": 50,
                "tab_id": tabID,
                "event_types": eventTypes,
                "truncate_messages": false
            ])
            guard let events = result["events"] as? [[String: Any]] else {
                throw MagiMCPOrchestratorError.missingToolField(tool: "repo_get_events", field: "events")
            }
            return (events.compactMap { $0["message"] as? String }, nil)
        } catch let error as MagiMCPClientError {
            if case let .protocolError(message) = error,
               message.contains("unknown argument") || message.contains("Invalid params") {
                return ([], message)
            }
            if case let .toolError(_, message) = error {
                return ([], message)
            }
            throw error
        }
    }

    private func tabStatusSnapshot(tabID: String) -> (status: [String: Any]?, error: String?) {
        do {
            let result = try client.callTool(name: "tab_status", arguments: ["tab_id": tabID])
            return (result, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private struct PendingParsedMemberState {
        var session: MagiMemberTab
        var markers: MagiProtocolMarkers
        var startedAt: Date
        var eventSinceMillis: Int64
        var lastError: Error?
        var lastOutput: String = ""
        var lastCapture: MagiPolledOutput?
        var lastLoggedOutputCount: Int?
        var lastLoggedEventSignature: String?
        var lastLoggedEventError: String?
        var lastLoggedStatusError: String?
        var lastLoggedParseError: String?
        var nextProgressPulseAt: Date = Date()
        var progressPulse: Int = 0
        var nextTailPollAt: Date = Date()
    }

    private func collectPendingParsed<T>(
        runID: String,
        roundID: String,
        stageKind: MagiProtocolStage,
        stage: String,
        sessions: [MagiMemberTab],
        repositoryRoot: String?,
        startedAt: Date,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void,
        parse: (MagiMemberTab, String, MagiProtocolMarkers) throws -> T,
        onParsed: (MagiMemberTab, T) throws -> Void
    ) throws -> [T] {
        let deadline = Date().addingTimeInterval(roundTimeoutSeconds)
        let eventSinceMillis = runtimeEventSinceMillis(startedAt: startedAt)
        var pendingOrder = sessions.map(\.member.id)
        var pending = Dictionary(
            uniqueKeysWithValues: sessions.map { session in
                (
                    session.member.id,
                    PendingParsedMemberState(
                        session: session,
                        markers: MagiProtocolMarkers(
                            runID: runID,
                            roundID: roundID,
                            memberID: session.member.id,
                            stage: stageKind
                        ),
                        startedAt: startedAt,
                        eventSinceMillis: eventSinceMillis
                    )
                )
            }
        )
        var results: [T] = []

        while !pendingOrder.isEmpty, Date() < deadline {
            var completedMemberIDs: [MagiMemberID] = []

            for memberID in pendingOrder {
                try throwIfInterrupted(stage: stage)
                guard var state = pending[memberID] else { continue }

                let now = Date()
                let readMode: MagiTerminalReadMode = now >= state.nextTailPollAt ? .tail : .none
                var capture = try pollStructuredOutput(
                    tabID: state.session.tabID,
                    repositoryRoot: repositoryRoot,
                    sinceMillis: state.eventSinceMillis,
                    terminalReadMode: readMode
                )
                var output = capture.combinedOutput
                if !output.isEmpty {
                    state.lastOutput = output
                }
                state.lastCapture = capture
                logStructuredPollIfNeeded(
                    state: &state,
                    capture: capture,
                    stage: stage,
                    stageKind: stageKind,
                    technicalLog: technicalLog
                )
                renderPendingProgressIfNeeded(
                    state: &state,
                    capture: capture,
                    stage: stage,
                    stageKind: stageKind
                )

                do {
                    let parsed = try parse(state.session, output, state.markers)
                    try completePendingParse(
                        parsed,
                        state: state,
                        output: output,
                        roundID: roundID,
                        stageKind: stageKind,
                        stage: stage,
                        technicalLog: technicalLog,
                        recordCapture: recordCapture,
                        onParsed: onParsed
                    )
                    results.append(parsed)
                    completedMemberIDs.append(memberID)
                    continue
                } catch {
                    state.lastError = error
                    logStructuredParsePendingIfNeeded(
                        state: &state,
                        error: error,
                        stage: stage,
                        stageKind: stageKind,
                        technicalLog: technicalLog
                    )
                }

                if shouldFetchFullOutputForParse(
                    state.lastError,
                    capture: capture,
                    output: output,
                    markers: state.markers,
                    elapsed: Date().timeIntervalSince(state.startedAt)
                ) {
                    capture = try pollStructuredOutput(
                        tabID: state.session.tabID,
                        repositoryRoot: repositoryRoot,
                        sinceMillis: state.eventSinceMillis,
                        terminalReadMode: .fullStable
                    )
                    output = capture.combinedOutput
                    state.lastOutput = output
                    state.lastCapture = capture
                    logStructuredPollIfNeeded(
                        state: &state,
                        capture: capture,
                        stage: stage,
                        stageKind: stageKind,
                        technicalLog: technicalLog
                    )

                    do {
                        let parsed = try parse(state.session, output, state.markers)
                        try completePendingParse(
                            parsed,
                            state: state,
                            output: output,
                            roundID: roundID,
                            stageKind: stageKind,
                            stage: stage,
                            technicalLog: technicalLog,
                            recordCapture: recordCapture,
                            onParsed: onParsed
                        )
                        results.append(parsed)
                        completedMemberIDs.append(memberID)
                        continue
                    } catch {
                        state.lastError = error
                        logStructuredParsePendingIfNeeded(
                            state: &state,
                            error: error,
                            stage: stage,
                            stageKind: stageKind,
                            technicalLog: technicalLog
                        )
                    }
                }

                if shouldRunStableRepair(
                    state.lastError,
                    capture: capture,
                    output: state.lastOutput,
                    elapsed: Date().timeIntervalSince(state.startedAt)
                ) {
                    let parseError = state.lastError?.localizedDescription ?? "structured block did not parse after stable output"
                    recordCapture(rawTranscript(
                        memberID: state.session.member.id,
                        roundID: roundID,
                        stage: stageKind.rawValue,
                        tabID: state.session.tabID,
                        output: state.lastOutput,
                        parseError: parseError,
                        repairAttempted: true,
                        repairSucceeded: false
                    ))
                    let parsed = try runStructuredRepair(
                        context: StructuredRepairContext(
                            runID: runID,
                            roundID: roundID,
                            stageKind: stageKind,
                            stage: stage,
                            member: state.session.member,
                            tabID: state.session.tabID,
                            repositoryRoot: repositoryRoot,
                            expectedMarkers: state.markers,
                            parseError: parseError,
                            lastOutput: state.lastOutput,
                            lastError: state.lastError
                        ),
                        technicalLog: technicalLog,
                        recordCapture: recordCapture
                    ) { output in
                        try parse(state.session, output, state.markers)
                    }
                    try onParsed(state.session, parsed)
                    results.append(parsed)
                    completedMemberIDs.append(memberID)
                    continue
                }

                if readMode == .tail {
                    state.nextTailPollAt = Date().addingTimeInterval(normalTailPollIntervalSeconds)
                }
                pending[memberID] = state
            }

            if !completedMemberIDs.isEmpty {
                for memberID in completedMemberIDs {
                    pending.removeValue(forKey: memberID)
                }
                pendingOrder.removeAll { completedMemberIDs.contains($0) }
            }

            if !pendingOrder.isEmpty {
                Thread.sleep(forTimeInterval: terminalStyle.supportsDynamicOutput ? 0.25 : 0.75)
            }
        }

        guard pendingOrder.isEmpty else {
            let timedOutID = pendingOrder[0]
            guard var state = pending[timedOutID] else {
                throw MagiMCPOrchestratorError.timedOut(stage: stage, member: "unknown", lastError: nil)
            }
            return try handlePendingTimeout(
                state: &state,
                results: results,
                runID: runID,
                roundID: roundID,
                stageKind: stageKind,
                stage: stage,
                repositoryRoot: repositoryRoot,
                technicalLog: technicalLog,
                recordCapture: recordCapture,
                parse: parse,
                onParsed: onParsed
            )
        }

        clearProgressLine()
        return results
    }

    private func completePendingParse<T>(
        _ parsed: T,
        state: PendingParsedMemberState,
        output: String,
        roundID: String,
        stageKind: MagiProtocolStage,
        stage: String,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void,
        onParsed: (MagiMemberTab, T) throws -> Void
    ) throws {
        technicalLog.record(
            "structured_parse_succeeded",
            stage: stage,
            memberID: state.session.member.id,
            tabID: state.session.tabID,
            fields: [
                "stage_kind": stageKind.rawValue,
                "source": state.lastCapture?.terminalReadMode.logName ?? "unknown"
            ]
        )
        recordCapture(rawTranscript(
            memberID: state.session.member.id,
            roundID: roundID,
            stage: stageKind.rawValue,
            tabID: state.session.tabID,
            output: output
        ))
        clearProgressLine()
        try onParsed(state.session, parsed)
    }

    private func handlePendingTimeout<T>(
        state: inout PendingParsedMemberState,
        results: [T],
        runID: String,
        roundID: String,
        stageKind: MagiProtocolStage,
        stage: String,
        repositoryRoot: String?,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void,
        parse: (MagiMemberTab, String, MagiProtocolMarkers) throws -> T,
        onParsed: (MagiMemberTab, T) throws -> Void
    ) throws -> [T] {
        clearProgressLine()
        let capture = try pollStructuredOutput(
            tabID: state.session.tabID,
            repositoryRoot: repositoryRoot,
            sinceMillis: state.eventSinceMillis,
            terminalReadMode: .fullStable
        )
        let output = capture.combinedOutput
        state.lastOutput = output
        state.lastCapture = capture

        do {
            let parsed = try parse(state.session, output, state.markers)
            try completePendingParse(
                parsed,
                state: state,
                output: output,
                roundID: roundID,
                stageKind: stageKind,
                stage: stage,
                technicalLog: technicalLog,
                recordCapture: recordCapture,
                onParsed: onParsed
            )
            return results + [parsed]
        } catch {
            state.lastError = error
        }

        let parseError = state.lastError?.localizedDescription ?? "structured block did not appear before timeout"
        if shouldRunStableRepair(
            state.lastError,
            capture: capture,
            output: output,
            elapsed: Date().timeIntervalSince(state.startedAt)
        ) {
            recordCapture(rawTranscript(
                memberID: state.session.member.id,
                roundID: roundID,
                stage: stageKind.rawValue,
                tabID: state.session.tabID,
                output: output,
                parseError: parseError,
                repairAttempted: true,
                repairSucceeded: false
            ))
            let parsed = try runStructuredRepair(
                context: StructuredRepairContext(
                    runID: runID,
                    roundID: roundID,
                    stageKind: stageKind,
                    stage: stage,
                    member: state.session.member,
                    tabID: state.session.tabID,
                    repositoryRoot: repositoryRoot,
                    expectedMarkers: state.markers,
                    parseError: parseError,
                    lastOutput: output,
                    lastError: state.lastError
                ),
                technicalLog: technicalLog,
                recordCapture: recordCapture
            ) { repairOutput in
                try parse(state.session, repairOutput, state.markers)
            }
            try onParsed(state.session, parsed)
            return results + [parsed]
        }

        recordCapture(rawTranscript(
            memberID: state.session.member.id,
            roundID: roundID,
            stage: stageKind.rawValue,
            tabID: state.session.tabID,
            output: output,
            parseError: parseError,
            repairAttempted: false,
            repairSucceeded: false
        ))
        technicalLog.record(
            "structured_parse_timed_out",
            stage: stage,
            level: "error",
            memberID: state.session.member.id,
            tabID: state.session.tabID,
            message: parseError,
            fields: ["stage_kind": stageKind.rawValue]
        )
        throw MagiMCPOrchestratorError.timedOut(
            stage: stage,
            member: state.session.member.persona.displayName,
            lastError: parseError
        )
    }

    private func logStructuredPollIfNeeded(
        state: inout PendingParsedMemberState,
        capture: MagiPolledOutput,
        stage: String,
        stageKind: MagiProtocolStage,
        technicalLog: MagiTechnicalLog
    ) {
        if capture.terminalReadMode != .none, state.lastLoggedOutputCount != capture.terminalOutput.count {
            state.lastLoggedOutputCount = capture.terminalOutput.count
            technicalLog.record(
                "tab_output_polled",
                stage: stage,
                memberID: state.session.member.id,
                tabID: state.session.tabID,
                fields: [
                    "characters": String(capture.terminalOutput.count),
                    "lines": capture.terminalReadMode == .fullStable ? String(fullOutputLines) : String(normalOutputTailLines),
                    "mode": capture.terminalReadMode.logName,
                    "stage_kind": stageKind.rawValue
                ]
            )
        }

        let eventSignature = "\(capture.eventMessages.count):\(capture.eventCharacters)"
        if capture.eventMessages.isEmpty == false, state.lastLoggedEventSignature != eventSignature {
            state.lastLoggedEventSignature = eventSignature
            technicalLog.record(
                "repo_events_polled",
                stage: stage,
                memberID: state.session.member.id,
                tabID: state.session.tabID,
                fields: [
                    "events": String(capture.eventMessages.count),
                    "characters": String(capture.eventCharacters),
                    "since_millis": String(state.eventSinceMillis),
                    "stage_kind": stageKind.rawValue
                ]
            )
        }
        if let eventError = capture.eventError, state.lastLoggedEventError != eventError {
            state.lastLoggedEventError = eventError
            technicalLog.record(
                "repo_events_unavailable",
                stage: stage,
                level: "warning",
                memberID: state.session.member.id,
                tabID: state.session.tabID,
                message: eventError
            )
        }
        if let statusError = capture.tabStatusError, state.lastLoggedStatusError != statusError {
            state.lastLoggedStatusError = statusError
            technicalLog.record(
                "tab_status_unavailable",
                stage: stage,
                level: "warning",
                memberID: state.session.member.id,
                tabID: state.session.tabID,
                message: statusError
            )
        }
    }

    private func logStructuredParsePendingIfNeeded(
        state: inout PendingParsedMemberState,
        error: Error,
        stage: String,
        stageKind: MagiProtocolStage,
        technicalLog: MagiTechnicalLog
    ) {
        let message = error.localizedDescription
        guard state.lastLoggedParseError != message else { return }
        state.lastLoggedParseError = message
        technicalLog.record(
            "structured_parse_pending",
            stage: stage,
            memberID: state.session.member.id,
            tabID: state.session.tabID,
            message: message,
            fields: ["stage_kind": stageKind.rawValue]
        )
    }

    private func renderPendingProgressIfNeeded(
        state: inout PendingParsedMemberState,
        capture: MagiPolledOutput,
        stage: String,
        stageKind: MagiProtocolStage,
        mode: MagiProgressMode = .waiting
    ) {
        let now = Date()
        if terminalStyle.supportsDynamicOutput || progressPulseSeconds <= 0 || now >= state.nextProgressPulseAt {
            renderProgressLine(
                member: state.session.member,
                stage: stage,
                stageKind: stageKind,
                pulse: state.progressPulse,
                terminalCharacters: capture.terminalOutput.count,
                eventCount: capture.eventMessages.count,
                mode: mode
            )
            state.progressPulse += 1
            state.nextProgressPulseAt = now.addingTimeInterval(progressPulseSeconds)
        }
    }

    private func shouldFetchFullOutputForParse(
        _ error: Error?,
        capture: MagiPolledOutput,
        output: String,
        markers: MagiProtocolMarkers,
        elapsed: TimeInterval
    ) -> Bool {
        guard capture.terminalReadMode != .fullStable else { return false }
        guard error != nil else { return false }
        if !MagiTranscriptParser.blockCandidates(in: output, markers: markers).isEmpty {
            return true
        }
        let hasMarkerText = output.contains(markers.begin) || output.contains(markers.end)
        guard hasMarkerText || elapsed >= idleRepairGraceSeconds else { return false }
        guard elapsed >= idleRepairGraceSeconds else { return false }
        return capture.tabStatus.map(MagiMCPEventParsing.tabStatusIsIdleForRepair) ?? false
    }

    private func shouldRunStableRepair(
        _ error: Error?,
        capture: MagiPolledOutput,
        output: String,
        elapsed: TimeInterval
    ) -> Bool {
        guard error != nil else { return false }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard elapsed >= idleRepairGraceSeconds else { return false }
        return capture.tabStatus.map(MagiMCPEventParsing.tabStatusIsIdleForRepair) ?? false
    }

    private func runtimeEventSinceMillis(startedAt: Date) -> Int64 {
        Int64(max(0, (startedAt.timeIntervalSince1970 - 2) * 1000))
    }

    private func waitForParsed<T>(
        runID: String,
        roundID: String,
        stageKind: MagiProtocolStage,
        stage: String,
        member: MagiMember,
        tabID: String,
        repositoryRoot: String?,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void,
        parser: (String) throws -> T
    ) throws -> T {
        let deadline = Date().addingTimeInterval(roundTimeoutSeconds)
        let startedAt = Date()
        let expectedMarkers = MagiProtocolMarkers(
            runID: runID,
            roundID: roundID,
            memberID: member.id,
            stage: stageKind
        )
        var lastError: Error?
        var lastOutput = ""
        var lastLoggedOutputCount: Int?
        var lastLoggedEventSignature: String?
        var lastLoggedEventError: String?
        var lastLoggedStatusError: String?
        var nextProgressPulseAt = Date()
        var progressPulse = 0

        while Date() < deadline {
            try throwIfInterrupted(stage: stage)
            let capture = try pollStructuredOutput(
                tabID: tabID,
                repositoryRoot: repositoryRoot,
                sinceMillis: runtimeEventSinceMillis(startedAt: startedAt),
                terminalReadMode: .tail
            )
            let output = capture.combinedOutput
            lastOutput = output
            let now = Date()
            if terminalStyle.supportsDynamicOutput {
                renderProgressLine(
                    member: member,
                    stage: stage,
                    stageKind: stageKind,
                    pulse: progressPulse,
                    terminalCharacters: capture.terminalOutput.count,
                    eventCount: capture.eventMessages.count
                )
                progressPulse += 1
            } else if progressPulseSeconds > 0, now >= nextProgressPulseAt {
                renderProgressLine(
                    member: member,
                    stage: stage,
                    stageKind: stageKind,
                    pulse: progressPulse,
                    terminalCharacters: capture.terminalOutput.count,
                    eventCount: capture.eventMessages.count
                )
                progressPulse += 1
                nextProgressPulseAt = now.addingTimeInterval(progressPulseSeconds)
            }
            if lastLoggedOutputCount != capture.terminalOutput.count {
                lastLoggedOutputCount = capture.terminalOutput.count
                technicalLog.record(
                    "tab_output_polled",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    fields: ["characters": String(capture.terminalOutput.count)]
                )
            }
            let eventSignature = "\(capture.eventMessages.count):\(capture.eventCharacters)"
            if capture.eventMessages.isEmpty == false, lastLoggedEventSignature != eventSignature {
                lastLoggedEventSignature = eventSignature
                technicalLog.record(
                    "repo_events_polled",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    fields: [
                        "events": String(capture.eventMessages.count),
                        "characters": String(capture.eventCharacters)
                    ]
                )
            }
            if let eventError = capture.eventError, lastLoggedEventError != eventError {
                lastLoggedEventError = eventError
                technicalLog.record(
                    "repo_events_unavailable",
                    stage: stage,
                    level: "warning",
                    memberID: member.id,
                    tabID: tabID,
                    message: eventError
                )
            }
            if let statusError = capture.tabStatusError, lastLoggedStatusError != statusError {
                lastLoggedStatusError = statusError
                technicalLog.record(
                    "tab_status_unavailable",
                    stage: stage,
                    level: "warning",
                    memberID: member.id,
                    tabID: tabID,
                    message: statusError
                )
            }
            do {
                let parsed = try parser(output)
                technicalLog.record(
                    "structured_parse_succeeded",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    fields: ["stage_kind": stageKind.rawValue]
                )
                recordCapture(rawTranscript(
                    memberID: member.id,
                    roundID: roundID,
                    stage: stageKind.rawValue,
                    tabID: tabID,
                    output: output
                ))
                clearProgressLine()
                return parsed
            } catch {
                lastError = error
                technicalLog.record(
                    "structured_parse_pending",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    message: error.localizedDescription,
                    fields: ["stage_kind": stageKind.rawValue]
                )
                if shouldRepairImmediately(error) {
                    break
                }
                if shouldRepairAfterIdleMissingBlock(
                    error,
                    capture: capture,
                    output: output,
                    markers: expectedMarkers,
                    elapsed: Date().timeIntervalSince(startedAt)
                ) {
                    technicalLog.record(
                        "structured_parse_idle_without_block",
                        stage: stage,
                        memberID: member.id,
                        tabID: tabID,
                        message: error.localizedDescription,
                        fields: ["stage_kind": stageKind.rawValue]
                    )
                    break
                }
                try sleepBeforeNextPoll(
                    member: member,
                    stage: stage,
                    stageKind: stageKind,
                    pulse: &progressPulse,
                    terminalCharacters: capture.terminalOutput.count,
                    eventCount: capture.eventMessages.count
                )
            }
        }

        clearProgressLine()

        let parseError = lastError?.localizedDescription ?? "structured block did not appear before timeout"
        recordCapture(rawTranscript(
            memberID: member.id,
            roundID: roundID,
            stage: stageKind.rawValue,
            tabID: tabID,
            output: lastOutput,
            parseError: parseError,
            repairAttempted: true,
            repairSucceeded: false
        ))

        return try runStructuredRepair(
            context: StructuredRepairContext(
                runID: runID,
                roundID: roundID,
                stageKind: stageKind,
                stage: stage,
                member: member,
                tabID: tabID,
                repositoryRoot: repositoryRoot,
                expectedMarkers: expectedMarkers,
                parseError: parseError,
                lastOutput: lastOutput,
                lastError: lastError
            ),
            technicalLog: technicalLog,
            recordCapture: recordCapture,
            parser: parser
        )
    }

    /// Inputs the repair sub-flow needs from the wait loop that spawned it.
    private struct StructuredRepairContext {
        let runID: String
        let roundID: String
        let stageKind: MagiProtocolStage
        let stage: String
        let member: MagiMember
        let tabID: String
        let repositoryRoot: String?
        let expectedMarkers: MagiProtocolMarkers
        let parseError: String
        let lastOutput: String
        let lastError: Error?
    }

    /// The structured-output repair sub-flow of `waitForParsed`: sends the
    /// repair prompt, polls until the re-emitted block parses, and records
    /// the terminal outcome. Split out so the poll loop and the repair flow
    /// each stay within readable (and lintable) bounds.
    private func runStructuredRepair<T>(
        context: StructuredRepairContext,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void,
        parser: (String) throws -> T
    ) throws -> T {
        let runID = context.runID
        let roundID = context.roundID
        let stageKind = context.stageKind
        let stage = context.stage
        let member = context.member
        let tabID = context.tabID
        let repositoryRoot = context.repositoryRoot
        let expectedMarkers = context.expectedMarkers
        let parseError = context.parseError
        let lastOutput = context.lastOutput
        let lastError = context.lastError
        clearProgressLine()
        defer { clearProgressLine() }
        printLine(memberLine(member, "requesting structured output repair", state: .repair))
        technicalLog.record(
            "structured_repair_requested",
            stage: stage,
            memberID: member.id,
            tabID: tabID,
            message: parseError,
            fields: ["stage_kind": stageKind.rawValue]
        )
        let repairTranscript = MagiPromptBuilder.repairTranscriptExcerpt(
            lastOutput,
            markers: expectedMarkers,
            maxCharacters: repairTranscriptMaxCharacters
        )
        technicalLog.record(
            "structured_repair_transcript_excerpt",
            stage: stage,
            memberID: member.id,
            tabID: tabID,
            fields: [
                "raw_characters": String(lastOutput.count),
                "excerpt_characters": String(repairTranscript.count)
            ]
        )
        let repairPrompt = MagiPromptBuilder.repairPrompt(
            runID: runID,
            roundID: roundID,
            member: member,
            stage: stageKind,
            parseError: parseError,
            rawTranscript: repairTranscript
        )
        try sendPrompt(
            repairPrompt,
            to: tabID,
            stage: "\(stage) repair",
            memberID: member.id,
            technicalLog: technicalLog
        )

        let repairDeadline = Date().addingTimeInterval(repairTimeoutSeconds)
        var repairOutput = ""
        var repairError: Error?
        var nextRepairProgressPulseAt = Date()
        var repairPulse = 0

        while Date() < repairDeadline {
            try throwIfInterrupted(stage: "\(stage) repair")
            let repairCapture = try pollStructuredOutput(
                tabID: tabID,
                repositoryRoot: repositoryRoot,
                sinceMillis: nil,
                terminalReadMode: .fullStable
            )
            repairOutput = repairCapture.combinedOutput
            let now = Date()
            if terminalStyle.supportsDynamicOutput {
                renderProgressLine(
                    member: member,
                    stage: "\(stage) repair",
                    stageKind: stageKind,
                    pulse: repairPulse,
                    terminalCharacters: repairCapture.terminalOutput.count,
                    eventCount: repairCapture.eventMessages.count,
                    mode: .repair
                )
                repairPulse += 1
            } else if progressPulseSeconds > 0, now >= nextRepairProgressPulseAt {
                renderProgressLine(
                    member: member,
                    stage: "\(stage) repair",
                    stageKind: stageKind,
                    pulse: repairPulse,
                    terminalCharacters: repairCapture.terminalOutput.count,
                    eventCount: repairCapture.eventMessages.count,
                    mode: .repair
                )
                repairPulse += 1
                nextRepairProgressPulseAt = now.addingTimeInterval(progressPulseSeconds)
            }
            do {
                let parsed = try parser(repairOutput)
                technicalLog.record(
                    "structured_repair_succeeded",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    fields: ["stage_kind": stageKind.rawValue]
                )
                recordCapture(rawTranscript(
                    memberID: member.id,
                    roundID: roundID,
                    stage: stageKind.rawValue,
                    tabID: tabID,
                    output: repairOutput,
                    repairAttempted: true,
                    repairSucceeded: true
                ))
                return parsed
            } catch {
                repairError = error
                technicalLog.record(
                    "structured_repair_pending",
                    stage: stage,
                    memberID: member.id,
                    tabID: tabID,
                    message: error.localizedDescription,
                    fields: ["stage_kind": stageKind.rawValue]
                )
                try sleepBeforeNextPoll(
                    member: member,
                    stage: "\(stage) repair",
                    stageKind: stageKind,
                    pulse: &repairPulse,
                    terminalCharacters: repairCapture.terminalOutput.count,
                    eventCount: repairCapture.eventMessages.count,
                    mode: .repair
                )
            }
        }

        recordCapture(rawTranscript(
            memberID: member.id,
            roundID: roundID,
            stage: stageKind.rawValue,
            tabID: tabID,
            output: repairOutput,
            parseError: repairError?.localizedDescription,
            repairAttempted: true,
            repairSucceeded: false
        ))

        if lastError == nil {
            technicalLog.record(
                "structured_parse_timed_out",
                stage: stage,
                level: "error",
                memberID: member.id,
                tabID: tabID,
                message: repairError?.localizedDescription,
                fields: ["stage_kind": stageKind.rawValue]
            )
            throw MagiMCPOrchestratorError.timedOut(
                stage: stage,
                member: member.persona.displayName,
                lastError: repairError?.localizedDescription
            )
        }

        technicalLog.record(
            "structured_parse_failed",
            stage: stage,
            level: "error",
            memberID: member.id,
            tabID: tabID,
            message: repairError?.localizedDescription ?? lastError?.localizedDescription,
            fields: ["stage_kind": stageKind.rawValue]
        )
        throw MagiMCPOrchestratorError.parseFailedAfterRepair(
            stage: stage,
            member: member.persona.displayName,
            lastError: repairError?.localizedDescription ?? lastError?.localizedDescription
        )
    }

    private func shouldRepairImmediately(_ error: Error) -> Bool {
        _ = error
        return false
    }

    private func shouldRepairAfterIdleMissingBlock(
        _ error: Error,
        capture: MagiPolledOutput,
        output: String,
        markers: MagiProtocolMarkers,
        elapsed: TimeInterval
    ) -> Bool {
        guard case .missingBlock = error as? MagiTranscriptParseError else {
            return false
        }
        _ = markers
        guard elapsed >= idleRepairGraceSeconds else { return false }
        return capture.tabStatus.map(MagiMCPEventParsing.tabStatusIsIdleForRepair) ?? false
    }

    private func rawTranscript(
        memberID: MagiMemberID,
        roundID: String,
        stage: String,
        tabID: String,
        output: String,
        parseError: String? = nil,
        repairAttempted: Bool = false,
        repairSucceeded: Bool = false
    ) -> MagiRawTranscript {
        MagiRawTranscript(
            id: "\(roundID)-\(memberID.rawValue)-\(stage)-raw-\(UUID().uuidString.lowercased())",
            memberID: memberID,
            roundID: roundID,
            stage: stage,
            tabID: tabID,
            output: output,
            parseError: parseError,
            repairAttempted: repairAttempted,
            repairSucceeded: repairSucceeded
        )
    }

    private func collectVotes(
        runID: String,
        roundID: String,
        sessions: [MagiMemberTab],
        stageName: String,
        repositoryRoot: String?,
        technicalLog: MagiTechnicalLog,
        recordCapture: (MagiRawTranscript) -> Void
    ) throws -> (votes: [MagiVote], vetoes: [MagiVeto]) {
        var votes: [MagiVote] = []
        var vetoes: [MagiVeto] = []

        _ = try collectPendingParsed(
            runID: runID,
            roundID: roundID,
            stageKind: .vote,
            stage: stageName,
            sessions: sessions,
            repositoryRoot: repositoryRoot,
            startedAt: Date(),
            technicalLog: technicalLog,
            recordCapture: recordCapture,
            parse: { session, output, markers in
                try MagiTranscriptParser.parseVote(
                    memberID: session.member.id,
                    roundID: roundID,
                    output: output,
                    markers: markers
                )
            },
            onParsed: { session, result in
                let verdict = result.vote.verdictKind.map { "[\($0.rawValue)] " } ?? ""
                let voteDetail = "vote sealed \(verdict)(confidence \(String(format: "%.2f", result.vote.confidence)))"
                printLine(memberLine(session.member, voteDetail, state: .done))
                votes.append(result.vote)
                if let veto = result.veto {
                    vetoes.append(veto)
                }
            }
        )

        return (votes, vetoes)
    }

    private func stringField(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return String(bool) }
        if let int = value as? Int { return String(int) }
        return "\(value)"
    }

    private func boolField(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            return ["true", "yes", "1"].contains(string.lowercased())
        }
        if let int = value as? Int { return int != 0 }
        return false
    }

    private func reviewEvidenceRequests(
        _ requests: [MagiEvidenceRequest],
        config: MagiConfig
    ) throws -> [MagiEvidenceRequest] {
        let uniqueRequests = Array(Dictionary(grouping: requests, by: \.id).compactMap { $0.value.first })
            .sorted { $0.id < $1.id }
        guard !uniqueRequests.isEmpty else { return [] }

        announceStage(
            "PHASE 3 // FACT GATHERING",
            evidencePolicyStageDetail(config.evidencePolicy)
        )

        guard config.evidencePolicy != .ask || isInteractive else {
            throw MagiMCPOrchestratorError.evidenceApprovalRequiredNonInteractive
        }

        var reviewed: [MagiEvidenceRequest] = []
        for request in uniqueRequests {
            printLine("")
            printLine(memberLine(request.memberID, "requests a fact check", state: .working))
            printLine("   \(statusLine("Priority", request.priority.rawValue))")
            printLine("   \(statusLine("Reason", compact(request.reason)))")
            if !request.requiredEvidence.isEmpty {
                printLine("   \(statusLine("Wants", compact(request.requiredEvidence.joined(separator: "; "))))")
            }
            let commands = MagiEvidenceCollectorPlanner.commands(for: request)
            let commandReview = reviewCollectorCommands(commands, config: config)
            var reviewedRequest = request
            guard !commands.isEmpty else {
                announceStep("No collector proposed; recorded as a deliberation note.")
                reviewedRequest.status = .skipped
                reviewed.append(reviewedRequest)
                continue
            }

            printLine("   \(terminalStyle.styled("Proposed collectors", .bold, .cyan))")
            for command in commands {
                let payload = command.payload.map { " \($0)" } ?? ""
                let collectorNote = commandReview.skipReasons[command.id]
                    ?? (command.usesWeb ? "web" : "local")
                let collector = terminalStyle.styled(command.collectorKind.rawValue, .yellow)
                printLine("   - \(collector):\(payload) [\(collectorNote)]")
            }

            guard !commandReview.actionable.isEmpty else {
                announceStep("No runnable collector remains; recorded as skipped without approval.")
                reviewedRequest.status = .skipped
                reviewed.append(reviewedRequest)
                continue
            }

            switch config.evidencePolicy {
            case .ask:
                if promptYesNo("Authorize this fact gathering?", defaultValue: false) {
                    reviewedRequest.status = .approved
                    announceStep("Authorized; the fact packet enters the queue.")
                } else {
                    reviewedRequest.status = .denied
                    announceStep("Denied; the council proceeds without this packet.")
                }
            case .autoDeny:
                reviewedRequest.status = .denied
                announceStep("Auto-denied by evidence policy; the council proceeds without this packet.")
            case .preapproved:
                reviewedRequest.status = .approved
                announceStep("Preapproved by evidence policy; the fact packet enters the queue.")
            }
            reviewed.append(reviewedRequest)
        }

        return reviewed
    }

    private struct MagiCollectorCommandReview {
        var actionable: [MagiCollectorCommand]
        var skipReasons: [String: String]
    }

    private func reviewCollectorCommands(
        _ commands: [MagiCollectorCommand],
        config: MagiConfig
    ) -> MagiCollectorCommandReview {
        var actionable: [MagiCollectorCommand] = []
        var skipReasons: [String: String] = [:]
        for command in commands {
            if command.collectorKind == .unsupported {
                skipReasons[command.id] = "skipped: unsupported collector"
            } else if command.usesWeb, !config.webAccessAllowed {
                skipReasons[command.id] = "skipped: web disabled"
            } else {
                actionable.append(command)
            }
        }
        return MagiCollectorCommandReview(actionable: actionable, skipReasons: skipReasons)
    }

    private func evidencePolicyStageDetail(_ policy: MagiEvidenceApprovalPolicy) -> String {
        switch policy {
        case .ask:
            return "The council may request external facts before the final vote. Actionable collectors require approval."
        case .autoDeny:
            return "The council may request external facts, but policy auto-denies actionable collectors."
        case .preapproved:
            return "The council may request external facts. Actionable collectors are preapproved by policy."
        }
    }

    private func collectEvidence(
        for requests: [MagiEvidenceRequest],
        config: MagiConfig,
        technicalLog: MagiTechnicalLog
    ) throws -> [MagiEvidencePacket] {
        guard !requests.isEmpty else { return [] }
        announceStage("PHASE 3B // FACTS IN MOTION", "Approved collectors run, report, and disappear.")

        var packets: [MagiEvidencePacket] = []
        for request in requests {
            try throwIfInterrupted(stage: "evidence collection")
            let commands = reviewCollectorCommands(
                MagiEvidenceCollectorPlanner.commands(for: request),
                config: config
            ).actionable
            for command in commands {
                try throwIfInterrupted(stage: "evidence collection")
                printLine(collectorLine(command, "running", state: .working))
                let packet = try runCollector(command: command, request: request, technicalLog: technicalLog)
                let state: MagiMemberLineState = packet.metadata["collection_status"] == "failed" ? .repair : .done
                printLine(collectorLine(command, compact(packet.summary), state: state))
                packets.append(packet)
            }
        }
        return packets
    }

    private func markEvidenceRequestsFromPackets(_ packets: [MagiEvidencePacket], in run: inout MagiRun) {
        guard !packets.isEmpty else { return }
        let statusesByRequestID = Dictionary(grouping: packets.compactMap { packet -> (String, MagiEvidenceRequestStatus)? in
            guard let requestID = packet.requestID,
                  let rawStatus = packet.metadata["collection_status"],
                  let status = MagiEvidenceRequestStatus(rawValue: rawStatus) else {
                return nil
            }
            return (requestID, status)
        }, by: { $0.0 })

        for index in run.evidenceRequests.indices {
            let requestID = run.evidenceRequests[index].id
            let statuses = statusesByRequestID[requestID]?.map(\.1) ?? []
            if statuses.contains(.failed) {
                run.evidenceRequests[index].status = .failed
            } else if statuses.contains(.fulfilled) {
                run.evidenceRequests[index].status = .fulfilled
            } else if statuses.contains(.skipped) {
                run.evidenceRequests[index].status = .skipped
            }
        }
    }

    private func runCollector(
        command: MagiCollectorCommand,
        request: MagiEvidenceRequest,
        technicalLog: MagiTechnicalLog
    ) throws -> MagiEvidencePacket {
        let create = try client.callTool(name: "tab_create", arguments: [
            "directory": paths.currentDirectory
        ])
        guard let tabID = create["tab_id"] as? String else {
            throw MagiMCPOrchestratorError.missingToolField(tool: "tab_create", field: "tab_id")
        }
        defer {
            closeCollectorTab(tabID: tabID, collectorID: command.id, technicalLog: technicalLog)
        }

        let ready = try client.callTool(name: "tab_wait_ready", arguments: [
            "tab_id": tabID,
            "timeout_ms": 30000
        ])
        guard ready["can_accept_exec"] as? Bool == true else {
            throw MagiMCPOrchestratorError.launchFailed(member: command.id, reason: "collector tab did not become ready")
        }

        let sentinel = "MAGI_COLLECTOR_DONE_\(command.id.replacingOccurrences(of: "-", with: "_"))"
        let script = """
        \(command.command)
        status=$?
        printf '\\n\(sentinel):%s\\n' "$status"
        """
        _ = try client.callTool(name: "tab_exec", arguments: [
            "tab_id": tabID,
            "command": "/bin/sh -lc \(shellQuote(script))"
        ])

        let result = try waitForCollector(tabID: tabID, sentinel: sentinel, collectorID: command.id)
        let collectionStatus: MagiEvidenceRequestStatus = result.exitStatus == 0 ? .fulfilled : .failed
        if collectionStatus == .failed {
            technicalLog.record(
                "collector_failed",
                stage: "evidence collection",
                level: "warning",
                tabID: tabID,
                message: "Collector exited with status \(result.exitStatus)",
                fields: [
                    "collector_id": command.id,
                    "collector_kind": command.collectorKind.rawValue
                ]
            )
        }
        return MagiEvidencePacket(
            id: "\(command.id)-packet",
            requestID: request.id,
            collectorID: command.id,
            summary: collectorSummary(output: result.output, exitStatus: result.exitStatus),
            content: result.output,
            sourceDescription: command.sourceDescription,
            metadata: collectorMetadata(
                command: command,
                tabID: tabID,
                webAccessAllowed: command.usesWeb,
                collectionStatus: collectionStatus.rawValue,
                exitStatus: result.exitStatus
            )
        )
    }

    private func closeCollectorTab(
        tabID: String,
        collectorID: String,
        technicalLog: MagiTechnicalLog
    ) {
        do {
            _ = try client.callTool(name: "tab_close", arguments: [
                "tab_id": tabID,
                "force": true
            ])
            technicalLog.record(
                "collector_tab_closed",
                stage: "evidence collection",
                tabID: tabID,
                fields: ["collector_id": collectorID]
            )
        } catch {
            technicalLog.record(
                "collector_tab_close_failed",
                stage: "evidence collection",
                level: "warning",
                tabID: tabID,
                message: error.localizedDescription,
                fields: ["collector_id": collectorID]
            )
        }
    }

    private func closeMemberTabs(
        _ sessions: [MagiMemberTab],
        config: MagiConfig,
        technicalLog: MagiTechnicalLog,
        outcome: String,
        allowMCPCalls: Bool = true
    ) {
        guard !sessions.isEmpty else { return }
        guard config.autoCloseAgentTabs else {
            technicalLog.record(
                "member_tab_cleanup_skipped",
                stage: "cleanup",
                fields: [
                    "reason": "disabled",
                    "outcome": outcome,
                    "member_tab_count": String(sessions.count)
                ]
            )
            return
        }
        guard allowMCPCalls else {
            technicalLog.record(
                "member_tab_cleanup_skipped",
                stage: "cleanup",
                level: "warning",
                fields: [
                    "reason": "control_plane_unavailable",
                    "outcome": outcome,
                    "member_tab_count": String(sessions.count)
                ]
            )
            return
        }

        for session in sessions {
            closeMemberTab(
                session,
                technicalLog: technicalLog,
                outcome: outcome
            )
        }
    }

    private func closeMemberTab(
        _ session: MagiMemberTab,
        technicalLog: MagiTechnicalLog,
        outcome: String
    ) {
        do {
            _ = try client.callTool(name: "tab_close", arguments: [
                "tab_id": session.tabID,
                "force": true
            ])
            technicalLog.record(
                "member_tab_closed",
                stage: "cleanup",
                memberID: session.member.id,
                tabID: session.tabID,
                fields: [
                    "outcome": outcome,
                    "title": MagiTabTitleFormatter.title(
                        memberID: session.member.id,
                        displayName: session.member.persona.displayName
                    )
                ]
            )
        } catch {
            technicalLog.record(
                "member_tab_close_failed",
                stage: "cleanup",
                level: "warning",
                memberID: session.member.id,
                tabID: session.tabID,
                message: error.localizedDescription,
                fields: ["outcome": outcome]
            )
        }
    }

    private func shouldAttemptMemberTabCleanup(after category: MagiRunFailureCategory) -> Bool {
        switch category {
        case .chau7Unavailable, .mcpSocketMissing:
            return false
        case .providerUnavailable,
             .tabCreationFailed,
             .agentTimeout,
             .malformedJSON,
             .evidenceDenied,
             .veto,
             .deadlock,
             .interrupted,
             .partialArtifacts,
             .artifactWriteFailed,
             .unknown:
            return true
        }
    }

    private func collectorMetadata(
        command: MagiCollectorCommand,
        tabID: String?,
        webAccessAllowed: Bool,
        collectionStatus: String,
        exitStatus: Int? = nil
    ) -> [String: String] {
        var metadata: [String: String] = [
            "collector_kind": command.collectorKind.rawValue,
            "source_description": command.sourceDescription,
            "collection_status": collectionStatus,
            "requires_mcp_command_permission": String(command.requiresMCPCommandPermission),
            "approved_by_user": "true",
            "web_access": String(command.usesWeb),
            "web_access_allowed": String(webAccessAllowed)
        ]
        if let tabID {
            metadata["tab_id"] = tabID
        }
        if let exitStatus {
            metadata["exit_status"] = String(exitStatus)
        }
        if let payload = command.payload {
            switch command.collectorKind {
            case .localRepoSearch, .webQuery:
                metadata["query"] = payload
            case .localFileRead:
                metadata["path"] = payload
            case .localCommand:
                metadata["command"] = payload
            case .localGitStatus, .localGitDiff, .unsupported:
                metadata["payload"] = payload
            }
        }
        return metadata
    }

    private func waitForCollector(tabID: String, sentinel: String, collectorID: String) throws -> MagiCollectorExecutionResult {
        let deadline = Date().addingTimeInterval(collectorTimeoutSeconds)
        var latest = ""
        while Date() < deadline {
            try throwIfInterrupted(stage: "evidence collection")
            latest = try tabOutput(tabID: tabID, lines: fullOutputLines)
            if let result = MagiCollectorOutputParser.parse(output: latest, sentinel: sentinel) {
                return result
            }
            Thread.sleep(forTimeInterval: 2)
        }
        throw MagiMCPOrchestratorError.timedOut(stage: "evidence collection", member: collectorID, lastError: nil)
    }

    private func collectorSummary(output: String, exitStatus: Int) -> String {
        guard exitStatus == 0 else {
            let detail = firstNonEmptyLine(output).map { ": \($0)" } ?? ""
            return "collector failed with exit status \(exitStatus)\(detail)"
        }
        return firstNonEmptyLine(output) ?? "collector completed"
    }

    private func firstNonEmptyLine(_ output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func promptYesNo(_ message: String, defaultValue: Bool) -> Bool {
        let suffix = defaultValue ? "Y/n" : "y/N"
        while true {
            printLine("\(message) [\(suffix)]:")
            let value = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.isEmpty { return defaultValue }
            if value == "y" || value == "yes" { return true }
            if value == "n" || value == "no" { return false }
            printLine("Choose yes or no.")
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

}

private struct MagiMemberTab {
    var member: MagiMember
    var tabID: String
}

private struct MagiLaunchVerification {
    var promptInputVisible: Bool
    var promptSubmitted: Bool
    var agentRunning: Bool
}

enum MagiANSIStyle: String {
    case bold = "1"
    case dim = "2"
    case red = "31"
    case green = "32"
    case yellow = "33"
    case cyan = "36"
    case magenta = "35"
}

struct MagiRunTerminalStyle {
    var isEnabled: Bool
    var supportsDynamicOutput: Bool
    var wrapColumn: Int

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdoutIsTTY: Bool = isatty(STDOUT_FILENO) != 0
    ) {
        let canUseTerminalControl = stdoutIsTTY && environment["TERM"] != "dumb"
        self.isEnabled = canUseTerminalControl && environment["NO_COLOR"] == nil
        self.supportsDynamicOutput = canUseTerminalControl && environment["MAGI_NO_ANIMATION"] == nil
        self.wrapColumn = min(140, max(72, Int(environment["COLUMNS"] ?? "") ?? 110))
    }

    func styled(_ text: String, _ styles: MagiANSIStyle...) -> String {
        guard isEnabled, !styles.isEmpty else { return text }
        let prefix = styles.map(\.rawValue).joined(separator: ";")
        return "\u{001B}[\(prefix)m\(text)\u{001B}[0m"
    }

    var clearLine: String {
        "\u{001B}[2K"
    }
}

private enum MagiMemberLineState {
    case info
    case working
    case ready
    case done
    case repair

    var symbol: String {
        switch self {
        case .info:
            return "-"
        case .working:
            return "~"
        case .ready:
            return "+"
        case .done:
            return "*"
        case .repair:
            return "!"
        }
    }
}

private enum MagiProgressMode {
    case waiting
    case repair
}
