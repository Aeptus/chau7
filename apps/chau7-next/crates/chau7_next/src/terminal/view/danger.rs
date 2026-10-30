//! Dangerous-command tint (TRM-055): typed command lines that match a
//! pattern are tinted at once whenever highlighting is on; output rows are
//! tinted by scope (AI output only, or all output) from a scan that runs on
//! a throttle (`scheduleDangerousOutputHighlight`): after the idle delay once
//! output stops, at least every max interval while it streams, slower during
//! output bursts and when the UI lags, and lighter in low-power mode
//! (`chau7_next_core::danger_highlight`). The delay between when a scan was
//! due and when it ran is the "highlight" latency of the debug console.

use std::time::{Duration, Instant};

use chau7_next_core::command_risk::is_risky;
use chau7_next_core::danger_highlight::{self, BurstState, RiskCache};
use chau7_next_core::feature_profiler::{self, Feature};
use chau7_next_core::input::input_lines::InputLineTracker;
use gpui::{Context, Task};

use super::TerminalView;
use crate::settings::Settings;
use crate::settings::dangerous_commands::HighlightScope;
use crate::terminal::session::TerminalSession;

pub(super) struct DangerState {
    /// Rows of typed command lines that matched (`dangerousCommandTracker`).
    input_rows: InputLineTracker,
    /// Output rows (absolute) found risky by the last scan.
    output_rows: Vec<i64>,
    cache: RiskCache,
    burst: BurstState,
    /// A scan is due on the next frame.
    due: bool,
    /// (scroll offset, columns, rows) of the last scan: the user scrolling
    /// or a resize rescans at once; new output waits for the throttle.
    scanned: Option<(i64, u16, u16)>,
    last_run: Option<Instant>,
    pending: Option<Task<()>>,
    /// Patterns of the cached results (an edit in Settings clears them).
    patterns: Vec<String>,
    epoch: Instant,
}

impl DangerState {
    pub(super) fn new(scrollback_lines: usize) -> Self {
        Self {
            input_rows: InputLineTracker::new(scrollback_lines.max(1)),
            output_rows: Vec::new(),
            cache: RiskCache::default(),
            burst: BurstState::default(),
            due: true,
            scanned: None,
            last_run: None,
            pending: None,
            patterns: Vec::new(),
            epoch: Instant::now(),
        }
    }

    /// Clear Scrollback: every row is gone.
    pub(super) fn reset(&mut self) {
        self.input_rows.reset();
        self.output_rows.clear();
        self.scanned = None;
        self.due = true;
    }
}

fn output_scope_allows(settings: &Settings, session: &TerminalSession) -> bool {
    match settings.dangerous_commands.scope {
        HighlightScope::Disabled => false,
        HighlightScope::AiOutputs => session.ai_app.is_some(),
        HighlightScope::AllOutputs => true,
    }
}

impl TerminalView {
    /// A typed line was entered at absolute row `row`
    /// (`recordDangerousCommandLineIfNeeded`).
    pub(super) fn danger_note_input_line(&mut self, line: &str, row: i64, cx: &Context<Self>) {
        let settings = Settings::get(cx);
        if is_risky(line, &settings.dangerous_commands.patterns) {
            self.danger.input_rows.record(row);
        }
    }

    /// Output arrived (`recordDangerousOutputIfNeeded`): note the burst and
    /// schedule a scan when output rows are highlighted.
    pub(super) fn danger_note_output(&mut self, cx: &mut Context<Self>) {
        let now = self.danger.epoch.elapsed().as_secs_f64();
        let session = self.session.read(cx);
        self.danger.burst.record(session.last_output_bytes, now);
        let settings = Settings::get(cx);
        if !output_scope_allows(settings, session) {
            return;
        }
        if !session.restore_surface_visible() && session.surface_prewarm_remaining().is_none() {
            // A scan only produces row tints for a displayed frame. Keep it
            // due for reveal instead of waking the window from a hidden timer.
            self.danger.pending = None;
            self.danger.due = true;
            return;
        }
        let (input_lag, output_lag) = session.ui_lag_ms();
        let saturated = danger_highlight::is_cpu_saturated(input_lag, output_lag);
        let timing = danger_highlight::highlight_timing(
            settings.dangerous_commands.highlight_idle_delay_ms,
            settings.dangerous_commands.highlight_max_interval_ms,
            self.danger.burst.is_active(),
            saturated,
        );
        let since = self
            .danger
            .last_run
            .map(|t| t.elapsed().as_secs_f64())
            .unwrap_or(f64::INFINITY);
        let delay = Duration::from_secs_f64(danger_highlight::next_delay(since, timing));
        let expected = Instant::now() + delay;
        // A new burst of output pushes the pending scan back (Swift cancels
        // the work item and schedules a new one).
        self.danger.pending = Some(cx.spawn(async move |this, cx| {
            if !delay.is_zero() {
                cx.background_executor().timer(delay).await;
            }
            let _ = this.update(cx, |this, cx| {
                let congestion = Instant::now().saturating_duration_since(expected);
                this.session
                    .read(cx)
                    .record_highlight_latency(congestion.as_secs_f64() * 1000.0);
                this.danger.last_run = Some(Instant::now());
                this.danger.due = true;
                this.danger.pending = None;
                cx.notify();
            });
        }));
    }

