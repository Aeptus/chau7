import Foundation
import Chau7Core

extension TerminalSessionModel {
    /// Optional ingestion seam for Codex App Server JSON-RPC traffic. The
    /// current PTY launch path remains unchanged; an opt-in transport can feed
    /// messages here without creating a second notification architecture.
    @discardableResult
    func ingestCodexAppServerMessage(_ line: String) -> Bool {
        guard let interaction = CodexAppServerInteractionParser.parse(line: line) else {
            return false
        }
        if let threadID = interaction.threadID,
           let activeSessionID = lastAISessionId,
           threadID.caseInsensitiveCompare(activeSessionID) != .orderedSame {
            return false
        }

        let outcome = codexAppServerInteractionTracker.consume(interaction)
        switch interaction.phase {
        case .requested:
            guard let kind = interaction.kind else { return false }
            let eventType: String
            let message: String
            switch kind {
            case .userInput:
                if status != .approvalRequired { status = .waitingForInput }
                eventType = "user_input_requested"
                let prompt = interaction.prompt
                let options = prompt?.optionLabels.isEmpty == false
                    ? "\nOptions: \(prompt?.optionLabels.joined(separator: ", ") ?? "")"
                    : ""
                message = (prompt?.message ?? "Codex is waiting for input.") + options
            case .approval:
                status = .approvalRequired
                eventType = "approval_requested"
                message = "Codex is waiting for approval."
            }
            appModel?.recordEvent(
                source: .codex,
                type: eventType,
                tool: "Codex",
                message: message,
                notify: true,
                directory: currentDirectory,
                tabID: ownerTabID,
                sessionID: interaction.threadID ?? lastAISessionId,
                producer: "codex_app_server",
                reliability: .authoritative
            )

        case .resolved:
            if outcome.pendingKinds.contains(.approval) {
                status = .approvalRequired
            } else if outcome.pendingKinds.contains(.userInput) {
                status = .waitingForInput
            } else if outcome.resolvedKind != nil {
                status = isAIRunning ? .running : .done
                onPermissionResolved?()
            }
        }
        return true
    }

    var codexFeedbackHealthSummary: String {
        if let monitor = codexFeedbackMonitor {
            return monitor.healthSnapshot().summary
        }
        if codexFeedbackMonitorSessionID != nil {
            return codexFeedbackLookupRetryWorkItem == nil
                ? "unresolved"
                : "discovering rollout"
        }
        return "inactive"
    }

