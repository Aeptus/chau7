import Foundation

// MARK: - Token Optimization Mode

/// Global mode controlling when token optimization is active across tabs.
public enum TokenOptimizationMode: String, CaseIterable, Codable, Sendable {
    /// Token optimization disabled entirely — no PATH injection, no flag files.
    case off

    /// Every tab, every command — flag files always created.
    case allTabs

    /// Only when an AI CLI is detected via `activeAppName`.
    case aiOnly

    /// Per-tab manual control — default off, user opts in.
    case manual
}

// MARK: - Per-Tab Override

/// Per-tab override for token optimization, allowing users to force-on or
/// force-off regardless of the global mode.
public enum TabTokenOptOverride: String, Codable, CaseIterable, Sendable {
    /// Follow the global mode's default behavior.
    case `default`

    /// Always active, regardless of global mode.
    case forceOn

    /// Never active, regardless of global mode.
    case forceOff
}

// MARK: - Decision Logic

/// Result of a CTO flag recalculation.
public struct CTOFlagDecision: Equatable, Sendable {
    public let previousState: Bool
    public let nextState: Bool
    public let changed: Bool

    public init(previousState: Bool, nextState: Bool, changed: Bool) {
        self.previousState = previousState
        self.nextState = nextState
        self.changed = changed
    }
}

/// Determines whether token optimization should be active for a given tab's state.
///
/// This is the single source of truth for the entire decision matrix:
/// - `.off` mode: never active
/// - `.forceOff` override: never active
/// - `.forceOn` override: always active
/// - `.allTabs` + `.default`: active
/// - `.aiOnly` + `.default`: active only when AI is detected
/// - `.manual` + `.default`: inactive
public func shouldBeActive(
    mode: TokenOptimizationMode,
    override: TabTokenOptOverride,
    isAIActive: Bool
) -> Bool {
    switch (mode, override) {
    case (.off, _): return false
    case (_, .forceOff): return false
    case (_, .forceOn): return true
    case (.allTabs, .default): return true
    case (.aiOnly, .default): return isAIActive
    case (.manual, .default): return false
    }
}

/// Human-readable decision reason used by runtime monitoring.
public func decisionReason(
    mode: TokenOptimizationMode,
    override: TabTokenOptOverride,
    isAIActive: Bool
) -> CTODecisionReason {
    if mode == .off { return .off }
    if override == .forceOn { return .forceOn }
    if override == .forceOff { return .forceOff }

    switch mode {
    case .allTabs:
        return .allTabsDefault
    case .aiOnly:
        return isAIActive ? .aiOnlyWithAI : .aiOnlyWithoutAI
    case .manual:
        return .manualDefault
    case .off:
        return .off
    }
}

// MARK: - Decision Reason

/// Runtime telemetry **resolution** reason for token-optimization decisions —
/// which rule in `decisionReason(mode:override:isAIActive:)` produced the
/// final flag state. Sibling of `CTODecisionTrigger`, which captures the
/// *event* that caused the recalc; reason answers "what's the new state and
/// why", trigger answers "what made us re-check".
public enum CTODecisionReason: String, Codable, Sendable {
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

/// What caused a recalc to fire. Recorded alongside `CTODecisionReason` so
/// `reasonBreakdown` can answer questions like "of the 153 unchanged
/// recalcs today, how many were `.aiStateChanged` no-ops?" — the partition
/// the `.lowChangeRate` health rule wants to distinguish (jitter in the
/// active-app signal vs. genuine flap of mode/override).
public enum CTODecisionTrigger: String, Codable, Sendable {
    /// Process-tree or shell-integration update flipped `activeAppName` or
    /// `liveAgentName`. Dominant source of no-op recalcs.
    case aiStateChanged
    /// Global `tokenOptimizationMode` setting changed via Settings or MCP.
    case modeChanged
    /// Per-tab `tokenOptOverride` changed (Settings, command palette, MCP).
    case overrideChanged
    /// First prompt after shell init flushed a deferred-flag set.
    case shellInitialized
    /// Tab / split-pane close path defensive cleanup.
    case sessionClosed
    /// Initial recalc as a session's `setup()` finishes — the legacy "we
    /// don't know yet" bucket; should narrow as more call sites adopt
    /// explicit triggers.
    case initialEvaluation
}

// MARK: - Runtime Health

public enum CTORuntimeHealthState: String, Codable, Sendable {
    case healthy
    case warning
    case critical
}

public enum CTORuntimeAssessmentIssue: String, Codable, Equatable, Sendable {
    case lowChangeRate
    case highDeferredSkips
    case lowDeferredFlushRate
    case staleDecisions
    case modeOffWithTrackedSessions
    case lowDecisionThroughput
}

public struct CTORuntimeAssessment: Codable, Equatable, Sendable {
    public let state: CTORuntimeHealthState
    public let score: Int
    public let issues: [CTORuntimeAssessmentIssue]
    public let summary: String

