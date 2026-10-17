//! Throttling and scanning of the dangerous-command tint on terminal output
//! (`TerminalSessionModel+ShellIntegration.swift`: `updateOutputBurstState`,
//! `dangerousOutputHighlightTiming`, `shouldUseLowPowerHighlights`,
//! `isCpuSaturated`, `dangerousOutputRowsVisible`).
//!
//! Typed command lines are checked once, when entered; output rows are
//! rescanned at most every "max interval" while output streams, and after an
//! "idle delay" once it stops. During an output burst or when the UI lags,
//! updates slow down, and in low-power mode only a few uncached rows are
//! scanned per pass and wrapped lines are not joined.

use std::collections::HashMap;

use crate::command_risk::is_risky;

/// Output in this window (s) counts towards a burst.
pub const BURST_WINDOW_SECS: f64 = 2.0;
/// A gap longer than this (s) ends a burst.
pub const BURST_IDLE_SECS: f64 = 0.35;
/// Bytes within the window that make a burst.
pub const BURST_BYTES: usize = 64 * 1024;
/// Chunks within the window that make a burst.
pub const BURST_CHUNKS: usize = 24;
/// Input or output lag (ms) at which the UI counts as saturated.
pub const CPU_SATURATED_MS: i64 = 80;
/// Rows kept in the risk cache before it is cleared.
pub const RISK_CACHE_MAX_ENTRIES: usize = 800;

/// `outputBurstActive` and its counters.
#[derive(Debug, Clone, Default)]
pub struct BurstState {
    start: f64,
    bytes: usize,
    chunks: usize,
    active: bool,
    last_output: Option<f64>,
}

impl BurstState {
    /// `updateOutputBurstState`: `bytes` of output arrived at `now` (s).
    pub fn record(&mut self, bytes: usize, now: f64) {
        let gap = self.last_output.map(|t| now - t).unwrap_or(f64::INFINITY);
        self.last_output = Some(now);
        if gap > BURST_IDLE_SECS {
            self.start = now;
            self.bytes = 0;
            self.chunks = 0;
            self.active = false;
        }
        self.bytes += bytes;
        self.chunks += 1;
        if !self.active {
            if now - self.start > BURST_WINDOW_SECS {
                self.start = now;
                self.bytes = bytes;
                self.chunks = 1;
            }
            let in_window = now - self.start <= BURST_WINDOW_SECS;
            if in_window && (self.bytes >= BURST_BYTES || self.chunks >= BURST_CHUNKS) {
                self.active = true;
            }
        }
    }

    pub fn is_active(&self) -> bool {
        self.active
    }
}

/// `isCpuSaturated`: input or output lag (average, else last) of 80 ms or
/// more. Highlight lag is left out on purpose (it includes its own delay).
pub fn is_cpu_saturated(input_lag_ms: Option<i64>, output_lag_ms: Option<i64>) -> bool {
    input_lag_ms.unwrap_or(0).max(output_lag_ms.unwrap_or(0)) >= CPU_SATURATED_MS
}

/// `dangerousOutputHighlightTiming`: (idle delay, max interval) in seconds.
/// The settings are clamped (0 to 5,000 ms, 250 to 10,000 ms); a burst caps
/// updates near 2 Hz, a saturated UI near 1 Hz.
pub fn highlight_timing(
    idle_delay_ms: u32,
    max_interval_ms: u32,
    burst: bool,
    cpu_saturated: bool,
) -> (f64, f64) {
    let idle_ms = idle_delay_ms.min(5000);
    let max_ms = max_interval_ms.clamp(250, 10_000).max(idle_ms);
    let mut idle = idle_ms as f64 / 1000.0;
    let mut max = max_ms as f64 / 1000.0;
    if burst {
        idle = idle.max(0.5);
        max = max.max(0.5);
    }
    if cpu_saturated {
        idle = idle.max(1.0);
        max = max.max(1.0);
    }
    (idle, max)
}

/// When the next scan runs after output: at once when the last one is older
/// than the max interval, else after the idle delay
/// (`scheduleDangerousOutputHighlight`).
pub fn next_delay(since_last_run: f64, timing: (f64, f64)) -> f64 {
    let (idle, max) = timing;
    if since_last_run >= max { 0.0 } else { idle }
}

/// `shouldUseLowPowerHighlights`.
pub fn low_power_active(enabled: bool, burst: bool, cpu_saturated: bool) -> bool {
    enabled && (burst || cpu_saturated)
}

/// Risk of each row text already checked (`outputRiskCache`).
#[derive(Debug, Default, Clone)]
pub struct RiskCache {
    by_text: HashMap<String, bool>,
}

impl RiskCache {
    pub fn clear(&mut self) {
        self.by_text.clear();
    }

    fn get(&self, text: &str) -> Option<bool> {
        self.by_text.get(text).copied()
    }

    fn put(&mut self, text: &str, risky: bool) {
        self.by_text.insert(text.to_string(), risky);
    }
}

