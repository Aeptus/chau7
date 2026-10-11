//! (dev) Input, output and highlight latency of a terminal session
//! (`TerminalSessionModel+Telemetry.swift` and the latency parts of
//! `TerminalSessionModel+ShellIntegration.swift`).
//!
//! Input latency runs from a keystroke to the next PTY output; output
//! latency from PTY output to the frame that shows it. The last 120 samples
//! of each give an average and p50/p95. A sample over the spike threshold
//! (60 ms input, 120 ms output and highlight) is logged at most every 15 s
//! per kind and added to a lag timeline (120 events) for the debug console.
//! Times are seconds as `f64` (any monotonic clock).

/// Samples kept per kind (`latencySampleCapacity`).
pub const SAMPLE_CAPACITY: usize = 120;
/// Lag events kept (`lagTimelineCapacity`).
pub const LAG_TIMELINE_CAPACITY: usize = 120;
/// Longer samples are stale and dropped (`maxAcceptedLatencyMs`).
pub const MAX_ACCEPTED_MS: f64 = 10_000.0;
/// Minimum time between two logged spikes of one kind.
pub const SPIKE_COOLDOWN_SECS: f64 = 15.0;
/// A pending output measure is dropped after this long without a frame.
pub const OUTPUT_FALLBACK_SECS: f64 = 0.2;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LagKind {
    Input,
    Output,
    Highlight,
}

impl LagKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Input => "input",
            Self::Output => "output",
            Self::Highlight => "highlight",
        }
    }

    /// Spike threshold in ms.
    pub fn threshold_ms(self) -> f64 {
        match self {
            Self::Input => 60.0,
            Self::Output | Self::Highlight => 120.0,
        }
    }
}

/// Ring buffer of the last samples (`LatencySampleBuffer`).
#[derive(Debug, Clone)]
pub struct SampleBuffer {
    buffer: Vec<i64>,
    index: usize,
    count: usize,
}

impl SampleBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            buffer: vec![0; capacity.max(1)],
            index: 0,
            count: 0,
        }
    }

    pub fn push(&mut self, value: i64) {
        self.buffer[self.index] = value;
        self.index = (self.index + 1) % self.buffer.len();
        self.count = (self.count + 1).min(self.buffer.len());
    }

    pub fn reset(&mut self) {
        self.index = 0;
        self.count = 0;
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    pub fn values(&self) -> Vec<i64> {
        if self.count >= self.buffer.len() {
            self.buffer.clone()
        } else {
            self.buffer[..self.count].to_vec()
        }
    }

    /// Average of the kept samples (`recentAverage`, integer division).
    pub fn recent_average(&self) -> Option<i64> {
        let values = self.values();
        if values.is_empty() {
            None
        } else {
            Some(values.iter().sum::<i64>() / values.len() as i64)
        }
    }
}