    public init(state: CTORuntimeHealthState, score: Int, issues: [CTORuntimeAssessmentIssue], summary: String) {
        self.state = state
        self.score = score
        self.issues = issues
        self.summary = summary
    }
}

// MARK: - Decision Event

/// Single decision event used by the debug stats panel.
public struct CTODecisionEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let sessionID: String
    public let mode: String
    public let override: String
    public let isAIActive: Bool
    public let previousState: Bool
    public let nextState: Bool
    public let changed: Bool
    public let reason: CTODecisionReason
    /// What event prompted the recalc. Optional for source-compat with
    /// pre-1.2 call sites that didn't supply this; new call sites should
    /// always pass a meaningful trigger.
    public let trigger: CTODecisionTrigger?
    public let deferred: Bool
    public let delayToActivateMs: Int?
    public let debugNote: String?

    public init(
        sessionID: String,
        mode: TokenOptimizationMode,
        override: TabTokenOptOverride,
        isAIActive: Bool,
        previousState: Bool,
        nextState: Bool,
        reason: CTODecisionReason,
        trigger: CTODecisionTrigger? = nil,
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
        self.trigger = trigger
        self.deferred = deferred
        self.delayToActivateMs = delayToActivateMs
        self.debugNote = debugNote
    }
}

// MARK: - Runtime Snapshot

/// Snapshot of runtime counters shown in settings/debug views.
public struct CTORuntimeSnapshot: Codable, Equatable, Sendable {
    public let mode: String
    public let recalcCount: Int
    public let createdCount: Int
    public let removedCount: Int
    public let unchangedCount: Int
    public let deferredSetCount: Int
    public let deferredFlushCount: Int
    public let deferredSkipCount: Int
    /// Count of `deferredSet` calls that were *cancelled* before reaching
    /// the first prompt (session closed, mode flipped to `.off`, …).
    /// Subtracted from `deferredSetCount` when computing
    /// `deferredFlushRatePercent` so the rate reflects only sessions that
    /// had a real chance to flush.
    public let deferredCancelCount: Int
    public let setupCount: Int
    public let teardownCount: Int
    public let modeChangeCount: Int
    public let lastModeChangeAt: Date?
    public let lastDecisionAt: Date?
    public let lastDecision: CTODecisionEvent?
    public let activeSessionCount: Int
    public let trackedSessions: Int
    public let pendingDeferredSessions: Int
    public let reasonBreakdown: [String: Int]
    /// Per-trigger counts of recalcs since the last reset. Keys are
    /// `CTODecisionTrigger.rawValue`. Empty for snapshots taken from
    /// pre-1.2 callers that didn't pass a trigger.
    public let triggerBreakdown: [String: Int]
    public let deferredFlushDelayCount: Int
    public let deferredFlushDelayMinMs: Int?
    public let deferredFlushDelayMaxMs: Int?
    public let deferredFlushDelayAverageMs: Double?
    public let deferredFlushDelayLastMs: Int?
    public let recentDecisions: [CTODecisionEvent]
    public let firstSeenAt: Date
    public let uptimeSeconds: Int
    public let decisionsPerMinute: Double
    /// Most recent `chau7-optim gain` sample, if any. Polled by
    /// `CTOManager` while `tokenOptimizationMode` is non-`.off`. Nil when
    /// the optimizer is not installed, the poller hasn't fired yet, or
    /// the helper returned no data.
    public let gainStats: CTOGainStats?
    /// Wall-clock time of the most recent successful `gainStats` sample.
    /// Used by diagnostic views to age out stale numbers.
    public let gainStatsLastSampledAt: Date?