    /// Copy the danger rows from the last displayed frame for an immutable
    /// snapshot. Any due scan remains scheduled for the next live frame.
    pub(super) fn danger_rows_for_snapshot(
        &self,
        session: &TerminalSession,
        settings: &Settings,
    ) -> Vec<usize> {
        if settings.dangerous_commands.scope == HighlightScope::Disabled {
            return Vec::new();
        }
        let grid = &session.grid;
        let top = grid.scrollback_rows as i64 - grid.display_offset as i64;
        let bottom = top + grid.rows as i64 - 1;
        let mut rows: Vec<usize> = self
            .danger
            .input_rows
            .visible_rows(top, bottom)
            .into_iter()
            .map(|row| (row - top) as usize)
            .collect();
        if output_scope_allows(settings, session) {
            rows.extend(
                self.danger
                    .output_rows
                    .iter()
                    .filter(|row| (top..=bottom).contains(*row))
                    .map(|row| (row - top) as usize),
            );
        }
        rows.sort_unstable();
        rows.dedup();
        rows
    }

    /// Viewport rows to tint in this frame (`dangerousRowTints`). Scans the
    /// output rows when a scan is due or the viewport moved.
    pub(super) fn danger_rows_for_frame(
        &mut self,
        session: &TerminalSession,
        settings: &Settings,
    ) -> Vec<usize> {
        let danger = &settings.dangerous_commands;
        if danger.scope == HighlightScope::Disabled {
            return Vec::new();
        }
        let grid = &session.grid;
        let top = grid.scrollback_rows as i64 - grid.display_offset as i64;
        let bottom = top + grid.rows as i64 - 1;
        let mut rows: Vec<usize> = self
            .danger
            .input_rows
            .visible_rows(top, bottom)
            .into_iter()
            .map(|r| (r - top) as usize)
            .collect();
        if output_scope_allows(settings, session) {
            if self.danger.patterns != danger.patterns {
                self.danger.patterns = danger.patterns.clone();
                self.danger.cache.clear();
                self.danger.due = true;
            }
            let viewport = (grid.display_offset as i64, grid.cols, grid.rows);
            if self.danger.due || self.danger.scanned != Some(viewport) {
                self.danger.due = false;
                self.danger.scanned = Some(viewport);
                let (input_lag, output_lag) = session.ui_lag_ms();
                let low_power = danger_highlight::low_power_active(
                    danger.highlight_low_power,
                    self.danger.burst.is_active(),
                    danger_highlight::is_cpu_saturated(input_lag, output_lag),
                );
                let cols = grid.cols as usize;
                let texts: Vec<String> = if cols == 0 {
                    Vec::new()
                } else {
                    grid.cells
                        .chunks(cols)
                        .map(|chunk| chunk.iter().map(|c| c.character).collect())
                        .collect()
                };
                let cache = &mut self.danger.cache;
                let found = feature_profiler::measure(Feature::DangerScan, 0, || {
                    danger_highlight::scan_rows(&texts, cols, &danger.patterns, low_power, cache)
                });
                self.danger.output_rows = found.into_iter().map(|r| top + r as i64).collect();
            }
            rows.extend(
                self.danger
                    .output_rows
                    .iter()
                    .filter(|r| (top..=bottom).contains(*r))
                    .map(|r| (r - top) as usize),
            );
        }
        rows.sort_unstable();
        rows.dedup();
        rows
    }
}
