//! Token optimization (CTO): modes, per-tab override, activation decision,
//! runtime health assessment, gain stats, rewrite map and consumption models.
//!
//! Port of `TokenOptimization.swift` from `apps/chau7-macos/Sources/Chau7Core`.
//!
//! The Swift file contains no filesystem paths, so no function here takes one
//! (the wrapper folders `cto_bin` / `cto_active` belong to the app layer).
//!
//! Differences from Swift: `Date` values are `f64` seconds since the Swift
//! reference date (2001-01-01 UTC), which is how Swift's default `Codable`
//! writes dates, so snapshots stay byte-compatible. Functions that read the
//! clock in Swift have an `_at(now)` variant taking the current time in the
//! same unit. `override` is `override_mode` in Rust (reserved word); the JSON
//! key stays `override`.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

use crate::profile_rules::uuid_upper;

/// Seconds between the Unix epoch and the Swift reference date (2001-01-01).
const REFERENCE_DATE_UNIX_OFFSET: f64 = 978_307_200.0;

/// Current time as seconds since the Swift reference date.
pub fn reference_now() -> f64 {
    let unix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    unix - REFERENCE_DATE_UNIX_OFFSET
}

// MARK: - Modes

/// Global mode controlling when token optimization is active across tabs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TokenOptimizationMode {
    /// Disabled entirely: no PATH injection, no flag files.
    #[default]
    Off,
    /// Every tab, every command.
    AllTabs,
    /// Only when an AI CLI is detected.
    AiOnly,
    /// Per-tab manual control, default off.
    Manual,
}

impl TokenOptimizationMode {
    pub const ALL: [TokenOptimizationMode; 4] = [
        TokenOptimizationMode::Off,
        TokenOptimizationMode::AllTabs,
        TokenOptimizationMode::AiOnly,
        TokenOptimizationMode::Manual,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::AllTabs => "allTabs",
            Self::AiOnly => "aiOnly",
            Self::Manual => "manual",
        }
    }
}

/// Per-tab override, forcing optimization on or off regardless of the mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TabTokenOptOverride {
    /// Follow the global mode's default behavior.
    #[serde(rename = "default")]
    Default,
    /// Always active, regardless of global mode (except `off`).
    #[serde(rename = "forceOn")]
    ForceOn,
    /// Never active.
    #[serde(rename = "forceOff")]
    ForceOff,
}

impl TabTokenOptOverride {
    pub const ALL: [TabTokenOptOverride; 3] = [
        TabTokenOptOverride::Default,
        TabTokenOptOverride::ForceOn,
        TabTokenOptOverride::ForceOff,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::ForceOn => "forceOn",
            Self::ForceOff => "forceOff",
        }
    }
}

// MARK: - Decision logic

/// Result of a CTO flag recalculation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CTOFlagDecision {
    pub previous_state: bool,
    pub next_state: bool,
    pub changed: bool,
}

/// Whether token optimization should be active for a tab. Single source of
/// truth for the decision matrix.
pub fn should_be_active(
    mode: TokenOptimizationMode,
    override_mode: TabTokenOptOverride,
    is_ai_active: bool,
) -> bool {
    use TabTokenOptOverride as O;
    use TokenOptimizationMode as M;
    match (mode, override_mode) {
        (M::Off, _) => false,
        (_, O::ForceOff) => false,
        (_, O::ForceOn) => true,
        (M::AllTabs, O::Default) => true,
        (M::AiOnly, O::Default) => is_ai_active,
        (M::Manual, O::Default) => false,
    }
}

/// Human-readable decision reason used by runtime monitoring.
pub fn decision_reason(
    mode: TokenOptimizationMode,
    override_mode: TabTokenOptOverride,
    is_ai_active: bool,
) -> CTODecisionReason {
    if mode == TokenOptimizationMode::Off {
        return CTODecisionReason::Off;
    }
    if override_mode == TabTokenOptOverride::ForceOn {
        return CTODecisionReason::ForceOn;
    }
    if override_mode == TabTokenOptOverride::ForceOff {
        return CTODecisionReason::ForceOff;
    }
    match mode {
        TokenOptimizationMode::AllTabs => CTODecisionReason::AllTabsDefault,
        TokenOptimizationMode::AiOnly => {
            if is_ai_active {
                CTODecisionReason::AiOnlyWithAI
            } else {
                CTODecisionReason::AiOnlyWithoutAI
            }
        }
        TokenOptimizationMode::Manual => CTODecisionReason::ManualDefault,
        TokenOptimizationMode::Off => CTODecisionReason::Off,
    }
}