    /// Keeps exactly one structured-feedback monitor bound to the active
    /// Codex session. Rollout discovery happens off the main thread because
    /// its final fallback may scan the sessions directory.
    func refreshCodexFeedbackMonitorIfNeeded() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshCodexFeedbackMonitorIfNeeded()
            }
            return
        }

        guard let sessionID = eligibleCodexFeedbackSessionID() else {
            stopCodexFeedbackMonitoring()
            return
        }

        guard codexFeedbackMonitorSessionID != sessionID else { return }
        stopCodexFeedbackMonitoring()
        codexFeedbackMonitorSessionID = sessionID
        codexFeedbackLookupGeneration &+= 1
        locateCodexRollout(
            sessionID: sessionID,
            generation: codexFeedbackLookupGeneration,
            attempt: 0
        )
    }

    func stopCodexFeedbackMonitoring() {
        codexFeedbackLookupGeneration &+= 1
        codexFeedbackLookupRetryWorkItem?.cancel()
        codexFeedbackLookupRetryWorkItem = nil
        codexFeedbackMonitor?.stop()
        codexFeedbackMonitor = nil
        codexFeedbackMonitorSessionID = nil
    }

    private func eligibleCodexFeedbackSessionID() -> String? {
        guard isAIRunning,
              AIResumeParser.normalizeProviderName(lastAIProvider ?? "") == "codex",
              let rawSessionID = lastAISessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: rawSessionID) != nil,
              lastAISessionIdentitySource != .synthetic else {
            return nil
        }
        return rawSessionID
    }

    private func locateCodexRollout(
        sessionID: String,
        generation: UInt64,
        attempt: Int
    ) {
        let startedAt = agentStartedAt ?? Date()
        codexFeedbackLookupQueue.async { [weak self] in
            guard let self else { return }
            let rolloutURL = CodexContentProvider().findRolloutFile(
                sessionID: sessionID,
                startedAt: startedAt
            )
            DispatchQueue.main.async { [weak self] in
                self?.finishCodexRolloutLookup(
                    rolloutURL,
                    sessionID: sessionID,
                    generation: generation,
                    attempt: attempt
                )
            }
        }
    }

    private func finishCodexRolloutLookup(
        _ rolloutURL: URL?,
        sessionID: String,
        generation: UInt64,
        attempt: Int
    ) {
        guard codexFeedbackLookupGeneration == generation,
              codexFeedbackMonitorSessionID == sessionID,
              eligibleCodexFeedbackSessionID() == sessionID else {
            return
        }

        if let rolloutURL {
            let monitor = CodexFeedbackMonitor(
                fileURL: rolloutURL,
                onPrompt: { [weak self] prompt in
                    self?.handleCodexFeedbackPrompt(prompt, sessionID: sessionID)
                },
                onResolution: { [weak self] callID, hasOtherPendingPrompt in
                    self?.handleCodexFeedbackResolution(
                        callID: callID,
                        hasOtherPendingPrompt: hasOtherPendingPrompt,
                        sessionID: sessionID
                    )
                }
            )
            codexFeedbackMonitor = monitor
            monitor.start()
            Log.info(
                "Codex feedback monitor started session=\(sessionID.prefix(8)) rollout=\(rolloutURL.lastPathComponent)"
            )
            return
        }

        if attempt == CodexFeedbackLookupPolicy.fastRetryCount {
            Log.warn(
                "Codex feedback rollout still unavailable session=\(sessionID.prefix(8)); continuing discovery every 60s"
            )
        }

        let delay = CodexFeedbackLookupPolicy.retryDelay(afterAttempt: attempt)
        let retry = DispatchWorkItem { [weak self] in
            guard let self,
                  codexFeedbackLookupGeneration == generation,
                  codexFeedbackMonitorSessionID == sessionID,
                  eligibleCodexFeedbackSessionID() == sessionID else {
                return
            }
            codexFeedbackLookupRetryWorkItem = nil
            locateCodexRollout(
                sessionID: sessionID,
                generation: generation,
                attempt: min(attempt + 1, CodexFeedbackLookupPolicy.fastRetryCount + 1)
            )
        }
        codexFeedbackLookupRetryWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    private func handleCodexFeedbackPrompt(
        _ prompt: CodexFeedbackPrompt,
        sessionID: String
    ) {
        guard codexFeedbackMonitorSessionID == sessionID,
              eligibleCodexFeedbackSessionID() == sessionID else {
            return
        }

        if status != .approvalRequired {
            status = .waitingForInput
        }

        let optionSummary = prompt.optionLabels.isEmpty
            ? ""
            : "\nOptions: \(prompt.optionLabels.joined(separator: ", "))"
        appModel?.recordEvent(
            source: .codex,
            type: "user_input_requested",
            tool: "Codex",
            message: prompt.message + optionSummary,
            notify: true,
            directory: currentDirectory,
            tabID: ownerTabID,
            sessionID: sessionID,
            producer: "codex_rollout_feedback",
            reliability: .authoritative
        )
        Log.info(
            "Codex structured feedback pending session=\(sessionID.prefix(8)) call=\(prompt.callID?.prefix(12) ?? "unknown") options=\(prompt.optionLabels.count)"
        )
    }

    private func handleCodexFeedbackResolution(
        callID: String,
        hasOtherPendingPrompt: Bool,
        sessionID: String
    ) {
        guard codexFeedbackMonitorSessionID == sessionID else { return }
        if !hasOtherPendingPrompt {
            if status == .waitingForInput {
                status = isAIRunning ? .running : .done
            }
            onPermissionResolved?()
        }
        Log.info(
            "Codex structured feedback resolved session=\(sessionID.prefix(8)) call=\(callID.prefix(12)) remaining=\(hasOtherPendingPrompt)"
        )
    }
}
