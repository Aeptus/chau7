//! Port of `Monitoring/CodexSessionResolver.swift`: Codex session lookup in
//! `~/.codex/sessions/<yyyy>/<mm>/<dd>/*.jsonl` (read only). The first line
//! of a rollout file is a `session_meta` record with the session id and
//! working directory.
//!
//! - [`CodexSessionResolver::metadata`]: a session id to its directory,
//!   looking in the day folders around a reference date first, then the 14
//!   most recent day folders; results are cached.
//! - [`session_candidates`]: sessions of a directory in the 3 most recent
//!   day folders, closest directory match only, newest first.
//! - [`best_matching_session_id`]: picks among known candidates.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Datelike, Utc};

use crate::ai::resume::{SessionCandidate, best_session_match, is_valid_session_id};
use crate::path_rank::bidirectional_prefix_rank;
use crate::session_restore::{
    modified_secs, numeric_children, parse_codex_session_meta, read_first_line,
};

/// `Candidate`.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub session_id: String,
    pub cwd: String,
    pub touched_at: f64,
}

/// `~/.codex/sessions` under `home`.
pub fn sessions_dir(home: &Path) -> PathBuf {
    home.join(".codex").join("sessions")
}

/// `<sessions>/<yyyy>/<mm>/<dd>` of a Unix time, in UTC.
fn day_directory(sessions: &Path, time: f64) -> Option<PathBuf> {
    let date: DateTime<Utc> = DateTime::from_timestamp(time as i64, 0)?;
    Some(
        sessions
            .join(format!("{:04}", date.year()))
            .join(format!("{:02}", date.month()))
            .join(format!("{:02}", date.day())),
    )
}

/// The newest day folders, at most `limit` (`recentDayDirectories`).
fn recent_day_directories(sessions: &Path, limit: usize) -> Vec<PathBuf> {
    let mut days = Vec::new();
    for year in numeric_children(sessions) {
        for month in numeric_children(&year) {
            for day in numeric_children(&month) {
                days.push(day);
                if days.len() >= limit {
                    return days;
                }
            }
        }
    }
    days
}

/// Day folders around `reference` (same day, day before, day after), then
/// the 14 most recent (`prioritizedDayDirectories`).
fn prioritized_day_directories(sessions: &Path, reference: Option<f64>) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut ordered = Vec::new();
    let mut push = |dir: PathBuf| {
        if seen.insert(dir.clone()) {
            ordered.push(dir);
        }
    };
    if let Some(reference) = reference {
        for offset in [0.0, -1.0, 1.0] {
            if let Some(dir) = day_directory(sessions, reference + offset * 86_400.0) {
                push(dir);
            }
        }
    }
    for dir in recent_day_directories(sessions, 14) {
        push(dir);
    }
    ordered
}

/// `.jsonl` file names of a folder, newest name first.
fn rollout_files(dir: &Path) -> Vec<String> {
    let mut files: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|n| n.ends_with(".jsonl"))
                .collect()
        })
        .unwrap_or_default();
    files.sort();
    files.reverse();
    files
}

/// Session id to directory lookups, cached (`metadataCache`).
#[derive(Debug, Default, Clone)]
pub struct CodexSessionResolver {
    cache: HashMap<String, Candidate>,
}

impl CodexSessionResolver {
    pub fn new() -> Self {
        Self::default()
    }

    /// `metadata(forSessionID:referenceDate:)`.
    pub fn metadata(
        &mut self,
        home: &Path,
        session_id: &str,
        reference: Option<f64>,
    ) -> Option<Candidate> {
        let id = session_id.trim();
        if !is_valid_session_id(id) {
            return None;
        }
        if let Some(cached) = self.cache.get(id) {
            return Some(cached.clone());
        }
        let sessions = sessions_dir(home);
        for day in prioritized_day_directories(&sessions, reference) {
            for file in rollout_files(&day).into_iter().filter(|f| f.contains(id)) {
                let path = day.join(&file);
                let Some((cwd, found)) =
                    read_first_line(&path).and_then(|l| parse_codex_session_meta(&l))
                else {
                    continue;
                };
                if found != id {
                    continue;
                }
                let candidate = Candidate {
                    session_id: found,
                    cwd,
                    touched_at: modified_secs(&path),
                };
                self.cache.insert(id.to_string(), candidate.clone());
                return Some(candidate);
            }
        }
        None
    }
}

