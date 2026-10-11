//! (dev) Feature profiler (`Performance/FeatureProfiler.swift`): how long
//! each feature took (output processing, rendering, highlight, danger scan,
//! AI detection...), totals over the last 10 s and 60 s from one-second
//! buckets (120 kept), and the last 300 events.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// `FeatureMetric`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Feature {
    OutputProcessing,
    TerminalRender,
    HighlightDraw,
    DangerScan,
    AnsiParse,
    LocalEcho,
    Semantic,
    AiDetect,
    RemoteOutput,
    MetalRender,
    OutputMainThread,
    PromptUpdate,
    DevServerDetect,
}

impl Feature {
    pub const ALL: [Feature; 13] = [
        Feature::OutputProcessing,
        Feature::TerminalRender,
        Feature::HighlightDraw,
        Feature::DangerScan,
        Feature::AnsiParse,
        Feature::LocalEcho,
        Feature::Semantic,
        Feature::AiDetect,
        Feature::RemoteOutput,
        Feature::MetalRender,
        Feature::OutputMainThread,
        Feature::PromptUpdate,
        Feature::DevServerDetect,
    ];

    /// Display name (Swift raw value).
    pub fn label(self) -> &'static str {
        match self {
            Feature::OutputProcessing => "Output",
            Feature::TerminalRender => "Render",
            Feature::HighlightDraw => "Highlight",
            Feature::DangerScan => "Danger Scan",
            Feature::AnsiParse => "ANSI Parse",
            Feature::LocalEcho => "Local Echo",
            Feature::Semantic => "Semantic",
            Feature::AiDetect => "AI Detect",
            Feature::RemoteOutput => "Remote Output",
            Feature::MetalRender => "Metal Render",
            Feature::OutputMainThread => "Output Main",
            Feature::PromptUpdate => "Prompt Update",
            Feature::DevServerDetect => "Dev Server",
        }
    }
}

/// `FeatureTotals`.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Totals {
    pub total_ms: f64,
    pub count: usize,
    pub max_ms: f64,
    pub total_bytes: usize,
}

impl Totals {
    fn add(&mut self, ms: f64, bytes: usize) {
        self.total_ms += ms;
        self.count += 1;
        self.max_ms = self.max_ms.max(ms);
        self.total_bytes += bytes;
    }

    fn merge(&mut self, other: &Totals) {
        self.total_ms += other.total_ms;
        self.count += other.count;
        self.max_ms = self.max_ms.max(other.max_ms);
        self.total_bytes += other.total_bytes;
    }

    pub fn average_ms(&self) -> f64 {
        if self.count == 0 {
            0.0
        } else {
            self.total_ms / self.count as f64
        }
    }
}

/// `FeatureEvent`.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub feature: Feature,
    pub duration_ms: i64,
    pub bytes: usize,
    /// Seconds since the Unix epoch.
    pub second: i64,
    pub metadata: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub last_10s: HashMap<Feature, Totals>,
    pub last_60s: HashMap<Feature, Totals>,
    /// Newest first.
    pub recent: Vec<Event>,
}

impl Snapshot {
    /// Numeric diagnostics, without caller metadata or terminal content.
    pub fn to_json(&self, event_limit: usize) -> serde_json::Value {
        let totals = |window: &HashMap<Feature, Totals>| {
            Feature::ALL
                .into_iter()
                .filter_map(|feature| {
                    let stats = window.get(&feature)?;
                    Some(serde_json::json!({
                        "feature": feature.label(), "sample_count": stats.count,
                        "total_ms": stats.total_ms, "average_ms": stats.average_ms(),
                        "max_ms": stats.max_ms, "total_bytes": stats.total_bytes
                    }))
                })
                .collect::<Vec<_>>()
        };
        let recent = self
            .recent
            .iter()
            .take(event_limit.min(EVENT_CAPACITY))
            .map(|event| {
                serde_json::json!({"feature": event.feature.label(),
                "duration_ms": event.duration_ms, "bytes": event.bytes,
                "at_unix_seconds": event.second})
            })
            .collect::<Vec<_>>();
        serde_json::json!({"last_10s": totals(&self.last_10s),
            "last_60s": totals(&self.last_60s), "recent_events": recent})
    }

    /// A plain-text table (feature, count, average, max over 10 s and 60 s).
    pub fn report(&self) -> String {
        let mut out =
            String::from("Feature          10s: n   avg ms   max ms | 60s: n   avg ms   max ms\n");
        for feature in Feature::ALL {
            let a = self.last_10s.get(&feature).copied().unwrap_or_default();
            let b = self.last_60s.get(&feature).copied().unwrap_or_default();
            if b.count == 0 {
                continue;
            }
            out.push_str(&format!(
                "{:<16} {:>6} {:>8.2} {:>8.2} | {:>6} {:>8.2} {:>8.2}\n",
                feature.label(),
                a.count,
                a.average_ms(),
                a.max_ms,
                b.count,
                b.average_ms(),
                b.max_ms
            ));
        }
        out
    }
}

const BUCKET_SECONDS: usize = 120;
const EVENT_CAPACITY: usize = 300;

