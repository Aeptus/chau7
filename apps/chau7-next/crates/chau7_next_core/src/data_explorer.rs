//! Data Explorer logic (`DataExplorer/*.swift`): AI runs grouped by
//! repository, the labels each row shows (tokens, cost, success rate,
//! relative time, durations, short paths and session ids).

use std::collections::HashMap;

use chrono::{DateTime, Local, Utc};

use crate::telemetry::run::TelemetryRun;

/// Runs read for By Repo (`TelemetryRunFilter(limit: 500)`).
pub const REPO_RUN_LIMIT: usize = 500;
/// Runs listed in All Runs.
pub const RUN_LIST_LIMIT: usize = 200;
/// Commands listed in Commands.
pub const HISTORY_LIMIT: usize = 200;

/// Command totals of a repository (`commandStatsForRepo`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CommandTotals {
    pub total: i64,
    pub successful: i64,
}

/// One row of By Repo (`RepoRunGroup`).
#[derive(Debug, Clone, PartialEq)]
pub struct RepoRunGroup {
    pub repo_path: String,
    pub repo_name: String,
    pub run_count: usize,
    /// Providers, sorted.
    pub providers: Vec<String>,
    pub total_tokens: i64,
    pub total_turns: i64,
    pub total_cost: f64,
    pub total_commands: i64,
    /// Successful commands over all commands, 0 when none.
    pub success_rate: f64,
    pub last_active: DateTime<Utc>,
}

/// Last path component (`URL(fileURLWithPath:).lastPathComponent`).
pub fn last_component(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return path.to_string();
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed).to_string()
}

/// Group runs by repository, else working directory, else "Unknown";
/// most recently active first (`SessionsExplorerView.reload`).
pub fn group_runs_by_repo(
    runs: &[TelemetryRun],
    command_totals: impl Fn(&str) -> CommandTotals,
    repo_cost: impl Fn(&str) -> f64,
) -> Vec<RepoRunGroup> {
    let mut by_repo: HashMap<String, Vec<&TelemetryRun>> = HashMap::new();
    for run in runs {
        let key = run.repo_path.clone().unwrap_or_else(|| {
            if run.cwd.is_empty() {
                "Unknown".into()
            } else {
                run.cwd.clone()
            }
        });
        by_repo.entry(key).or_default().push(run);
    }
    let mut groups: Vec<RepoRunGroup> = by_repo
        .into_iter()
        .map(|(path, runs)| {
            let mut providers: Vec<String> = runs.iter().map(|r| r.provider.clone()).collect();
            providers.sort();
            providers.dedup();
            let totals = command_totals(&path);
            RepoRunGroup {
                repo_name: last_component(&path),
                run_count: runs.len(),
                providers,
                total_tokens: runs
                    .iter()
                    .map(|r| r.token_usage().total_billable_tokens())
                    .sum(),
                total_turns: runs.iter().map(|r| r.turn_count).sum(),
                total_cost: repo_cost(&path),
                total_commands: totals.total,
                success_rate: if totals.total > 0 {
                    totals.successful as f64 / totals.total as f64
                } else {
                    0.0
                },
                last_active: runs
                    .iter()
                    .map(|r| r.started_at)
                    .max()
                    .unwrap_or(DateTime::<Utc>::MIN_UTC),
                repo_path: path,
            }
        })
        .collect();
    groups.sort_by_key(|g| std::cmp::Reverse(g.last_active));
    groups
}

/// Token count label (`formatTokens`): `1.2M`, `12K`, `950`.
pub fn format_tokens(count: i64) -> String {
    if count >= 1_000_000 {
        format!("{:.1}M", count as f64 / 1_000_000.0)
    } else if count >= 1000 {
        format!("{:.0}K", count as f64 / 1000.0)
    } else {
        count.to_string()
    }
}

/// Cost label (`$%.2f`).
pub fn format_cost(cost: f64) -> String {
    format!("${cost:.2}")
}

/// Color of the success rate badge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RateLevel {
    /// Over 90%.
    Good,
    /// Over 70%.
    Fair,
    Poor,
}

pub fn rate_level(rate: f64) -> RateLevel {
    if rate > 0.9 {
        RateLevel::Good
    } else if rate > 0.7 {
        RateLevel::Fair
    } else {
        RateLevel::Poor
    }
}

/// Percent label of a rate (`%.0f%%`).
pub fn format_rate(rate: f64) -> String {
    format!("{:.0}%", rate * 100.0)
}

/// Color of a provider badge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderColor {
    Purple,
    Green,
    Orange,
    Teal,
    Secondary,
}

pub fn provider_color(provider: &str) -> ProviderColor {
    match provider.to_lowercase().as_str() {
        "claude" => ProviderColor::Purple,
        "codex" => ProviderColor::Green,
        "cline" => ProviderColor::Orange,
        "chatgpt" => ProviderColor::Teal,
        _ => ProviderColor::Secondary,
    }
}

