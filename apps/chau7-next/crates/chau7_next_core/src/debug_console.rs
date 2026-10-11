//! Pure logic of the Debug Console (`Debug/DebugConsoleView.swift`): number
//! and duration formats, the token optimizer figures (rates, per-tab table,
//! periods), event colors, tab labels, analytics data shapes and the PTY log
//! size rows of the Health tab.
//!
//! The window and its tabs are in `chau7_next/src/debug/`. Modules that own a
//! data source (token optimizer, telemetry, proxy analytics) fill the shapes
//! defined here through the registration API of that module.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::token_optimization::{
    CTOGainStats, CTORuntimeSnapshot, ProviderConsumptionStats, TabTokenConsumption,
};

/// Meaning of a color; the UI maps it to the theme.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tone {
    Good,
    Warn,
    Bad,
    Info,
    Accent,
    Muted,
}

// ----- number formats ---------------------------------------------------------

/// `1.5M`, `2.3K`, `999` (`formatTokenCount`).
pub fn format_token_count(count: i64) -> String {
    if count >= 1_000_000 {
        format!("{:.1}M", count as f64 / 1_000_000.0)
    } else if count >= 1000 {
        format!("{:.1}K", count as f64 / 1000.0)
    } else {
        count.to_string()
    }
}

/// `1.5M`, `23K` (repos list: no decimals under a million).
pub fn format_repo_tokens(count: i64) -> String {
    if count >= 1_000_000 {
        format!("{:.1}M", count as f64 / 1_000_000.0)
    } else if count >= 1000 {
        format!("{:.0}K", count as f64 / 1000.0)
    } else {
        count.to_string()
    }
}

/// `$1.23`, `$0.012`, `$0.0012`, `--` for none (`formatCost`).
pub fn format_cost(cost: f64) -> String {
    if cost >= 1.0 {
        format!("${cost:.2}")
    } else if cost >= 0.01 {
        format!("${cost:.3}")
    } else if cost > 0.0 {
        format!("${cost:.4}")
    } else {
        "--".to_string()
    }
}

/// `1.5 MB` style size, "-" for zero (`formatBytes`).
pub fn format_bytes(bytes: u64) -> String {
    if bytes == 0 {
        return "-".to_string();
    }
    file_size(bytes)
}

/// A file size like `ByteCountFormatter` (file style): `512 bytes`,
/// `1.5 KB`, `2 MB`.
pub fn file_size(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["KB", "MB", "GB", "TB"];
    if bytes < 1000 {
        return format!("{bytes} bytes");
    }
    let mut value = bytes as f64 / 1000.0;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    let text = if value >= 100.0 {
        format!("{value:.0}")
    } else {
        format!("{value:.1}")
    };
    format!("{} {}", text.trim_end_matches(".0"), UNITS[unit])
}

/// Size of a PTY log in the Health tab: `12KB`, `1.5MB` (`loadHealthData`).
pub fn format_log_size(size: u64) -> String {
    if size > 1024 * 1024 {
        format!("{:.1}MB", size as f64 / 1_048_576.0)
    } else {
        format!("{}KB", size / 1024)
    }
}

/// A PTY log over 10 MB is shown in red.
pub fn log_size_warns(size: u64) -> bool {
    size > 10 * 1024 * 1024
}

/// `1h 02m 03s`, `2m 05s`, `7s` (`ctoFormatDuration(Int)`).
pub fn format_uptime(seconds: i64) -> String {
    if seconds < 0 {
        return "0s".to_string();
    }
    let (h, m, s) = (seconds / 3600, seconds % 3600 / 60, seconds % 60);
    if h > 0 {
        format!("{h}h {m:02}m {s:02}s")
    } else if m > 0 {
        format!("{m}m {s:02}s")
    } else {
        format!("{s}s")
    }
}

/// `n/a` or `120ms` (`ctoFormatDelay`).
pub fn format_delay(ms: Option<i64>) -> String {
    ms.map_or_else(|| "n/a".to_string(), |v| format!("{v}ms"))
}

