//! Read-only Claude store lookup. Callers perform filesystem work off the UI thread.
//! Mirrors current Swift ClaudeSessionResolver cache generations and ownership policy.
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Component, Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant, SystemTime};

use crate::ai::resume::{SessionCandidate, is_valid_session_id};
use crate::path_rank::bidirectional_prefix_rank;

const METADATA_LIMIT: usize = 256;
const HISTORY_LIMIT: usize = 4;
const NEGATIVE_TTL: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub session_id: String,
    pub project_directory: Option<String>,
    pub transcript_path: Option<PathBuf>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Fingerprint {
    size: u64,
    modified: Option<SystemTime>,
    created: Option<SystemTime>,
    file_number: Option<u64>,
}
fn fingerprint(path: &Path) -> Option<Fingerprint> {
    let metadata = fs::metadata(path).ok()?;
    #[cfg(unix)]
    let file_number = {
        use std::os::unix::fs::MetadataExt;
        Some(metadata.ino())
    };
    #[cfg(not(unix))]
    let file_number = None;
    Some(Fingerprint {
        size: metadata.len(),
        modified: metadata.modified().ok(),
        created: metadata.created().ok(),
        file_number,
    })
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Context {
    history: Option<Fingerprint>,
    projects: Option<Fingerprint>,
}
struct Cached {
    context: Context,
    candidate: Option<Candidate>,
    negative_expiry: Instant,
}
#[derive(Clone)]
struct HistoryEntry {
    project: String,
    timestamp: f64,
}
struct HistoryIndex {
    fingerprint: Fingerprint,
    entries: HashMap<String, HistoryEntry>,
}
#[derive(Default)]
pub struct Resolver {
    metadata: HashMap<(PathBuf, String), Cached>,
    history: HashMap<PathBuf, HistoryIndex>,
}
static SHARED: LazyLock<Mutex<Resolver>> = LazyLock::new(|| Mutex::new(Resolver::default()));

/// Uses a bounded process-wide cache; homes are part of the cache key.
pub fn metadata(home: &Path, session_id: &str, transcript: Option<&Path>) -> Option<Candidate> {
    SHARED
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .metadata(home, session_id, transcript)
}
pub fn clear_cache() {
    SHARED.lock().unwrap_or_else(|e| e.into_inner()).clear();
}
impl Resolver {
    pub fn clear(&mut self) {
        self.metadata.clear();
        self.history.clear();
    }
    pub fn metadata(
        &mut self,
        home: &Path,
        session_id: &str,
        transcript: Option<&Path>,
    ) -> Option<Candidate> {
        self.metadata_at(home, session_id, transcript, Instant::now())
    }
    fn metadata_at(
        &mut self,
        home: &Path,
        session_id: &str,
        transcript: Option<&Path>,
        now: Instant,
    ) -> Option<Candidate> {
        let session_id = session_id.trim();
        if !is_valid_session_id(session_id) {
            return None;
        }
        let history_path = home.join(".claude/history.jsonl");
        let projects = home.join(".claude/projects");
        let context = Context {
            history: fingerprint(&history_path),
            projects: fingerprint(&projects),
        };
        let key = (home.to_path_buf(), session_id.to_owned());
        if transcript.is_none()
            && let Some(cached) = self.metadata.get(&key)
            && cached.context == context
            && (cached.candidate.is_some() || cached.negative_expiry > now)
            && cached
                .candidate
                .as_ref()
                .and_then(|c| c.transcript_path.as_ref())
                .is_none_or(|p| p.exists())
        {
            return cached.candidate.clone();
        }
        let project_directory =
            self.history_project(&history_path, context.history.as_ref(), session_id);
        let history_transcript = project_directory
            .as_ref()
            .and_then(|project| transcript_for_project(home, project, session_id));
        let event_transcript = transcript
            .filter(|path| usable_event_transcript(path, session_id))
            .map(Path::to_path_buf);
        let transcript_path = history_transcript
            .or(event_transcript)
            .or_else(|| scan_transcript(&projects, session_id));
        let candidate =
            (project_directory.is_some() || transcript_path.is_some()).then(|| Candidate {
                session_id: session_id.to_owned(),
                project_directory,
                transcript_path,
            });
        if transcript.is_none() {
            if self.metadata.len() >= METADATA_LIMIT {
                self.metadata.clear();
            }
            self.metadata.insert(
                key,
                Cached {
                    context,
                    candidate: candidate.clone(),
                    negative_expiry: now + NEGATIVE_TTL,
                },
            );
        }
        candidate
    }
    fn history_project(
        &mut self,
        path: &Path,
        generation: Option<&Fingerprint>,
        id: &str,
    ) -> Option<String> {
        if let Some(generation) = generation
            && let Some(index) = self.history.get(path)
            && &index.fingerprint == generation
        {
            return index.entries.get(id).map(|e| e.project.clone());
        }
        let file = fs::File::open(path).ok()?;
        let mut entries: HashMap<String, HistoryEntry> = HashMap::new();
        // Stream lines and discard prompts; a history file is never loaded wholesale.
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            let Ok(json) = serde_json::from_str::<serde_json::Value>(&line) else {
                continue;
            };
            let (Some(id), Some(project)) = (json["sessionId"].as_str(), json["project"].as_str())
            else {
                continue;
            };
            let project = project.trim();
            if project.is_empty() {
                continue;
            }
            let timestamp = json["timestamp"].as_f64().unwrap_or(0.0);
            if entries.get(id).is_none_or(|e| timestamp >= e.timestamp) {
                entries.insert(
                    id.to_owned(),
                    HistoryEntry {
                        project: project.to_owned(),
                        timestamp,
                    },
                );
            }
        }
        let project = entries.get(id).map(|e| e.project.clone());
        if let Some(generation) = generation {
            if self.history.len() >= HISTORY_LIMIT {
                self.history.clear();
            }
            self.history.insert(
                path.to_path_buf(),
                HistoryIndex {
                    fingerprint: generation.clone(),
                    entries,
                },
            );
        }
        project
    }
}