#[derive(Default)]
pub struct Profiler {
    buckets: VecDeque<(i64, HashMap<Feature, Totals>)>,
    events: VecDeque<Event>,
}

impl Profiler {
    pub fn record_at(
        &mut self,
        second: i64,
        feature: Feature,
        ms: f64,
        bytes: usize,
        metadata: Option<String>,
    ) {
        if !ms.is_finite() || ms < 0.0 {
            return;
        }
        match self.buckets.back_mut() {
            Some((s, totals)) if *s == second => totals.entry(feature).or_default().add(ms, bytes),
            _ => {
                let mut totals = HashMap::new();
                totals
                    .entry(feature)
                    .or_insert_with(Totals::default)
                    .add(ms, bytes);
                self.buckets.push_back((second, totals));
                while self.buckets.len() > BUCKET_SECONDS {
                    self.buckets.pop_front();
                }
            }
        }
        self.events.push_back(Event {
            feature,
            duration_ms: ms.round() as i64,
            bytes,
            second,
            metadata,
        });
        while self.events.len() > EVENT_CAPACITY {
            self.events.pop_front();
        }
    }

    pub fn snapshot_at(&self, now_second: i64) -> Snapshot {
        Snapshot {
            last_10s: self.totals_from(now_second - 9),
            last_60s: self.totals_from(now_second - 59),
            recent: self.events.iter().rev().cloned().collect(),
        }
    }

    fn totals_from(&self, start: i64) -> HashMap<Feature, Totals> {
        let mut out: HashMap<Feature, Totals> = HashMap::new();
        for (second, totals) in &self.buckets {
            if *second < start {
                continue;
            }
            for (feature, t) in totals {
                out.entry(*feature).or_default().merge(t);
            }
        }
        out
    }
}

static SHARED: Mutex<Option<Profiler>> = Mutex::new(None);

fn now_second() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Record one measurement in the shared profiler.
pub fn record(feature: Feature, ms: f64, bytes: usize) {
    if let Ok(mut shared) = SHARED.lock() {
        shared.get_or_insert_with(Profiler::default).record_at(
            now_second(),
            feature,
            ms,
            bytes,
            None,
        );
    }
}

/// Time `f` as `feature`.
pub fn measure<T>(feature: Feature, bytes: usize, f: impl FnOnce() -> T) -> T {
    let start = Instant::now();
    let out = f();
    record(feature, start.elapsed().as_secs_f64() * 1000.0, bytes);
    out
}

/// Totals and recent events of the shared profiler.
pub fn snapshot() -> Snapshot {
    SHARED
        .lock()
        .ok()
        .and_then(|shared| shared.as_ref().map(|p| p.snapshot_at(now_second())))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_sum_buckets() {
        let mut p = Profiler::default();
        p.record_at(100, Feature::TerminalRender, 2.0, 0, None);
        p.record_at(100, Feature::TerminalRender, 4.0, 0, None);
        p.record_at(150, Feature::TerminalRender, 10.0, 0, None);
        p.record_at(155, Feature::OutputProcessing, 1.0, 512, Some("tab".into()));
        let s = p.snapshot_at(155);
        let render10 = s.last_10s[&Feature::TerminalRender];
        assert_eq!((render10.count, render10.max_ms), (1, 10.0));
        let render60 = s.last_60s[&Feature::TerminalRender];
        assert_eq!(render60.count, 3);
        assert_eq!(render60.average_ms(), 16.0 / 3.0);
        assert_eq!(s.last_60s[&Feature::OutputProcessing].total_bytes, 512);
        assert_eq!(s.recent[0].feature, Feature::OutputProcessing);
        assert!(s.report().contains("Render"));
    }

    #[test]
    fn json_diagnostics_are_numeric_bounded_and_exclude_metadata() {
        let mut profiler = Profiler::default();
        profiler.record_at(
            100,
            Feature::TerminalRender,
            2.5,
            64,
            Some("private command".into()),
        );
        profiler.record_at(100, Feature::TerminalRender, 3.5, 128, None);
        let value = profiler.snapshot_at(100).to_json(1);
        assert_eq!(value["last_10s"][0]["sample_count"], 2);
        assert_eq!(value["last_10s"][0]["average_ms"], 3.0);
        assert_eq!(value["recent_events"].as_array().unwrap().len(), 1);
        assert!(!value.to_string().contains("private command"));
        assert!(
            profiler.snapshot_at(100).to_json(0)["recent_events"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn invalid_durations_do_not_corrupt_diagnostics() {
        let mut profiler = Profiler::default();
        for ms in [f64::NAN, f64::INFINITY, -1.0] {
            profiler.record_at(100, Feature::TerminalRender, ms, 0, None);
        }
        assert!(profiler.snapshot_at(100).last_10s.is_empty());
    }

    #[test]
    fn capacity_limits() {
        let mut p = Profiler::default();
        for i in 0..400 {
            p.record_at(i, Feature::AiDetect, 1.0, 0, None);
        }
        assert_eq!(p.buckets.len(), BUCKET_SECONDS);
        assert_eq!(p.events.len(), EVENT_CAPACITY);
        assert_eq!(p.snapshot_at(399).last_10s[&Feature::AiDetect].count, 10);
    }
}
