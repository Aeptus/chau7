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
    var isInterrupted: () -> Bool = { false }
    var roundTimeoutSeconds: TimeInterval = 900
    var repairTimeoutSeconds: TimeInterval = 120
    var collectorTimeoutSeconds: TimeInterval = 120
    var launchTimeoutMs = 60000
    var launchMemberThrottleSeconds: TimeInterval = 0.6

    // swiftlint:disable:next function_body_length
    func run(question: String, config: MagiConfig) throws -> MagiRun {
        let runID = MagiRunID.make()
        let council = try loadCouncil(config: config)
        let questionKind = MagiQuestionKind.infer(from: question)
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
                "evidence_requires_approval": "true",
                "web_access_allowed": String(config.webAccessAllowed),
                "question_kind": questionKind.rawValue,
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
                "member_count": String(council.members.count)
            ]
        )

        do {
            try writeCheckpoint(&run, stage: "initialized", technicalLog: technicalLog)
            try throwIfInterrupted(stage: "startup")

            printLine("Run")
            printLine(runID)
            printLine("Verdict mode: \(questionKind.rawValue)")
            printLine("")

            let round1 = MagiRunStateMachine.startRound(
                &run,
                id: "round-1",
                index: 1,
                kind: .independentAnalysis
            )
            try writeCheckpoint(&run, stage: "round-1-started", technicalLog: technicalLog)

            printLine("Launching council")
            technicalLog.record("council_launch_started", stage: "launch")
            var sessions: [MagiMemberTab] = []
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
                printLine("- \(member.persona.displayName): \(tabID)")
                sessions.append(MagiMemberTab(member: member, tabID: tabID))
                Thread.sleep(forTimeInterval: launchMemberThrottleSeconds)
            }
            run.metadata["member_tab_count"] = String(sessions.count)
            for session in sessions {
                run.metadata["member_tab_\(session.member.id.rawValue)"] = session.tabID
            }
            run.metadata["member_tabs"] = sessions
                .map { "\($0.member.id.rawValue)=\($0.tabID)" }
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

            printLine("")
            printLine("Round 1")
            var positions: [MagiPosition] = []
            for session in sessions {
                try throwIfInterrupted(stage: "independent analysis")
                let markers = MagiProtocolMarkers(
                    runID: runID,
                    roundID: round1.id,
                    memberID: session.member.id,
                    stage: .position
                )
                let position = try waitForParsed(
                    runID: runID,
                    roundID: round1.id,
                    stageKind: .position,
                    stage: "independent analysis",
                    member: session.member,
                    tabID: session.tabID,
                    repositoryRoot: repositoryRoot,
                    technicalLog: technicalLog,
                    recordCapture: { run.rawTranscripts.append($0) }
                ) { output in
                    try MagiTranscriptParser.parsePosition(
                        memberID: session.member.id,
                        roundID: round1.id,
                        output: output,
                        markers: markers
                    )
                }
                printLine("- \(session.member.persona.displayName): \(position.recommendation)")
                positions.append(position)
                run.positions.append(position)
                try writeCheckpoint(&run, stage: "round-1-\(session.member.id.rawValue)-position", technicalLog: technicalLog)
            }
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

            printLine("")
            printLine("Cross-examination")
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
            var critiqueResults: [(critiques: [MagiCritique], evidenceRequests: [MagiEvidenceRequest])] = []
            for session in sessions {
                try throwIfInterrupted(stage: "cross-examination")
                let markers = MagiProtocolMarkers(
                    runID: runID,
                    roundID: round2.id,
                    memberID: session.member.id,
                    stage: .critique
                )
                let result = try waitForParsed(
                    runID: runID,
                    roundID: round2.id,
                    stageKind: .critique,
                    stage: "cross-examination",
                    member: session.member,
                    tabID: session.tabID,
                    repositoryRoot: repositoryRoot,
                    technicalLog: technicalLog,
                    recordCapture: { run.rawTranscripts.append($0) }
                ) { output in
                    try MagiTranscriptParser.parseCritiques(
                        criticMemberID: session.member.id,
                        roundID: round2.id,
                        output: output,
                        markers: markers
                    )
                }
                printLine("- \(session.member.persona.displayName): \(result.critiques.count) critique(s)")
                critiqueResults.append(result)
                run.critiques.append(contentsOf: result.critiques)
                try writeCheckpoint(&run, stage: "round-2-\(session.member.id.rawValue)-critique", technicalLog: technicalLog)
            }
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
            let evidencePackets = try collectEvidence(for: approvedRequests, config: config)
            run.evidencePackets.append(contentsOf: evidencePackets)
            markEvidenceRequestsFulfilled(
                ids: Set(evidencePackets.filter { $0.metadata["collection_status"] == "fulfilled" }.compactMap(\.requestID)),
                in: &run
            )
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

            printLine("")
            printLine("Final vote")
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

            var policy = MagiResolutionPolicy(
                majorityThreshold: council.majorityThreshold,
                deadlockExtraRoundEnabled: config.deadlockExtraRoundEnabled,
                vetoBlocksVerdict: config.vetoBlocksVerdict
            )
            var verdict = MagiDecisionResolver.resolve(
                votes: voteResults.votes,
                vetoes: voteResults.vetoes,
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
                printLine("")
                printLine("Extra deliberation")
                for session in sessions {
                    try throwIfInterrupted(stage: "extra deliberation")
                    let prompt = MagiPromptBuilder.extraRoundPrompt(
                        runID: runID,
                        roundID: extraRound.id,
                        member: session.member,
                        question: question,
                        votes: voteResults.votes,
                        vetoes: voteResults.vetoes,
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
                policy.deadlockExtraRoundEnabled = false
                verdict = MagiDecisionResolver.resolve(
                    votes: voteResults.votes,
                    vetoes: voteResults.vetoes,
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

            printLine("")
            printLine("Verdict")
            printLine(verdict.kind.rawValue)
            if let decision = verdict.decision {
                printLine("Decision: \(decision)")
            }
            printLine("Confidence: \(String(format: "%.2f", verdict.confidence))")
            printLine("Artifacts: \(bundle.rootDirectory)")
            printLine("Technical log: \(technicalLog.path)")

            return run
        } catch {
            technicalLog.record(
                "run_failed",
                stage: failureStage(for: error),
                level: "error",
                message: error.localizedDescription,
                fields: ["category": failureCategory(for: error).rawValue]
            )
            let category = failureCategory(for: error)
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

        let bundle = try MagiRunArtifactStore.write(run: run, fileManager: fileManager)
        if run.artifactBundle != bundle {
            MagiRunStateMachine.recordArtifactBundle(bundle, in: &run)
            return try MagiRunArtifactStore.write(run: run, fileManager: fileManager)
        }
        return bundle
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
                reasoning: memberConfig.reasoning
            )
        }
        return MagiCouncil(id: config.defaultCouncilID, name: "MAGI", members: members)
    }

    private func launchMember(
        _ member: MagiMember,
        prompt: String,
        technicalLog: MagiTechnicalLog
    ) throws -> String {
        let command = providerCommand(for: member)
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
        guard (agent["prompt"] as? String) == "sent" else {
            throw MagiMCPOrchestratorError.launchFailed(
                member: member.persona.displayName,
                reason: "provider launched in \(tabID), but Chau7 did not detect an attached agent for prompt injection"
            )
        }
        guard promptInputVisible else {
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

    private func providerCommand(for member: MagiMember) -> String {
        member.provider.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func tabOutput(tabID: String, source: String = "pty_log") throws -> String {
        let result = try client.callTool(name: "tab_output", arguments: [
            "tab_id": tabID,
            "lines": 10000,
            "wait_for_stable_ms": 1000,
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

    private func pollStructuredOutput(tabID: String, repositoryRoot: String?) throws -> MagiPolledOutput {
        let terminalOutput = try tabOutput(tabID: tabID)
        let eventCapture = try tabEventMessages(tabID: tabID, repositoryRoot: repositoryRoot)
        return MagiPolledOutput(
            terminalOutput: terminalOutput,
            eventMessages: eventCapture.messages,
            eventError: eventCapture.error
        )
    }

    private func tabEventMessages(
        tabID: String,
        repositoryRoot: String?
    ) throws -> (messages: [String], error: String?) {
        guard let repositoryRoot,
              !repositoryRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ([], nil)
        }

        let eventTypes = [
            "agent-turn-complete",
            "finished",
            "response_complete",
            "task_finished"
        ]
        do {
            let result = try client.callTool(name: "repo_get_events", arguments: [
                "repo_path": repositoryRoot,
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
        var lastError: Error?
        var lastOutput = ""
        var lastLoggedOutputCount: Int?
        var lastLoggedEventSignature: String?
        var lastLoggedEventError: String?

        while Date() < deadline {
            try throwIfInterrupted(stage: stage)
            let capture = try pollStructuredOutput(tabID: tabID, repositoryRoot: repositoryRoot)
            let output = capture.combinedOutput
            lastOutput = output
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
                Thread.sleep(forTimeInterval: 3)
            }
        }

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

        printLine("- \(member.persona.displayName): requesting structured output repair")
        technicalLog.record(
            "structured_repair_requested",
            stage: stage,
            memberID: member.id,
            tabID: tabID,
            message: parseError,
            fields: ["stage_kind": stageKind.rawValue]
        )
        let repairPrompt = MagiPromptBuilder.repairPrompt(
            runID: runID,
            roundID: roundID,
            member: member,
            stage: stageKind,
            parseError: parseError,
            rawTranscript: lastOutput
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

        while Date() < repairDeadline {
            try throwIfInterrupted(stage: "\(stage) repair")
            repairOutput = try pollStructuredOutput(tabID: tabID, repositoryRoot: repositoryRoot).combinedOutput
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
                Thread.sleep(forTimeInterval: 3)
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
        guard let parseError = error as? MagiTranscriptParseError else { return true }
        switch parseError {
        case .missingBlock:
            return false
        case .invalidJSON, .invalidContract:
            return true
        }
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

        for session in sessions {
            try throwIfInterrupted(stage: stageName)
            let markers = MagiProtocolMarkers(
                runID: runID,
                roundID: roundID,
                memberID: session.member.id,
                stage: .vote
            )
            let result = try waitForParsed(
                runID: runID,
                roundID: roundID,
                stageKind: .vote,
                stage: stageName,
                member: session.member,
                tabID: session.tabID,
                repositoryRoot: repositoryRoot,
                technicalLog: technicalLog,
                recordCapture: recordCapture
            ) { output in
                try MagiTranscriptParser.parseVote(
                    memberID: session.member.id,
                    roundID: roundID,
                    output: output,
                    markers: markers
                )
            }
            let verdict = result.vote.verdictKind.map { "[\($0.rawValue)] " } ?? ""
            printLine("- \(session.member.persona.displayName): \(verdict)\(result.vote.choice)")
            votes.append(result.vote)
            if let veto = result.veto {
                vetoes.append(veto)
            }
        }

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

        printLine("")
        printLine("Evidence requests")

        guard isInteractive else {
            throw MagiMCPOrchestratorError.evidenceApprovalRequiredNonInteractive
        }

        if !config.evidenceRequiresApproval {
            printLine("Config evidence_requires_approval=false is ignored in MAGI V1; evidence still requires approval.")
        }

        var reviewed: [MagiEvidenceRequest] = []
        for request in uniqueRequests {
            printLine("")
            printLine("\(request.id)")
            printLine("Member: \(request.memberID.displayName)")
            printLine("Priority: \(request.priority.rawValue)")
            printLine("Reason: \(request.reason)")
            if !request.requiredEvidence.isEmpty {
                printLine("Required: \(request.requiredEvidence.joined(separator: "; "))")
            }
            let commands = MagiEvidenceCollectorPlanner.commands(for: request)
            if !commands.isEmpty {
                printLine("Collectors:")
                for command in commands {
                    let payload = command.payload.map { " \($0)" } ?? ""
                    let webNote = command.usesWeb
                        ? (config.webAccessAllowed ? " web" : " web disabled")
                        : " local"
                    printLine("- \(command.collectorKind.rawValue):\(payload) [\(webNote)]")
                }
            }
            var reviewedRequest = request
            if promptYesNo("Approve this evidence collection?", defaultValue: false) {
                reviewedRequest.status = .approved
            } else {
                reviewedRequest.status = .denied
            }
            reviewed.append(reviewedRequest)
        }

        return reviewed
    }

    private func collectEvidence(for requests: [MagiEvidenceRequest], config: MagiConfig) throws -> [MagiEvidencePacket] {
        guard !requests.isEmpty else { return [] }
        printLine("")
        printLine("Collecting evidence")

        var packets: [MagiEvidencePacket] = []
        for request in requests {
            try throwIfInterrupted(stage: "evidence collection")
            let commands = MagiEvidenceCollectorPlanner.commands(for: request)
            for command in commands {
                try throwIfInterrupted(stage: "evidence collection")
                if command.usesWeb, !config.webAccessAllowed {
                    let packet = skippedWebPacket(command: command, request: request)
                    printLine("- \(command.id): \(packet.summary)")
                    packets.append(packet)
                    continue
                }
                let packet = try runCollector(command: command, request: request)
                printLine("- \(command.id): \(packet.summary)")
                packets.append(packet)
            }
        }
        return packets
    }

    private func markEvidenceRequestsFulfilled(ids: Set<String>, in run: inout MagiRun) {
        guard !ids.isEmpty else { return }
        for index in run.evidenceRequests.indices where ids.contains(run.evidenceRequests[index].id) {
            run.evidenceRequests[index].status = .fulfilled
        }
    }

    private func skippedWebPacket(command: MagiCollectorCommand, request: MagiEvidenceRequest) -> MagiEvidencePacket {
        MagiEvidencePacket(
            id: "\(command.id)-packet",
            requestID: request.id,
            collectorID: command.id,
            summary: "web access disabled",
            content: "web.query was requested and approved, but web_access_allowed=false for this MAGI run.",
            sourceDescription: command.sourceDescription,
            metadata: collectorMetadata(
                command: command,
                tabID: nil,
                webAccessAllowed: false,
                collectionStatus: "skipped"
            )
        )
    }

    private func runCollector(command: MagiCollectorCommand, request: MagiEvidenceRequest) throws -> MagiEvidencePacket {
        let create = try client.callTool(name: "tab_create", arguments: [
            "directory": paths.currentDirectory
        ])
        guard let tabID = create["tab_id"] as? String else {
            throw MagiMCPOrchestratorError.missingToolField(tool: "tab_create", field: "tab_id")
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

        let output = try waitForCollector(tabID: tabID, sentinel: sentinel, collectorID: command.id)
        return MagiEvidencePacket(
            id: "\(command.id)-packet",
            requestID: request.id,
            collectorID: command.id,
            summary: firstNonEmptyLine(output) ?? "collector completed",
            content: output,
            sourceDescription: command.sourceDescription,
            metadata: collectorMetadata(
                command: command,
                tabID: tabID,
                webAccessAllowed: command.usesWeb,
                collectionStatus: "fulfilled"
            )
        )
    }

    private func collectorMetadata(
        command: MagiCollectorCommand,
        tabID: String?,
        webAccessAllowed: Bool,
        collectionStatus: String
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

    private func waitForCollector(tabID: String, sentinel: String, collectorID: String) throws -> String {
        let deadline = Date().addingTimeInterval(collectorTimeoutSeconds)
        var latest = ""
        while Date() < deadline {
            try throwIfInterrupted(stage: "evidence collection")
            latest = try tabOutput(tabID: tabID)
            if latest.contains(sentinel) {
                return strippedCollectorOutput(latest, sentinel: sentinel)
            }
            Thread.sleep(forTimeInterval: 2)
        }
        throw MagiMCPOrchestratorError.timedOut(stage: "evidence collection", member: collectorID, lastError: nil)
    }

    private func strippedCollectorOutput(_ output: String, sentinel: String) -> String {
        output
            .components(separatedBy: .newlines)
            .filter { !$0.contains(sentinel) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
