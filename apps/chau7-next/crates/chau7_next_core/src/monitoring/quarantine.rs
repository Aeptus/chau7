//! Current Swift stale session source quarantine: one exact reconciliation,
//! then suppressed repeats with periodic bounded summaries. No event payloads.
use std::collections::HashMap;
use uuid::Uuid;

const MAX_SOURCES: usize = 512;
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SourceKey {
    pub tab_id: Uuid,
    pub session_id: String,
    pub provider: String,
}
impl SourceKey {
    pub fn new(tab_id: Uuid, session_id: &str, provider: &str) -> Self {
        Self {
            tab_id,
            session_id: session_id.trim().to_owned(),
            provider: provider.trim().to_lowercase(),
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    ReconcileAndReport,
    Suppress,
    ReportSummary { suppressed_count: u64 },
}
#[derive(Clone, Copy)]
struct Entry {
    last_report_at: f64,
    suppressed_count: u64,
}
pub struct Quarantine {
    entries: HashMap<SourceKey, Entry>,
    report_interval: f64,
}
impl Default for Quarantine {
    fn default() -> Self {
        Self::new(60.0)
    }
}
impl Quarantine {
    pub fn new(report_interval: f64) -> Self {
        Self {
            entries: HashMap::new(),
            report_interval: if report_interval.is_finite() {
                report_interval.max(1.0)
            } else {
                60.0
            },
        }
    }
    pub fn record_failure(&mut self, key: SourceKey, now: f64) -> Decision {
        let now = if now.is_finite() { now } else { 0.0 };
        if let Some(entry) = self.entries.get_mut(&key) {
            entry.suppressed_count = entry.suppressed_count.saturating_add(1);
            if now - entry.last_report_at < self.report_interval {
                return Decision::Suppress;
            }
            let suppressed_count = entry.suppressed_count;
            entry.suppressed_count = 0;
            entry.last_report_at = now;
            return Decision::ReportSummary { suppressed_count };
        }
        if self.entries.len() >= MAX_SOURCES
            && let Some(oldest) = self
                .entries
                .iter()
                .min_by(|(ka, a), (kb, b)| {
                    a.last_report_at
                        .total_cmp(&b.last_report_at)
                        .then_with(|| ka.tab_id.cmp(&kb.tab_id))
                        .then_with(|| ka.session_id.cmp(&kb.session_id))
                })
                .map(|(key, _)| key.clone())
        {
            self.entries.remove(&oldest);
        }
        self.entries.insert(
            key,
            Entry {
                last_report_at: now,
                suppressed_count: 0,
            },
        );
        Decision::ReconcileAndReport
    }
    pub fn clear(&mut self, key: &SourceKey) -> bool {
        self.entries.remove(key).is_some()
    }
    pub fn contains(&self, key: &SourceKey) -> bool {
        self.entries.contains_key(key)
    }
    pub fn retain_tabs(&mut self, live: &std::collections::HashSet<Uuid>) {
        self.entries.retain(|key, _| live.contains(&key.tab_id));
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn key(tab: Uuid, id: &str) -> SourceKey {
        SourceKey::new(tab, id, " Claude ")
    }
    #[test]
    fn first_failure_reconciles_repeats_coalesce_and_success_clears() {
        let mut quarantine = Quarantine::default();
        let source = key(Uuid::new_v4(), " s1 ");
        assert_eq!(source.provider, "claude");
        assert_eq!(source.session_id, "s1");
        assert_eq!(
            quarantine.record_failure(source.clone(), 0.0),
            Decision::ReconcileAndReport
        );
        for time in 1..60 {
            assert_eq!(
                quarantine.record_failure(source.clone(), f64::from(time)),
                Decision::Suppress
            );
        }
        assert_eq!(
            quarantine.record_failure(source.clone(), 60.0),
            Decision::ReportSummary {
                suppressed_count: 60
            }
        );
        assert_eq!(
            quarantine.record_failure(source.clone(), 61.0),
            Decision::Suppress
        );
        assert!(quarantine.clear(&source));
        assert!(!quarantine.contains(&source));
        assert_eq!(
            quarantine.record_failure(source, 62.0),
            Decision::ReconcileAndReport
        );
    }
    #[test]
    fn sources_are_scoped_bounded_and_closed_tabs_removed() {
        let mut quarantine = Quarantine::default();
        let tab = Uuid::new_v4();
        for index in 0..1024 {
            quarantine.record_failure(key(tab, &format!("s{index}")), f64::from(index));
            assert!(quarantine.entries.len() <= MAX_SOURCES);
        }
        let other = Uuid::new_v4();
        quarantine.record_failure(key(other, "s1023"), 1024.0);
        quarantine.retain_tabs(&[other].into_iter().collect());
        assert_eq!(quarantine.entries.len(), 1);
        assert!(!quarantine.contains(&key(tab, "s1023")));
    }
    #[test]
    fn invalid_clock_and_interval_never_panic_or_overflow() {
        let mut quarantine = Quarantine::new(f64::NAN);
        let source = key(Uuid::new_v4(), "s1");
        assert_eq!(
            quarantine.record_failure(source.clone(), f64::NAN),
            Decision::ReconcileAndReport
        );
        assert_eq!(
            quarantine.record_failure(source.clone(), -1.0),
            Decision::Suppress
        );
        assert_eq!(
            quarantine.record_failure(source, 60.0),
            Decision::ReportSummary {
                suppressed_count: 2
            }
        );
    }
}