    public init(
        mode: String,
        recalcCount: Int,
        createdCount: Int,
        removedCount: Int,
        unchangedCount: Int,
        deferredSetCount: Int,
        deferredFlushCount: Int,
        deferredSkipCount: Int,
        deferredCancelCount: Int = 0,
        setupCount: Int,
        teardownCount: Int,
        modeChangeCount: Int,
        lastModeChangeAt: Date?,
        lastDecisionAt: Date?,
        lastDecision: CTODecisionEvent?,
        activeSessionCount: Int,
        trackedSessions: Int,
        pendingDeferredSessions: Int,
        reasonBreakdown: [String: Int],
        triggerBreakdown: [String: Int] = [:],
        deferredFlushDelayCount: Int,
        deferredFlushDelayMinMs: Int?,
        deferredFlushDelayMaxMs: Int?,
        deferredFlushDelayAverageMs: Double?,
        deferredFlushDelayLastMs: Int?,
        recentDecisions: [CTODecisionEvent],
        firstSeenAt: Date,
        uptimeSeconds: Int,
        decisionsPerMinute: Double,
        gainStats: CTOGainStats? = nil,
        gainStatsLastSampledAt: Date? = nil
    ) {
        self.mode = mode
        self.recalcCount = recalcCount
        self.createdCount = createdCount
        self.removedCount = removedCount
        self.unchangedCount = unchangedCount
        self.deferredSetCount = deferredSetCount
        self.deferredFlushCount = deferredFlushCount
        self.deferredSkipCount = deferredSkipCount
        self.deferredCancelCount = deferredCancelCount
        self.setupCount = setupCount
        self.teardownCount = teardownCount
        self.modeChangeCount = modeChangeCount
        self.lastModeChangeAt = lastModeChangeAt
        self.lastDecisionAt = lastDecisionAt
        self.lastDecision = lastDecision
        self.activeSessionCount = activeSessionCount
        self.trackedSessions = trackedSessions
        self.pendingDeferredSessions = pendingDeferredSessions
        self.reasonBreakdown = reasonBreakdown
        self.triggerBreakdown = triggerBreakdown
        self.deferredFlushDelayCount = deferredFlushDelayCount
        self.deferredFlushDelayMinMs = deferredFlushDelayMinMs
        self.deferredFlushDelayMaxMs = deferredFlushDelayMaxMs
        self.deferredFlushDelayAverageMs = deferredFlushDelayAverageMs
        self.deferredFlushDelayLastMs = deferredFlushDelayLastMs
        self.recentDecisions = recentDecisions
        self.firstSeenAt = firstSeenAt
        self.uptimeSeconds = uptimeSeconds
        self.decisionsPerMinute = decisionsPerMinute
        self.gainStats = gainStats
        self.gainStatsLastSampledAt = gainStatsLastSampledAt
    }
}

public extension CTORuntimeSnapshot {
    var isStableState: Bool {
        isStableCTORuntimeState(
            recalcCount: recalcCount,
            unchangedCount: unchangedCount,
            activeSessionCount: activeSessionCount
        )
    }

    var decisionsChangeRatePercent: Double {
        guard recalcCount > 0 else { return 0 }
        let changedCount = max(0, recalcCount - unchangedCount)
        return (Double(changedCount) / Double(recalcCount)) * 100
    }

    /// Denominator for the deferred-flush / skip rate metrics: total
    /// deferred-sets that had a chance to flush, i.e. excluding cancels
    /// (session closed before first prompt, mode flipped to .off, …).
    var deferredEligibleCount: Int {
        max(0, deferredSetCount - deferredCancelCount)
    }

    var deferredSkipRatePercent: Double {
        guard deferredEligibleCount > 0 else { return 0 }
        let ratio = Double(deferredSkipCount) / Double(deferredEligibleCount)
        return min(max(ratio, 0), 1) * 100
    }