/// Runtime telemetry reason for token optimization decisions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CTODecisionReason {
    #[serde(rename = "off")]
    Off,
    #[serde(rename = "allTabsDefault")]
    AllTabsDefault,
    #[serde(rename = "aiOnlyWithAI")]
    AiOnlyWithAI,
    #[serde(rename = "aiOnlyWithoutAI")]
    AiOnlyWithoutAI,
    #[serde(rename = "manualDefault")]
    ManualDefault,
    #[serde(rename = "forceOn")]
    ForceOn,
    #[serde(rename = "forceOff")]
    ForceOff,
    #[serde(rename = "skippedDueToDeferred")]
    SkippedDueToDeferred,
    #[serde(rename = "unchanged")]
    Unchanged,
}

// MARK: - Runtime health

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CTORuntimeHealthState {
    Healthy,
    Warning,
    Critical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CTORuntimeAssessmentIssue {
    LowChangeRate,
    HighDeferredSkips,
    LowDeferredFlushRate,
    StaleDecisions,
    ModeOffWithTrackedSessions,
    LowDecisionThroughput,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CTORuntimeAssessment {
    pub state: CTORuntimeHealthState,
    pub score: i64,
    pub issues: Vec<CTORuntimeAssessmentIssue>,
    pub summary: String,
}

// MARK: - Decision event

/// Single decision event used by the debug stats panel.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CTODecisionEvent {
    #[serde(with = "uuid_upper")]
    pub id: Uuid,
    /// Seconds since the Swift reference date.
    pub timestamp: f64,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    pub mode: String,
    #[serde(rename = "override")]
    pub override_mode: String,
    #[serde(rename = "isAIActive")]
    pub is_ai_active: bool,
    pub previous_state: bool,
    pub next_state: bool,
    pub changed: bool,
    pub reason: CTODecisionReason,
    pub deferred: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delay_to_activate_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub debug_note: Option<String>,
}

impl CTODecisionEvent {
    /// Mirrors the Swift initializer: new id, timestamp is now, `deferred`
    /// false, `changed` true, no delay or note (set the pub fields to change).
    pub fn new(
        session_id: &str,
        mode: TokenOptimizationMode,
        override_mode: TabTokenOptOverride,
        is_ai_active: bool,
        previous_state: bool,
        next_state: bool,
        reason: CTODecisionReason,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            timestamp: reference_now(),
            session_id: session_id.to_string(),
            mode: mode.raw_value().to_string(),
            override_mode: override_mode.raw_value().to_string(),
            is_ai_active,
            previous_state,
            next_state,
            changed: true,
            reason,
            deferred: false,
            delay_to_activate_ms: None,
            debug_note: None,
        }
    }
}

// MARK: - Runtime snapshot

/// Snapshot of runtime counters shown in settings/debug views.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CTORuntimeSnapshot {
    pub mode: String,
    pub recalc_count: i64,
    pub created_count: i64,
    pub removed_count: i64,
    pub unchanged_count: i64,
    pub deferred_set_count: i64,
    pub deferred_flush_count: i64,
    pub deferred_skip_count: i64,
    pub setup_count: i64,
    pub teardown_count: i64,
    pub mode_change_count: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_mode_change_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_decision_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_decision: Option<CTODecisionEvent>,
    pub active_session_count: i64,
    pub tracked_sessions: i64,
    pub pending_deferred_sessions: i64,
    pub reason_breakdown: HashMap<String, i64>,
    pub deferred_flush_delay_count: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deferred_flush_delay_min_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deferred_flush_delay_max_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deferred_flush_delay_average_ms: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deferred_flush_delay_last_ms: Option<i64>,
    pub recent_decisions: Vec<CTODecisionEvent>,
    pub first_seen_at: f64,
    pub uptime_seconds: i64,
    pub decisions_per_minute: f64,
}

impl CTORuntimeSnapshot {
    pub fn is_stable_state(&self) -> bool {
        is_stable_cto_runtime_state(
            self.recalc_count,
            self.unchanged_count,
            self.active_session_count,
        )
    }

    pub fn decisions_change_rate_percent(&self) -> f64 {
        if self.recalc_count <= 0 {
            return 0.0;
        }
        let changed = (self.recalc_count - self.unchanged_count).max(0);
        (changed as f64 / self.recalc_count as f64) * 100.0
    }

    pub fn deferred_skip_rate_percent(&self) -> f64 {
        if self.deferred_set_count <= 0 {
            return 0.0;
        }
        let ratio = self.deferred_skip_count as f64 / self.deferred_set_count as f64;
        ratio.clamp(0.0, 1.0) * 100.0
    }

    pub fn deferred_flush_rate_percent(&self) -> f64 {
        if self.deferred_set_count <= 0 {
            return 0.0;
        }
        let ratio = self.deferred_flush_count as f64 / self.deferred_set_count as f64;
        ratio.clamp(0.0, 1.0) * 100.0
    }

    pub fn active_session_ratio_percent(&self) -> f64 {
        if self.tracked_sessions <= 0 {
            return 0.0;
        }
        (self.active_session_count as f64 / self.tracked_sessions as f64) * 100.0
    }