/// `HH:mm:ss.SSS` of a time of day in milliseconds since midnight.
pub fn format_clock(millis_of_day: u32) -> String {
    let ms = millis_of_day % 1000;
    let total = millis_of_day / 1000;
    format!(
        "{:02}:{:02}:{:02}.{ms:03}",
        total / 3600 % 24,
        total % 3600 / 60,
        total % 60
    )
}

/// `3m ago` style, abbreviated (`RelativeDateTimeFormatter`, abbreviated).
pub fn relative_time(seconds_ago: i64) -> String {
    let s = seconds_ago.max(0);
    if s < 60 {
        "now".to_string()
    } else if s < 3600 {
        format!("{} min. ago", s / 60)
    } else if s < 86_400 {
        format!("{} hr. ago", s / 3600)
    } else if s < 86_400 * 30 {
        format!("{} days ago", s / 86_400)
    } else {
        format!("{} mo. ago", s / (86_400 * 30))
    }
}

// ----- token optimizer ---------------------------------------------------------

/// Period filter of the Token Optimizer tab (`CTOTimePeriod`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CtoPeriod {
    #[default]
    Session,
    Today,
    Week,
    All,
}

impl CtoPeriod {
    pub const ALL: [CtoPeriod; 4] = [Self::Session, Self::Today, Self::Week, Self::All];

    pub fn label(self) -> &'static str {
        match self {
            Self::Session => "Session",
            Self::Today => "Today",
            Self::Week => "7 Days",
            Self::All => "All Time",
        }
    }

    /// Note under the picker (`ctoPeriodNote`).
    pub fn note(self) -> &'static str {
        match self {
            Self::Session => {
                "Command counts use the selected period. Token savings come from daily optimizer totals, so Session shows today's savings."
            }
            _ => "Command counts and token savings use the selected period.",
        }
    }

    /// `Token Rate (Day)` for the session period (`ctoSavingsMetricTitle`).
    pub fn savings_title(self, base: &str) -> String {
        if self == Self::Session {
            format!("{base} (Day)")
        } else {
            base.to_string()
        }
    }

    /// Earliest timestamp (seconds since the Unix epoch) included, `None`
    /// for all time. `session_start` is the monitor's first-seen time,
    /// `start_of_today` and `now` are Unix seconds.
    pub fn cutoff(self, session_start: f64, start_of_today: f64, now: f64) -> Option<f64> {
        match self {
            Self::Session => Some(session_start),
            Self::Today => Some(start_of_today),
            Self::Week => Some(now - 7.0 * 86_400.0),
            Self::All => None,
        }
    }
}

/// One line of the optimizer's command log (`CTOManager.CommandLogEntry`).
#[derive(Debug, Clone, PartialEq)]
pub struct CtoLogEntry {
    /// Unix seconds.
    pub timestamp: f64,
    pub session_id: String,
    pub command: String,
    pub exit_code: i64,
    /// `optimized`, `fallthrough`, `skipped` or `error`.
    pub outcome: String,
}

impl CtoLogEntry {
    /// A deliberate bypass, not a failure.
    pub fn is_intentional_skip(&self) -> bool {
        self.outcome == "skipped"
    }
}

/// Color of an outcome (`ctoOutcomeColor`).
pub fn outcome_tone(outcome: &str) -> Tone {
    match outcome {
        "optimized" => Tone::Good,
        "fallthrough" => Tone::Warn,
        "skipped" => Tone::Muted,
        _ => Tone::Bad,
    }
}

/// Entries of the period.
pub fn filter_log(log: &[CtoLogEntry], cutoff: Option<f64>) -> Vec<CtoLogEntry> {
    log.iter()
        .filter(|e| cutoff.is_none_or(|c| e.timestamp >= c))
        .cloned()
        .collect()
}

/// Optimized share of the commands, skipped ones excluded (`ctoFilteredRate`).
pub fn command_rate(log: &[CtoLogEntry]) -> Option<f64> {
    let meaningful: Vec<&CtoLogEntry> = log.iter().filter(|e| e.outcome != "skipped").collect();
    if meaningful.is_empty() {
        return None;
    }
    let optimized = meaningful
        .iter()
        .filter(|e| e.outcome == "optimized")
        .count();
    Some(optimized as f64 / meaningful.len() as f64 * 100.0)
}