    var deferredFlushRatePercent: Double {
        guard deferredEligibleCount > 0 else { return 0 }
        let ratio = Double(deferredFlushCount) / Double(deferredEligibleCount)
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

    var assessment: CTORuntimeAssessment {
        var score = 100
        var issues: [CTORuntimeAssessmentIssue] = []

        // Each rule below contributes a *continuous* deduction proportional
        // to how far the current value is past its threshold. The previous
        // implementation used binary cliffs (e.g. 29.9% change rate got the
        // same -30 hit as 1%), which gave the user no way to tell "mildly
        // off" from "wildly broken" and made the score state jump abruptly
        // when a single recalculation crossed a boundary.

        // Low change rate only matters while the system is still settling.
        // Once stable (`isStableCTORuntimeState`), a low change rate means
        // convergence — that's healthy and the rule is skipped.
        if recalcCount > 0, !isStableState {
            let penalty = CTOHealthScoring.lowChangeRatePenalty(changeRatePercent: decisionsChangeRatePercent)
            if penalty > 0 {
                score -= penalty
                issues.append(.lowChangeRate)
            }
        }

        // Skip / flush rates need enough samples before they're meaningful
        // (>= 5 *eligible* deferred sets, i.e. excluding cancelled defers).
        if deferredEligibleCount >= 5 {
            let skipPenalty = CTOHealthScoring.highDeferredSkipsPenalty(skipRatePercent: deferredSkipRatePercent)
            if skipPenalty > 0 {
                score -= skipPenalty
                issues.append(.highDeferredSkips)
            }
            let flushPenalty = CTOHealthScoring.lowDeferredFlushRatePenalty(flushRatePercent: deferredFlushRatePercent)
            if flushPenalty > 0 {
                score -= flushPenalty
                issues.append(.lowDeferredFlushRate)
            }
        }

        // Stale decisions only matter if sessions are actively running.
        // In steady state with all tabs idle/settled, no decisions is correct.
        if let age = ageSinceLastDecisionSeconds, activeSessionCount > 0, !isStableState {
            let penalty = CTOHealthScoring.staleDecisionsPenalty(ageSinceLastDecisionSeconds: age)
            if penalty > 0 {
                score -= penalty
                issues.append(.staleDecisions)
            }
        }

        if mode == TokenOptimizationMode.off.rawValue, trackedSessions > 0 {
            // Mode-off is binary by nature — it's either on or off — so this
            // rule keeps its flat deduction.
            score -= 20
            issues.append(.modeOffWithTrackedSessions)
        }

        if recalcCount == 0, trackedSessions > 0, uptimeSeconds >= 60 {
            // Same — either the engine has run or it hasn't.
            score -= 10
            issues.append(.lowDecisionThroughput)
        }

        let normalizedScore = max(0, min(100, score))
        let state: CTORuntimeHealthState = normalizedScore >= 85
            ? .healthy
            : normalizedScore >= 65
            ? .warning
            : .critical

        let summary = switch state {
        case .healthy:
            "healthy"
        case .warning:
            "needsReview"
        case .critical:
            "requiresAttention"
        }

        return CTORuntimeAssessment(
            state: state,
            score: normalizedScore,
            issues: issues,
            summary: summary
        )
    }
}

// MARK: - State Snapshot for Disk Export

/// Compact diagnostic snapshot of CTO state, written alongside the per-session
/// `cto_active/<session-id>` flag files at `~/.chau7/cto_state.json` whenever
/// the engine's decision state changes. The wrapper scripts continue to read
/// flag files (their hot-path `[ -f $flag ]` check is a single `stat()`), so
/// this file is purely a diagnostic mirror — humans, bug reports, and
/// external tooling can inspect "what does Chau7 currently think CTO is
/// doing" without scraping multiple files.
///
/// Schema version is recorded so future readers can detect older / newer
/// layouts. Bump it whenever the meaning of any field changes (additive
/// fields don't require a bump).
public struct CTOStateSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let mode: String
    public let updatedAt: Date
    public let activeSessions: [String]
    public let trackedSessions: [String]
    public let deferredSessions: [String]
    public let gainStats: CTOGainStats?

    public init(
        schemaVersion: Int = CTOStateSnapshot.currentSchemaVersion,
        mode: String,
        updatedAt: Date,
        activeSessions: [String],
        trackedSessions: [String],
        deferredSessions: [String],
        gainStats: CTOGainStats? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.updatedAt = updatedAt
        self.activeSessions = activeSessions
        self.trackedSessions = trackedSessions
        self.deferredSessions = deferredSessions
        self.gainStats = gainStats
    }
}

// MARK: - Assessment Transitions