    /// Seconds since the last decision, relative to `now` (reference-date
    /// seconds). `None` when there was no decision.
    pub fn age_since_last_decision_seconds_at(&self, now: f64) -> Option<i64> {
        self.last_decision_at.map(|at| ((now - at) as i64).max(0))
    }

    pub fn age_since_last_decision_seconds(&self) -> Option<i64> {
        self.age_since_last_decision_seconds_at(reference_now())
    }

    fn decision_intervals_seconds(&self) -> Vec<f64> {
        if self.recent_decisions.len() <= 1 {
            return Vec::new();
        }
        let mut times: Vec<f64> = self.recent_decisions.iter().map(|d| d.timestamp).collect();
        times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        times.windows(2).map(|w| w[1] - w[0]).collect()
    }

    pub fn decision_interval_average_seconds(&self) -> Option<f64> {
        let intervals = self.decision_intervals_seconds();
        if intervals.is_empty() {
            return None;
        }
        Some(intervals.iter().sum::<f64>() / intervals.len() as f64)
    }

    pub fn decision_interval_min_seconds(&self) -> Option<f64> {
        self.decision_intervals_seconds()
            .into_iter()
            .reduce(f64::min)
    }

    pub fn decision_interval_max_seconds(&self) -> Option<f64> {
        self.decision_intervals_seconds()
            .into_iter()
            .reduce(f64::max)
    }

    /// Health assessment using the current time for the staleness check.
    pub fn assessment(&self) -> CTORuntimeAssessment {
        self.assessment_at(reference_now())
    }

    /// Health assessment relative to `now` (reference-date seconds).
    pub fn assessment_at(&self, now: f64) -> CTORuntimeAssessment {
        let mut score: i64 = 100;
        let mut issues = Vec::new();

        // Low change rate only matters while still settling.
        if self.recalc_count > 0
            && self.decisions_change_rate_percent() < 30.0
            && !self.is_stable_state()
        {
            score -= 30;
            issues.push(CTORuntimeAssessmentIssue::LowChangeRate);
        }

        // Need enough samples (>= 5 deferred) before percentages are meaningful.
        if self.deferred_set_count >= 5 && self.deferred_skip_rate_percent() > 35.0 {
            score -= 30;
            issues.push(CTORuntimeAssessmentIssue::HighDeferredSkips);
        }

        if self.deferred_set_count >= 5 && self.deferred_flush_rate_percent() < 80.0 {
            score -= 20;
            issues.push(CTORuntimeAssessmentIssue::LowDeferredFlushRate);
        }

        // Stale decisions only matter if sessions are actively running.
        let stale = self
            .age_since_last_decision_seconds_at(now)
            .is_some_and(|age| age > 300);
        if stale && self.active_session_count > 0 && !self.is_stable_state() {
            score -= 15;
            issues.push(CTORuntimeAssessmentIssue::StaleDecisions);
        }

        if self.mode == TokenOptimizationMode::Off.raw_value() && self.tracked_sessions > 0 {
            score -= 20;
            issues.push(CTORuntimeAssessmentIssue::ModeOffWithTrackedSessions);
        }

        if self.recalc_count == 0 && self.tracked_sessions > 0 && self.uptime_seconds >= 60 {
            score -= 10;
            issues.push(CTORuntimeAssessmentIssue::LowDecisionThroughput);
        }

        let normalized = score.clamp(0, 100);
        let state = if normalized >= 85 {
            CTORuntimeHealthState::Healthy
        } else if normalized >= 65 {
            CTORuntimeHealthState::Warning
        } else {
            CTORuntimeHealthState::Critical
        };
        let summary = match state {
            CTORuntimeHealthState::Healthy => "healthy",
            CTORuntimeHealthState::Warning => "needsReview",
            CTORuntimeHealthState::Critical => "requiresAttention",
        };
        CTORuntimeAssessment {
            state,
            score: normalized,
            issues,
            summary: summary.to_string(),
        }
    }
}

/// A runtime state is stable only after enough recalculations have converged
/// and no sessions remain actively tracked as on.
pub fn is_stable_cto_runtime_state(
    recalc_count: i64,
    unchanged_count: i64,
    active_session_count: i64,
) -> bool {
    recalc_count >= 10 && unchanged_count > recalc_count / 2 && active_session_count == 0
}

// MARK: - Gain statistics

/// Token savings data returned by `chau7-optim gain --format json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CTOGainStats {
    #[serde(rename = "total_commands")]
    pub commands: i64,
    #[serde(rename = "total_input")]
    pub input_tokens: i64,
    #[serde(rename = "total_output")]
    pub output_tokens: i64,
    #[serde(rename = "total_saved")]
    pub saved_tokens: i64,
    #[serde(rename = "avg_savings_pct")]
    pub savings_pct: f64,
    #[serde(rename = "total_time_ms")]
    pub total_time_ms: i64,
    #[serde(rename = "avg_time_ms")]
    pub avg_time_ms: i64,
}

