import Foundation
import Chau7Core

// MARK: - CTO Runtime Monitor

/// Runtime monitor that records CTO decisions and lifecycle events.
final class CTORuntimeMonitor {
    static let shared = CTORuntimeMonitor()

    private let lock = NSLock()
    private var recalcCount = 0
    private var createdCount = 0
    private var removedCount = 0
    private var unchangedCount = 0
    private var deferredSetCount = 0
    private var deferredFlushCount = 0
    private var deferredSkipCount = 0
    private var deferredCancelCount = 0
    private var setupCount = 0
    private var teardownCount = 0
    private var modeChangeCount = 0
    private var lastModeChangeAt: Date?
    private var lastDecisionAt: Date?
    private var lastDecision: CTODecisionEvent?
    private var activeSessionCount = 0
    private var trackedSessions = 0
    private var reasonBreakdown: [CTODecisionReason: Int] = [:]
    private var triggerBreakdown: [CTODecisionTrigger: Int] = [:]
    private var activeSessions: Set<String> = []
    private var trackedSessionIDs: Set<String> = []
    private var deferredSessionIDs: Set<String> = []
    private var recentDecisions: [CTODecisionEvent] = []
    private var deferredFlushDelaySumMs: Int64 = 0
    private var deferredFlushDelayMinMs = 0
    private var deferredFlushDelayMaxMs = 0
    private var deferredFlushDelayLastMs: Int?
    private var deferredFlushDelayCount = 0
    private var currentMode: TokenOptimizationMode = .off
    private var lastEmittedAssessment: CTORuntimeAssessment?
    private var lastGainStats: CTOGainStats?
    private var lastGainStatsAt: Date?
    private let firstSeenAt: Date
    private let maxRecentDecisions = 50
    private let summaryInterval = 25

    private init() {
        self.firstSeenAt = Date()
    }

    // MARK: - Public API

    func snapshot() -> CTORuntimeSnapshot {
        withLock {
            let elapsedSeconds = max(Date().timeIntervalSince(firstSeenAt), 1)
            let decisionsPerMinute = (Double(recalcCount) / elapsedSeconds) * 60
            return CTORuntimeSnapshot(
                mode: currentMode.rawValue,
                recalcCount: recalcCount,
                createdCount: createdCount,
                removedCount: removedCount,
                unchangedCount: unchangedCount,
                deferredSetCount: deferredSetCount,
                deferredFlushCount: deferredFlushCount,
                deferredSkipCount: deferredSkipCount,
                deferredCancelCount: deferredCancelCount,
                setupCount: setupCount,
                teardownCount: teardownCount,
                modeChangeCount: modeChangeCount,
                lastModeChangeAt: lastModeChangeAt,
                lastDecisionAt: lastDecisionAt,
                lastDecision: lastDecision,
                activeSessionCount: activeSessionCount,
                trackedSessions: trackedSessions,
                pendingDeferredSessions: deferredSessionIDs.count,
                reasonBreakdown: reasonBreakdown.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
                triggerBreakdown: triggerBreakdown.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
                deferredFlushDelayCount: deferredFlushDelayCount,
                deferredFlushDelayMinMs: deferredFlushDelayCount > 0 ? deferredFlushDelayMinMs : nil,
                deferredFlushDelayMaxMs: deferredFlushDelayCount > 0 ? deferredFlushDelayMaxMs : nil,
                deferredFlushDelayAverageMs: deferredFlushDelayCount > 0
                    ? Double(deferredFlushDelaySumMs) / Double(deferredFlushDelayCount)
                    : nil,
                deferredFlushDelayLastMs: deferredFlushDelayLastMs,
                recentDecisions: recentDecisions,
                firstSeenAt: firstSeenAt,
                uptimeSeconds: Int(elapsedSeconds.rounded()),
                decisionsPerMinute: decisionsPerMinute,
                gainStats: lastGainStats,
                gainStatsLastSampledAt: lastGainStatsAt
            )
        }
    }

    func reset() {
        resetForTesting()
    }

