import Foundation

// MARK: - RTK Runtime Monitor

/// Runtime telemetry for token optimization decisions.
///
/// This keeps the optimizer behavior unchanged while making it easy to
/// inspect why RTK flags were created/removed and how often deferred mode
/// is actually being used.
enum RTKDecisionReason: String, Codable {
    case off
    case allTabsDefault
    case aiOnlyWithAI
    case aiOnlyWithoutAI
    case manualDefault
    case forceOn
    case forceOff
    case skippedDueToDeferred
    case unchanged
}

enum RTKRuntimeHealthState: String, Codable {
    case healthy
    case warning
    case critical
}

enum RTKRuntimeAssessmentIssue: String, Codable, Equatable {
    case lowChangeRate
    case highDeferredSkips
    case lowDeferredFlushRate
    case staleDecisions
    case modeOffWithTrackedSessions
    case lowDecisionThroughput
}

struct RTKRuntimeAssessment: Codable, Equatable {
    let state: RTKRuntimeHealthState
    let score: Int
    let issues: [RTKRuntimeAssessmentIssue]
    let summary: String
}

/// Single RTK decision event used by the debug stats panel.
struct RTKDecisionEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let sessionID: String
    let mode: String
    let override: String
    let isAIActive: Bool
    let previousState: Bool
    let nextState: Bool
    let changed: Bool
    let reason: RTKDecisionReason
    let deferred: Bool
    let delayToActivateMs: Int?
    let debugNote: String?

    init(
        sessionID: String,
        mode: TokenOptimizationMode,
        override: TabTokenOptOverride,
        isAIActive: Bool,
        previousState: Bool,
        nextState: Bool,
        reason: RTKDecisionReason,
        deferred: Bool = false,
        delayToActivateMs: Int? = nil,
        changed: Bool = true,
        debugNote: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.sessionID = sessionID
        self.mode = mode.rawValue
        self.override = override.rawValue
        self.isAIActive = isAIActive
        self.previousState = previousState
        self.nextState = nextState
        self.changed = changed
        self.reason = reason
        self.deferred = deferred
        self.delayToActivateMs = delayToActivateMs
        self.debugNote = debugNote
    }
}

/// Snapshot of RTK runtime counters shown in settings/debug views.
struct RTKRuntimeSnapshot: Codable, Equatable {
    let mode: String
    let recalcCount: Int
    let createdCount: Int
    let removedCount: Int
    let unchangedCount: Int
    let deferredSetCount: Int
    let deferredFlushCount: Int
    let deferredSkipCount: Int
    let setupCount: Int
    let teardownCount: Int
    let modeChangeCount: Int
    let lastModeChangeAt: Date?
    let lastDecisionAt: Date?
    let lastDecision: RTKDecisionEvent?
    let activeSessionCount: Int
    let trackedSessions: Int
    let pendingDeferredSessions: Int
    let reasonBreakdown: [String: Int]
    let deferredFlushDelayCount: Int
    let deferredFlushDelayMinMs: Int?
    let deferredFlushDelayMaxMs: Int?
    let deferredFlushDelayAverageMs: Double?
    let deferredFlushDelayLastMs: Int?
    let recentDecisions: [RTKDecisionEvent]
    let firstSeenAt: Date
    let uptimeSeconds: Int
    let decisionsPerMinute: Double
    let decisionIntervalAverageSeconds: Double?
    let decisionIntervalMinSeconds: Double?
    let decisionIntervalMaxSeconds: Double?
}

extension RTKRuntimeSnapshot {
    var decisionsChangeRatePercent: Double {
        guard recalcCount > 0 else { return 0 }
        let changedCount = max(0, recalcCount - unchangedCount)
        return (Double(changedCount) / Double(recalcCount)) * 100
    }

    var deferredSkipRatePercent: Double {
        guard deferredSetCount > 0 else { return 0 }
        let ratio = Double(deferredSkipCount) / Double(deferredSetCount)
        return min(max(ratio, 0), 1) * 100
    }

    var deferredFlushRatePercent: Double {
        guard deferredSetCount > 0 else { return 0 }
        let ratio = Double(deferredFlushCount) / Double(deferredSetCount)
        return min(max(ratio, 0), 1) * 100
    }

    var activeSessionRatioPercent: Double {
        guard trackedSessions > 0 else { return 0 }
        return (Double(activeSessionCount) / Double(trackedSessions)) * 100
    }