// MARK: - Per-tab and per-provider consumption

/// AI token usage aggregated per tab from the telemetry database.
#[derive(Debug, Clone, PartialEq)]
pub struct TabTokenConsumption {
    pub tab_id: String,
    pub run_count: i64,
    pub priced_run_count: i64,
    pub missing_cost_run_count: i64,
    pub total_input_tokens: i64,
    pub total_cached_input_tokens: i64,
    pub total_output_tokens: i64,
    pub total_reasoning_output_tokens: i64,
    pub total_cost_usd: f64,
    /// Most recent provider for this tab (e.g. "claude").
    pub last_provider: Option<String>,
    /// Most recent repo path, falling back to the last working directory.
    pub last_location_path: Option<String>,
}

impl TabTokenConsumption {
    /// Optional counters default to 0 and optional strings to `None`.
    pub fn new(
        tab_id: &str,
        run_count: i64,
        total_input_tokens: i64,
        total_output_tokens: i64,
        total_cost_usd: f64,
    ) -> Self {
        Self {
            tab_id: tab_id.to_string(),
            run_count,
            priced_run_count: 0,
            missing_cost_run_count: 0,
            total_input_tokens,
            total_cached_input_tokens: 0,
            total_output_tokens,
            total_reasoning_output_tokens: 0,
            total_cost_usd,
            last_provider: None,
            last_location_path: None,
        }
    }

    pub fn id(&self) -> &str {
        &self.tab_id
    }

    pub fn total_billable_tokens(&self) -> i64 {
        self.total_input_tokens
            + self.total_cached_input_tokens
            + self.total_output_tokens
            + self.total_reasoning_output_tokens
    }
}

/// AI token usage aggregated per provider from the telemetry database.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ProviderConsumptionStats {
    pub provider: String,
    pub run_count: i64,
    pub priced_run_count: i64,
    pub missing_cost_run_count: i64,
    /// None is legacy/unknown; Some(0) means the queried runs had no token counters.
    #[serde(default)]
    pub token_observed_run_count: Option<i64>,
    pub total_input_tokens: i64,
    pub total_cached_input_tokens: i64,
    #[serde(default)]
    pub total_cache_creation_input_tokens: i64,
    #[serde(default)]
    pub total_cache_read_input_tokens: i64,
    pub total_output_tokens: i64,
    pub total_reasoning_output_tokens: i64,
    pub total_cost_usd: f64,
}

impl ProviderConsumptionStats {
    /// Optional counters default to 0.
    pub fn new(
        provider: &str,
        run_count: i64,
        total_input_tokens: i64,
        total_output_tokens: i64,
        total_cost_usd: f64,
    ) -> Self {
        Self {
            provider: provider.to_string(),
            run_count,
            priced_run_count: 0,
            missing_cost_run_count: 0,
            token_observed_run_count: None,
            total_input_tokens,
            total_cached_input_tokens: 0,
            total_cache_creation_input_tokens: 0,
            total_cache_read_input_tokens: 0,
            total_output_tokens,
            total_reasoning_output_tokens: 0,
            total_cost_usd,
        }
    }

    pub fn uncategorized_cached_input_tokens(&self) -> i64 {
        self.total_cached_input_tokens
            .saturating_sub(self.total_cache_creation_input_tokens)
            .saturating_sub(self.total_cache_read_input_tokens)
            .max(0)
    }

    pub fn id(&self) -> &str {
        &self.provider
    }

    pub fn total_billable_tokens(&self) -> i64 {
        self.total_input_tokens
            + self.total_cached_input_tokens
            + self.total_output_tokens
            + self.total_reasoning_output_tokens
    }
}

// MARK: - Rewrite map and supported commands

/// Shell command names mapped to their optimizer subcommand. Commands here are
/// routed through `chau7-optim` when active.
pub const CTO_REWRITE_MAP: [(&str, &str); 34] = [
    ("cat", "read"),
    ("ls", "ls"),
    ("find", "find"),
    ("tree", "tree"),
    ("grep", "grep"),
    ("rg", "rg"),
    ("git", "git"),
    ("diff", "diff"),
    ("cargo", "cargo"),
    ("curl", "curl"),
    ("docker", "docker"),
    ("kubectl", "kubectl"),
    ("gh", "gh"),
    ("pnpm", "pnpm"),
    ("wget", "wget"),
    ("npm", "npm"),
    ("npx", "npx"),
    ("vitest", "vitest"),
    ("prisma", "prisma"),
    ("tsc", "tsc"),
    ("next", "next"),
    ("lint", "lint"),
    ("prettier", "prettier"),
    ("format", "format"),
    ("playwright", "playwright"),
    ("ruff", "ruff"),
    ("pytest", "pytest"),
    ("pip", "pip"),
    ("go", "go"),
    ("golangci-lint", "golangci-lint"),
    ("swift", "swift"),
    ("python", "python"),
    ("python3", "python"),
    // sed -n 'range p' file -> chau7-optim read
    ("sed", "read"),
];

