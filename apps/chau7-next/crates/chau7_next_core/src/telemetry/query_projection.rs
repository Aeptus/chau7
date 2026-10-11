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
/// MCP queries remain bounded even when a client sends extreme integers.
pub const MAX_QUERY_LIMIT: usize = 1_000;
pub const MAX_QUERY_OFFSET: usize = 10_000;
pub const MAX_STORE_SCAN: usize = 12_000;

pub fn query_window(filter: &super::run::TelemetryRunFilter) -> (usize, usize) {
    let offset = filter.offset.unwrap_or(0).clamp(0, MAX_QUERY_OFFSET as i64) as usize;
    let limit = filter.limit.unwrap_or(50).clamp(0, MAX_QUERY_LIMIT as i64) as usize;
    (offset, limit)
}

pub fn matches_filter(run: &TelemetryRun, filter: &super::run::TelemetryRunFilter) -> bool {
    filter
        .parent_run_id
        .as_ref()
        .is_none_or(|id| run.parent_run_id.as_ref() == Some(id))
        && filter
            .session_id
            .as_ref()
            .is_none_or(|id| run.session_id.as_ref() == Some(id))
        && filter
            .repo_path
            .as_ref()
            .is_none_or(|path| run.repo_path.as_ref() == Some(path))
        && filter
            .provider
            .as_ref()
            .is_none_or(|provider| &run.provider == provider)
        && filter.after.is_none_or(|at| run.started_at >= at)
        && filter.before.is_none_or(|at| run.started_at <= at)
}

/// Keep live lifecycle, session identity and tags. A separately persisted proxy
/// observation may carry newer authoritative metrics than the live recorder.
pub fn with_proxy_metrics(mut live: TelemetryRun, stored: Option<TelemetryRun>) -> TelemetryRun {
    use super::token_metrics::TokenUsageSource;
    if let Some(stored) = stored.filter(|r| r.token_usage_source == Some(TokenUsageSource::Proxy)) {
        if stored.model.is_some() {
            live.model = stored.model;
        }
        live.total_input_tokens = stored.total_input_tokens;
        live.total_cached_input_tokens = stored.total_cached_input_tokens;
        live.total_cache_creation_input_tokens = stored.total_cache_creation_input_tokens;
        live.total_cache_read_input_tokens = stored.total_cache_read_input_tokens;
        live.total_output_tokens = stored.total_output_tokens;
        live.total_reasoning_output_tokens = stored.total_reasoning_output_tokens;
        live.token_usage_source = stored.token_usage_source;
        live.token_usage_state = stored.token_usage_state;
        live.cost_usd = stored.cost_usd;
        live.cost_source = stored.cost_source;
        live.cost_state = stored.cost_state;
        for (key, value) in stored
            .metadata
            .into_iter()
            .filter(|(k, _)| k.starts_with("proxy_"))
        {
            live.metadata.insert(key, value);
        }
    }
    live
}

pub fn project_run(run: &TelemetryRun, active: bool, live_content: bool) -> serde_json::Value {
    use super::token_metrics::CostSource;
    use serde_json::json;
    let mut value = serde_json::to_value(run).unwrap_or_else(|_| json!({}));
    let state = if active {
        if live_content {
            ContentState::Partial
        } else {
            ContentState::Missing
        }
    } else {
        completed_content_state(run)
    };
    value["run_state"] = json!(if active { "active" } else { "completed" });
    value["content_state"] = serde_json::to_value(state).unwrap_or_default();
    let count = |key: &str| {
        run.metadata
            .get(key)
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(0)
    };
    value["measurement_coverage"] = json!({
        "state": run.metadata.get("proxy_coverage").map(String::as_str).unwrap_or(
            if run.cost_source == Some(CostSource::Estimated) { "estimated" } else { "unavailable" }),
        "attributed_requests": count("proxy_request_count"),
        "priced_requests": count("proxy_priced_request_count"),
        "unobserved_usage": "unknown"
    });
    value
}