    func resetForTesting() {
        withLock {
            recalcCount = 0
            createdCount = 0
            removedCount = 0
            unchangedCount = 0
            deferredSetCount = 0
            deferredFlushCount = 0
            deferredSkipCount = 0
            deferredCancelCount = 0
            setupCount = 0
            teardownCount = 0
            modeChangeCount = 0
            lastModeChangeAt = nil
            lastDecisionAt = nil
            lastDecision = nil
            activeSessions.removeAll()
            trackedSessionIDs.removeAll()
            deferredSessionIDs.removeAll()
            recentDecisions.removeAll(keepingCapacity: true)
            activeSessionCount = 0
            trackedSessions = 0
            reasonBreakdown.removeAll(keepingCapacity: true)
            triggerBreakdown.removeAll(keepingCapacity: true)
            deferredFlushDelaySumMs = 0
            deferredFlushDelayMinMs = 0
            deferredFlushDelayMaxMs = 0
            deferredFlushDelayLastMs = nil
            deferredFlushDelayCount = 0
            currentMode = .off
            lastEmittedAssessment = nil
            lastGainStats = nil
            lastGainStatsAt = nil
        }
        LogEnhanced.info(.cto, "cto monitor reset", metadata: ["scope": "manual"])
    }

    func recordModeChanged(from previousMode: TokenOptimizationMode, to currentMode: TokenOptimizationMode) {
        var modeChangeCountSnapshot = 0
        withLock {
            if previousMode != currentMode {
                modeChangeCount += 1
                lastModeChangeAt = Date()
            }
            self.currentMode = currentMode
            if currentMode == .off {
                deferredSessionIDs.removeAll()
            }
            modeChangeCountSnapshot = modeChangeCount
        }

        if previousMode != currentMode {
            let metadata: [String: String] = [
                "previousMode": previousMode.rawValue,
                "currentMode": currentMode.rawValue,
                "modeChanges": "\(modeChangeCountSnapshot)"
            ]
            LogEnhanced.info(.cto, "CTO mode changed", metadata: metadata)
        }
    }

    /// Pipe a fresh `chau7-optim gain` sample into the monitor. Callers
    /// poll the helper binary and forward the summary here; the snapshot
    /// then carries the most recent value so diagnostic views and the
    /// runtime summary can correlate the decision-level health metric
    /// with actual token savings.
    ///
    /// Passing nil indicates the helper returned no data (e.g. optimizer
    /// not installed, no commands observed yet). The previous sample is
    /// dropped in that case so the snapshot reports the absence rather
    /// than a stale-but-positive figure.
    func recordGainStats(_ stats: CTOGainStats?, at sampledAt: Date = Date()) {
        withLock {
            lastGainStats = stats
            lastGainStatsAt = stats == nil ? nil : sampledAt
        }
        if let stats {
            LogEnhanced.trace(
                .cto,
                "CTO gain stats sampled",
                metadata: [
                    "commands": "\(stats.commands)",
                    "savedTokens": "\(stats.savedTokens)",
                    "savingsPct": String(format: "%.1f", stats.savingsPct)
                ]
            )
        }
    }

    func recordManagerSetup(mode: TokenOptimizationMode? = nil) {
        var shouldLogSummary = false
        var setupCountSnapshot = 0
        withLock {
            if let mode {
                currentMode = mode
            }
            setupCount += 1
            setupCountSnapshot = setupCount
            shouldLogSummary = setupCount.isMultiple(of: 5)
        }
        LogEnhanced.info(
            .cto,
            "CTO manager setup observed",
            metadata: ["setups": "\(setupCountSnapshot)", "mode": currentMode.rawValue]
        )
        if shouldLogSummary {
            emitSummary()
        }
    }

    func recordManagerTeardown() {
        var teardownCountSnapshot = 0
        withLock {
            teardownCount += 1
            teardownCountSnapshot = teardownCount
            deferredSessionIDs.removeAll()
        }
        LogEnhanced.info(.cto, "CTO manager teardown observed", metadata: ["teardowns": "\(teardownCountSnapshot)"])
    }

    func untrackSession(_ sessionID: String) {
        let removedAnyState = withLock {
            let removedTracked = trackedSessionIDs.remove(sessionID) != nil
            let removedActive = activeSessions.remove(sessionID) != nil
            let removedDeferred = deferredSessionIDs.remove(sessionID) != nil
            activeSessionCount = activeSessions.count
            trackedSessions = trackedSessionIDs.count
            return removedTracked || removedActive || removedDeferred
        }

        guard removedAnyState else { return }
        LogEnhanced.trace(.cto, "CTO session untracked", metadata: ["session": sessionID])
    }