/// Codex sessions of `directory` (`sessionCandidates(forDirectory:)`):
/// (session id, last activity), newest first.
pub fn session_candidates(home: &Path, directory: &str, now: f64) -> Vec<(String, f64)> {
    let sessions = sessions_dir(home);
    let mut seen = HashSet::new();
    let mut results: Vec<(String, f64, u8)> = Vec::new();
    for day in prioritized_day_directories(&sessions, Some(now))
        .into_iter()
        .take(3)
    {
        for file in rollout_files(&day) {
            let path = day.join(&file);
            let Some((cwd, id)) = read_first_line(&path).and_then(|l| parse_codex_session_meta(&l))
            else {
                continue;
            };
            if !seen.insert(id.clone()) {
                continue;
            }
            let Some(rank) = bidirectional_prefix_rank(directory, &cwd) else {
                continue;
            };
            results.push((id, modified_secs(&path), rank));
        }
    }
    let Some(best) = results.iter().map(|r| r.2).min() else {
        return Vec::new();
    };
    let mut best: Vec<(String, f64)> = results
        .into_iter()
        .filter(|r| r.2 == best)
        .map(|r| (r.0, r.1))
        .collect();
    best.sort_by(|a, b| b.1.total_cmp(&a.1));
    best
}

/// `bestMatchingSessionID(forDirectory:referenceDate:candidates:)`.
pub fn best_matching_session_id(
    directory: &str,
    reference: Option<f64>,
    candidates: &[Candidate],
) -> Option<String> {
    let mut best_by_id: HashMap<&str, &Candidate> = HashMap::new();
    for candidate in candidates {
        let keep = best_by_id
            .get(candidate.session_id.as_str())
            .is_none_or(|existing| candidate.touched_at > existing.touched_at);
        if keep {
            best_by_id.insert(&candidate.session_id, candidate);
        }
    }
    let matches: Vec<(&Candidate, u8)> = best_by_id
        .values()
        .filter_map(|c| bidirectional_prefix_rank(directory, &c.cwd).map(|r| (*c, r)))
        .collect();
    let best = matches.iter().map(|m| m.1).min()?;
    let mut ranked: Vec<SessionCandidate> = matches
        .into_iter()
        .filter(|m| m.1 == best)
        .map(|m| SessionCandidate {
            session_id: m.0.session_id.clone(),
            touched_at: m.0.touched_at,
        })
        .collect();
    ranked.sort_by(|a, b| a.session_id.cmp(&b.session_id));
    best_session_match(&ranked, reference)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(id: &str, cwd: &str, at: f64) -> Candidate {
        Candidate {
            session_id: id.into(),
            cwd: cwd.into(),
            touched_at: at,
        }
    }

    #[test]
    fn prefers_exact_directory_before_activity_hint() {
        let candidates = [
            candidate("session-a", "/tmp/project", 1000.0 - 120.0),
            candidate("session-b", "/tmp/project/src", 1000.0 - 3.0),
            candidate("session-c", "/tmp/other", 1000.0 - 1.0),
        ];
        assert_eq!(
            best_matching_session_id("/tmp/project", Some(1000.0), &candidates).as_deref(),
            Some("session-a")
        );
    }

    #[test]
    fn ambiguous_without_reference_is_none() {
        let candidates = [
            candidate("session-a", "/tmp/project", 100.0),
            candidate("session-b", "/tmp/project", 200.0),
        ];
        assert_eq!(
            best_matching_session_id("/tmp/project", None, &candidates),
            None
        );
    }

    #[test]
    fn prefers_exact_over_related() {
        let candidates = [
            candidate("session-root", "/tmp/project", 970.0),
            candidate("session-child", "/tmp/project/app", 999.0),
        ];
        assert_eq!(
            best_matching_session_id("/tmp/project", Some(1000.0), &candidates).as_deref(),
            Some("session-root")
        );
    }

    #[test]
    fn metadata_and_candidates_from_disk() {
        let home = std::env::temp_dir().join(format!(
            "chau7-next-codex-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        // 2026-03-04 12:00 UTC
        let at = 1_772_625_600.0;
        let day = sessions_dir(&home).join("2026").join("03").join("04");
        std::fs::create_dir_all(&day).unwrap();
        let id = "0199aaaa-bbbb-cccc-dddd-eeeeffff0000";
        std::fs::write(
            day.join(format!("rollout-2026-03-04T12-00-00-{id}.jsonl")),
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"cwd\":\"/work/app\"}}}}\n{{}}\n"
            ),
        )
        .unwrap();
        let mut resolver = CodexSessionResolver::new();
        let found = resolver.metadata(&home, id, Some(at)).unwrap();
        assert_eq!(found.cwd, "/work/app");
        // Cached: still found after the file is gone.
        std::fs::remove_dir_all(sessions_dir(&home)).unwrap();
        assert!(resolver.metadata(&home, id, Some(at)).is_some());
        assert!(resolver.metadata(&home, "bad id", None).is_none());

        std::fs::create_dir_all(&day).unwrap();
        std::fs::write(
            day.join(format!("rollout-{id}.jsonl")),
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"cwd\":\"/work/app\"}}}}\n"),
        )
        .unwrap();
        let list = session_candidates(&home, "/work/app", at);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].0, id);
        assert!(session_candidates(&home, "/elsewhere", at).is_empty());
        let _ = std::fs::remove_dir_all(&home);
    }
}
