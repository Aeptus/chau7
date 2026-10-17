//! Port of `Analytics/TerminalAnalytics.swift`: the numbers of the
//! terminal analytics dashboard (ANL-001, ANL-002).

use crate::history_record::{FrequentCommand, HistoryRecord};

/// Records the success rate and average duration are computed from.
pub const RECENT_LIMIT: usize = 1000;
/// Rows of "Most Used Commands".
pub const TOP_COMMANDS: usize = 10;
/// Widest bar of "Most Used Commands", in points.
pub const BAR_MAX_WIDTH: f32 = 150.0;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct TerminalAnalytics {
    pub total_commands: i64,
    /// 0 to 1: share of exit code 0 among records that have an exit code.
    pub success_rate: f64,
    /// Seconds, over records that have a duration.
    pub avg_duration: f64,
    pub top_commands: Vec<FrequentCommand>,
}

impl TerminalAnalytics {
    /// `refresh()`: `recent` are the newest records (at most
    /// [`RECENT_LIMIT`]), `top` the most frequent commands.
    pub fn compute(total: i64, recent: &[HistoryRecord], top: Vec<FrequentCommand>) -> Self {
        let mut out = Self {
            total_commands: total,
            top_commands: top.into_iter().take(TOP_COMMANDS).collect(),
            ..Default::default()
        };
        let with_code: Vec<i64> = recent.iter().filter_map(|r| r.exit_code).collect();
        if !with_code.is_empty() {
            let ok = with_code.iter().filter(|c| **c == 0).count();
            out.success_rate = ok as f64 / with_code.len() as f64;
        }
        let durations: Vec<f64> = recent.iter().filter_map(|r| r.duration).collect();
        if !durations.is_empty() {
            out.avg_duration = durations.iter().sum::<f64>() / durations.len() as f64;
        }
        out
    }

    /// `85%`.
    pub fn success_rate_string(&self) -> String {
        format!("{:.0}%", self.success_rate * 100.0)
    }

    /// `1.2s`.
    pub fn avg_duration_string(&self) -> String {
        format!("{:.1}s", self.avg_duration)
    }

    /// Width of a command's bar, scaled to the most used command.
    pub fn bar_width(&self, count: i64) -> f32 {
        let max = self.top_commands.first().map_or(1, |c| c.count).max(1);
        count as f32 / max as f32 * BAR_MAX_WIDTH
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn record(code: Option<i64>, duration: Option<f64>) -> HistoryRecord {
        let mut r = HistoryRecord::new("ls");
        r.exit_code = code;
        r.duration = duration;
        r
    }

    #[test]
    fn rates_and_averages_like_swift() {
        let recent = vec![
            record(Some(0), Some(1.0)),
            record(Some(1), None),
            record(None, Some(2.0)),
            record(Some(0), Some(3.0)),
        ];
        let top = vec![
            FrequentCommand {
                command: "git status".into(),
                count: 8,
                last_used: Utc::now(),
            },
            FrequentCommand {
                command: "ls".into(),
                count: 2,
                last_used: Utc::now(),
            },
        ];
        let a = TerminalAnalytics::compute(42, &recent, top);
        assert_eq!(a.total_commands, 42);
        assert!((a.success_rate - 2.0 / 3.0).abs() < 1e-9);
        assert_eq!(a.success_rate_string(), "67%");
        assert_eq!(a.avg_duration_string(), "2.0s");
        assert_eq!(a.bar_width(8), 150.0);
        assert_eq!(a.bar_width(2), 37.5);
        let empty = TerminalAnalytics::compute(0, &[], Vec::new());
        assert_eq!(empty.success_rate_string(), "0%");
        assert_eq!(empty.avg_duration_string(), "0.0s");
        assert_eq!(empty.bar_width(3), 450.0);
    }
}