    func recordManagerBulkRemove(count: Int) {
        withLock {
            removedCount += count
            reasonBreakdown[.off, default: 0] += count
            deferredSessionIDs.removeAll()
            trackedSessionIDs.subtract(activeSessions)
            activeSessions.removeAll()
            activeSessionCount = 0
            trackedSessions = trackedSessionIDs.count
        }
        if count > 0 {
            LogEnhanced.info(
                .cto,
                "CTO bulk flag cleanup",
                metadata: ["removed": "\(count)", "scope": "teardown/all"]
            )
        }
    }

    func recordDeferredSet(sessionID: String) {
        var pendingDeferred = 0
        withLock {
            deferredSetCount += 1
            deferredSessionIDs.insert(sessionID)
            pendingDeferred = deferredSessionIDs.count
            trackSession(sessionID)
        }
        LogEnhanced.trace(
            .cto,
            "CTO deferred set",
            metadata: [
                "session": sessionID,
                "mode": currentMode.rawValue,
                "pendingDeferred": "\(pendingDeferred)"
            ]
        )
    }

    func recordDeferredFlush(
        sessionID: String,
        delayToActivateMs: Int,
        mode: TokenOptimizationMode,
        override: TabTokenOptOverride,
        isAIActive: Bool,
        previousState: Bool,
        nextState: Bool,
        changed: Bool,
        reason: CTODecisionReason,
        note: String? = nil
    ) {
        var event: CTODecisionEvent?
        withLock {
            deferredFlushCount += 1
            deferredSessionIDs.remove(sessionID)
            trackSession(sessionID)
            updateDeferredDelayStats(delayToActivateMs: delayToActivateMs)
            event = recordDecisionInternal(
                sessionID: sessionID,
                mode: mode,
                override: override,
                isAIActive: isAIActive,
                previousState: previousState,
                nextState: nextState,
                changed: changed,
                reason: reason,
                trigger: .shellInitialized,
                deferred: true,
                delayToActivateMs: delayToActivateMs,
                debugNote: note
            )
        }
        if let event {
            logDecisionEvent(event)
        }
        LogEnhanced.trace(
            .cto,
            "CTO deferred flush",
            metadata: [
                "session": sessionID,
                "delayMs": "\(delayToActivateMs)",
                "reason": reason.rawValue
            ]
        )
    }

    func recordDeferredSkip(
        sessionID: String,
        reason: String,
        mode: TokenOptimizationMode,
        override: TabTokenOptOverride,
        isAIActive: Bool
    ) {
        var event: CTODecisionEvent?
        withLock {
            deferredSkipCount += 1
            deferredSessionIDs.remove(sessionID)
            trackSession(sessionID)
            event = CTODecisionEvent(
                sessionID: sessionID,
                mode: mode,
                override: override,
                isAIActive: isAIActive,
                previousState: false,
                nextState: false,
                reason: .skippedDueToDeferred,
                deferred: true,
                changed: false,
                debugNote: reason
            )
            appendRecentDecision(event)
        }
        if let event {
            logDecisionEvent(event)
        }
        LogEnhanced.trace(
            .cto,
            "CTO deferred skip",
            metadata: [
                "session": sessionID,
                "mode": mode.rawValue,
                "reason": "skippedDueToDeferred",
                "skipReason": reason
            ]
        )
    }

    /// Record that a pending deferred-flush was *cancelled* — the session
    /// closed (or its mode flipped to off) before reaching the first
    /// prompt. Distinct from `recordDeferredSkip`, which captures
    /// "a non-deferred decision suppressed a flag flip while a deferral
    /// was still pending". Cancellations are subtracted from the
    /// denominator of `deferredFlushRatePercent` so the flush-rate health
    /// metric reflects only sessions that actually had a chance to flush.
    func recordDeferredCancel(
        sessionID: String,
        reason: String,
        mode: TokenOptimizationMode,
        override: TabTokenOptOverride,
        isAIActive: Bool
    ) {
        var event: CTODecisionEvent?
        withLock {
            deferredCancelCount += 1
            deferredSessionIDs.remove(sessionID)
            event = CTODecisionEvent(
                sessionID: sessionID,
                mode: mode,
                override: override,
                isAIActive: isAIActive,
                previousState: false,
                nextState: false,
                reason: .skippedDueToDeferred,
                deferred: true,
                changed: false,
                debugNote: "cancelled:\(reason)"
            )
            appendRecentDecision(event)
        }
        if let event {
            logDecisionEvent(event)
        }
        LogEnhanced.trace(
            .cto,
            "CTO deferred cancel",
            metadata: [
                "session": sessionID,
                "mode": mode.rawValue,
                "cancelReason": reason
            ]
        )
    }