/// Green from 80 %, orange from 50 %, else red; grey when unknown.
pub fn rate_tone(rate: Option<f64>) -> Tone {
    match rate {
        None => Tone::Muted,
        Some(r) if r >= 80.0 => Tone::Good,
        Some(r) if r >= 50.0 => Tone::Warn,
        Some(_) => Tone::Bad,
    }
}

/// Token savings: green from 40 %, orange from 20 %, else red.
pub fn token_rate_tone(stats: Option<&CTOGainStats>) -> Tone {
    match stats {
        None => Tone::Muted,
        Some(s) if s.savings_pct >= 40.0 => Tone::Good,
        Some(s) if s.savings_pct >= 20.0 => Tone::Warn,
        Some(_) => Tone::Bad,
    }
}

/// `85%` or `--`.
pub fn format_percent(rate: Option<f64>) -> String {
    rate.map_or_else(|| "--".to_string(), |r| format!("{r:.0}%"))
}

/// Count of entries with an outcome.
pub fn count_outcome(log: &[CtoLogEntry], outcome: &str) -> usize {
    log.iter().filter(|e| e.outcome == outcome).count()
}

/// Commands of one tab (`CTOTabStat`).
#[derive(Debug, Clone, PartialEq)]
pub struct CtoTabStat {
    pub session_id: String,
    pub total: usize,
    pub optimized: usize,
    pub fallthrough: usize,
    pub skipped: usize,
}

impl CtoTabStat {
    /// Rate excluding skipped commands.
    pub fn rate(&self) -> f64 {
        let meaningful = self.total - self.skipped;
        if meaningful > 0 {
            self.optimized as f64 / meaningful as f64 * 100.0
        } else {
            0.0
        }
    }
}

/// Per-tab counts, most commands first (`ctoPerTabStats`).
pub fn per_tab_stats(log: &[CtoLogEntry]) -> Vec<CtoTabStat> {
    let mut grouped: BTreeMap<&str, CtoTabStat> = BTreeMap::new();
    for entry in log {
        let stat = grouped
            .entry(&entry.session_id)
            .or_insert_with(|| CtoTabStat {
                session_id: entry.session_id.clone(),
                total: 0,
                optimized: 0,
                fallthrough: 0,
                skipped: 0,
            });
        stat.total += 1;
        match entry.outcome.as_str() {
            "optimized" => stat.optimized += 1,
            "fallthrough" => stat.fallthrough += 1,
            "skipped" => stat.skipped += 1,
            _ => {}
        }
    }
    let mut stats: Vec<CtoTabStat> = grouped.into_values().collect();
    stats.sort_by_key(|s| std::cmp::Reverse(s.total));
    stats
}

/// Session ids of the table, biggest AI token users first, then by command
/// count (the sort of the per-tab table).
pub fn per_tab_rows(tab_stats: &[CtoTabStat], ai: &[TabTokenConsumption]) -> Vec<String> {
    let mut ids: BTreeSet<String> = tab_stats.iter().map(|s| s.session_id.clone()).collect();
    ids.extend(ai.iter().map(|a| a.tab_id.clone()));
    let tokens = |id: &str| {
        ai.iter()
            .find(|a| a.tab_id == id)
            .map_or(0, |a| a.total_input_tokens + a.total_output_tokens)
    };
    let commands = |id: &str| {
        tab_stats
            .iter()
            .find(|s| s.session_id == id)
            .map_or(0, |s| s.total)
    };
    let mut ids: Vec<String> = ids.into_iter().collect();
    ids.sort_by(|a, b| {
        tokens(b)
            .cmp(&tokens(a))
            .then_with(|| commands(b).cmp(&commands(a)))
    });
    ids
}