    var ageSinceLastDecisionSeconds: Int? {
        guard let lastDecisionAt else { return nil }
        return max(0, Int(Date().timeIntervalSince(lastDecisionAt)))
    }

    private var decisionIntervalsSeconds: [Double] {
        guard recentDecisions.count > 1 else { return [] }
        let sortedDecisions = recentDecisions.sorted(by: { $0.timestamp < $1.timestamp })
        return zip(sortedDecisions, sortedDecisions.dropFirst()).map {
            $1.timestamp.timeIntervalSince($0.timestamp)
        }
    }

    var decisionIntervalAverageSeconds: Double? {
        guard !decisionIntervalsSeconds.isEmpty else { return nil }
        return decisionIntervalsSeconds.reduce(0, +) / Double(decisionIntervalsSeconds.count)
    }

    var decisionIntervalMinSeconds: Double? {
        decisionIntervalsSeconds.min()
    }

    var decisionIntervalMaxSeconds: Double? {
        decisionIntervalsSeconds.max()
    }

    var assessment: RTKRuntimeAssessment {
        var score = 100
        var issues: [RTKRuntimeAssessmentIssue] = []

        if recalcCount > 0 && decisionsChangeRatePercent < 30.0 {
            score -= 30
            issues.append(.lowChangeRate)
        }

        if deferredSetCount > 0 && deferredSkipRatePercent > 35.0 {
            score -= 30
            issues.append(.highDeferredSkips)
        }

        if deferredSetCount > 0 && deferredFlushRatePercent < 80.0 {
            score -= 20
            issues.append(.lowDeferredFlushRate)
        }

        if let age = ageSinceLastDecisionSeconds, age > 300 {
            score -= 15
            issues.append(.staleDecisions)
        }

        if mode == TokenOptimizationMode.off.rawValue && trackedSessions > 0 {
            score -= 20
            issues.append(.modeOffWithTrackedSessions)
        }

        if recalcCount == 0 && trackedSessions > 0 && uptimeSeconds >= 60 {
            score -= 10
            issues.append(.lowDecisionThroughput)
        }

        let normalizedScore = max(0, min(100, score))
        let state: RTKRuntimeHealthState = normalizedScore >= 85
            ? .healthy
            : normalizedScore >= 65
            ? .warning
            : .critical

        let summary: String = switch state {
        case .healthy:
            "healthy"
        case .warning:
            "needsReview"
        case .critical:
            "requiresAttention"
        }

        return RTKRuntimeAssessment(
            state: state,
            score: normalizedScore,
            issues: issues,
            summary: summary
        )
    }
}

/// Runtime monitor that records RTK decisions and lifecycle events.
final class RTKRuntimeMonitor {
    static let shared = RTKRuntimeMonitor()

    private let lock = NSLock()
    private var recalcCount = 0
    private var createdCount = 0
    private var removedCount = 0
    private var unchangedCount = 0
    private var deferredSetCount = 0
    private var deferredFlushCount = 0
    private var deferredSkipCount = 0
    private var setupCount = 0
    private var teardownCount = 0
    private var modeChangeCount = 0
    private var lastModeChangeAt: Date?
    private var lastDecisionAt: Date?
    private var lastDecision: RTKDecisionEvent?
    private var activeSessionCount = 0
    private var trackedSessions = 0
    private var reasonBreakdown: [RTKDecisionReason: Int] = [:]
    private var activeSessions: Set<String> = []
    private var trackedSessionIDs: Set<String> = []
    private var deferredSessionIDs: Set<String> = []
    private var recentDecisions: [RTKDecisionEvent] = []
    private var deferredFlushDelaySumMs: Int64 = 0
    private var deferredFlushDelayMinMs: Int = 0
    private var deferredFlushDelayMaxMs: Int = 0
    private var deferredFlushDelayLastMs: Int?
    private var deferredFlushDelayCount: Int = 0
    private var currentMode: TokenOptimizationMode = .off
    private let firstSeenAt: Date
    private let maxRecentDecisions = 50
    private let summaryInterval = 25

    private init() {
        self.firstSeenAt = Date()
    }

    // MARK: - Public API