    func recordDecision(
        sessionID: String,
        mode: TokenOptimizationMode,
        override: TabTokenOptOverride,
        isAIActive: Bool,
        previousState: Bool,
        nextState: Bool,
        changed: Bool,
        reason: CTODecisionReason,
        trigger: CTODecisionTrigger? = nil,
        delayToActivateMs: Int? = nil,
        note: String? = nil
    ) {
        var event: CTODecisionEvent?
        var shouldEmitSummary = false
        withLock {
            event = recordDecisionInternal(
                sessionID: sessionID,
                mode: mode,
                override: override,
                isAIActive: isAIActive,
                previousState: previousState,
                nextState: nextState,
                changed: changed,
                reason: reason,
                trigger: trigger,
                deferred: false,
                delayToActivateMs: delayToActivateMs,
                debugNote: note
            )
            if recalcCount.isMultiple(of: summaryInterval) {
                shouldEmitSummary = true
            }
        }

        if let event {
            logDecisionEvent(event)
            if shouldEmitSummary {
                emitSummary()
            }
        }
    }

    /// Emit summary metrics for a quick global view in logs.
    func emitSummary() {
        let snap = snapshot()
        guard snap.recalcCount > 0 || snap.setupCount > 0 || snap.teardownCount > 0 else { return }

        let assessment = snap.assessment
        let metadata: [String: String] = [
            "recalcCount": "\(snap.recalcCount)",
            "created": "\(snap.createdCount)",
            "removed": "\(snap.removedCount)",
            "unchanged": "\(snap.unchangedCount)",
            "deferredSet": "\(snap.deferredSetCount)",
            "deferredFlush": "\(snap.deferredFlushCount)",
            "deferredSkip": "\(snap.deferredSkipCount)",
            "changeRatePct": String(format: "%.1f", snap.decisionsChangeRatePercent),
            "deferredSkipPct": String(format: "%.1f", snap.deferredSkipRatePercent),
            "deferredFlushPct": String(format: "%.1f", snap.deferredFlushRatePercent),
            "activeRatioPct": String(format: "%.1f", snap.activeSessionRatioPercent),
            "uptimeMinutes": String(format: "%.2f", Double(snap.uptimeSeconds) / 60.0),
            "decisionsPerMinute": String(format: "%.1f", snap.decisionsPerMinute),
            "decisionIntervalAvgMs": snap.decisionIntervalAverageSeconds
                .map { String(format: "%.0f", $0 * 1000) } ?? "n/a",
            "decisionIntervalMinMs": snap.decisionIntervalMinSeconds
                .map { String(format: "%.0f", $0 * 1000) } ?? "n/a",
            "decisionIntervalMaxMs": snap.decisionIntervalMaxSeconds
                .map { String(format: "%.0f", $0 * 1000) } ?? "n/a",
            "healthState": assessment.state.rawValue,
            "healthScore": "\(assessment.score)",
            "healthSummary": assessment.summary,
            "healthIssues": assessment.issues.map(\.rawValue).joined(separator: ","),
            "ageSinceLastDecisionSeconds": snap.ageSinceLastDecisionSeconds.map(String.init) ?? "n/a"
        ]

        switch assessment.state {
        case .healthy:
            LogEnhanced.info(.cto, "CTO runtime summary", metadata: metadata)
        case .warning, .critical:
            LogEnhanced.warn(.cto, "CTO runtime summary", metadata: metadata)
        }

        emitAssessmentTransitionIfChanged(assessment)
    }

    /// Log a one-line transition record whenever `emitSummary` observes a
    /// change in `assessment.state` compared to the previous summary. The
    /// previous code only emitted at WARN when the state was non-healthy,
    /// so the recovery edge (warning → healthy, critical → warning) was
    /// silent — you couldn't tell from logs whether the system *got
    /// better* after a fix, only that it had been bad earlier. This
    /// records both edges symmetrically:
    ///   - degradations (healthy → warning, warning → critical, …) at WARN
    ///   - recoveries  (warning → healthy, critical → warning, …) at INFO
    /// New issues and resolved issues are included so the line carries
    /// the actionable delta, not just a state label.
    private func emitAssessmentTransitionIfChanged(_ current: CTORuntimeAssessment) {
        let previous = withLock { lastEmittedAssessment }
        withLock { lastEmittedAssessment = current }

        guard let transition = CTOAssessmentTransition.between(previous: previous, current: current) else {
            return
        }

        switch transition {
        case .initial(let state, let score, let issues):
            LogEnhanced.info(
                .cto,
                "CTO runtime state initial",
                metadata: [
                    "state": state.rawValue,
                    "score": "\(score)",
                    "issues": issues.map(\.rawValue).joined(separator: ",")
                ]
            )

        case .degraded(let metadata):
            LogEnhanced.warn(.cto, "CTO runtime state degraded", metadata: metadata)

        case .recovered(let metadata):
            LogEnhanced.info(.cto, "CTO runtime state recovered", metadata: metadata)
        }
    }

