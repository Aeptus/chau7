import Chau7Core
import Foundation

/// Resume-prefill delivery state machine for `OverlayTabsModel`. The
/// "resume prefill" is the `claude --resume <id>` / `codex resume <id>`
/// command that gets typed into a restored terminal session so the
/// previous AI conversation continues. Five concerns:
///
///   1. **Scheduling** — `scheduleResumeCommand` arms the prefill on a
///      delayed retry scheduler (used by the legacy retry path); the
///      modern path uses `enqueueResumePrefill` to bind the prefill to
///      the session's pending-prefill queue and avoid post-reveal retry
///      storms.
///
///   2. **Validation** — `evaluateResumeRestoreIntent` (pure, T1) +
///      `validateResumeRestoreIntent` (instance wrapper that emits the
///      rejection log) check whether a queued prefill still matches the
///      live pane's directory + provider + sessionID. Mismatches reject
///      the prefill so a repaired-pane doesn't get an old session's
///      command.
///
///   3. **Delivery state machine** — `decideResumeRestoreDeliveryUpdate`
///      (pure, T4) + `recordResumeRestoreDeliveryState` (instance
///      wrapper) govern per-pane outcome transitions: terminal outcomes
///      (delivered/rejected) are sticky against `superseded`, newer
///      tokens win, etc.
///
///   4. **Command parsing** — `normalizedResumeCommand` /
///      `isSafeResumeCommand` validate command strings before delivery.
///      Shell-injection-resistant: a sessionID containing `;` /
///      whitespace / `/` is rejected by `AIResumeParser.isValidSessionId`.
///
///   5. **Intent payload** — `ResumeRestoreIntent` struct carries the
///      command + expected metadata + paneID through the delivery path.
///
/// Pure rules are unit-tested in
/// `ResumeRestoreIntentMatchTests.swift` (T1) and
/// `ResumeRestoreDeliveryDecisionTests.swift` (T4).
extension OverlayTabsModel {