/// Nearest-rank percentile, index rounded half to even (`percentileValue`).
pub fn percentile(samples: &[i64], p: f64) -> Option<i64> {
    if samples.is_empty() {
        return None;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let p = p.clamp(0.0, 1.0);
    let index = ((sorted.len() - 1) as f64 * p).round_ties_even() as usize;
    Some(sorted[index])
}

/// `"p50ms / p95ms (n=N)"` or `"n/a"`.
pub fn percentiles_summary(buffer: &SampleBuffer) -> String {
    let values = buffer.values();
    match (percentile(&values, 0.5), percentile(&values, 0.95)) {
        (Some(p50), Some(p95)) => format!("{p50}ms / {p95}ms (n={})", values.len()),
        _ => "n/a".into(),
    }
}

/// One spike in the lag timeline (`LagEvent`).
#[derive(Debug, Clone, PartialEq)]
pub struct LagEvent {
    pub kind: LagKind,
    pub elapsed_ms: i64,
    pub average_ms: i64,
    pub p50: Option<i64>,
    pub p95: Option<i64>,
    pub sample_count: usize,
    /// Same clock as the samples.
    pub at: f64,
}

#[derive(Debug, Clone)]
struct KindState {
    samples: SampleBuffer,
    last_ms: Option<i64>,
    last_logged_at: Option<f64>,
}

impl KindState {
    fn new() -> Self {
        Self {
            samples: SampleBuffer::new(SAMPLE_CAPACITY),
            last_ms: None,
            last_logged_at: None,
        }
    }
}

/// Latency of one session.
#[derive(Debug, Clone)]
pub struct LatencyTracker {
    input: KindState,
    output: KindState,
    highlight: KindState,
    pending_input_at: Option<f64>,
    pending_output_at: Option<f64>,
    timeline: Vec<LagEvent>,
}

impl Default for LatencyTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl LatencyTracker {
    pub fn new() -> Self {
        Self {
            input: KindState::new(),
            output: KindState::new(),
            highlight: KindState::new(),
            pending_input_at: None,
            pending_output_at: None,
            timeline: Vec::new(),
        }
    }

    fn state(&self, kind: LagKind) -> &KindState {
        match kind {
            LagKind::Input => &self.input,
            LagKind::Output => &self.output,
            LagKind::Highlight => &self.highlight,
        }
    }

    fn state_mut(&mut self, kind: LagKind) -> &mut KindState {
        match kind {
            LagKind::Input => &mut self.input,
            LagKind::Output => &mut self.output,
            LagKind::Highlight => &mut self.highlight,
        }
    }

    /// The user typed (`markInputLatencyStart`).
    pub fn mark_input(&mut self, now: f64) {
        self.pending_input_at = Some(now);
    }

    /// PTY output arrived: ends a pending input measure and starts an
    /// output measure (`recordInputLatencyIfNeeded`, `markOutputLatencyStart`).
    /// Returns a spike to log, if any.
    pub fn mark_output(&mut self, now: f64) -> Option<LagEvent> {
        let spike = self
            .pending_input_at
            .take()
            .and_then(|start| self.record(LagKind::Input, (now - start) * 1000.0, now));
        if self.pending_output_at.is_none() {
            self.pending_output_at = Some(now);
        }
        spike
    }

    /// A frame showing the output was drawn (`recordOutputLatencyIfNeeded`).
    pub fn mark_rendered(&mut self, now: f64) -> Option<LagEvent> {
        let start = self.pending_output_at.take()?;
        self.record(LagKind::Output, (now - start) * 1000.0, now)
    }

    /// Drops an output measure no frame closed in time.
    pub fn expire_output(&mut self, now: f64) {
        if self
            .pending_output_at
            .is_some_and(|start| now - start >= OUTPUT_FALLBACK_SECS)
        {
            self.pending_output_at = None;
        }
    }

    /// A dangerous-command highlight pass took `elapsed_ms`.
    pub fn record_highlight(&mut self, elapsed_ms: f64, now: f64) -> Option<LagEvent> {
        self.record(LagKind::Highlight, elapsed_ms, now)
    }

    /// Adds a sample. Returns the lag event when it is a spike worth logging.
    pub fn record(&mut self, kind: LagKind, elapsed_ms: f64, now: f64) -> Option<LagEvent> {
        if !elapsed_ms.is_finite() || !now.is_finite() {
            return None;
        }
        let elapsed_ms = elapsed_ms.max(0.0);
        if elapsed_ms > MAX_ACCEPTED_MS {
            return None;
        }
        let rounded = elapsed_ms.round() as i64;
        let state = self.state_mut(kind);
        state.samples.push(rounded);
        state.last_ms = Some(rounded);
        if elapsed_ms < kind.threshold_ms() {
            return None;
        }
        if state
            .last_logged_at
            .is_some_and(|last| now - last < SPIKE_COOLDOWN_SECS)
        {
            return None;
        }
        state.last_logged_at = Some(now);
        let values = state.samples.values();
        let event = LagEvent {
            kind,
            elapsed_ms: rounded,
            average_ms: state.samples.recent_average().unwrap_or(-1),
            p50: percentile(&values, 0.5),
            p95: percentile(&values, 0.95),
            sample_count: values.len(),
            at: now,
        };
        self.timeline.push(event.clone());
        let excess = self.timeline.len().saturating_sub(LAG_TIMELINE_CAPACITY);
        self.timeline.drain(..excess);
        Some(event)
    }

    /// `"12ms (avg 9ms)"` or `"n/a"`.
    pub fn summary(&self, kind: LagKind) -> String {
        let state = self.state(kind);
        match (state.last_ms, state.samples.recent_average()) {
            (None, _) => "n/a".into(),
            (Some(last), Some(avg)) => format!("{last}ms (avg {avg}ms)"),
            (Some(last), None) => format!("{last}ms"),
        }
    }

    /// Recent average, else the last sample (`inputLatencyAverageMs ??
    /// inputLatencyMs`).
    pub fn lag_ms(&self, kind: LagKind) -> Option<i64> {
        let state = self.state(kind);
        state.samples.recent_average().or(state.last_ms)
    }

    pub fn percentiles(&self, kind: LagKind) -> String {
        percentiles_summary(&self.state(kind).samples)
    }

    /// Structured samples for diagnostics, independent of display formatting.
    pub fn statistics(&self, kind: LagKind) -> serde_json::Value {
        let state = self.state(kind);
        let values = state.samples.values();
        serde_json::json!({
            "last_ms": state.last_ms, "average_ms": state.samples.recent_average(),
            "p50_ms": percentile(&values, 0.5), "p95_ms": percentile(&values, 0.95),
            "max_ms": values.iter().max(), "sample_count": values.len(),
            "spike_threshold_ms": kind.threshold_ms()
        })
    }

    pub fn timeline(&self) -> &[LagEvent] {
        &self.timeline
    }

    pub fn clear_timeline(&mut self) {
        self.timeline.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numeric_statistics_have_units_and_missing_values() {
        let mut tracker = LatencyTracker::default();
        assert_eq!(
            tracker.statistics(LagKind::Input)["last_ms"],
            serde_json::Value::Null
        );
        for value in [10.0, 20.0, 30.0] {
            tracker.record(LagKind::Input, value, 0.0);
        }
        let value = tracker.statistics(LagKind::Input);
        assert_eq!(value["sample_count"], 3);
        assert_eq!(value["p50_ms"], 20);
        assert_eq!(value["p95_ms"], 30);
        assert_eq!(value["average_ms"], 20);
        tracker.record(LagKind::Input, f64::NAN, 0.0);
        tracker.record(LagKind::Input, f64::INFINITY, 0.0);
        assert_eq!(tracker.statistics(LagKind::Input)["sample_count"], 3);
    }

    #[test]
    fn ring_buffer_and_average() {
        let mut b = SampleBuffer::new(3);
        assert!(b.is_empty());
        assert_eq!(b.recent_average(), None);
        for v in [1, 2, 3, 10] {
            b.push(v);
        }
        assert_eq!(b.values().len(), 3);
        assert_eq!(b.recent_average(), Some(5));
        b.reset();
        assert!(b.is_empty());
    }

    #[test]
    fn percentiles_round_half_even() {
        assert_eq!(percentile(&[], 0.5), None);
        assert_eq!(percentile(&[5, 1, 3], 0.5), Some(3));
        // (4 - 1) * 0.5 = 1.5, rounds to 2.
        assert_eq!(percentile(&[1, 2, 3, 4], 0.5), Some(3));
        assert_eq!(percentile(&[1, 2, 3, 4], 0.95), Some(4));
    }

    #[test]
    fn input_and_output_samples() {
        let mut t = LatencyTracker::new();
        assert_eq!(t.summary(LagKind::Input), "n/a");
        t.mark_input(0.0);
        assert!(t.mark_output(0.010).is_none());
        assert_eq!(t.summary(LagKind::Input), "10ms (avg 10ms)");
        assert!(t.mark_rendered(0.015).is_none());
        assert_eq!(t.summary(LagKind::Output), "5ms (avg 5ms)");
        assert_eq!(t.percentiles(LagKind::Output), "5ms / 5ms (n=1)");
        // No pending output: nothing recorded.
        assert!(t.mark_rendered(1.0).is_none());
        t.mark_output(2.0);
        t.expire_output(2.3);
        assert!(t.mark_rendered(2.4).is_none());
    }

    #[test]
    fn spikes_are_rate_limited() {
        let mut t = LatencyTracker::new();
        t.mark_input(0.0);
        let spike = t.mark_output(0.080).unwrap();
        assert_eq!(spike.kind, LagKind::Input);
        assert_eq!(spike.elapsed_ms, 80);
        t.mark_input(1.0);
        assert!(t.mark_output(1.1).is_none(), "cooldown");
        t.mark_input(20.0);
        assert!(t.mark_output(20.1).is_some());
        assert_eq!(t.timeline().len(), 2);
        assert!(t.record(LagKind::Output, 20_000.0, 30.0).is_none(), "stale");
        assert!(t.record_highlight(130.0, 30.0).is_some());
        t.clear_timeline();
        assert!(t.timeline().is_empty());
    }
}
