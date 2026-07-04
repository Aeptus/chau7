import Chau7Core
import Foundation

extension MagiMCPOrchestrator {
    func loadCouncil(config: MagiConfig) throws -> MagiCouncil {
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

    func launchMember(
        _ member: MagiMember,
        prompt: String,
        technicalLog: MagiTechnicalLog
    ) throws -> String {
        let providerCommand = MagiProviderCommandBuilder.command(for: member)
        let command = providerCommand.commandLine
        let result = try client.agentLaunch(MagiMCPAgentLaunchRequest(
            directory: paths.currentDirectory,
            agentCommand: command,
            prompt: prompt,
            count: 1,
            readyTimeoutMs: launchTimeoutMs
        ))

        guard let agent = result.agents.first else {
            throw MagiMCPOrchestratorError.missingToolField(tool: "agent_launch", field: "agents[0]")
        }
        guard let tabID = agent.tabID else {
            throw MagiMCPOrchestratorError.missingToolField(tool: "agent_launch", field: "agents[0].tab_id")
        }
        let tabTitle = renameMemberTab(
            tabID: tabID,
            member: member,
            technicalLog: technicalLog
        )
        let launchStatus = agent.status.isEmpty ? "missing" : agent.status
        let promptStatus = agent.promptStatus.isEmpty ? "missing" : agent.promptStatus
        var promptInputVisible = agent.promptInputVisible ?? false
        var promptSubmitted = agent.promptSubmitted ?? false
        var agentRunning = agent.agentRunning ?? false
        if !agent.promptVerificationFieldsPresent, promptStatus == "sent" {
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
        guard agent.status == "launched" else {
            throw MagiMCPOrchestratorError.launchFailed(
                member: member.persona.displayName,
                reason: agent.error ?? "agent_launch returned status \(launchStatus)"
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
    func renameMemberTab(
        tabID: String,
        member: MagiMember,
        technicalLog: MagiTechnicalLog
    ) -> String {
        let title = MagiTabTitleFormatter.title(
            memberID: member.id,
            displayName: member.persona.displayName
        )
        do {
            try client.renameTab(MagiMCPTabRenameRequest(tabID: tabID, title: title))
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

    func verifyLaunchedMemberPrompt(
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

    func waitForPromptNeedle(
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

    func waitForAgentRunning(
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

    func tabStatusReportsRunningAgent(tabID: String) throws -> Bool {
        let status = try client.tabStatus(MagiMCPTabStatusRequest(tabID: tabID))
        if status.hasActiveRun {
            return true
        }

        let hasAgentIdentity =
            status.activeApp.isEmpty == false
                || status.aiProvider.isEmpty == false
        guard hasAgentIdentity else { return false }

        let runningStates = ["running", "waitingForInput", "approvalRequired", "stuck"]
        return runningStates.contains(status.status)
            || runningStates.contains(status.rawStatus)
    }

    func agentOutputLooksResponsive(_ output: String, provider: String) -> Bool {
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

    func promptVisibilityNeedles(from prompt: String) -> [String] {
        prompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
            .prefix(3)
            .map { String($0.prefix(min(80, $0.count))) }
    }

    func sendPrompt(
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
        let sendResult = try client.sendInput(MagiMCPTabInputRequest(tabID: tabID, input: prompt))
        technicalLog.record(
            "prompt_input_sent",
            stage: stage,
            memberID: memberID,
            tabID: tabID,
            fields: ["ok": sendResult.ok]
        )
        Thread.sleep(forTimeInterval: 0.3)
        let submitResult = try client.submitPrompt(MagiMCPTabSubmitPromptRequest(tabID: tabID))
        technicalLog.record(
            "prompt_submitted",
            stage: stage,
            memberID: memberID,
            tabID: tabID,
            fields: [
                "ok": submitResult.ok,
                "enter_count": submitResult.enterCount
            ]
        )
    }

    func collectVotes(
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

    func closeMemberTabs(
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

    func closeMemberTab(
        _ session: MagiMemberTab,
        technicalLog: MagiTechnicalLog,
        outcome: String
    ) {
        do {
            try client.closeTab(MagiMCPTabCloseRequest(tabID: session.tabID, force: true))
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

    func shouldAttemptMemberTabCleanup(after category: MagiRunFailureCategory) -> Bool {
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
}


struct MagiMemberTab {
    var member: MagiMember
    var tabID: String
}

struct MagiLaunchVerification {
    var promptInputVisible: Bool
    var promptSubmitted: Bool
    var agentRunning: Bool
}
