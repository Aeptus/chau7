//! Current Swift active/completed query ordering and content-state projection.
use super::run::TelemetryRun;
use serde::Serialize;
use std::collections::HashSet;
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ContentState {
    Missing,
    Partial,
    Final,
}
pub fn completed_content_state(run: &TelemetryRun) -> ContentState {
    if run.turn_count > 0
        || run
            .raw_transcript_ref
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty())
    {
        ContentState::Final
    } else {
        ContentState::Missing
    }
}
pub fn merge_runs(
    mut active: Vec<TelemetryRun>,
    stored: Vec<TelemetryRun>,
    offset: usize,
    limit: Option<usize>,
) -> Vec<TelemetryRun> {
    active.sort_by(|a, b| {
        b.started_at
            .cmp(&a.started_at)
            .then_with(|| b.id.cmp(&a.id))
    });
    let mut seen = HashSet::new();
    active
        .into_iter()
        .chain(stored)
        .filter(|r| seen.insert(r.id.clone()))
        .skip(offset)
        .take(limit.unwrap_or(usize::MAX))
        .collect()
}
pub fn combined_repository_cost(run: f64, proxy: f64, attributed: f64) -> f64 {
    run + proxy - attributed.max(0.).min(run.max(0.)).min(proxy.max(0.))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn active_identity_priority_and_pagination() {
        let a = TelemetryRun::new("claude", "/repo");
        let mut old = a.clone();
        old.total_input_tokens = Some(20);
        let mut b = a.clone();
        b.id = "b".into();
        b.started_at -= chrono::Duration::seconds(1);
        let rows = merge_runs(vec![a.clone()], vec![old, b.clone()], 0, None);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0], a);
        assert_eq!(
            merge_runs(vec![a.clone()], vec![a, b.clone()], 1, Some(1)),
            vec![b]
        );
    }
    #[test]
    fn missing_content_and_retained_overlap() {
        let mut run = TelemetryRun::new("claude", "/repo");
        assert_eq!(completed_content_state(&run), ContentState::Missing);
        run.turn_count = 1;
        assert_eq!(completed_content_state(&run), ContentState::Final);
        assert_eq!(combined_repository_cost(10., 8., 3.), 15.);
        assert_eq!(combined_repository_cost(2., 8., 10.), 8.);
        assert_eq!(combined_repository_cost(10., 1., 5.), 10.);
    }
}