pub fn project_sessions(
    rows: Vec<serde_json::Map<String, serde_json::Value>>,
    active: &[TelemetryRun],
    stored: &[TelemetryRun],
    active_only: bool,
) -> Vec<serde_json::Map<String, serde_json::Value>> {
    use serde_json::{Value, json};
    let mut active_counts = std::collections::HashMap::<&str, usize>::new();
    let active_ids: HashSet<_> = active.iter().map(|r| r.id.as_str()).collect();
    for run in active {
        if let Some(id) = run.session_id.as_deref() {
            *active_counts.entry(id).or_default() += 1;
        }
    }
    let mut latest_by_session = std::collections::HashMap::<&str, &TelemetryRun>::new();
    for run in active.iter().chain(stored) {
        let Some(id) = run.session_id.as_deref() else {
            continue;
        };
        let newer = latest_by_session
            .get(id)
            .is_none_or(|old| (run.started_at, &run.id) > (old.started_at, &old.id));
        if newer {
            latest_by_session.insert(id, run);
        }
    }
    rows.into_iter()
        .filter_map(|mut row| {
            let id = row.get("session_id")?.as_str()?.to_owned();
            if id.is_empty() {
                return None;
            }
            let live_count = active_counts.get(id.as_str()).copied().unwrap_or(0);
            if active_only && live_count == 0 {
                return None;
            }
            let total = row.get("run_count").and_then(Value::as_u64).unwrap_or(0);
            row.insert("active_run_count".into(), json!(live_count));
            row.insert(
                "completed_run_count".into(),
                json!(total.saturating_sub(live_count as u64)),
            );
            let latest = latest_by_session.get(id.as_str()).copied();
            let is_active = latest.is_some_and(|r| active_ids.contains(r.id.as_str()));
            row.insert(
                "latest_run_id".into(),
                json!(latest.map(|r| r.id.as_str()).unwrap_or("")),
            );
            row.insert(
                "latest_run_state".into(),
                json!(if is_active { "active" } else { "completed" }),
            );
            if let Some(latest) = latest {
                row.insert("provider".into(), json!(latest.provider));
                if let Some(repo) = &latest.repo_path {
                    row.insert("repo_path".into(), json!(repo));
                }
                row.insert(
                    "last_active".into(),
                    json!(
                        latest
                            .started_at
                            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
                    ),
                );
            }
            Some(row)
        })
        .collect()
}

/// Read at most the requested tail, including when the file grows after stat.
/// A partial leading JSONL row is discarded by callers' JSON parsing.
pub fn bounded_file_tail(path: &std::path::Path, max_bytes: u64) -> Option<String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(size.saturating_sub(max_bytes)))
        .ok()?;
    let mut bytes = Vec::new();
    file.take(max_bytes).read_to_end(&mut bytes).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

pub fn codex_live_turns(
    text: &str,
    session: &str,
    run: &TelemetryRun,
) -> Vec<super::turn::TelemetryTurn> {
    use super::turn::{TelemetryTurn, TurnRole};
    use serde_json::Value;
    let cutoff = run.started_at - chrono::Duration::seconds(1);
    let mut turns = Vec::new();
    for line in text.lines() {
        let Ok(row) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if row["session_id"].as_str() != Some(session) {
            continue;
        }
        let Some(content) = row["text"]
            .as_str()
            .map(str::trim)
            .filter(|t| !t.is_empty())
        else {
            continue;
        };
        let ts = &row["ts"];
        let seconds = ts
            .as_f64()
            .or_else(|| ts.as_str().and_then(|s| s.parse::<f64>().ok()));
        let timestamp = seconds
            .and_then(|n| {
                if !n.is_finite() {
                    return None;
                }
                chrono::DateTime::from_timestamp(
                    n.floor() as i64,
                    (n.fract().max(0.) * 1_000_000_000.) as u32,
                )
            })
            .or_else(|| super::date_codec::parse_iso8601(ts.as_str()));
        if timestamp.is_some_and(|at| at < cutoff) {
            continue;
        }
        let mut turn = TelemetryTurn::new(&run.id, turns.len() as i64, TurnRole::Human);
        turn.id = format!("{}-live-{}", run.id, turns.len());
        turn.content = Some(content.into());
        turn.timestamp = timestamp;
        turns.push(turn);
        if turns.len() >= 50 {
            break;
        }
    }
    turns
}

pub fn pty_live_turns(text: &str, run: &TelemetryRun) -> Vec<super::turn::TelemetryTurn> {
    use super::turn::{TelemetryTurn, TurnRole};
    let sanitized = crate::escape_sanitizer::sanitize(text);
    let (content, _) = crate::mcp::output::format_pty_log_output(&sanitized, 80);
    let mut content = content.trim().to_owned();
    // One exceptionally long terminal line must not defeat the byte bound.
    if content.len() > crate::mcp::output::MAX_OUTPUT_BYTES {
        let mut start = content.len() - crate::mcp::output::MAX_OUTPUT_BYTES;
        while !content.is_char_boundary(start) {
            start += 1;
        }
        content = content[start..].to_owned();
    }
    if content.is_empty() {
        return Vec::new();
    }
    let mut turn = TelemetryTurn::new(&run.id, 0, TurnRole::Assistant);
    turn.id = format!("{}-live-pty", run.id);
    turn.content = Some(content);
    turn.timestamp = Some(chrono::Utc::now());
    vec![turn]
}