/// `dangerousOutputRowsVisible`: indexes into `rows` (viewport rows, top
/// first) whose text matches a pattern. A row filling the whole width is
/// joined with the next one, so a wrapped command matches too (both rows
/// then count). In low-power mode at most `min(16, max(6, rows / 3))`
/// uncached rows are checked per pass and wrapped rows are not joined.
pub fn scan_rows(
    rows: &[String],
    cols: usize,
    patterns: &[String],
    low_power: bool,
    cache: &mut RiskCache,
) -> Vec<usize> {
    if cols == 0 || rows.is_empty() {
        return Vec::new();
    }
    if cache.by_text.len() > RISK_CACHE_MAX_ENTRIES {
        cache.clear();
    }
    let max_computations = if low_power {
        (rows.len() / 3).clamp(6, 16)
    } else {
        usize::MAX
    };
    let mut computed = 0;
    let mut found = Vec::new();
    let mut index = 0;
    while index < rows.len() {
        let text = rows[index].trim_end();
        if text.trim().is_empty() {
            index += 1;
            continue;
        }
        if let Some(risky) = cache.get(text) {
            if risky {
                found.push(index);
            } else if !low_power && let Some(next) = joined_risky(rows, index, cols, patterns) {
                found.push(index);
                found.push(next);
                index = next + 1;
                continue;
            }
            index += 1;
            continue;
        }
        if computed >= max_computations {
            index += 1;
            continue;
        }
        computed += 1;
        let risky = is_risky(text, patterns);
        cache.put(text, risky);
        if risky {
            found.push(index);
        } else if !low_power && let Some(next) = joined_risky(rows, index, cols, patterns) {
            found.push(index);
            found.push(next);
            index = next + 1;
            continue;
        }
        index += 1;
    }
    found
}

/// The next row's index when row `index` fills the width and, joined with
/// the next row, matches.
fn joined_risky(rows: &[String], index: usize, cols: usize, patterns: &[String]) -> Option<usize> {
    let trimmed = rows[index].trim();
    let next = index + 1;
    if trimmed.chars().count() + 1 < cols || next >= rows.len() {
        return None;
    }
    let combined = format!("{trimmed}{}", rows[next].trim_end());
    is_risky(&combined, patterns).then_some(next)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn patterns() -> Vec<String> {
        vec!["rm -rf".to_string()]
    }

    #[test]
    fn burst_needs_many_bytes_or_chunks_in_the_window() {
        let mut b = BurstState::default();
        b.record(1000, 0.0);
        assert!(!b.is_active());
        b.record(70 * 1024, 0.1);
        assert!(b.is_active());
        // A pause ends it.
        b.record(10, 1.0);
        assert!(!b.is_active());
        let mut c = BurstState::default();
        for i in 0..24 {
            c.record(10, i as f64 * 0.05);
        }
        assert!(c.is_active());
    }

    #[test]
    fn timing_is_clamped_and_slowed_down() {
        assert_eq!(highlight_timing(500, 2000, false, false), (0.5, 2.0));
        assert_eq!(highlight_timing(9000, 100, false, false), (5.0, 5.0));
        assert_eq!(highlight_timing(0, 250, true, false), (0.5, 0.5));
        assert_eq!(highlight_timing(0, 250, true, true), (1.0, 1.0));
        assert_eq!(next_delay(3.0, (0.5, 2.0)), 0.0);
        assert_eq!(next_delay(1.0, (0.5, 2.0)), 0.5);
    }

    #[test]
    fn saturation_and_low_power() {
        assert!(is_cpu_saturated(Some(90), None));
        assert!(is_cpu_saturated(None, Some(80)));
        assert!(!is_cpu_saturated(Some(10), Some(79)));
        assert!(low_power_active(true, true, false));
        assert!(!low_power_active(false, true, true));
        assert!(!low_power_active(true, false, false));
    }

    #[test]
    fn scans_rows_and_joins_wrapped_lines() {
        let rows: Vec<String> = ["ls -la", "sudo rm -", "rf /tmp/x", "echo rm -rf /"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let mut cache = RiskCache::default();
        // Width 9: "sudo rm -" fills the row and continues on the next.
        let found = scan_rows(&rows, 9, &patterns(), false, &mut cache);
        assert_eq!(found, vec![1, 2, 3]);
        // Low power: no joining.
        let mut cache = RiskCache::default();
        assert_eq!(scan_rows(&rows, 9, &patterns(), true, &mut cache), vec![3]);
    }

    #[test]
    fn low_power_limits_uncached_checks() {
        let rows: Vec<String> = (0..30).map(|i| format!("line {i} rm -rf x")).collect();
        let mut cache = RiskCache::default();
        let first = scan_rows(&rows, 80, &patterns(), true, &mut cache);
        assert_eq!(first.len(), 10);
        // Cached rows are free, so the next pass gets further.
        let second = scan_rows(&rows, 80, &patterns(), true, &mut cache);
        assert_eq!(second.len(), 20);
    }
}