/// Describes a transition between two consecutive `CTORuntimeAssessment`
/// emissions for the runtime-state-change log line. Pure-data result of
/// comparing two assessments so the comparison logic can be unit-tested
/// in the core target.
public enum CTOAssessmentTransition: Equatable, Sendable {
    /// First emission since reset / launch — no previous assessment to
    /// compare to. Carries the initial state for the log line so timelines
    /// have an anchor.
    case initial(state: CTORuntimeHealthState, score: Int, issues: [CTORuntimeAssessmentIssue])
    /// State worsened (e.g. healthy → warning, warning → critical).
    /// `metadata` is the pre-formatted dictionary for `LogEnhanced`.
    case degraded(metadata: [String: String])
    /// State improved (e.g. warning → healthy, critical → warning).
    case recovered(metadata: [String: String])

    /// Compute the transition (if any) between `previous` and `current`.
    /// Returns nil when both assessments share the same `state` — score
    /// movement within the same state band is observable through
    /// `emitSummary` already and doesn't need its own line.
    public static func between(
        previous: CTORuntimeAssessment?, current: CTORuntimeAssessment
    ) -> CTOAssessmentTransition? {
        guard let previous else {
            return .initial(state: current.state, score: current.score, issues: current.issues)
        }
        guard previous.state != current.state else { return nil }

        let previousIssues = Set(previous.issues)
        let currentIssues = Set(current.issues)
        let addedIssues = currentIssues.subtracting(previousIssues).map(\.rawValue).sorted()
        let resolvedIssues = previousIssues.subtracting(currentIssues).map(\.rawValue).sorted()

        let metadata: [String: String] = [
            "from": previous.state.rawValue,
            "to": current.state.rawValue,
            "scoreFrom": "\(previous.score)",
            "scoreTo": "\(current.score)",
            "scoreDelta": "\(current.score - previous.score)",
            "addedIssues": addedIssues.joined(separator: ","),
            "resolvedIssues": resolvedIssues.joined(separator: ",")
        ]

        return current.score > previous.score
            ? .recovered(metadata: metadata)
            : .degraded(metadata: metadata)
    }
}

// MARK: - Health Scoring

/// Continuous-scoring functions for each CTO health rule. Pulled into a
/// caseless enum so they're independently testable (per-rule partition
/// coverage) without exercising the full `CTORuntimeSnapshot` constructor.
public enum CTOHealthScoring {

    /// `.lowChangeRate` rule: change rate in [0, 30] maps to penalty
    /// [maxPenalty, 0]. At or above 30%, no penalty.
    public static let lowChangeRateThresholdPercent = 30.0
    public static let lowChangeRateMaxPenalty = 30

    public static func lowChangeRatePenalty(changeRatePercent: Double) -> Int {
        proportionalPenalty(
            value: changeRatePercent,
            threshold: lowChangeRateThresholdPercent,
            worstCase: 0,
            maxPenalty: lowChangeRateMaxPenalty
        )
    }

    /// `.highDeferredSkips` rule: skip rate in [35, 100] maps to penalty
    /// [0, maxPenalty]. At or below 35%, no penalty.
    public static let highDeferredSkipsThresholdPercent = 35.0
    public static let highDeferredSkipsMaxPenalty = 30

    public static func highDeferredSkipsPenalty(skipRatePercent: Double) -> Int {
        proportionalPenalty(
            value: skipRatePercent,
            threshold: highDeferredSkipsThresholdPercent,
            worstCase: 100,
            maxPenalty: highDeferredSkipsMaxPenalty
        )
    }

    /// `.lowDeferredFlushRate` rule: flush rate in [0, 80] maps to penalty
    /// [maxPenalty, 0]. At or above 80%, no penalty.
    public static let lowDeferredFlushRateThresholdPercent = 80.0
    public static let lowDeferredFlushRateMaxPenalty = 20

    public static func lowDeferredFlushRatePenalty(flushRatePercent: Double) -> Int {
        proportionalPenalty(
            value: flushRatePercent,
            threshold: lowDeferredFlushRateThresholdPercent,
            worstCase: 0,
            maxPenalty: lowDeferredFlushRateMaxPenalty
        )
    }

    /// `.staleDecisions` rule: age in [300, 1800] seconds maps to penalty
    /// [0, maxPenalty]. At or under 5 min, no penalty; at or over 30 min,
    /// the full hit. The previous binary "any age > 300s → -15" turned
    /// short idle pauses into the same severity as multi-hour silence.
    public static let staleDecisionsThresholdSeconds = 300
    public static let staleDecisionsWorstSeconds = 1800
    public static let staleDecisionsMaxPenalty = 15