pub fn combined_repository_cost(run: f64, proxy: f64, attributed: f64) -> f64 {
    run + proxy - attributed.max(0.).min(run.max(0.)).min(proxy.max(0.))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_window_filters_and_coverage_are_truthful() {
        use super::super::run::TelemetryRunFilter;
        let mut run = TelemetryRun::new("codex", "/repo");
        run.parent_run_id = Some("parent".into());
        let mut filter = TelemetryRunFilter {
            parent_run_id: Some("parent".into()),
            limit: Some(i64::MAX),
            offset: Some(i64::MAX),
            ..Default::default()
        };
        assert_eq!(query_window(&filter), (MAX_QUERY_OFFSET, MAX_QUERY_LIMIT));
        assert!(matches_filter(&run, &filter));
        filter.before = Some(run.started_at - chrono::Duration::seconds(1));
        assert!(!matches_filter(&run, &filter));
        let value = project_run(&run, true, false);
        assert_eq!(value["content_state"], "missing");
        assert_eq!(value["measurement_coverage"]["unobserved_usage"], "unknown");
        assert!(value.get("costUSD").is_none());
        assert_eq!(project_run(&run, true, true)["content_state"], "partial");
        run.turn_count = 1;
        assert_eq!(project_run(&run, false, false)["content_state"], "final");
    }

    #[test]
    fn proxy_overlay_preserves_current_lifecycle_and_tags() {
        use super::super::token_metrics::TokenUsageSource;
        let mut live = TelemetryRun::new("claude", "/repo");
        live.session_id = Some("new-session".into());
        live.tags = vec!["new-tag".into()];
        let mut stored = live.clone();
        stored.session_id = Some("old-session".into());
        stored.ended_at = Some(chrono::Utc::now());
        stored.tags.clear();
        stored.token_usage_source = Some(TokenUsageSource::Proxy);
        stored.model = Some("observed-model".into());
        stored.total_output_tokens = Some(123);
        stored
            .metadata
            .insert("proxy_coverage".into(), "measured".into());
        let projected = with_proxy_metrics(live.clone(), Some(stored));
        assert_eq!(projected.session_id, live.session_id);
        assert_eq!(projected.tags, live.tags);
        assert!(projected.ended_at.is_none());
        assert_eq!(projected.total_output_tokens, Some(123));
        assert_eq!(projected.model.as_deref(), Some("observed-model"));
        assert_eq!(
            project_run(&projected, true, false)["measurement_coverage"]["state"],
            "measured"
        );
    }

    #[test]
    fn session_enrichment_tracks_newest_active_and_completed_runs() {
        use serde_json::json;
        let mut live = TelemetryRun::new("codex", "/repo");
        live.session_id = Some("S".into());
        let mut old = live.clone();
        old.id = "old".into();
        old.started_at -= chrono::Duration::seconds(1);
        let row = json!({"session_id":"S","run_count":2})
            .as_object()
            .unwrap()
            .clone();
        let projected = project_sessions(
            vec![row.clone()],
            std::slice::from_ref(&live),
            std::slice::from_ref(&old),
            true,
        );
        assert_eq!(projected[0]["active_run_count"], 1);
        assert_eq!(projected[0]["completed_run_count"], 1);
        assert_eq!(projected[0]["latest_run_id"], live.id);
        assert_eq!(projected[0]["latest_run_state"], "active");
        assert!(
            project_sessions(vec![row.clone()], &[], std::slice::from_ref(&old), true).is_empty()
        );
        assert_eq!(
            project_sessions(vec![row], &[], &[old], false)[0]["latest_run_state"],
            "completed"
        );
    }

    #[test]
    fn live_transcripts_filter_identity_time_and_bound_output() {
        use serde_json::json;
        let run = TelemetryRun::new("codex", "/repo");
        let rows = [
            json!({"session_id":"S","text":"old","ts":run.started_at.timestamp()-10}),
            json!({"session_id":"other","text":"wrong","ts":run.started_at.timestamp()}),
            json!({"session_id":"S","text":" current ","ts":run.started_at.timestamp().to_string()}),
        ];
        let text = rows
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("\n");
        let turns = codex_live_turns(&text, "S", &run);
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0].content.as_deref(), Some("current"));
        assert_eq!(turns[0].role, super::super::turn::TurnRole::Human);
        let huge = "é".repeat(400_000);
        let pty = pty_live_turns(&format!("\x1b[31m{huge}\x1b[0m"), &run);
        assert!(pty[0].content.as_ref().unwrap().len() <= crate::mcp::output::MAX_OUTPUT_BYTES);
        assert!(!pty[0].content.as_ref().unwrap().contains('\x1b'));
        let dir =
            std::env::temp_dir().join(format!("chau7-next-live-tail-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tail");
        std::fs::write(&path, "123456789").unwrap();
        assert_eq!(bounded_file_tail(&path, 4).as_deref(), Some("6789"));
        std::fs::remove_dir_all(dir).unwrap();
    }

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
