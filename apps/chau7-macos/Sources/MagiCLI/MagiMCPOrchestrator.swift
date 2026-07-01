import Chau7Core
import Foundation

enum MagiMCPOrchestratorError: Error, LocalizedError {
    case launchFailed(member: String, reason: String)
    case missingToolField(tool: String, field: String)
    case timedOut(stage: String, member: String, lastError: String?)
    case parseFailedAfterRepair(stage: String, member: String, lastError: String?)
    case evidenceApprovalRequiredNonInteractive

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
    var roundTimeoutSeconds: TimeInterval = 900
    var repairTimeoutSeconds: TimeInterval = 120
    var collectorTimeoutSeconds: TimeInterval = 120
    var launchTimeoutMs: Int = 60_000

    func run(question: String, config: MagiConfig) throws -> MagiRun {
        let runID = Self.newRunID()
        let council = try loadCouncil(config: config)
        let questionKind = MagiQuestionKind.infer(from: question)
        let repositoryRoot = paths.repositoryRoot(fileManager: fileManager)
        let artifactRoot = paths.runRoot(runID: runID, repositoryRoot: repositoryRoot)
        var run = MagiRun(
            id: runID,
            question: question,
            council: council,
            status: .running,
            artifactBundle: MagiArtifactBundle(runID: runID, rootDirectory: artifactRoot),
            metadata: [
                "mcp_socket": mcpSocketPath,
                "evidence_requires_approval": "true",
                "web_access_allowed": String(config.webAccessAllowed),
                "question_kind": questionKind.rawValue,
                "verdict_defaults": "majority,equal_weights,one_extra_round_on_deadlock,veto_blocks",
                "artifact_root": artifactRoot,
                "artifact_scope": repositoryRoot == nil ? "global" : "repository",
                "repository_root": repositoryRoot ?? ""
            ]
        )

        do {
        printLine("Run")
        printLine(runID)
        printLine("Verdict mode: \(questionKind.rawValue)")
        printLine("")

        let round1 = MagiRound(id: "round-1", index: 1, kind: .independentAnalysis)
        run.rounds.append(round1)

        printLine("Launching council")
        let sessions = try council.members.map { member in
            let prompt = MagiPromptBuilder.independentAnalysisPrompt(
                runID: runID,
                roundID: round1.id,
                question: question,
                member: member
            )
            let tabID = try launchMember(member, prompt: prompt)
            printLine("- \(member.persona.displayName): \(tabID)")
            return MagiMemberTab(member: member, tabID: tabID)
        }

        printLine("")
        printLine("Round 1")
        var positions: [MagiPosition] = []
        for session in sessions {
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
        }
        run.positions.append(contentsOf: positions)

        let councilPacket = MagiPromptBuilder.councilPacket(
            runID: runID,
            question: question,
            positions: positions
        )

        let round2 = MagiRound(id: "round-2", index: 2, kind: .crossExamination)
        run.rounds.append(round2)

        printLine("")
        printLine("Cross-examination")
        for session in sessions {
            let prompt = MagiPromptBuilder.critiquePrompt(
                runID: runID,
                roundID: round2.id,
                member: session.member,
                councilPacket: councilPacket
            )
            try sendPrompt(prompt, to: session.tabID)
        }

        var evidenceRequests = positions.flatMap(\.evidenceRequests)
        var critiqueResults: [(critiques: [MagiCritique], evidenceRequests: [MagiEvidenceRequest])] = []
        for session in sessions {
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
        }
        let critiques = critiqueResults.flatMap(\.critiques)
        evidenceRequests.append(contentsOf: critiqueResults.flatMap(\.evidenceRequests))
        run.critiques.append(contentsOf: critiques)

        let reviewedRequests = try reviewEvidenceRequests(evidenceRequests, config: config)
        run.evidenceRequests.append(contentsOf: reviewedRequests)
        let approvedRequests = reviewedRequests.filter { $0.status == .approved }
        if !approvedRequests.isEmpty {
            run.status = .waitingForEvidenceApproval
        }

        let round3 = MagiRound(id: "round-3", index: 3, kind: .evidenceCollection)
        run.rounds.append(round3)
        let evidencePackets = try collectEvidence(for: approvedRequests, config: config)
        run.evidencePackets.append(contentsOf: evidencePackets)
        markEvidenceRequestsFulfilled(
            ids: Set(evidencePackets.filter { $0.metadata["collection_status"] == "fulfilled" }.compactMap(\.requestID)),
            in: &run
        )
        run.status = .running

        let round4 = MagiRound(id: "round-4", index: 4, kind: .vote)
        run.rounds.append(round4)

        printLine("")
        printLine("Final vote")
        for session in sessions {
            let prompt = MagiPromptBuilder.finalVotePrompt(
                runID: runID,
                roundID: round4.id,
                member: session.member,
                councilPacket: councilPacket,
                critiques: critiques,
                evidencePackets: evidencePackets,
                questionKind: questionKind
            )
            try sendPrompt(prompt, to: session.tabID)
        }

        var voteResults = try collectVotes(
            runID: runID,
            roundID: round4.id,
            sessions: sessions,
            stageName: "final vote",
            recordCapture: { run.rawTranscripts.append($0) }
        )

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
            let extraRound = MagiRound(id: "round-5", index: 5, kind: .extraDeliberation)
            run.rounds.append(extraRound)
            printLine("")
            printLine("Extra deliberation")
            for session in sessions {
                let prompt = MagiPromptBuilder.extraRoundPrompt(
                    runID: runID,
                    roundID: extraRound.id,
                    member: session.member,
                    question: question,
                    votes: voteResults.votes,
                    vetoes: voteResults.vetoes,
                    questionKind: questionKind
                )
                try sendPrompt(prompt, to: session.tabID)
            }

            voteResults = try collectVotes(
                runID: runID,
                roundID: extraRound.id,
                sessions: sessions,
                stageName: "extra deliberation",
                recordCapture: { run.rawTranscripts.append($0) }
            )
            policy.deadlockExtraRoundEnabled = false
            verdict = MagiDecisionResolver.resolve(
                votes: voteResults.votes,
                vetoes: voteResults.vetoes,
                policy: policy,
                questionKind: questionKind
            )
        }

        run.finalVerdict = verdict
        run.status = .completed
        run.completedAt = Date()

        let bundle = try MagiRunArtifactWriter.write(run: run, fileManager: fileManager)
        run.artifactBundle = bundle

        printLine("")
        printLine("Verdict")
        printLine(verdict.kind.rawValue)
        if let decision = verdict.decision {
            printLine("Decision: \(decision)")
        }
        printLine("Confidence: \(String(format: "%.2f", verdict.confidence))")
        printLine("Artifacts: \(bundle.rootDirectory)")

        return run
        } catch {
            run.status = .failed
            run.completedAt = Date()
            run.metadata["error"] = error.localizedDescription
            if let bundle = try? MagiRunArtifactWriter.write(run: run, fileManager: fileManager) {
                printLine("")
                printLine("Failed")
                printLine(error.localizedDescription)
                printLine("Artifacts: \(bundle.rootDirectory)")
            }
            throw error
        }
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