    func snapshot() -> RTKRuntimeSnapshot {
        withLock {
            let elapsedSeconds = max(Date().timeIntervalSince(firstSeenAt), 1)
            let decisionsPerMinute = (Double(recalcCount) / elapsedSeconds) * 60
            let recentDecisionsSnapshot = recentDecisions
            let sortedDecisions = recentDecisionsSnapshot.sorted(by: { $0.timestamp < $1.timestamp })
            let intervals = zip(sortedDecisions, sortedDecisions.dropFirst()).map {
                $1.timestamp.timeIntervalSince($0.timestamp)
            }
            let intervalAvg: Double? = intervals.isEmpty
                ? nil
                : intervals.reduce(0, +) / Double(intervals.count)
            let intervalMin = intervals.min()
            let intervalMax = intervals.max()
            return RTKRuntimeSnapshot(
                mode: currentMode.rawValue,
                recalcCount: recalcCount,
                createdCount: createdCount,
                removedCount: removedCount,
                unchangedCount: unchangedCount,
                deferredSetCount: deferredSetCount,
                deferredFlushCount: deferredFlushCount,
                deferredSkipCount: deferredSkipCount,
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
                decisionIntervalAverageSeconds: intervalAvg,
                decisionIntervalMinSeconds: intervalMin,
                decisionIntervalMaxSeconds: intervalMax
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
            deferredFlushDelaySumMs = 0
            deferredFlushDelayMinMs = 0
            deferredFlushDelayMaxMs = 0
            deferredFlushDelayLastMs = nil
            deferredFlushDelayCount = 0
            currentMode = .off
        }
        LogEnhanced.info(.rtk, "rtk monitor reset", metadata: ["scope": "manual"])
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
            LogEnhanced.info(.rtk, "RTK mode changed", metadata: metadata)
        }
    }

    func recordManagerSetup() {
        var shouldLogSummary = false
        var setupCountSnapshot = 0
        withLock {
            setupCount += 1
            setupCountSnapshot = setupCount
            shouldLogSummary = setupCount % 5 == 0
        }
        LogEnhanced.info(
            .rtk,
            "RTK manager setup observed",
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
        LogEnhanced.info(.rtk, "RTK manager teardown observed", metadata: ["teardowns": "\(teardownCountSnapshot)"])
    }

    func recordManagerBulkRemove(count: Int) {
        withLock {
            removedCount += count
            reasonBreakdown[.off, default: 0] += count
            deferredSessionIDs.removeAll()
            trackedSessionIDs.subtract(Array(activeSessions))
            activeSessions.removeAll()
            activeSessionCount = 0
            trackedSessions = 0
        }
        if count > 0 {
            LogEnhanced.info(
                .rtk,
                "RTK bulk flag cleanup",
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
            .rtk,
            "RTK deferred set",
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
        reason: RTKDecisionReason,
        note: String? = nil
    ) {
        var event: RTKDecisionEvent?
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
                deferred: true,
                delayToActivateMs: delayToActivateMs,
                debugNote: note
            )
        }
        if let event {
            logDecisionEvent(event)
        }
        LogEnhanced.trace(
            .rtk,
            "RTK deferred flush",
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
        var event: RTKDecisionEvent?
        withLock {
            deferredSkipCount += 1
            deferredSessionIDs.remove(sessionID)
            trackSession(sessionID)
            event = RTKDecisionEvent(
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
            .rtk,
            "RTK deferred skip",
            metadata: [
                "session": sessionID,
                "mode": mode.rawValue,
                "reason": "skippedDueToDeferred",
                "skipReason": reason
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
        reason: RTKDecisionReason,
        delayToActivateMs: Int? = nil,
        note: String? = nil
    ) {
        var event: RTKDecisionEvent?
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
                deferred: false,
                delayToActivateMs: delayToActivateMs,
                debugNote: note
            )
            if recalcCount % summaryInterval == 0 {
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
            LogEnhanced.info(.rtk, "RTK runtime summary", metadata: metadata)
        case .warning, .critical:
            LogEnhanced.warn(.rtk, "RTK runtime summary", metadata: metadata)
        }
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
        reason: RTKDecisionReason,
        deferred: Bool,
        delayToActivateMs: Int?,
        debugNote: String?
    ) -> RTKDecisionEvent {
        currentMode = mode
        recalcCount += 1
        reasonBreakdown[reason, default: 0] += 1
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
        let event = RTKDecisionEvent(
            sessionID: sessionID,
            mode: mode,
            override: override,
            isAIActive: isAIActive,
            previousState: previousState,
            nextState: nextState,
            reason: reason,
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

    private func logDecisionEvent(_ event: RTKDecisionEvent) {
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
            LogEnhanced.info(.rtk, "RTK decision", metadata: metadata)
        } else {
            LogEnhanced.trace(.rtk, "RTK decision unchanged", metadata: metadata)
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

    private func appendRecentDecision(_ event: RTKDecisionEvent) {
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