    func scheduleResumeCommand(
        intent: ResumeRestoreIntent,
        targetTabID: UUID,
        restoreToken: String,
        remainingAttempts: Int,
        delay: TimeInterval = 0
    ) {
        let paneID = intent.paneID
        guard remainingAttempts > 0 else {
            // Last resort: queue the command so the session's own retry logic
            // can deliver it when the terminal becomes ready (e.g. tab unsuspends).
            if let tab = tabs.first(where: { $0.id == targetTabID }),
               let session = tab.splitController.root.findSession(id: paneID) {
                guard validateResumeRestoreIntent(intent, against: session, tabID: targetTabID) else {
                    recordResumeRestoreDeliveryState(
                        paneID: paneID,
                        token: restoreToken,
                        outcome: .rejected,
                        tabID: targetTabID,
                        reason: "ownership_validation_failed_after_retries"
                    )
                    latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                    return
                }
                let deliveredImmediately = enqueueResumePrefill(
                    intent: intent,
                    into: session,
                    targetTabID: targetTabID,
                    restoreToken: restoreToken,
                    queuedReason: "retries_exhausted",
                    deliveredReason: "prefilled_after_retries_exhausted"
                )
                if deliveredImmediately {
                    Log.info("restoreTabState: retries exhausted but delivered prefill immediately for tab=\(targetTabID) pane=\(paneID)")
                } else {
                    Log.warn("restoreTabState: retries exhausted, queued prefill for tab=\(targetTabID) pane=\(paneID)")
                }
            } else {
                Log.warn("restoreTabState: retries exhausted, tab/pane gone for tab=\(targetTabID) pane=\(paneID)")
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard latestRestoreResumeTokenByPaneID[paneID] == restoreToken else {
                recordResumeRestoreDeliveryState(
                    paneID: paneID,
                    token: restoreToken,
                    outcome: .superseded,
                    tabID: targetTabID,
                    reason: "stale_retry"
                )
                Log.trace("restoreTabState: skipping stale resume prefill for tab=\(targetTabID) pane=\(paneID)")
                return
            }

            guard let restoredTab = tabs.first(where: { $0.id == targetTabID }) else {
                Log.warn("restoreTabState: cannot send resume command for missing tab=\(targetTabID)")
                latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                return
            }

            guard let reResolvedSession = restoredTab.splitController.root.findSession(id: paneID) else {
                Log.warn("restoreTabState: cannot find pane=\(paneID) for tab=\(targetTabID)")
                latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                return
            }

            if !reResolvedSession.canPrefillInput() {
                let hasView = reResolvedSession.existingRustTerminalView != nil

                // No view means this tab is outside the nearby rendering range.
                if !hasView {
                    switch StartupRestoreCoordinator.shared.noViewResumeDecision(remainingAttempts: remainingAttempts) {
                    case .retryWaitingForView:
                        let nextDelay = min(delay + 0.15, 0.75)
                        Log.trace(
                            "restoreTabState: waiting for view before resume prefill for tab=\(targetTabID) pane=\(paneID) retry in \(String(format: "%.2f", nextDelay))s"
                        )
                        scheduleResumeCommand(
                            intent: intent,
                            targetTabID: targetTabID,
                            restoreToken: restoreToken,
                            remainingAttempts: remainingAttempts - 1,
                            delay: nextDelay
                        )
                        return
                    case .queueSessionPrefill:
                        // Delegate to the session's pending prefill mechanism which will
                        // deliver the command when the view is eventually created via
                        // attachRustTerminal → flushPendingPrefillInputIfReady.
                        guard validateResumeRestoreIntent(intent, against: reResolvedSession, tabID: targetTabID) else {
                            recordResumeRestoreDeliveryState(
                                paneID: paneID,
                                token: restoreToken,
                                outcome: .rejected,
                                tabID: targetTabID,
                                reason: "ownership_validation_failed_before_queue"
                            )
                            latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                            return
                        }
                        enqueueResumePrefill(
                            intent: intent,
                            into: reResolvedSession,
                            targetTabID: targetTabID,
                            restoreToken: restoreToken,
                            queuedReason: "waiting_for_view",
                            deliveredReason: "prefilled_after_waiting_for_view"
                        )
                        Log.info("restoreTabState: no view for tab=\(targetTabID) pane=\(paneID), queued session-level prefill")
                        return
                    }
                }

                let nextDelay = min(delay + Self.resumeCommandRetryDelaySeconds, Self.resumeCommandMaxRetryDelay)
                let message =
                    """
                    restoreTabState: resume command not ready for tab=\(targetTabID) pane=\(paneID) \
                    (loading=\(reResolvedSession.isShellLoading), atPrompt=\(reResolvedSession.isAtPrompt), \
                    status=\(reResolvedSession.status), hasView=\(hasView)); \
                    retry in \(String(format: "%.2f", nextDelay))s
                    """
                if StartupRestoreCoordinator.shared.shouldWarnAboutResumeNotReady() {
                    Log.warn(message)
                } else {
                    Log.trace(message)
                }
                scheduleResumeCommand(
                    intent: intent,
                    targetTabID: targetTabID,
                    restoreToken: restoreToken,
                    remainingAttempts: remainingAttempts - 1,
                    delay: nextDelay
                )
                return
            }

            guard validateResumeRestoreIntent(intent, against: reResolvedSession, tabID: targetTabID) else {
                recordResumeRestoreDeliveryState(
                    paneID: paneID,
                    token: restoreToken,
                    outcome: .rejected,
                    tabID: targetTabID,
                    reason: "ownership_validation_failed_before_delivery"
                )
                latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                return
            }

            // Prefill the pane-owned resume command so the user can confirm with Enter.
            enqueueResumePrefill(
                intent: intent,
                into: reResolvedSession,
                targetTabID: targetTabID,
                restoreToken: restoreToken,
                queuedReason: "deferred_after_ready_check",
                deliveredReason: "prefilled"
            )
        }
    }

    /// Pure normalize+compare for resume-restore intent matching.
    ///
    /// Extracted from `validateResumeRestoreIntent` so the validation logic
    /// can be unit-tested via `swift test` without constructing a live
    /// `TerminalSessionModel`. The instance method is now a thin wrapper
    /// that pulls fields off the session, calls this helper, and emits the
    /// rejection log on mismatch.
    ///
    /// All inputs are raw (un-normalized); the helper applies the same
    /// trimming and provider/session-id normalization the production path
    /// has always used.
    struct ResumeRestoreIntentMatch {
        let directoryMatches: Bool
        let providerMatches: Bool
        let sessionMatches: Bool
        let normalizedExpectedDirectory: String
        let normalizedCurrentDirectory: String
        let normalizedExpectedProvider: String?
        let normalizedCurrentProvider: String?
        let normalizedExpectedSessionID: String?
        let normalizedCurrentSessionID: String?
        var allMatch: Bool {
            directoryMatches && providerMatches && sessionMatches
        }
    }

    static func evaluateResumeRestoreIntent(
        expectedDirectory: String,
        currentDirectory: String,
        expectedProvider: String?,
        currentProvider: String?,
        expectedSessionID: String?,
        currentSessionID: String?
    ) -> ResumeRestoreIntentMatch {
        let normalizedExpectedDirectory = expectedDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrentDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpectedProvider = AIResumeParser.normalizeProviderName(expectedProvider ?? "")
        let normalizedExpectedSessionID = OverlayTabsModel.normalizeAISessionId(expectedSessionID)
        let normalizedCurrentSessionID = OverlayTabsModel.normalizeAISessionId(currentSessionID)

        // Directory ownership check. The previous `isEmpty ||` shortcut
        // treated "expected directory unknown" as "match anything" — which
        // silently delivered a resume command to whatever session happened
        // to occupy the pane slot. Tighten: accept only if the normalized
        // strings are equal (both empty is still fine — a genuinely
        // directory-less saved state matching a directory-less live session
        // is not a mismatch). Empty-expected + non-empty-current is now
        // rejected.
        let directoryMatches = normalizedExpectedDirectory == normalizedCurrentDirectory

        // Provider / session ownership check. Three-way:
        //   - expected = nil  → wildcard, always matches (saved state lacked
        //                       identity, trust the live session).
        //   - current  = nil  → identity not yet corroborated. The launch
        //                       arguments (`claude --resume <id>` /
        //                       `codex resume <id>`) guarantee the session
        //                       is the right one — identity detection just
        //                       hasn't caught up to the prompt. Treat as
        //                       match and let delivery proceed; rejecting
        //                       here is the recurring class of regression
        //                       that loses prefills every time identity
        //                       detection is tightened. (See git history
        //                       around b39a863a / d485275c.)
        //   - both set        → must be equal.
        let providerMatches: Bool
        if let expected = normalizedExpectedProvider {
            providerMatches = currentProvider == nil || currentProvider == expected
        } else {
            providerMatches = true
        }
        let sessionMatches: Bool
        if let expected = normalizedExpectedSessionID {
            sessionMatches = normalizedCurrentSessionID == nil || normalizedCurrentSessionID == expected
        } else {
            sessionMatches = true
        }

        return ResumeRestoreIntentMatch(
            directoryMatches: directoryMatches,
            providerMatches: providerMatches,
            sessionMatches: sessionMatches,
            normalizedExpectedDirectory: normalizedExpectedDirectory,
            normalizedCurrentDirectory: normalizedCurrentDirectory,
            normalizedExpectedProvider: normalizedExpectedProvider,
            normalizedCurrentProvider: currentProvider,
            normalizedExpectedSessionID: normalizedExpectedSessionID,
            normalizedCurrentSessionID: normalizedCurrentSessionID
        )
    }

    func validateResumeRestoreIntent(
        _ intent: ResumeRestoreIntent,
        against session: TerminalSessionModel,
        tabID: UUID
    ) -> Bool {
        let match = Self.evaluateResumeRestoreIntent(
            expectedDirectory: intent.expectedDirectory,
            currentDirectory: session.currentDirectory,
            expectedProvider: intent.expectedProvider,
            currentProvider: session.effectiveAIProvider,
            expectedSessionID: intent.expectedSessionID,
            currentSessionID: session.effectiveAISessionId
        )

        guard match.allMatch else {
            Log.warn(
                """
                restoreTabState: rejecting resume prefill for tab=\(tabID) pane=\(intent.paneID) \
                command=\(intent.command.prefix(40)) \
                expected=(dir=\(match.normalizedExpectedDirectory), provider=\(match.normalizedExpectedProvider ?? "nil"), \
                session=\(match.normalizedExpectedSessionID?.prefix(8) ?? "nil")) \
                actual=(dir=\(match.normalizedCurrentDirectory), provider=\(match.normalizedCurrentProvider ?? "nil"), \
                session=\(match.normalizedCurrentSessionID?.prefix(8) ?? "nil"))
                """
            )
            return false
        }

        return true
    }

    /// Pure decision step for `recordResumeRestoreDeliveryState`. Decides
    /// whether an incoming `(token, outcome)` should overwrite the existing
    /// per-pane delivery state, preserve a newer-token state, or preserve a
    /// terminal outcome already on file.
    ///
    /// Extracted as a static helper so the state-machine logic is unit-
    /// testable via `swift test` without constructing a live model.
    /// `recordResumeRestoreDeliveryState` calls this and applies the
    /// decision (writing to `resumeRestoreDeliveryStateByPaneID` and
    /// emitting the corresponding log line).
    enum ResumeRestoreDeliveryDecision: Equatable {
        /// Overwrite the existing entry (or insert if none) with the new
        /// `ResumeRestoreDeliveryState`.
        case write(ResumeRestoreDeliveryState)
        /// Preserve the existing entry: a newer token has already been
        /// recorded; the incoming outcome is stale.
        case preserveNewerToken
        /// Preserve the existing entry: it has reached a terminal outcome
        /// (`delivered` / `rejected`) which `superseded` cannot override.
        case preserveTerminalOutcome
    }

    static func decideResumeRestoreDeliveryUpdate(
        existing: ResumeRestoreDeliveryState?,
        newToken: String,
        newOutcome: ResumeRestoreDeliveryState.Outcome
    ) -> ResumeRestoreDeliveryDecision {
        // The gates only apply when the incoming outcome is `superseded`.
        // For any other outcome (pending / queued / delivered / rejected),
        // the new entry always wins — restoreTabState always issues these
        // with the latest token it has, and a delivered/rejected always
        // supersedes a pending/queued for the same token.
        if let existing, newOutcome == .superseded {
            if existing.token != newToken {
                return .preserveNewerToken
            }
            switch existing.outcome {
            case .delivered, .rejected:
                return .preserveTerminalOutcome
            case .pending, .queued, .superseded:
                break
            }
        }
        return .write(ResumeRestoreDeliveryState(token: newToken, outcome: newOutcome))
    }

    func recordResumeRestoreDeliveryState(
        paneID: UUID,
        token: String,
        outcome: ResumeRestoreDeliveryState.Outcome,
        tabID: UUID,
        reason: String
    ) {
        let decision = Self.decideResumeRestoreDeliveryUpdate(
            existing: resumeRestoreDeliveryStateByPaneID[paneID],
            newToken: token,
            newOutcome: outcome
        )
        switch decision {
        case .preserveNewerToken:
            let existing = resumeRestoreDeliveryStateByPaneID[paneID]
            Log.trace(
                "restoreTabState: preserving newer resume outcome for tab=\(tabID) pane=\(paneID) existingToken=\(existing?.token.prefix(8) ?? "nil") staleToken=\(token.prefix(8))"
            )
        case .preserveTerminalOutcome:
            let existing = resumeRestoreDeliveryStateByPaneID[paneID]
            Log.trace(
                "restoreTabState: preserving terminal resume outcome for tab=\(tabID) pane=\(paneID) token=\(token.prefix(8)) existing=\(existing?.outcome.rawValue ?? "nil")"
            )
        case .write(let newState):
            resumeRestoreDeliveryStateByPaneID[paneID] = newState
            Log.info(
                "restoreTabState: resume outcome tab=\(tabID) pane=\(paneID) token=\(token.prefix(8)) outcome=\(outcome.rawValue) reason=\(reason)"
            )
        }
    }

    @discardableResult
    func enqueueResumePrefill(
        intent: ResumeRestoreIntent,
        into session: TerminalSessionModel,
        targetTabID: UUID,
        restoreToken: String,
        queuedReason: String,
        deliveredReason: String
    ) -> Bool {
        let paneID = intent.paneID
        let prefillResult = session.prefillInput(
            intent.command,
            rejectionReasonProvider: { [weak self, weak session] in
                guard let self, let session else { return "session_unavailable_at_delivery" }
                guard latestRestoreResumeTokenByPaneID[paneID] == restoreToken else {
                    return "superseded_at_delivery"
                }
                guard validateResumeRestoreIntent(intent, against: session, tabID: targetTabID) else {
                    return "ownership_validation_failed_at_delivery"
                }
                return nil
            },
            onDelivered: { [weak self] in
                guard let self else { return }
                StartupRestoreCoordinator.shared.noteDeliveredResumePrefill()
                recordResumeRestoreDeliveryState(
                    paneID: paneID,
                    token: restoreToken,
                    outcome: .delivered,
                    tabID: targetTabID,
                    reason: deliveredReason
                )
                if latestRestoreResumeTokenByPaneID[paneID] == restoreToken {
                    latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                }
                Log.info(
                    """
                    restoreTabState: resume command prefilling for tab=\(targetTabID) pane=\(paneID) \
                    provider=\(intent.expectedProvider ?? "nil") session=\(intent.expectedSessionID?.prefix(8) ?? "nil") \
                    dir=\(intent.expectedDirectory)
                    """
                )
            },
            onRejected: { [weak self] rejectionReason in
                guard let self else { return }
                let outcome: ResumeRestoreDeliveryState.Outcome = rejectionReason.hasPrefix("superseded")
                    ? .superseded
                    : .rejected
                recordResumeRestoreDeliveryState(
                    paneID: paneID,
                    token: restoreToken,
                    outcome: outcome,
                    tabID: targetTabID,
                    reason: rejectionReason
                )
                if latestRestoreResumeTokenByPaneID[paneID] == restoreToken {
                    latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                }
            }
        )

        switch prefillResult {
        case .delivered:
            return true
        case .queued:
            StartupRestoreCoordinator.shared.noteQueuedResumePrefill()
            recordResumeRestoreDeliveryState(
                paneID: paneID,
                token: restoreToken,
                outcome: .queued,
                tabID: targetTabID,
                reason: queuedReason
            )
            return false
        case .rejected:
            return false
        }
    }

    struct ResumeRestoreIntent {
        let paneID: UUID
        let command: String
        let expectedDirectory: String
        let expectedProvider: String?
        let expectedSessionID: String?
        let expectedSessionIDSource: AISessionIdentitySource?
        let isFocusedPane: Bool
    }

    static func normalizedResumeCommand(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isSafeResumeCommand(trimmed) else { return nil }
        return trimmed
    }

    static func isSafeResumeCommand(_ command: String) -> Bool {
        if let sessionId = command.extractResumeSessionId(prefix: "claude --resume ") {
            return isValidSessionId(sessionId)
        }
        if let sessionId = command.extractResumeSessionId(prefix: "codex resume ") {
            return isValidSessionId(sessionId)
        }
        return false
    }
}
