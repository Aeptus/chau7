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
    case (.off, _):               return false
    case (_, .forceOff):           return false
    case (_, .forceOn):            return true
    case (.allTabs, .default):     return true
    case (.aiOnly, .default):      return isAIActive
    case (.manual, .default):      return false
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

/// Runtime telemetry reason for token optimization decisions.
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
    public let deferredFlushDelayCount: Int
    public let deferredFlushDelayMinMs: Int?
    public let deferredFlushDelayMaxMs: Int?
    public let deferredFlushDelayAverageMs: Double?
    public let deferredFlushDelayLastMs: Int?
    public let recentDecisions: [CTODecisionEvent]
    public let firstSeenAt: Date
    public let uptimeSeconds: Int
    public let decisionsPerMinute: Double

    public init(
        mode: String,
        recalcCount: Int,
        createdCount: Int,
        removedCount: Int,
        unchangedCount: Int,
        deferredSetCount: Int,
        deferredFlushCount: Int,
        deferredSkipCount: Int,
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
        deferredFlushDelayCount: Int,
        deferredFlushDelayMinMs: Int?,
        deferredFlushDelayMaxMs: Int?,
        deferredFlushDelayAverageMs: Double?,
        deferredFlushDelayLastMs: Int?,
        recentDecisions: [CTODecisionEvent],
        firstSeenAt: Date,
        uptimeSeconds: Int,
        decisionsPerMinute: Double
    ) {
        self.mode = mode
        self.recalcCount = recalcCount
        self.createdCount = createdCount
        self.removedCount = removedCount
        self.unchangedCount = unchangedCount
        self.deferredSetCount = deferredSetCount
        self.deferredFlushCount = deferredFlushCount
        self.deferredSkipCount = deferredSkipCount
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
        self.deferredFlushDelayCount = deferredFlushDelayCount
        self.deferredFlushDelayMinMs = deferredFlushDelayMinMs
        self.deferredFlushDelayMaxMs = deferredFlushDelayMaxMs
        self.deferredFlushDelayAverageMs = deferredFlushDelayAverageMs
        self.deferredFlushDelayLastMs = deferredFlushDelayLastMs
        self.recentDecisions = recentDecisions
        self.firstSeenAt = firstSeenAt
        self.uptimeSeconds = uptimeSeconds
        self.decisionsPerMinute = decisionsPerMinute
    }
}

public extension CTORuntimeSnapshot {
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

    var assessment: CTORuntimeAssessment {
        var score = 100
        var issues: [CTORuntimeAssessmentIssue] = []

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
        let state: CTORuntimeHealthState = normalizedScore >= 85
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

        return CTORuntimeAssessment(
            state: state,
            score: normalizedScore,
            issues: issues,
            summary: summary
        )
    }
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
]

/// Commands that are exec-only (no optimizer subcommand mapping).
public let execOnlyCommands: Set<String> = ["head", "tail", "wc"]

/// All commands that have wrapper scripts (optimizer-routed + exec-only).
public let supportedCommands: [String] = {
    (Array(ctoRewriteMap.keys) + Array(execOnlyCommands)).sorted()
}()

// MARK: - Wrapper Health

/// Per-command installation status.
public struct WrapperHealth: Identifiable, Sendable {
    public let command: String
    public let isInstalled: Bool
    public let isExecutable: Bool
    /// Whether this command routes through the optimizer (vs exec-only).
    public let hasCTORoute: Bool
    public var id: String { command }

    public init(command: String, isInstalled: Bool, isExecutable: Bool, hasCTORoute: Bool) {
        self.command = command
        self.isInstalled = isInstalled
        self.isExecutable = isExecutable
        self.hasCTORoute = hasCTORoute
    }
}