    private func launchMember(_ member: MagiMember, prompt: String) throws -> String {
        let result = try client.callTool(name: "agent_launch", arguments: [
            "directory": paths.currentDirectory,
            "agent_command": providerCommand(for: member),
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
        return tabID
    }

    private func providerCommand(for member: MagiMember) -> String {
        member.provider.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendPrompt(_ prompt: String, to tabID: String) throws {
        _ = try client.callTool(name: "tab_send_input", arguments: [
            "tab_id": tabID,
            "input": prompt
        ])
        Thread.sleep(forTimeInterval: 0.3)
        _ = try client.callTool(name: "tab_submit_prompt", arguments: [
            "tab_id": tabID
        ])
    }

    private func tabOutput(tabID: String) throws -> String {
        let result = try client.callTool(name: "tab_output", arguments: [
            "tab_id": tabID,
            "lines": 10_000,
            "wait_for_stable_ms": 1_000,
            "source": "pty_log"
        ])
        guard let output = result["output"] as? String else {
            throw MagiMCPOrchestratorError.missingToolField(tool: "tab_output", field: "output")
        }
        return output
    }

    private func waitForParsed<T>(
        runID: String,
        roundID: String,
        stageKind: MagiProtocolStage,
        stage: String,
        member: MagiMember,
        tabID: String,
        recordCapture: (MagiRawTranscript) -> Void,
        parser: (String) throws -> T
    ) throws -> T {
        let deadline = Date().addingTimeInterval(roundTimeoutSeconds)
        var lastError: Error?
        var lastOutput = ""

        while Date() < deadline {
            let output = try tabOutput(tabID: tabID)
            lastOutput = output
            do {
                let parsed = try parser(output)
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
        let repairPrompt = MagiPromptBuilder.repairPrompt(
            runID: runID,
            roundID: roundID,
            member: member,
            stage: stageKind,
            parseError: parseError,
            rawTranscript: lastOutput
        )
        try sendPrompt(repairPrompt, to: tabID)

        let repairDeadline = Date().addingTimeInterval(repairTimeoutSeconds)
        var repairOutput = ""
        var repairError: Error?

        while Date() < repairDeadline {
            repairOutput = try tabOutput(tabID: tabID)
            do {
                let parsed = try parser(repairOutput)
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
            throw MagiMCPOrchestratorError.timedOut(
                stage: stage,
                member: member.persona.displayName,
                lastError: repairError?.localizedDescription
            )
        }

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
        recordCapture: (MagiRawTranscript) -> Void
    ) throws -> (votes: [MagiVote], vetoes: [MagiVeto]) {
        var votes: [MagiVote] = []
        var vetoes: [MagiVeto] = []

        for session in sessions {
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
            let commands = MagiEvidenceCollectorPlanner.commands(for: request)
            for command in commands {
                if command.usesWeb && !config.webAccessAllowed {
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
            "timeout_ms": 30_000
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

    private static func newRunID() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "Z", with: "z")
        return "magi-\(timestamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

private struct MagiMemberTab {
    var member: MagiMember
    var tabID: String
}

enum MagiRunArtifactWriter {
    static func write(run: MagiRun, fileManager: FileManager) throws -> MagiArtifactBundle {
        let bundle = run.artifactBundle ?? MagiArtifactBundle(
            runID: run.id,
            rootDirectory: MagiArtifactBundle.rootDirectory(
                runID: run.id,
                repositoryRoot: nil,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
        )
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: bundle.rootDirectory),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: URL(fileURLWithPath: bundle.decisionJSONPath))

        try MagiRunArtifactRenderer.decisionMarkdown(for: run).write(
            to: URL(fileURLWithPath: bundle.decisionMarkdownPath),
            atomically: true,
            encoding: .utf8
        )
        try MagiRunArtifactRenderer.transcriptJSONL(for: run).write(
            to: URL(fileURLWithPath: bundle.transcriptJSONLPath),
            atomically: true,
            encoding: .utf8
        )
        try MagiRunArtifactRenderer.graphJSON(for: run).write(
            to: URL(fileURLWithPath: bundle.graphJSONPath),
            atomically: true,
            encoding: .utf8
        )
        try MagiRunArtifactRenderer.replayJSONL(for: run).write(
            to: URL(fileURLWithPath: bundle.replayJSONLPath),
            atomically: true,
            encoding: .utf8
        )
        try MagiRunArtifactRenderer.shareHTML(for: run).write(
            to: URL(fileURLWithPath: bundle.shareHTMLPath),
            atomically: true,
            encoding: .utf8
        )

        return bundle
    }
}