/// Optimizer subcommand for a shell command, if it is routed.
pub fn cto_rewrite(command: &str) -> Option<&'static str> {
    CTO_REWRITE_MAP
        .iter()
        .find(|(k, _)| *k == command)
        .map(|(_, v)| *v)
}

/// Commands that are exec-only (no optimizer subcommand mapping).
pub const EXEC_ONLY_COMMANDS: [&str; 3] = ["head", "tail", "wc"];

/// Commands commonly used as pipe filters (`cmd | grep pattern`). When stdin
/// is piped, their wrappers exec the real binary directly.
pub const PIPE_FILTER_COMMANDS: [&str; 4] = ["grep", "rg", "diff", "sed"];

/// All commands that have wrapper scripts (optimizer-routed plus exec-only),
/// sorted.
pub fn supported_commands() -> Vec<&'static str> {
    let mut all: Vec<&'static str> = CTO_REWRITE_MAP
        .iter()
        .map(|(k, _)| *k)
        .chain(EXEC_ONLY_COMMANDS)
        .collect();
    all.sort_unstable();
    all
}

// MARK: - Wrapper health

/// Per-command installation status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WrapperHealth {
    pub command: String,
    pub is_installed: bool,
    pub is_executable: bool,
    /// Whether this command routes through the optimizer (vs exec-only).
    pub has_cto_route: bool,
}