/// Shown text of a runtime health issue (`tokenOptimizerHealthIssueLabel`).
pub fn health_issue_label(
    issue: crate::token_optimization::CTORuntimeAssessmentIssue,
) -> &'static str {
    use crate::token_optimization::CTORuntimeAssessmentIssue as I;
    match issue {
        I::LowChangeRate => "Decision change rate is low",
        I::HighDeferredSkips => "Too many deferred skips",
        I::LowDeferredFlushRate => "Deferred flushes are not resolving",
        I::StaleDecisions => "No recent decisions",
        I::ModeOffWithTrackedSessions => "Mode is off while sessions are tracked",
        I::LowDecisionThroughput => "No decisions despite tracked sessions",
    }
}

/// Everything the Token Optimizer tab shows, for one period. The module that
/// owns the optimizer fills it (`debug::set_token_optimizer_source`).
#[derive(Debug, Clone, Default)]
pub struct TokenOptimizerData {
    pub runtime: CTORuntimeSnapshot,
    /// Command log of the period, oldest first.
    pub log: Vec<CtoLogEntry>,
    /// Savings of the period.
    pub gain: Option<CTOGainStats>,
    /// Saved tokens per session.
    pub session_gain: HashMap<String, CTOGainStats>,
    pub tab_consumption: Vec<TabTokenConsumption>,
    pub provider_consumption: Vec<ProviderConsumptionStats>,
}

// ----- events ---------------------------------------------------------------------