    public static func staleDecisionsPenalty(ageSinceLastDecisionSeconds age: Int) -> Int {
        proportionalPenalty(
            value: Double(age),
            threshold: Double(staleDecisionsThresholdSeconds),
            worstCase: Double(staleDecisionsWorstSeconds),
            maxPenalty: staleDecisionsMaxPenalty
        )
    }

    /// Compute a penalty proportional to how far `value` has moved from
    /// `threshold` toward `worstCase`. Returns 0 when `value` is on the
    /// "healthy" side of `threshold`, and `maxPenalty` at or past
    /// `worstCase`. Handles both increasing (skip rate, age) and decreasing
    /// (change rate, flush rate) severity directions by checking which
    /// side of the threshold is worse.
    private static func proportionalPenalty(
        value: Double, threshold: Double, worstCase: Double, maxPenalty: Int
    ) -> Int {
        let span = worstCase - threshold
        guard span != 0 else { return 0 }
        let normalized: Double
        if span > 0 {
            // Severity increases as value grows past threshold.
            normalized = (value - threshold) / span
        } else {
            // Severity increases as value falls below threshold.
            normalized = (threshold - value) / -span
        }
        let clamped = min(max(normalized, 0), 1)
        return Int((Double(maxPenalty) * clamped).rounded())
    }
}

/// A runtime state is stable when the decision engine has converged: it has
/// observed enough recalculations and most of them resolved to no-ops.
/// Convergence does *not* require zero active sessions — an AI session can
/// be active and the system can be stable; "stable" means "further recalcs
/// keep returning the same flag state", which is the correct steady-state
/// when AI tabs have settled on their flag.
///
/// The previous definition also required `activeSessionCount == 0`, which
/// made the system effectively never-stable for any user with an AI tab
/// open. That caused the `.lowChangeRate` health issue to fire on every
/// session whose flag was correctly converged-and-set — the opposite of
/// what the health metric was supposed to catch.
public func isStableCTORuntimeState(
    recalcCount: Int,
    unchangedCount: Int,
    activeSessionCount _: Int = 0
) -> Bool {
    recalcCount >= 10 && unchangedCount > recalcCount / 2
}

// MARK: - Gain Statistics

/// Token savings data returned by `chau7-optim gain --format json`.
public struct CTOGainStats: Codable, Equatable, Sendable {
    public let commands: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let savedTokens: Int
    public let savingsPct: Double
    public let totalTimeMs: Int
    public let avgTimeMs: Int

    public enum CodingKeys: String, CodingKey {
        case commands = "total_commands"
        case inputTokens = "total_input"
        case outputTokens = "total_output"
        case savedTokens = "total_saved"
        case savingsPct = "avg_savings_pct"
        case totalTimeMs = "total_time_ms"
        case avgTimeMs = "avg_time_ms"
    }

    public init(
        commands: Int,
        inputTokens: Int,
        outputTokens: Int,
        savedTokens: Int,
        savingsPct: Double,
        totalTimeMs: Int,
        avgTimeMs: Int
    ) {
        self.commands = commands
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.savedTokens = savedTokens
        self.savingsPct = savingsPct
        self.totalTimeMs = totalTimeMs
        self.avgTimeMs = avgTimeMs
    }
}

// MARK: - Per-Tab Token Consumption

/// AI token usage aggregated per tab from the telemetry database.
public struct TabTokenConsumption: Identifiable, Sendable {
    public let tabID: String
    public let runCount: Int
    public let pricedRunCount: Int
    public let missingCostRunCount: Int
    public let totalInputTokens: Int
    public let totalCachedInputTokens: Int
    public let totalOutputTokens: Int
    public let totalReasoningOutputTokens: Int
    public let totalCostUSD: Double
    /// Most recent provider for this tab (e.g. "claude"), for label display when the tab is closed.
    public let lastProvider: String?
    /// Most recent repo path for this tab, falling back to the last working directory.
    public let lastLocationPath: String?
    public var id: String {
        tabID
    }

    public init(
        tabID: String,
        runCount: Int,
        pricedRunCount: Int = 0,
        missingCostRunCount: Int = 0,
        totalInputTokens: Int,
        totalCachedInputTokens: Int = 0,
        totalOutputTokens: Int,
        totalReasoningOutputTokens: Int = 0,
        totalCostUSD: Double,
        lastProvider: String? = nil,
        lastLocationPath: String? = nil
    ) {
        self.tabID = tabID
        self.runCount = runCount
        self.pricedRunCount = pricedRunCount
        self.missingCostRunCount = missingCostRunCount
        self.totalInputTokens = totalInputTokens
        self.totalCachedInputTokens = totalCachedInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalReasoningOutputTokens = totalReasoningOutputTokens
        self.totalCostUSD = totalCostUSD
        self.lastProvider = lastProvider
        self.lastLocationPath = lastLocationPath
    }