impl WrapperHealth {
    pub fn id(&self) -> &str {
        &self.command
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_cache_categories_preserve_legacy_defaults_and_billable_total() {
        let mut stats = ProviderConsumptionStats::new("claude", 1, 100, 10, 0.1);
        stats.total_cached_input_tokens = 75;
        stats.total_cache_creation_input_tokens = 20;
        stats.total_cache_read_input_tokens = 30;
        stats.total_reasoning_output_tokens = 2;
        assert_eq!(stats.uncategorized_cached_input_tokens(), 25);
        assert_eq!(stats.total_billable_tokens(), 187);
        let mut old = serde_json::to_value(&stats).unwrap();
        old.as_object_mut()
            .unwrap()
            .remove("total_cache_creation_input_tokens");
        old.as_object_mut()
            .unwrap()
            .remove("total_cache_read_input_tokens");
        old.as_object_mut()
            .unwrap()
            .remove("token_observed_run_count");
        let restored: ProviderConsumptionStats = serde_json::from_value(old).unwrap();
        assert_eq!(restored.token_observed_run_count, None);
        assert_eq!(restored.total_cache_creation_input_tokens, 0);
        assert_eq!(restored.total_cache_read_input_tokens, 0);
        assert_eq!(restored.uncategorized_cached_input_tokens(), 75);
        assert_eq!(restored.total_billable_tokens(), 187);
        stats.total_cache_read_input_tokens = 100;
        assert_eq!(stats.uncategorized_cached_input_tokens(), 0);
    }

    use TabTokenOptOverride as O;
    use TokenOptimizationMode as M;
    use std::collections::HashSet;

    #[test]
    fn test_off_mode_always_inactive() {
        assert!(!should_be_active(M::Off, O::Default, false));
        assert!(!should_be_active(M::Off, O::Default, true));
        assert!(!should_be_active(M::Off, O::ForceOn, false));
        assert!(!should_be_active(M::Off, O::ForceOff, true));
    }

    #[test]
    fn test_force_off_override_always_inactive() {
        for mode in [M::AllTabs, M::AiOnly, M::Manual] {
            assert!(!should_be_active(mode, O::ForceOff, false));
            assert!(!should_be_active(mode, O::ForceOff, true));
        }
    }

    #[test]
    fn test_force_on_override_always_active() {
        for mode in [M::AllTabs, M::AiOnly, M::Manual] {
            assert!(should_be_active(mode, O::ForceOn, false));
            assert!(should_be_active(mode, O::ForceOn, true));
        }
    }

    #[test]
    fn test_all_tabs_mode_default_override_always_active() {
        assert!(should_be_active(M::AllTabs, O::Default, false));
    }

    #[test]
    fn test_exhaustive_decision_matrix() {
        let cases = [
            (M::Off, O::Default, false, false),
            (M::Off, O::Default, true, false),
            (M::Off, O::ForceOn, false, false),
            (M::Off, O::ForceOn, true, false),
            (M::Off, O::ForceOff, false, false),
            (M::Off, O::ForceOff, true, false),
            (M::AllTabs, O::Default, false, true),
            (M::AllTabs, O::Default, true, true),
            (M::AllTabs, O::ForceOn, false, true),
            (M::AllTabs, O::ForceOn, true, true),
            (M::AllTabs, O::ForceOff, false, false),
            (M::AllTabs, O::ForceOff, true, false),
            (M::AiOnly, O::Default, false, false),
            (M::AiOnly, O::Default, true, true),
            (M::AiOnly, O::ForceOn, false, true),
            (M::AiOnly, O::ForceOn, true, true),
            (M::AiOnly, O::ForceOff, false, false),
            (M::AiOnly, O::ForceOff, true, false),
            (M::Manual, O::Default, false, false),
            (M::Manual, O::Default, true, false),
            (M::Manual, O::ForceOn, false, true),
            (M::Manual, O::ForceOn, true, true),
            (M::Manual, O::ForceOff, false, false),
            (M::Manual, O::ForceOff, true, false),
        ];
        for (mode, over, ai, expected) in cases {
            assert_eq!(
                should_be_active(mode, over, ai),
                expected,
                "{mode:?} {over:?} ai={ai}"
            );
        }
    }

    #[test]
    fn test_token_optimization_mode_all_cases() {
        assert_eq!(M::ALL.len(), 4);
        assert!(M::ALL.contains(&M::Off));
        assert!(M::ALL.contains(&M::AllTabs));
        assert!(M::ALL.contains(&M::AiOnly));
        assert!(M::ALL.contains(&M::Manual));
    }

    #[test]
    fn test_token_optimization_mode_codable() {
        for mode in M::ALL {
            let json = serde_json::to_string(&mode).unwrap();
            assert_eq!(json, format!("\"{}\"", mode.raw_value()));
            let decoded: M = serde_json::from_str(&json).unwrap();
            assert_eq!(decoded, mode);
        }
    }

    #[test]
    fn test_stable_runtime_state_requires_no_active_sessions() {
        assert!(!is_stable_cto_runtime_state(12, 10, 1));
        assert!(is_stable_cto_runtime_state(12, 10, 0));
    }

    #[test]
    fn test_tab_token_opt_override_all_cases() {
        assert_eq!(O::ALL.len(), 3);
        assert!(O::ALL.contains(&O::Default));
        assert!(O::ALL.contains(&O::ForceOn));
        assert!(O::ALL.contains(&O::ForceOff));
    }

    #[test]
    fn test_tab_token_opt_override_codable() {
        for over in O::ALL {
            let json = serde_json::to_string(&over).unwrap();
            let decoded: O = serde_json::from_str(&json).unwrap();
            assert_eq!(decoded, over);
        }
    }

    #[test]
    fn test_tab_token_opt_override_raw_values() {
        assert_eq!(O::Default.raw_value(), "default");
        assert_eq!(O::ForceOn.raw_value(), "forceOn");
        assert_eq!(O::ForceOff.raw_value(), "forceOff");
        assert_eq!(serde_json::to_string(&O::ForceOn).unwrap(), "\"forceOn\"");
    }

    #[test]
    fn test_rewrite_map_covers_expected_commands() {
        let expected: HashMap<&str, &str> = HashMap::from([
            ("cat", "read"),
            ("ls", "ls"),
            ("find", "find"),
            ("tree", "tree"),
            ("grep", "grep"),
            ("rg", "rg"),
            ("git", "git"),
            ("diff", "diff"),
            ("cargo", "cargo"),
            ("curl", "curl"),
            ("docker", "docker"),
            ("kubectl", "kubectl"),
            ("gh", "gh"),
            ("pnpm", "pnpm"),
            ("wget", "wget"),
            ("npm", "npm"),
            ("npx", "npx"),
            ("vitest", "vitest"),
            ("prisma", "prisma"),
            ("tsc", "tsc"),
            ("next", "next"),
            ("lint", "lint"),
            ("prettier", "prettier"),
            ("format", "format"),
            ("playwright", "playwright"),
            ("ruff", "ruff"),
            ("pytest", "pytest"),
            ("pip", "pip"),
            ("go", "go"),
            ("golangci-lint", "golangci-lint"),
            ("swift", "swift"),
            ("python", "python"),
            ("python3", "python"),
            ("sed", "read"),
        ]);
        assert_eq!(CTO_REWRITE_MAP.len(), expected.len());
        for (cmd, sub) in expected {
            assert_eq!(cto_rewrite(cmd), Some(sub), "{cmd}");
        }
    }

    #[test]
    fn test_rewrite_map_and_exec_only_are_mutually_exclusive() {
        for cmd in EXEC_ONLY_COMMANDS {
            assert!(cto_rewrite(cmd).is_none(), "{cmd} overlaps");
        }
    }

    #[test]
    fn test_rewrite_map_plus_exec_only_covers_supported_commands() {
        let covered: HashSet<&str> = CTO_REWRITE_MAP
            .iter()
            .map(|(k, _)| *k)
            .chain(EXEC_ONLY_COMMANDS)
            .collect();
        let supported: HashSet<&str> = supported_commands().into_iter().collect();
        assert_eq!(covered, supported);
    }

    #[test]
    fn test_supported_commands_is_derived_from_map_and_exec_only() {
        let commands = supported_commands();
        assert_eq!(
            commands.len(),
            CTO_REWRITE_MAP.len() + EXEC_ONLY_COMMANDS.len()
        );
        let mut sorted = commands.clone();
        sorted.sort_unstable();
        assert_eq!(commands, sorted);
    }

    #[test]
    fn test_exec_only_commands_are_subset() {
        let supported = supported_commands();
        for cmd in EXEC_ONLY_COMMANDS {
            assert!(supported.contains(&cmd));
        }
    }

    #[test]
    fn test_pipe_filter_commands_are_subset_of_rewrite_map() {
        for cmd in PIPE_FILTER_COMMANDS {
            assert!(cto_rewrite(cmd).is_some(), "{cmd}");
        }
    }

    #[test]
    fn test_gain_stats_decoding_round_trip() {
        let stats = CTOGainStats {
            commands: 42,
            input_tokens: 10000,
            output_tokens: 3000,
            saved_tokens: 7000,
            savings_pct: 70.0,
            total_time_ms: 1500,
            avg_time_ms: 36,
        };
        let json = serde_json::to_string(&stats).unwrap();
        let decoded: CTOGainStats = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, stats);
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(v.get("total_commands").is_some());
        assert!(v.get("total_input").is_some());
        assert!(v.get("total_output").is_some());
        assert!(v.get("total_saved").is_some());
    }

