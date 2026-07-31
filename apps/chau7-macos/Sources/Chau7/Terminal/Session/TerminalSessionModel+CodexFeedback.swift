import Foundation
import Chau7Core

extension TerminalSessionModel {
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

        let maxAttempts = 20
        guard attempt < maxAttempts else {
            Log.warn(
                "Codex feedback monitor could not resolve rollout session=\(sessionID.prefix(8)) attempts=\(maxAttempts + 1)"
            )
            return
        }

        let delay = min(2.0, 0.25 * pow(1.45, Double(attempt)))
        let retry = DispatchWorkItem { [weak self] in
            guard let self,
                  codexFeedbackLookupGeneration == generation,
                  codexFeedbackMonitorSessionID == sessionID else {
                return
            }
            codexFeedbackLookupRetryWorkItem = nil
            locateCodexRollout(
                sessionID: sessionID,
                generation: generation,
                attempt: attempt + 1
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