/// Color of an event type badge (`aiEventTypeColor`).
pub fn event_tone(event_type: &str) -> Tone {
    let normalized: String = event_type
        .trim()
        .to_lowercase()
        .replace('-', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("_");
    match normalized.as_str() {
        "failed" | "error" | "context_limit" | "contextlimit" | "exit_failed" | "exitfailed" => {
            return Tone::Bad;
        }
        "permission" | "permission_request" | "permissionrequest" | "permission_prompt" => {
            return Tone::Warn;
        }
        "waiting_input" | "waitinginput" | "idle_prompt" | "idleprompt" | "input_required"
        | "attention_required" | "attentionrequired" | "notification" | "needs_attention"
        | "elicitation_dialog" | "idle" => return Tone::Warn,
        "finished" | "response_complete" | "responsecomplete" | "task_finished"
        | "taskfinished" => return Tone::Accent,
        _ => {}
    }
    let lower = event_type.to_lowercase();
    if lower.contains("tool") || lower.contains("process_") {
        Tone::Info
    } else {
        Tone::Muted
    }
}

/// Permission prompts are yellow in Swift, the other attention events orange.
pub fn event_is_permission(event_type: &str) -> bool {
    let lower = event_type.to_lowercase();
    lower.contains("permission")
}

// ----- tab labels -----------------------------------------------------------------

/// `Title · Disambiguator - repo` (`composedTabLabel`).
pub fn composed_tab_label(base: &str, repo: Option<&str>, disambiguator: Option<&str>) -> String {
    let title = match disambiguator {
        Some(d) if !d.is_empty() && !d.eq_ignore_ascii_case(base) => format!("{base} \u{b7} {d}"),
        _ => base.to_string(),
    };
    match repo {
        Some(repo) if !repo.is_empty() && !title.eq_ignore_ascii_case(repo) => {
            format!("{title} - {repo}")
        }
        _ => title,
    }
}

// ----- analytics --------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProxyStats {
    pub call_count: i64,
    pub total_tokens: i64,
    pub total_cost: f64,
    pub average_latency_ms: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProxyProviderStat {
    pub provider: String,
    pub call_count: i64,
    pub total_tokens: i64,
    pub total_cost: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProxyDailyPoint {
    pub date: String,
    pub call_count: i64,
    pub total_tokens: i64,
    pub total_cost: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProxyCall {
    pub provider: String,
    pub model: String,
    pub total_tokens: i64,
    pub formatted_cost: String,
    pub formatted_latency: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DailyRunCost {
    pub date: String,
    pub cost: f64,
    pub tokens: i64,
    pub priced_run_count: i64,
    pub total_run_count: i64,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct RepoAnalytics {
    pub path: String,
    pub name: String,
    pub total_commands: i64,
    /// 0 to 1.
    pub success_rate: f64,
    pub total_runs: i64,
    pub total_tokens: i64,
    pub total_cost: f64,
    pub providers: Vec<String>,
    pub top_tools: Vec<(String, i64)>,
    /// Seconds since the last command or run, when known.
    pub last_activity_ago: Option<i64>,
}

/// Data of the Analytics tab. Each part is filled by the module that owns it
/// (proxy analytics store, telemetry store, repository statistics).
#[derive(Debug, Clone, Default)]
pub struct AnalyticsData {
    pub proxy_stats: ProxyStats,
    pub proxy_providers: Vec<ProxyProviderStat>,
    pub proxy_daily: Vec<ProxyDailyPoint>,
    pub proxy_recent: Vec<ProxyCall>,
    pub run_providers: Vec<ProviderConsumptionStats>,
    pub run_tabs: Vec<TabTokenConsumption>,
    pub run_daily: Vec<DailyRunCost>,
    pub run_count: i64,
    pub repos: Vec<RepoAnalytics>,
}

/// `$0.0123`, `$0.0123 partial`, `cost unavailable`, `no cost data`
/// (`runCostLabel`).
pub fn run_cost_label(cost: f64, priced: i64, missing: i64) -> String {
    if priced == 0 {
        return if missing > 0 {
            "cost unavailable"
        } else {
            "no cost data"
        }
        .to_string();
    }
    let prefix = format!("${cost:.4}");
    if missing > 0 {
        format!("{prefix} partial")
    } else {
        prefix
    }
}

/// Colors of a repo success rate: green over 90 %, yellow over 70 %.
pub fn success_tone(rate: f64) -> Tone {
    if rate > 0.9 {
        Tone::Good
    } else if rate > 0.7 {
        Tone::Warn
    } else {
        Tone::Bad
    }
}

// ----- changed files panel ------------------------------------------------------------

/// The summary line of `git diff --stat` (`" 1 file changed, 3 insertions(+)"`),
/// without surrounding spaces: the last line that says "changed"
/// (`GitDiffTracker.diffStat`).
pub fn diff_stat_summary(output: &str) -> Option<String> {
    output
        .lines()
        .rev()
        .find(|line| line.contains("changed"))
        .map(|line| line.trim().to_string())
}

/// Files matching the filter box, case-insensitive substring
/// (`localizedCaseInsensitiveContains`); an empty filter keeps all.
pub fn filter_files<'a>(files: &'a [String], query: &str) -> Vec<&'a String> {
    let query = query.to_lowercase();
    files
        .iter()
        .filter(|f| query.is_empty() || f.to_lowercase().contains(&query))
        .collect()
}

/// `"3 files"`, `"1 file"` (footer of the panel).
pub fn files_count_label(count: usize) -> String {
    format!("{count} file{}", if count == 1 { "" } else { "s" })
}

/// Window title: `"Changed Files (3)"`.
pub fn changed_files_title(count: usize) -> String {
    format!("Changed Files ({count})")
}

/// A short symbol for the kind of a file (`iconForFile`, the SF Symbols
/// mapped to text glyphs).
pub fn file_glyph(path: &str) -> &'static str {
    let ext = path
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "swift" => "S",
        "rs" => "R",
        "go" => "G",
        "ts" | "tsx" | "js" | "jsx" => "</>",
        "css" | "scss" => "#",
        "html" => "@",
        "json" | "yaml" | "yml" | "toml" => "{}",
        "md" => "M",
        "png" | "jpg" | "jpeg" | "svg" => "img",
        _ => "-",
    }
}

#[cfg(test)]
mod changed_files_tests {
    #[test]
    fn diff_stat_takes_the_summary_line() {
        let out = " src/a.rs | 4 +++-\n 1 file changed, 3 insertions(+), 1 deletion(-)\n";
        assert_eq!(
            super::diff_stat_summary(out).as_deref(),
            Some("1 file changed, 3 insertions(+), 1 deletion(-)")
        );
        assert_eq!(super::diff_stat_summary(""), None);
    }

    #[test]
    fn changed_files_filter_and_labels() {
        use super::*;
        let files = vec!["src/Main.rs".to_string(), "README.md".to_string()];
        assert_eq!(filter_files(&files, "").len(), 2);
        assert_eq!(filter_files(&files, "main"), vec![&files[0]]);
        assert!(filter_files(&files, "zzz").is_empty());
        assert_eq!(files_count_label(1), "1 file");
        assert_eq!(files_count_label(2), "2 files");
        assert_eq!(changed_files_title(3), "Changed Files (3)");
        assert_eq!(file_glyph("a/b.RS"), "R");
        assert_eq!(file_glyph("Makefile"), "-");
        assert_eq!(file_glyph("x.toml"), "{}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(session: &str, outcome: &str, ts: f64) -> CtoLogEntry {
        CtoLogEntry {
            timestamp: ts,
            session_id: session.into(),
            command: "ls".into(),
            exit_code: 0,
            outcome: outcome.into(),
        }
    }

    #[test]
    fn number_formats() {
        assert_eq!(format_token_count(999), "999");
        assert_eq!(format_token_count(1500), "1.5K");
        assert_eq!(format_token_count(2_500_000), "2.5M");
        assert_eq!(format_repo_tokens(23_400), "23K");
        assert_eq!(format_cost(0.0), "--");
        assert_eq!(format_cost(0.0012), "$0.0012");
        assert_eq!(format_cost(0.0123), "$0.012");
        assert_eq!(format_cost(2.0), "$2.00");
        assert_eq!(format_log_size(2048), "2KB");
        assert_eq!(format_log_size(3 * 1024 * 1024), "3.0MB");
        assert!(log_size_warns(11 * 1024 * 1024));
        assert!(!log_size_warns(10 * 1024 * 1024));
    }

    #[test]
    fn file_sizes() {
        assert_eq!(format_bytes(0), "-");
        assert_eq!(format_bytes(512), "512 bytes");
        assert_eq!(format_bytes(1500), "1.5 KB");
        assert_eq!(format_bytes(2_000_000), "2 MB");
        assert_eq!(format_bytes(150_000), "150 KB");
    }

    #[test]
    fn durations_and_clock() {
        assert_eq!(format_uptime(7), "7s");
        assert_eq!(format_uptime(125), "2m 05s");
        assert_eq!(format_uptime(3723), "1h 02m 03s");
        assert_eq!(format_uptime(-4), "0s");
        assert_eq!(format_delay(None), "n/a");
        assert_eq!(format_delay(Some(40)), "40ms");
        assert_eq!(format_clock(45_296_123), "12:34:56.123");
        assert_eq!(relative_time(30), "now");
        assert_eq!(relative_time(180), "3 min. ago");
        assert_eq!(relative_time(7200), "2 hr. ago");
    }

    #[test]
    fn periods() {
        assert_eq!(
            CtoPeriod::ALL.map(CtoPeriod::label),
            ["Session", "Today", "7 Days", "All Time"]
        );
        assert_eq!(
            CtoPeriod::Session.savings_title("Token Rate"),
            "Token Rate (Day)"
        );
        assert_eq!(CtoPeriod::All.savings_title("Token Rate"), "Token Rate");
        assert!(
            CtoPeriod::Session
                .note()
                .contains("Session shows today's savings")
        );
        assert_eq!(CtoPeriod::All.cutoff(5.0, 10.0, 100.0), None);
        assert_eq!(CtoPeriod::Today.cutoff(5.0, 10.0, 100.0), Some(10.0));
        assert_eq!(CtoPeriod::Session.cutoff(5.0, 10.0, 100.0), Some(5.0));
        assert_eq!(CtoPeriod::Week.cutoff(5.0, 10.0, 700_000.0), Some(95_200.0));
    }

    #[test]
    fn rates_skip_intentional_bypasses() {
        let log = vec![
            entry("a", "optimized", 1.0),
            entry("a", "fallthrough", 2.0),
            entry("a", "skipped", 3.0),
            entry("b", "optimized", 4.0),
            entry("b", "optimized", 5.0),
        ];
        // 3 optimized of 4 meaningful.
        assert_eq!(command_rate(&log), Some(75.0));
        assert_eq!(command_rate(&[]), None);
        assert_eq!(command_rate(&[entry("a", "skipped", 1.0)]), None);
        assert_eq!(rate_tone(Some(75.0)), Tone::Warn);
        assert_eq!(rate_tone(Some(80.0)), Tone::Good);
        assert_eq!(rate_tone(Some(10.0)), Tone::Bad);
        assert_eq!(rate_tone(None), Tone::Muted);
        assert_eq!(format_percent(Some(74.6)), "75%");
        assert_eq!(format_percent(None), "--");
        assert_eq!(count_outcome(&log, "optimized"), 3);
        assert_eq!(filter_log(&log, Some(3.0)).len(), 3);
        assert_eq!(filter_log(&log, None).len(), 5);
    }

    #[test]
    fn token_rate_colors() {
        let stats = |pct: f64| CTOGainStats {
            commands: 1,
            input_tokens: 1,
            output_tokens: 1,
            saved_tokens: 1,
            savings_pct: pct,
            total_time_ms: 1,
            avg_time_ms: 1,
        };
        assert_eq!(token_rate_tone(Some(&stats(45.0))), Tone::Good);
        assert_eq!(token_rate_tone(Some(&stats(25.0))), Tone::Warn);
        assert_eq!(token_rate_tone(Some(&stats(5.0))), Tone::Bad);
        assert_eq!(token_rate_tone(None), Tone::Muted);
    }

    #[test]
    fn per_tab_table_order() {
        let log = vec![
            entry("a", "optimized", 1.0),
            entry("b", "optimized", 1.0),
            entry("b", "skipped", 1.0),
            entry("c", "fallthrough", 1.0),
        ];
        let stats = per_tab_stats(&log);
        assert_eq!(stats[0].session_id, "b");
        assert_eq!(stats[0].rate(), 100.0);
        assert_eq!(stats[0].skipped, 1);
        // Tab "c" has AI tokens: it goes first.
        let ai = vec![TabTokenConsumption::new("c", 1, 100, 50, 0.1)];
        assert_eq!(per_tab_rows(&stats, &ai), vec!["c", "b", "a"]);
        assert_eq!(per_tab_rows(&stats, &[]), vec!["b", "a", "c"]);
    }

    #[test]
    fn outcome_and_event_colors() {
        assert_eq!(outcome_tone("optimized"), Tone::Good);
        assert_eq!(outcome_tone("error"), Tone::Bad);
        assert_eq!(outcome_tone("skipped"), Tone::Muted);
        assert_eq!(event_tone("failed"), Tone::Bad);
        assert_eq!(event_tone("finished"), Tone::Accent);
        assert_eq!(event_tone("waiting_input"), Tone::Warn);
        assert_eq!(event_tone("tool_use"), Tone::Info);
        assert_eq!(event_tone("process_started"), Tone::Info);
        assert_eq!(event_tone("whatever"), Tone::Muted);
        assert!(event_is_permission("permission_request"));
    }

    #[test]
    fn tab_labels() {
        assert_eq!(
            composed_tab_label("Claude", Some("chau7"), None),
            "Claude - chau7"
        );
        assert_eq!(composed_tab_label("Claude", Some("claude"), None), "Claude");
        assert_eq!(
            composed_tab_label("Claude", None, Some("api")),
            "Claude \u{b7} api"
        );
        assert_eq!(composed_tab_label("Claude", None, Some("CLAUDE")), "Claude");
    }

    #[test]
    fn cost_labels() {
        assert_eq!(run_cost_label(0.0, 0, 0), "no cost data");
        assert_eq!(run_cost_label(0.0, 0, 2), "cost unavailable");
        assert_eq!(run_cost_label(1.5, 3, 0), "$1.5000");
        assert_eq!(run_cost_label(1.5, 3, 1), "$1.5000 partial");
        assert_eq!(success_tone(0.95), Tone::Good);
        assert_eq!(success_tone(0.8), Tone::Warn);
        assert_eq!(success_tone(0.5), Tone::Bad);
    }
}