    public var totalBillableTokens: Int {
        totalInputTokens + totalCachedInputTokens + totalOutputTokens + totalReasoningOutputTokens
    }
}

/// AI token usage aggregated per provider from the telemetry database.
public struct ProviderConsumptionStats: Identifiable, Sendable {
    public let provider: String
    public let runCount: Int
    public let pricedRunCount: Int
    public let missingCostRunCount: Int
    public let totalInputTokens: Int
    public let totalCachedInputTokens: Int
    public let totalOutputTokens: Int
    public let totalReasoningOutputTokens: Int
    public let totalCostUSD: Double
    public var id: String {
        provider
    }

    public init(
        provider: String,
        runCount: Int,
        pricedRunCount: Int = 0,
        missingCostRunCount: Int = 0,
        totalInputTokens: Int,
        totalCachedInputTokens: Int = 0,
        totalOutputTokens: Int,
        totalReasoningOutputTokens: Int = 0,
        totalCostUSD: Double
    ) {
        self.provider = provider
        self.runCount = runCount
        self.pricedRunCount = pricedRunCount
        self.missingCostRunCount = missingCostRunCount
        self.totalInputTokens = totalInputTokens
        self.totalCachedInputTokens = totalCachedInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalReasoningOutputTokens = totalReasoningOutputTokens
        self.totalCostUSD = totalCostUSD
    }

    public var totalBillableTokens: Int {
        totalInputTokens + totalCachedInputTokens + totalOutputTokens + totalReasoningOutputTokens
    }
}

// MARK: - Rewrite Map & Supported Commands

/// Maps shell command names to their optimizer subcommand equivalents.
/// Commands in this map are routed through `chau7-optim` when active.
public let ctoRewriteMap: [String: String] = [
    "cat": "read",
    "ls": "ls",
    "find": "find",
    "tree": "tree",
    "grep": "grep",
    "rg": "rg",
    "git": "git",
    "diff": "diff",
    "cargo": "cargo",
    "curl": "curl",
    "docker": "docker",
    "kubectl": "kubectl",
    "gh": "gh",
    "pnpm": "pnpm",
    "wget": "wget",
    "npm": "npm",
    "npx": "npx",
    "vitest": "vitest",
    "prisma": "prisma",
    "tsc": "tsc",
    "next": "next",
    "lint": "lint",
    "prettier": "prettier",
    "format": "format",
    "playwright": "playwright",
    "ruff": "ruff",
    "pytest": "pytest",
    "pip": "pip",
    "go": "go",
    "golangci-lint": "golangci-lint",
    "swift": "swift",
    "python": "python",
    "python3": "python",
    "sed": "read" // sed -n 'range p' file → chau7-optim read
]

/// Commands that are exec-only (no optimizer subcommand mapping).
public let execOnlyCommands: Set = ["head", "tail", "wc"]

/// Commands that are commonly used as pipe filters (`cmd | grep pattern`).
/// When stdin is piped (not a terminal), these wrappers skip the optimizer
/// and exec the real binary directly — the output IS the data stream.
public let pipeFilterCommands: Set = ["grep", "rg", "diff", "sed"]

/// All commands that have wrapper scripts (optimizer-routed + exec-only).
public let supportedCommands: [String] = (Array(ctoRewriteMap.keys) + Array(execOnlyCommands)).sorted()

// MARK: - Wrapper Health

/// Per-command installation status.
public struct WrapperHealth: Identifiable, Sendable {
    public let command: String
    public let isInstalled: Bool
    public let isExecutable: Bool
    /// Whether this command routes through the optimizer (vs exec-only).
    public let hasCTORoute: Bool
    public var id: String {
        command
    }

    public init(command: String, isInstalled: Bool, isExecutable: Bool, hasCTORoute: Bool) {
        self.command = command
        self.isInstalled = isInstalled
        self.isExecutable = isExecutable
        self.hasCTORoute = hasCTORoute
    }
}