/// `String.capitalized` for a provider name: first letter of each word upper.
pub fn capitalized(text: &str) -> String {
    text.split(' ')
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => {
                    first.to_uppercase().collect::<String>() + &chars.as_str().to_lowercase()
                }
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Repository name of a run: the repo path, else the working directory.
pub fn run_repo_name(run: &TelemetryRun) -> String {
    match run.repo_path.as_deref().filter(|p| !p.is_empty()) {
        Some(path) => last_component(path),
        None => last_component(&run.cwd),
    }
}

/// Session id shown in All Runs (`shortSessionID`): the first 8 characters
/// of ids longer than 12.
pub fn short_session_id(run: &TelemetryRun) -> String {
    let id = run.session_id.as_deref().unwrap_or(&run.id);
    if id.chars().count() > 12 {
        id.chars().take(8).collect()
    } else {
        id.to_string()
    }
}

/// `RelativeDateTimeFormatter` with `.abbreviated` units, English.
pub fn relative_time(date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let seconds = (now - date).num_seconds();
    let future = seconds < 0;
    let s = seconds.unsigned_abs();
    let (value, unit) = if s < 60 {
        (s, "sec.")
    } else if s < 3600 {
        (s / 60, "min.")
    } else if s < 86_400 {
        (s / 3600, "hr.")
    } else if s < 7 * 86_400 {
        (s / 86_400, if s / 86_400 == 1 { "day" } else { "days" })
    } else if s < 30 * 86_400 {
        (s / (7 * 86_400), "wk.")
    } else if s < 365 * 86_400 {
        (s / (30 * 86_400), "mo.")
    } else {
        (s / (365 * 86_400), "yr.")
    };
    if future {
        format!("in {value} {unit}")
    } else {
        format!("{value} {unit} ago")
    }
}

/// Command duration (`formatDuration`): `250ms`, `3.4s`, `2m5s`.
pub fn format_duration(seconds: f64) -> String {
    if seconds < 1.0 {
        format!("{:.0}ms", seconds * 1000.0)
    } else if seconds < 60.0 {
        format!("{seconds:.1}s")
    } else {
        let whole = seconds as i64;
        format!("{}m{}s", whole / 60, whole % 60)
    }
}

/// Home folder shown as `~` (`shortenPath`).
pub fn shorten_path(path: &str, home: &str) -> String {
    if !home.is_empty() && path.starts_with(home) {
        format!("~{}", &path[home.len()..])
    } else {
        path.to_string()
    }
}

/// Time of a command (`HH:mm:ss`, local time).
pub fn format_clock(date: DateTime<Utc>) -> String {
    date.with_timezone(&Local).format("%H:%M:%S").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn run(provider: &str, repo: Option<&str>, cwd: &str, minutes_ago: i64) -> TelemetryRun {
        let mut r = TelemetryRun::new(provider, cwd);
        r.repo_path = repo.map(str::to_string);
        r.started_at = Utc::now() - Duration::minutes(minutes_ago);
        r.total_input_tokens = Some(1000);
        r.total_output_tokens = Some(500);
        r.turn_count = 3;
        r
    }

    #[test]
    fn groups_by_repo_then_cwd() {
        let runs = vec![
            run("claude", Some("/w/app"), "/w/app/src", 30),
            run("codex", Some("/w/app"), "/w/app", 5),
            run("claude", None, "/tmp/scratch", 1),
            run("claude", None, "", 60),
        ];
        let groups = group_runs_by_repo(
            &runs,
            |path| {
                if path == "/w/app" {
                    CommandTotals {
                        total: 10,
                        successful: 9,
                    }
                } else {
                    CommandTotals::default()
                }
            },
            |_| 1.5,
        );
        let names: Vec<_> = groups.iter().map(|g| g.repo_name.as_str()).collect();
        assert_eq!(names, ["scratch", "app", "Unknown"]);
        let app = &groups[1];
        assert_eq!(app.run_count, 2);
        assert_eq!(app.providers, ["claude", "codex"]);
        assert_eq!(app.total_turns, 6);
        assert!((app.success_rate - 0.9).abs() < 1e-9);
        assert_eq!(app.total_cost, 1.5);
        assert!(app.total_tokens > 0);
    }

    #[test]
    fn labels() {
        assert_eq!(format_tokens(950), "950");
        assert_eq!(format_tokens(12_400), "12K");
        assert_eq!(format_tokens(1_250_000), "1.2M");
        assert_eq!(format_cost(0.456), "$0.46");
        assert_eq!(rate_level(0.95), RateLevel::Good);
        assert_eq!(rate_level(0.8), RateLevel::Fair);
        assert_eq!(rate_level(0.7), RateLevel::Poor);
        assert_eq!(format_rate(0.876), "88%");
        assert_eq!(provider_color("Claude"), ProviderColor::Purple);
        assert_eq!(provider_color("other"), ProviderColor::Secondary);
        assert_eq!(capitalized("chatgpt"), "Chatgpt");
        assert_eq!(format_duration(0.25), "250ms");
        assert_eq!(format_duration(3.44), "3.4s");
        assert_eq!(format_duration(125.0), "2m5s");
        assert_eq!(shorten_path("/home/u/src", "/home/u"), "~/src");
        assert_eq!(shorten_path("/opt/x", "/home/u"), "/opt/x");
    }

    #[test]
    fn run_names_and_ids() {
        let mut r = run("claude", None, "/w/proj/", 0);
        assert_eq!(run_repo_name(&r), "proj");
        r.session_id = Some("0123456789abcdef".into());
        assert_eq!(short_session_id(&r), "01234567");
        r.session_id = Some("short-id".into());
        assert_eq!(short_session_id(&r), "short-id");
    }

    #[test]
    fn relative_times() {
        let now = Utc::now();
        assert_eq!(relative_time(now - Duration::seconds(5), now), "5 sec. ago");
        assert_eq!(relative_time(now - Duration::minutes(3), now), "3 min. ago");
        assert_eq!(relative_time(now - Duration::hours(2), now), "2 hr. ago");
        assert_eq!(relative_time(now - Duration::days(1), now), "1 day ago");
        assert_eq!(relative_time(now - Duration::days(15), now), "2 wk. ago");
    }
}