    /// Test accessor: most recent assessment recorded by `emitSummary`.
    /// Production code should use `snapshot().assessment` for live data;
    /// this hook exists so transition-emission tests can assert the
    /// monitor's view of its own history.
    var lastEmittedAssessmentForTesting: CTORuntimeAssessment? {
        withLock { lastEmittedAssessment }
    }

    // MARK: - Private

    private func recordDecisionInternal(
        sessionID: String,
        mode: TokenOptimizationMode,
        override: TabTokenOptOverride,
        isAIActive: Bool,
        previousState: Bool,
        nextState: Bool,
        changed: Bool,
        reason: CTODecisionReason,
        trigger: CTODecisionTrigger? = nil,
        deferred: Bool,
        delayToActivateMs: Int?,
        debugNote: String?
    ) -> CTODecisionEvent {
        recalcCount += 1
        reasonBreakdown[reason, default: 0] += 1
        if let trigger {
            triggerBreakdown[trigger, default: 0] += 1
        }
        if changed {
            if nextState {
                createdCount += 1
            } else {
                removedCount += 1
            }
        } else {
            unchangedCount += 1
        }

        trackSession(sessionID)
        if nextState {
            activeSessions.insert(sessionID)
        } else {
            activeSessions.remove(sessionID)
        }
        activeSessionCount = activeSessions.count
        let event = CTODecisionEvent(
            sessionID: sessionID,
            mode: mode,
            override: override,
            isAIActive: isAIActive,
            previousState: previousState,
            nextState: nextState,
            reason: reason,
            trigger: trigger,
            deferred: deferred,
            delayToActivateMs: delayToActivateMs,
            changed: changed,
            debugNote: debugNote
        )
        lastDecision = event
        lastDecisionAt = event.timestamp
        appendRecentDecision(event)
        return event
    }

    private func logDecisionEvent(_ event: CTODecisionEvent) {
        var metadata: [String: String] = [
            "session": event.sessionID,
            "mode": event.mode,
            "override": event.override,
            "ai": "\(event.isAIActive)",
            "previousState": "\(event.previousState)",
            "nextState": "\(event.nextState)",
            "changed": "\(event.changed)",
            "reason": event.reason.rawValue,
            "deferred": "\(event.deferred)",
            "eventId": event.id.uuidString
        ]
        if let delayMs = event.delayToActivateMs {
            metadata["delayMs"] = "\(delayMs)"
        }
        if let debugNote = event.debugNote {
            metadata["note"] = debugNote
        }

        if event.changed {
            LogEnhanced.info(.cto, "CTO decision", metadata: metadata)
        } else {
            LogEnhanced.trace(.cto, "CTO decision unchanged", metadata: metadata)
        }
    }

    private func updateDeferredDelayStats(delayToActivateMs: Int) {
        deferredFlushDelayLastMs = delayToActivateMs
        deferredFlushDelayCount += 1
        deferredFlushDelaySumMs += Int64(delayToActivateMs)
        if deferredFlushDelayCount == 1 {
            deferredFlushDelayMinMs = delayToActivateMs
            deferredFlushDelayMaxMs = delayToActivateMs
        } else {
            deferredFlushDelayMinMs = min(deferredFlushDelayMinMs, delayToActivateMs)
            deferredFlushDelayMaxMs = max(deferredFlushDelayMaxMs, delayToActivateMs)
        }
    }

    private func trackSession(_ sessionID: String) {
        if trackedSessionIDs.insert(sessionID).inserted {
            trackedSessions = trackedSessionIDs.count
        }
    }

    private func appendRecentDecision(_ event: CTODecisionEvent?) {
        guard let event else { return }
        recentDecisions.append(event)
        if recentDecisions.count > maxRecentDecisions {
            recentDecisions.removeFirst(recentDecisions.count - maxRecentDecisions)
        }
    }

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }
}