    #[test]
    fn test_gain_stats_decoding_from_optimizer_json() {
        let json = r#"{
            "total_commands": 100,
            "total_input": 50000,
            "total_output": 15000,
            "total_saved": 35000,
            "avg_savings_pct": 70.0,
            "total_time_ms": 5000,
            "avg_time_ms": 50
        }"#;
        let stats: CTOGainStats = serde_json::from_str(json).unwrap();
        assert_eq!(stats.commands, 100);
        assert_eq!(stats.input_tokens, 50000);
        assert_eq!(stats.output_tokens, 15000);
        assert_eq!(stats.saved_tokens, 35000);
        assert!((stats.savings_pct - 70.0).abs() < 0.001);
        assert_eq!(stats.total_time_ms, 5000);
        assert_eq!(stats.avg_time_ms, 50);
    }

    // Pure parts of the app-level runtime monitor tests

    fn decision_at(ts: f64) -> CTODecisionEvent {
        let mut e = CTODecisionEvent::new(
            "s",
            M::Manual,
            O::Default,
            false,
            false,
            false,
            CTODecisionReason::Unchanged,
        );
        e.timestamp = ts;
        e.changed = false;
        e
    }

    #[test]
    fn test_cto_runtime_assessment_signals() {
        // Four unchanged decisions, nothing deferred.
        let snapshot = CTORuntimeSnapshot {
            mode: "manual".into(),
            recalc_count: 4,
            unchanged_count: 4,
            tracked_sessions: 4,
            ..Default::default()
        };
        assert!(snapshot.decisions_change_rate_percent().abs() < 0.001);
        let a = snapshot.assessment_at(0.0);
        assert!(a.issues.contains(&CTORuntimeAssessmentIssue::LowChangeRate));
        assert_eq!(a.state, CTORuntimeHealthState::Warning);
        assert_eq!(a.score, 70);
        assert_eq!(a.summary, "needsReview");
        assert!(snapshot.deferred_skip_rate_percent().abs() < 0.001);
        assert!(snapshot.deferred_flush_rate_percent().abs() < 0.001);
        assert!(snapshot.active_session_ratio_percent().abs() < 0.001);
    }

    #[test]
    fn test_cto_runtime_decision_interval_stats() {
        let snapshot = CTORuntimeSnapshot {
            recent_decisions: vec![
                decision_at(3.0),
                decision_at(1.0),
                decision_at(1.5),
                decision_at(6.0),
            ],
            ..Default::default()
        };
        let min = snapshot.decision_interval_min_seconds().unwrap();
        let max = snapshot.decision_interval_max_seconds().unwrap();
        let avg = snapshot.decision_interval_average_seconds().unwrap();
        assert!((min - 0.5).abs() < 1e-9);
        assert!((max - 3.0).abs() < 1e-9);
        assert!((avg - 5.0 / 3.0).abs() < 1e-9);
        assert!(min <= avg && avg <= max);
        let one = CTORuntimeSnapshot {
            recent_decisions: vec![decision_at(1.0)],
            ..Default::default()
        };
        assert!(one.decision_interval_average_seconds().is_none());
    }

    #[test]
    fn test_assessment_deferred_and_stale_and_throughput() {
        let s = CTORuntimeSnapshot {
            mode: "off".into(),
            recalc_count: 0,
            tracked_sessions: 2,
            uptime_seconds: 60,
            deferred_set_count: 10,
            deferred_skip_count: 5,
            deferred_flush_count: 5,
            ..Default::default()
        };
        let a = s.assessment_at(0.0);
        assert_eq!(
            a.issues,
            vec![
                CTORuntimeAssessmentIssue::HighDeferredSkips,
                CTORuntimeAssessmentIssue::LowDeferredFlushRate,
                CTORuntimeAssessmentIssue::ModeOffWithTrackedSessions,
                CTORuntimeAssessmentIssue::LowDecisionThroughput,
            ]
        );
        assert_eq!(a.score, 20);
        assert_eq!(a.state, CTORuntimeHealthState::Critical);
        assert_eq!(a.summary, "requiresAttention");

        let stale = CTORuntimeSnapshot {
            mode: "aiOnly".into(),
            recalc_count: 5,
            unchanged_count: 1,
            active_session_count: 1,
            tracked_sessions: 1,
            last_decision_at: Some(100.0),
            ..Default::default()
        };
        assert_eq!(stale.age_since_last_decision_seconds_at(500.0), Some(400));
        assert!(
            stale
                .assessment_at(500.0)
                .issues
                .contains(&CTORuntimeAssessmentIssue::StaleDecisions)
        );
        assert!(stale.assessment_at(200.0).issues.is_empty());
        assert_eq!(stale.assessment_at(200.0).summary, "healthy");
    }

    #[test]
    fn test_decision_reason_matches_matrix() {
        assert_eq!(
            decision_reason(M::Off, O::ForceOn, true),
            CTODecisionReason::Off
        );
        assert_eq!(
            decision_reason(M::Manual, O::ForceOn, false),
            CTODecisionReason::ForceOn
        );
        assert_eq!(
            decision_reason(M::AiOnly, O::ForceOff, true),
            CTODecisionReason::ForceOff
        );
        assert_eq!(
            decision_reason(M::AllTabs, O::Default, false),
            CTODecisionReason::AllTabsDefault
        );
        assert_eq!(
            decision_reason(M::AiOnly, O::Default, true),
            CTODecisionReason::AiOnlyWithAI
        );
        assert_eq!(
            decision_reason(M::AiOnly, O::Default, false),
            CTODecisionReason::AiOnlyWithoutAI
        );
        assert_eq!(
            decision_reason(M::Manual, O::Default, true),
            CTODecisionReason::ManualDefault
        );
        assert_eq!(
            serde_json::to_string(&CTODecisionReason::AiOnlyWithAI).unwrap(),
            "\"aiOnlyWithAI\""
        );
    }

    #[test]
    fn test_decision_event_json_keys() {
        let e = CTODecisionEvent::new(
            "abc",
            M::AiOnly,
            O::ForceOn,
            true,
            false,
            true,
            CTODecisionReason::ForceOn,
        );
        let v: serde_json::Value = serde_json::to_value(&e).unwrap();
        assert_eq!(v["sessionID"], "abc");
        assert_eq!(v["override"], "forceOn");
        assert_eq!(v["mode"], "aiOnly");
        assert_eq!(v["isAIActive"], true);
        assert!(v.get("isAiActive").is_none());
        assert!(v.get("delayToActivateMs").is_none());
        assert!(v.get("debugNote").is_none());
        let back: CTODecisionEvent = serde_json::from_value(v).unwrap();
        assert_eq!(back, e);
    }

    #[test]
    fn test_snapshot_round_trip_and_rates() {
        let s = CTORuntimeSnapshot {
            mode: "manual".into(),
            recalc_count: 10,
            unchanged_count: 7,
            deferred_set_count: 4,
            deferred_skip_count: 8,
            deferred_flush_count: 2,
            active_session_count: 1,
            tracked_sessions: 4,
            last_decision: Some(decision_at(2.0)),
            ..Default::default()
        };
        let json = serde_json::to_string(&s).unwrap();
        let back: CTORuntimeSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(back, s);
        assert!((s.decisions_change_rate_percent() - 30.0).abs() < 1e-9);
        assert!((s.deferred_skip_rate_percent() - 100.0).abs() < 1e-9);
        assert!((s.deferred_flush_rate_percent() - 50.0).abs() < 1e-9);
        assert!((s.active_session_ratio_percent() - 25.0).abs() < 1e-9);
        assert!(!s.is_stable_state());
    }

    #[test]
    fn test_consumption_totals() {
        let mut t = TabTokenConsumption::new("tab", 3, 100, 50, 1.5);
        t.total_cached_input_tokens = 10;
        t.total_reasoning_output_tokens = 5;
        assert_eq!(t.total_billable_tokens(), 165);
        assert_eq!(t.id(), "tab");
        let mut p = ProviderConsumptionStats::new("claude", 3, 100, 50, 1.5);
        p.total_cached_input_tokens = 1;
        assert_eq!(p.total_billable_tokens(), 151);
        assert_eq!(p.id(), "claude");
        let w = WrapperHealth {
            command: "ls".into(),
            is_installed: true,
            is_executable: true,
            has_cto_route: true,
        };
        assert_eq!(w.id(), "ls");
    }
}