fn normalized_directory(home: &Path, directory: &str) -> PathBuf {
    let directory = directory.trim();
    let expanded = if directory == "~" {
        home.to_path_buf()
    } else if let Some(suffix) = directory.strip_prefix("~/") {
        home.join(suffix)
    } else {
        PathBuf::from(directory)
    };
    let absolute = if expanded.is_absolute() {
        expanded
    } else {
        std::env::current_dir().unwrap_or_default().join(expanded)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}
fn project_folders(home: &Path, directory: &str) -> Vec<PathBuf> {
    if directory.trim().is_empty() {
        return Vec::new();
    }
    let directory = normalized_directory(home, directory)
        .to_string_lossy()
        .into_owned();
    let current = directory.replace('/', "-");
    let legacy = crate::session_restore::claude_project_dir_name(&directory);
    let root = home.join(".claude/projects");
    let mut folders = vec![root.join(&current)];
    if current != legacy {
        folders.push(root.join(legacy));
    }
    folders
}
fn transcript_in(folder: &Path, id: &str) -> Option<PathBuf> {
    let file = folder.join(format!("{id}.jsonl"));
    if file.exists() {
        return Some(file);
    }
    let directory = folder.join(id);
    directory.is_dir().then_some(directory)
}
fn transcript_for_project(home: &Path, directory: &str, id: &str) -> Option<PathBuf> {
    project_folders(home, directory)
        .iter()
        .find_map(|folder| transcript_in(folder, id))
}
fn usable_event_transcript(path: &Path, id: &str) -> bool {
    let name = path.file_name().and_then(|s| s.to_str());
    (name == Some(id) || name == Some(format!("{id}.jsonl").as_str())) && path.exists()
}
fn scan_transcript(root: &Path, id: &str) -> Option<PathBuf> {
    let mut entries: Vec<_> = fs::read_dir(root)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .collect();
    entries.sort();
    entries.iter().find_map(|folder| transcript_in(folder, id))
}
pub fn related_directory(home: &Path, project: &str, saved: &str) -> bool {
    if project.trim().is_empty() || saved.trim().is_empty() {
        return false;
    }
    let project = normalized_directory(home, project);
    let saved = normalized_directory(home, saved);
    // Native component boundaries also support Windows drives and separators.
    project.starts_with(&saved)
        || saved.starts_with(&project)
        || bidirectional_prefix_rank(&saved.to_string_lossy(), &project.to_string_lossy()).is_some()
}
/// Exact transcript ownership wins; otherwise a known unrelated history root rejects adoption.
pub fn has_restorable_transcript(
    home: &Path,
    id: &str,
    saved: &str,
    event_transcript: Option<&Path>,
) -> bool {
    let id = id.trim();
    if !is_valid_session_id(id) {
        return false;
    }
    if transcript_for_project(home, saved, id).is_some() {
        return true;
    }
    metadata(home, id, event_transcript).is_some_and(|candidate| {
        candidate.transcript_path.is_some()
            && candidate
                .project_directory
                .as_deref()
                .is_none_or(|project| related_directory(home, project, saved))
    })
}
pub fn restore_directory(home: &Path, id: &str, saved: &str) -> Option<String> {
    let project = metadata(home, id, None)?.project_directory?;
    (related_directory(home, &project, saved) && Path::new(&project).is_dir()).then_some(project)
}
/// Exact current Swift folder first, with the previously supported Claude encoding retained.
pub fn session_candidates(home: &Path, directory: &str) -> Vec<SessionCandidate> {
    let mut found = HashMap::new();
    for folder in project_folders(home, directory) {
        if let Ok(entries) = fs::read_dir(folder) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
                    continue;
                }
                let Some(id) = path.file_stem().and_then(|s| s.to_str()) else {
                    continue;
                };
                if is_valid_session_id(id) {
                    let touched_at = crate::session_restore::modified_secs(&path);
                    found
                        .entry(id.to_owned())
                        .and_modify(|time: &mut f64| *time = time.max(touched_at))
                        .or_insert(touched_at);
                }
            }
        }
    }
    let mut result: Vec<_> = found
        .into_iter()
        .map(|(session_id, touched_at)| SessionCandidate {
            session_id,
            touched_at,
        })
        .collect();
    result.sort_by(|a, b| {
        b.touched_at
            .total_cmp(&a.touched_at)
            .then_with(|| a.session_id.cmp(&b.session_id))
    });
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Home(PathBuf);
    impl Home {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "chau7-next-claude-resolver-{}",
                uuid::Uuid::new_v4()
            ));
            fs::create_dir_all(path.join(".claude/projects")).unwrap();
            Self(path)
        }
        fn history(&self, entries: &[(&str, &str, f64)]) {
            let body: String = entries
                .iter()
                .map(|(id, project, timestamp)| {
                    format!(
                        "{}\n",
                        serde_json::json!({"sessionId":id,"project":project,"timestamp":timestamp})
                    )
                })
                .collect();
            fs::write(self.0.join(".claude/history.jsonl"), body).unwrap();
        }
        fn transcript(&self, project: &str, id: &str) -> PathBuf {
            let folder = project_folders(&self.0, project).remove(0);
            fs::create_dir_all(&folder).unwrap();
            let path = folder.join(format!("{id}.jsonl"));
            fs::write(&path, b"{}\n").unwrap();
            path
        }
    }
    impl Drop for Home {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn history_uses_latest_timestamp_and_last_equal_entry_without_loading_prompts() {
        let home = Home::new();
        home.history(&[
            ("s1", "/old", 2.0),
            ("s1", " /new ", 4.0),
            ("s1", "/ignored", 1.0),
            ("s1", "/tie", 4.0),
        ]);
        let mut resolver = Resolver::default();
        assert_eq!(
            resolver
                .metadata(&home.0, " s1 ", None)
                .unwrap()
                .project_directory
                .as_deref(),
            Some("/tie")
        );
        assert_eq!(resolver.history.len(), 1);
        assert!(resolver.metadata(&home.0, "bad;id", None).is_none());
    }
    #[test]
    fn negative_cache_expires_when_only_nested_project_changes() {
        let home = Home::new();
        let folder = project_folders(&home.0, "/repo").remove(0);
        fs::create_dir_all(&folder).unwrap();
        let mut resolver = Resolver::default();
        let start = Instant::now();
        assert!(resolver.metadata_at(&home.0, "s1", None, start).is_none());
        let context = resolver.metadata[&(home.0.clone(), "s1".to_owned())]
            .context
            .clone();
        fs::write(folder.join("s1.jsonl"), b"{}").unwrap();
        assert_eq!(
            context.projects,
            fingerprint(&home.0.join(".claude/projects"))
        );
        assert!(
            resolver
                .metadata_at(&home.0, "s1", None, start + Duration::from_secs(1))
                .is_none()
        );
        assert!(
            resolver
                .metadata_at(&home.0, "s1", None, start + Duration::from_secs(3))
                .is_some()
        );
    }
    #[test]
    fn store_generation_invalidates_negative_and_rotated_history_cache() {
        let home = Home::new();
        home.history(&[("old", "/repo", 1.0)]);
        let mut resolver = Resolver::default();
        assert!(resolver.metadata(&home.0, "s1", None).is_none());
        let history = home.0.join(".claude/history.jsonl");
        let replacement = home.0.join(".claude/replacement.jsonl");
        fs::write(
            &replacement,
            serde_json::json!({"sessionId":"s1","project":"/new-root","timestamp":2}).to_string(),
        )
        .unwrap();
        fs::rename(replacement, history).unwrap();
        assert_eq!(
            resolver
                .metadata(&home.0, "s1", None)
                .unwrap()
                .project_directory
                .as_deref(),
            Some("/new-root")
        );
    }
    #[test]
    fn deleted_positive_transcript_is_not_restorable() {
        let home = Home::new();
        let transcript = home.transcript("/repo", "s1");
        let mut resolver = Resolver::default();
        assert!(
            resolver
                .metadata(&home.0, "s1", None)
                .unwrap()
                .transcript_path
                .is_some()
        );
        fs::remove_file(transcript).unwrap();
        assert!(resolver.metadata(&home.0, "s1", None).is_none());
    }
    #[test]
    fn event_path_bypasses_negative_cache_but_requires_exact_id_and_exists() {
        let home = Home::new();
        let mut resolver = Resolver::default();
        assert!(resolver.metadata(&home.0, "s1", None).is_none());
        let event = home.0.join("s1.jsonl");
        fs::write(&event, b"{}").unwrap();
        assert_eq!(
            resolver
                .metadata(&home.0, "s1", Some(&event))
                .unwrap()
                .transcript_path,
            Some(event.clone())
        );
        assert!(resolver.metadata(&home.0, "s2", Some(&event)).is_none());
        fs::remove_file(event).unwrap();
        assert!(
            resolver
                .metadata(&home.0, "s1", Some(&home.0.join("s1.jsonl")))
                .is_none()
        );
    }
    #[test]
    fn unrelated_history_rejects_adoption_unless_exact_saved_transcript_exists() {
        let home = Home::new();
        home.history(&[("s1", "/foreign", 1.0)]);
        let event = home.0.join("s1.jsonl");
        fs::write(&event, b"{}").unwrap();
        assert!(!has_restorable_transcript(
            &home.0,
            "s1",
            "/repo",
            Some(&event)
        ));
        assert!(has_restorable_transcript(
            &home.0,
            "s1",
            "/foreign/sub",
            Some(&event)
        ));
        assert!(!related_directory(&home.0, "/repo-extra", "/repo"));
        home.transcript("/repo", "s1");
        assert!(has_restorable_transcript(
            &home.0,
            "s1",
            "/repo",
            Some(&event)
        ));
    }
    #[test]
    fn homes_are_isolated_and_both_cache_maps_remain_bounded() {
        let mut resolver = Resolver::default();
        let homes: Vec<_> = (0..6).map(|_| Home::new()).collect();
        for (index, home) in homes.iter().enumerate() {
            home.history(&[("s1", &format!("/repo-{index}"), 1.0)]);
            assert_eq!(
                resolver
                    .metadata(&home.0, "s1", None)
                    .unwrap()
                    .project_directory,
                Some(format!("/repo-{index}"))
            );
            assert!(resolver.history.len() <= HISTORY_LIMIT);
        }
        for index in 0..300 {
            resolver.metadata(&homes[0].0, &format!("missing-{index}"), None);
            assert!(resolver.metadata.len() <= METADATA_LIMIT);
        }
        resolver.clear();
        assert!(resolver.metadata.is_empty() && resolver.history.is_empty());
    }
    #[test]
    fn exact_reverse_candidates_preserve_dotted_folder_and_filter_unsafe_ids() {
        let home = Home::new();
        home.transcript("/repo.with-dot", "s1");
        home.transcript("/repo.with-dot", "s2");
        home.transcript("/repo.with-dot", "unsafe;id");
        let found = session_candidates(&home.0, "/repo.with-dot/./");
        assert_eq!(found.len(), 2);
        assert!(found.windows(2).all(|w| w[0].touched_at >= w[1].touched_at));
        assert!(session_candidates(&home.0, "/repo.with-dot/child").is_empty());
        let legacy =
            home.0
                .join(".claude/projects")
                .join(crate::session_restore::claude_project_dir_name(
                    "/repo.with-dot",
                ));
        fs::create_dir_all(&legacy).unwrap();
        fs::write(legacy.join("s1.jsonl"), b"{}").unwrap();
        assert_eq!(session_candidates(&home.0, "/repo.with-dot").len(), 2);
    }
}
