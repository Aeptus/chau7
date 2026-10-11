//! Repository agent dashboard: Swift AgentDashboardTypes, FileTrackingParser
//! and SessionFilesTracker. Value copies cross the UI/background boundary;
//! unknown usage is represented as None rather than fabricated zeroes.
use crate::command_block::CommandBlock;
use crate::command_detection::tokenize;
use crate::runtime::{
    event_journal::EventJournal, runtime_event::RuntimeEvent, session_state::State,
};

use chrono::{DateTime, Utc};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::Path;
use uuid::Uuid;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Usage {
    pub input: u64,
    pub output: u64,
    pub cache_creation: u64,
    pub cache_read: u64,
}
impl Usage {
    pub fn total(&self) -> u64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.cache_creation)
            .saturating_add(self.cache_read)
    }
}
#[derive(Debug, Clone)]
pub struct Agent {
    pub id: String,
    pub tab_id: Uuid,
    /// Runtime/tab identity and telemetry terminal identity are distinct.
    pub telemetry_tab: Option<String>,
    pub backend: String,
    pub directory: String,
    pub purpose: Option<String>,
    pub parent_id: Option<String>,
    pub delegation_depth: usize,
    pub state: State,
    pub turns: u64,
    pub usage: Option<Usage>,
    pub usage_complete: bool,
    pub cost: Option<f64>,
    pub requires_approval: bool,
    pub latest_result: Option<(String, Option<String>)>,
    pub created_at: Option<DateTime<Utc>>,
    pub child_count: usize,
    pub last_tool: Option<String>,
    pub files: BTreeSet<String>,
    pub current_files: BTreeSet<String>,
}
pub fn in_repository(directory: &str, root: &str) -> bool {
    !root.is_empty() && Path::new(directory).starts_with(root)
}
pub fn newest_by_tab(agents: impl IntoIterator<Item = Agent>) -> Vec<Agent> {
    let mut index: BTreeMap<Uuid, Agent> = BTreeMap::new();
    for candidate in agents {
        if index.get(&candidate.tab_id).is_none_or(|current| {
            (candidate.created_at, &candidate.id) > (current.created_at, &current.id)
        }) {
            index.insert(candidate.tab_id, candidate);
        }
    }
    index.into_values().collect()
}
pub fn live_state(status: &str, at_prompt: bool) -> State {
    match status {
        "approvalRequired" => State::AwaitingApproval,
        "waitingForInput" => State::WaitingInput,
        "running" | "stuck" => State::Busy,
        "exited" => State::Stopped,
        _ => {
            if at_prompt {
                State::Ready
            } else {
                State::Busy
            }
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverallStatus {
    Idle,
    Active,
    HasApprovals,
    HasConflicts,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conflict {
    pub file: String,
    pub agents: Vec<String>,
    pub critical: bool,
}
pub fn conflicts(agents: &[Agent]) -> Vec<Conflict> {
    let mut owners: BTreeMap<&str, Vec<&Agent>> = BTreeMap::new();
    for agent in agents {
        for path in &agent.files {
            owners.entry(path).or_default().push(agent);
        }
    }
    owners
        .into_iter()
        .filter(|(_, owners)| owners.len() > 1)
        .map(|(file, owners)| Conflict {
            file: file.into(),
            critical: owners
                .iter()
                .filter(|a| a.current_files.contains(file))
                .count()
                > 1,
            agents: owners.into_iter().map(|a| a.id.clone()).collect(),
        })
        .collect()
}
pub fn overall_status(agents: &[Agent], conflicts: &[Conflict]) -> OverallStatus {
    if !conflicts.is_empty() {
        OverallStatus::HasConflicts
    } else if agents
        .iter()
        .any(|a| a.requires_approval || a.state == State::AwaitingApproval)
    {
        OverallStatus::HasApprovals
    } else if agents
        .iter()
        .any(|a| matches!(a.state, State::Busy | State::Starting))
    {
        OverallStatus::Active
    } else {
        OverallStatus::Idle
    }
}
pub fn count_children(agents: &mut [Agent]) {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for agent in agents.iter() {
        if let Some(parent) = &agent.parent_id {
            *counts.entry(parent.clone()).or_default() += 1;
        }
    }
    for agent in agents {
        agent.child_count = counts.get(&agent.id).copied().unwrap_or_default();
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum FileAction {
    Read,
    Created,
    Modified,
    Deleted,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileActivity {
    pub path: String,
    pub action: FileAction,
}
fn looks_like_path(s: &str) -> bool {
    const NAMES: &[&str] = &[
        "Dockerfile",
        "Containerfile",
        "Makefile",
        "Justfile",
        "Brewfile",
        "Gemfile",
        "Podfile",
        "Procfile",
        "Vagrantfile",
        "Rakefile",
        "Guardfile",
        "Fastfile",
        "Appfile",
        "Cartfile",
        "Mintfile",
        "Pipfile",
        "README",
        "LICENSE",
        "NOTICE",
        "CHANGELOG",
        "TODO",
    ];
    s.starts_with('/')
        || s.starts_with("./")
        || s.starts_with("../")
        || s.starts_with("~/")
        || NAMES.contains(&s)
        || s.contains('/')
        || s.contains('*')
        || s.contains('?')
        || (s.contains('.')
            && s.split_once('.')
                .is_some_and(|(a, b)| !a.is_empty() && !b.is_empty())
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || "._-".contains(c)))
}
fn candidates(tokens: impl IntoIterator<Item = String>) -> Vec<String> {
    tokens
        .into_iter()
        .filter(|s| {
            !s.is_empty()
                && !s.starts_with('-')
                && !s.contains('=')
                && !matches!(s.as_str(), "|" | "&&" | "||")
                && looks_like_path(s)
        })
        .collect()
}
fn redirect(token: &str) -> Option<Option<&str>> {
    for prefix in ["1>>", "2>>", "&>", ">>", "1>", "2>", ">"] {
        if let Some(rest) = token.strip_prefix(prefix) {
            return Some(if rest.is_empty() { None } else { Some(rest) });
        }
    }
    if token.contains('>') {
        Some(None)
    } else {
        None
    }
}
fn normalized_path(path: &str, root: &str) -> Option<String> {
    let trimmed = path.trim_matches(|c: char| c == '\'' || c == '"' || c.is_whitespace());
    if trimmed.is_empty() {
        return None;
    }
    let expanded = if let Some(rest) = trimmed.strip_prefix("~/") {
        std::env::var("HOME")
            .map(|home| format!("{home}/{rest}"))
            .unwrap_or_else(|_| trimmed.into())
    } else {
        trimmed.into()
    };
    Some(
        Path::new(&expanded)
            .strip_prefix(root)
            .ok()
            .filter(|p| !p.as_os_str().is_empty())
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or(expanded),
    )
}
fn normalize(activities: Vec<FileActivity>, root: &str) -> Vec<FileActivity> {
    let mut seen = HashSet::new();
    activities
        .into_iter()
        .filter_map(|a| {
            normalized_path(&a.path, root).map(|path| FileActivity {
                path,
                action: a.action,
            })
        })
        .filter(|a| seen.insert((a.path.clone(), a.action)))
        .collect()
}
pub fn file_activities(event: &RuntimeEvent, root: &str) -> Vec<FileActivity> {
    if event.event_type != "tool_use" {
        return vec![];
    }
    let tool = event.data.get("tool").map(String::as_str).unwrap_or("");
    let primary = event.data.get("file").filter(|p| !p.is_empty());
    let summary = event
        .data
        .get("args_summary")
        .map(String::as_str)
        .unwrap_or("");
    let mut activities = Vec::new();
    let mut add = |path: &str, action| {
        activities.push(FileActivity {
            path: path.into(),
            action,
        })
    };
    let default = match tool {
        "Read" | "Grep" | "Glob" | "LS" => FileAction::Read,
        "Write" => FileAction::Created,
        _ => FileAction::Modified,
    };
    if matches!(tool, "Grep" | "Glob" | "LS") {
        for path in candidates(tokenize(summary)) {
            add(&path, FileAction::Read);
        }
    } else if tool == "Bash" && !summary.trim().is_empty() {
        let tokens = tokenize(summary);
        let mut args = Vec::new();
        let mut skip = false;
        for token in tokens.iter().skip(1) {
            if skip {
                skip = false;
                continue;
            }
            if let Some(target) = redirect(token) {
                skip = target.is_none();
            } else {
                args.push(token.clone());
            }
        }
        let paths = candidates(args);
        match tokens.first().map(|s| s.to_lowercase()).as_deref() {
            Some(
                "cat" | "head" | "tail" | "less" | "more" | "grep" | "rg" | "ls" | "find" | "stat"
                | "file",
            ) => {
                for path in &paths {
                    add(path, FileAction::Read)
                }
            }
            Some("sed") => {
                for path in &paths {
                    add(
                        path,
                        if tokens.iter().any(|t| t == "-i" || t == "--in-place") {
                            FileAction::Modified
                        } else {
                            FileAction::Read
                        },
                    )
                }
            }
            Some("cp") => {
                for (i, path) in paths.iter().enumerate() {
                    add(
                        path,
                        if i + 1 == paths.len() {
                            FileAction::Modified
                        } else {
                            FileAction::Read
                        },
                    )
                }
            }
            Some("mv" | "rename") if paths.len() >= 2 => {
                add(&paths[0], FileAction::Deleted);
                add(&paths[1], FileAction::Created);
            }
            Some("rm" | "unlink") => {
                for path in &paths {
                    add(path, FileAction::Deleted)
                }
            }
            Some("touch") => {
                for path in &paths {
                    add(path, FileAction::Created)
                }
            }
            Some("tee") => {
                for path in &paths {
                    add(path, FileAction::Modified)
                }
            }
            _ => {
                if let Some(path) = primary {
                    add(path, FileAction::Modified)
                }
            }
        }
        for (i, token) in tokens.iter().enumerate() {
            if let Some(target) = redirect(token)
                && let Some(target) = target.or_else(|| tokens.get(i + 1).map(String::as_str))
                && target != "/dev/null"
                && !target.starts_with('&')
                && looks_like_path(target)
            {
                add(target, FileAction::Modified);
            }
        }
    } else if let Some(path) = primary {
        add(path, default);
    }
    if activities.is_empty()
        && let Some(path) = primary
    {
        activities.push(FileActivity {
            path: path.clone(),
            action: default,
        });
    }
    normalize(activities, root)
}
#[derive(Debug, Clone)]
pub struct FileTouch {
    pub turn_id: Option<String>,
    pub action: FileAction,
    pub timestamp: DateTime<Utc>,
}
#[derive(Default)]
pub struct FilesTracker {
    pub cursor: u64,
    pub current_turn: Option<String>,
    pub files: BTreeSet<String>,
    pub current_files: BTreeSet<String>,
    pub files_by_turn: BTreeMap<String, BTreeSet<String>>,
    pub timeline: BTreeMap<String, Vec<FileTouch>>,
    pub actions: BTreeMap<String, BTreeSet<FileAction>>,
    pub last_tool: Option<String>,
    processed_blocks: HashSet<Uuid>,
    turn_starts: BTreeMap<String, DateTime<Utc>>,
}
impl FilesTracker {
    /// After commit, retain journal/block cursors so old events are not replayed.
    pub fn clear_committed_files(&mut self) {
        self.files.clear();
        self.current_files.clear();
        self.files_by_turn.clear();
        self.timeline.clear();
        self.actions.clear();
    }
    pub fn update(&mut self, journal: Option<&EventJournal>, blocks: &[CommandBlock], root: &str) {
        if let Some(journal) = journal {
            loop {
                let batch = journal.events(self.cursor, 500);
                self.cursor = batch.cursor;
                for event in &batch.events {
                    self.consume(event, root);
                }
                if !batch.has_more {
                    break;
                }
            }
        }
        for block in blocks {
            if block.is_running() || !self.processed_blocks.insert(block.id) {
                continue;
            }
            let timestamp = block.end_time.unwrap_or(block.start_time);
            let turn = self
                .turn_starts
                .iter()
                .filter(|(_, t)| **t <= timestamp)
                .max_by_key(|(_, t)| **t)
                .map(|(id, _)| id.clone())
                .or_else(|| self.current_turn.clone());
            let action = match tokenize(&block.command)
                .first()
                .map(|s| s.to_lowercase())
                .as_deref()
            {
                Some("rm" | "unlink") => FileAction::Deleted,
                Some("touch") => FileAction::Created,
                _ => FileAction::Modified,
            };
            let activities = normalize(
                block
                    .changed_files
                    .iter()
                    .map(|path| FileActivity {
                        path: path.clone(),
                        action,
                    })
                    .collect(),
                root,
            );
            for activity in activities {
                self.record(activity, turn.clone(), timestamp);
            }
        }
    }
    fn consume(&mut self, event: &RuntimeEvent, root: &str) {
        if event.event_type == "turn_started"
            && let Some(turn) = &event.turn_id
            && self.current_turn.as_ref() != Some(turn)
        {
            self.current_turn = Some(turn.clone());
            self.current_files.clear();
            self.turn_starts.insert(turn.clone(), event.timestamp);
        }
        if self.current_turn.is_none() {
            self.current_turn = event.turn_id.clone();
        }
        if event.event_type == "tool_use" {
            self.last_tool = event.data.get("tool").cloned();
        }
        for activity in file_activities(event, root) {
            self.record(activity, event.turn_id.clone(), event.timestamp);
        }
    }
    fn record(&mut self, activity: FileActivity, turn: Option<String>, timestamp: DateTime<Utc>) {
        self.files.insert(activity.path.clone());
        self.actions
            .entry(activity.path.clone())
            .or_default()
            .insert(activity.action);
        self.timeline
            .entry(activity.path.clone())
            .or_default()
            .push(FileTouch {
                turn_id: turn.clone(),
                action: activity.action,
                timestamp,
            });
        if let Some(turn) = turn {
            self.files_by_turn
                .entry(turn.clone())
                .or_default()
                .insert(activity.path.clone());
            if self.current_turn.as_ref() == Some(&turn) {
                self.current_files.insert(activity.path);
            }
        }
    }
}
/// Next stores companion runbooks in its isolated repository overlay.
/// Session identifiers are hashed, so an imported identifier cannot escape it.
pub fn owned_plan_path(
    root: &crate::data_root::DataRoot,
    repository: &str,
    sessions: &[&str],
) -> std::path::PathBuf {
    let overlay = root.repo_overlay_dir(Path::new(repository));
    if let [session] = sessions {
        overlay
            .join("sessions")
            .join(crate::data_root::repo_overlay_key(Path::new(session)))
            .join("plan.md")
    } else {
        overlay.join("plan.md")
    }
}
/// Locate a Swift companion plan for a read-only import. A single session
/// selects its plan; repositories select touched plans before the companion.
/// Canonical containment excludes outside symlinks and malformed identifiers.
pub fn plan_source(
    repository: &Path,
    touched: &BTreeSet<String>,
    sessions: &[&str],
) -> Option<std::path::PathBuf> {
    let metadata = crate::data_root::DataRoot::repo_metadata_file(repository);
    let metadata = metadata.parent()?;
    let metadata_name = metadata.file_name()?.to_str()?.to_ascii_lowercase();
    let repo_plan = format!("{metadata_name}/plan.md");
    let sessions_prefix = format!("{metadata_name}/sessions/");
    let canonical_root = repository.canonicalize().ok()?;
    let contained = |candidate: std::path::PathBuf| {
        candidate
            .canonicalize()
            .ok()
            .filter(|p| p.starts_with(&canonical_root) && p.is_file())
    };
    if let [session] = sessions {
        if Path::new(session).components().count() != 1
            || !matches!(
                Path::new(session).components().next(),
                Some(std::path::Component::Normal(_))
            )
        {
            return None;
        }
        return contained(metadata.join("sessions").join(session).join("plan.md"));
    }
    for file in touched {
        let normalized = file.replace('\\', "/");
        let lower = normalized.to_ascii_lowercase();
        let is_plan = matches!(
            lower.as_str(),
            "plan.md" | "todo.md" | "plan.markdown" | "todo.markdown"
        ) || lower == repo_plan
            || (lower.starts_with(&sessions_prefix) && lower.ends_with("/plan.md"));
        if is_plan
            && Path::new(&normalized)
                .components()
                .all(|c| matches!(c, std::path::Component::Normal(_)))
            && let Some(source) = contained(repository.join(&normalized))
        {
            return Some(source);
        }
    }
    contained(metadata.join("plan.md"))
}
pub fn prepare_plan(path: &Path, repository_name: &str) -> std::io::Result<()> {
    prepare_plan_from(path, repository_name, None)
}
/// Import on an explicit Plan action. Existing Next edits always win, and
/// the shared Swift source is never written.
pub fn prepare_plan_from(
    path: &Path,
    repository_name: &str,
    source: Option<&Path>,
) -> std::io::Result<()> {
    use std::io::Write;
    if path.exists() {
        return Ok(());
    }
    let imported = source.map(std::fs::read).transpose()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => return Ok(()),
        Err(error) => return Err(error),
    };
    if let Some(contents) = imported {
        return file.write_all(&contents);
    }
    write!(
        file,
        "# {repository_name} Runbook\n\n## Goals\n- [ ] Clarify the objective\n- [ ] Confirm scope and risks\n\n## Tasks\n- [ ] Implement the next change\n- [ ] Verify with build and tests\n\n## Notes\n- Capture blockers, follow-ups, or handoff context here.\n"
    )
}
/// Validate literal git paths before a user-requested dashboard commit.
/// Paths outside this repository and git's own metadata are never staged.
pub fn commit_paths(repository: &str, files: &[String]) -> Result<Vec<String>, String> {
    let mut paths = BTreeSet::new();
    for file in files {
        let path = Path::new(file);
        // Windows paths may be rooted without a drive (\repo\file).
        // They still name a root and must be bounded by the repository.
        let relative = if path.has_root() {
            path.strip_prefix(repository)
                .map_err(|_| format!("File outside repository: {file}"))?
        } else {
            path
        };
        if relative.as_os_str().is_empty()
            || relative
                .components()
                .any(|c| !matches!(c, std::path::Component::Normal(_)))
            || relative
                .components()
                .next()
                .is_some_and(|c| c.as_os_str() == ".git")
            || file.starts_with(':')
        {
            return Err(format!("Invalid repository file: {file}"));
        }
        // Git pathspecs use forward slashes on every platform. Joining
        // components preserves a literal backslash in a Unix filename.
        paths.insert(
            relative
                .components()
                .map(|component| component.as_os_str().to_string_lossy())
                .collect::<Vec<_>>()
                .join("/"),
        );
    }
    if paths.is_empty() {
        return Err("No files touched by agents.".into());
    }
    Ok(paths.into_iter().collect())
}
/// Runs in a dashboard worker after an explicit commit click. --only keeps
/// unrelated previously staged changes out of this agent's commit.
pub fn commit_files(repository: &str, files: &[String], message: &str) -> Result<String, String> {
    if message.trim().is_empty() {
        return Err("Commit message cannot be empty.".into());
    }
    let files = commit_paths(repository, files)?;
    let mut add = vec!["--literal-pathspecs".into(), "add".into(), "--".into()];
    add.extend(files.iter().cloned());
    git_checked(repository, &add).map_err(|e| format!("Stage failed: {e}"))?;
    let mut commit = vec![
        "--literal-pathspecs".into(),
        "commit".into(),
        "--only".into(),
        "-m".into(),
        message.trim().into(),
        "--".into(),
    ];
    commit.extend(files);
    git_checked(repository, &commit).map_err(|e| format!("Commit failed: {e}"))
}
fn git_checked(repository: &str, args: &[String]) -> Result<String, String> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};
    let mut child = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let out = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        if let Some(reader) = stdout {
            let _ = reader.take(128 * 1024).read_to_end(&mut bytes);
        }
        bytes
    });
    let err = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        if let Some(reader) = stderr {
            let _ = reader.take(128 * 1024).read_to_end(&mut bytes);
        }
        bytes
    });
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break Err("Git operation timed out".to_string());
            }
        }
    };
    let stdout = String::from_utf8_lossy(&out.join().unwrap_or_default()).into_owned();
    let stderr = String::from_utf8_lossy(&err.join().unwrap_or_default()).into_owned();
    if status?.success() {
        Ok(stdout)
    } else {
        Err(stderr.trim().to_string())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn agent(id: &str, tab: Uuid) -> Agent {
        Agent {
            id: id.into(),
            tab_id: tab,
            telemetry_tab: None,
            backend: "claude".into(),
            directory: "/repo".into(),
            purpose: None,
            parent_id: None,
            delegation_depth: 0,
            state: State::Ready,
            turns: 0,
            usage: None,
            usage_complete: false,
            cost: None,
            requires_approval: false,
            latest_result: None,
            created_at: None,
            child_count: 0,
            last_tool: None,
            files: BTreeSet::new(),
            current_files: BTreeSet::new(),
        }
    }
    fn event(tool: &str, summary: &str, file: &str) -> RuntimeEvent {
        RuntimeEvent {
            seq: 1,
            session_id: "s".into(),
            turn_id: Some("t".into()),
            timestamp: Utc::now(),
            event_type: "tool_use".into(),
            data: [
                ("tool".into(), tool.into()),
                ("args_summary".into(), summary.into()),
                ("file".into(), file.into()),
            ]
            .into(),
        }
    }
    #[test]
    fn repository_boundaries() {
        assert!(in_repository("/repo/sub", "/repo"));
        assert!(!in_repository("/repository", "/repo"));
        assert!(!in_repository("/repo", ""));
    }
    #[test]
    fn newest_sessions_have_stable_ties() {
        let tab = Uuid::new_v4();
        let a = agent("a", tab);
        let z = agent("z", tab);
        assert_eq!(newest_by_tab([z, a])[0].id, "z");
    }
    #[test]
    fn conflict_severity_is_current_turn_overlap() {
        let mut a = agent("a", Uuid::new_v4());
        let mut b = agent("b", Uuid::new_v4());
        a.files.insert("x".into());
        b.files = a.files.clone();
        assert!(!conflicts(&[a.clone(), b.clone()])[0].critical);
        a.current_files = a.files.clone();
        b.current_files = b.files.clone();
        assert!(conflicts(&[a, b])[0].critical);
    }
    #[test]
    fn status_precedence() {
        let mut a = agent("a", Uuid::new_v4());
        a.state = State::Busy;
        assert_eq!(overall_status(&[a.clone()], &[]), OverallStatus::Active);
        a.requires_approval = true;
        assert_eq!(
            overall_status(&[a.clone()], &[]),
            OverallStatus::HasApprovals
        );
        assert_eq!(
            overall_status(
                &[a],
                &[Conflict {
                    file: "x".into(),
                    agents: vec![],
                    critical: false
                }]
            ),
            OverallStatus::HasConflicts
        );
    }
    #[test]
    fn reads_and_writes_keep_actions() {
        assert_eq!(
            file_activities(&event("Read", "", "/repo/a.rs"), "/repo"),
            vec![FileActivity {
                path: "a.rs".into(),
                action: FileAction::Read
            }]
        );
        assert_eq!(
            file_activities(&event("Write", "", "a.rs"), "/repo")[0].action,
            FileAction::Created
        );
    }
    #[test]
    fn bash_copy_and_rename() {
        let a = file_activities(&event("Bash", "cp a.rs b.rs", ""), "/repo");
        assert_eq!(
            a.iter().map(|a| a.action).collect::<Vec<_>>(),
            vec![FileAction::Read, FileAction::Modified]
        );
        let a = file_activities(&event("Bash", "mv a.rs b.rs", ""), "/repo");
        assert_eq!(
            a.iter().map(|a| a.action).collect::<Vec<_>>(),
            vec![FileAction::Deleted, FileAction::Created]
        );
    }
    #[test]
    fn redirects_are_not_read_targets() {
        let a = file_activities(
            &event("Bash", "cat input.txt > output.txt 2>/dev/null", ""),
            "/repo",
        );
        assert_eq!(
            a.iter().map(|a| (&*a.path, a.action)).collect::<Vec<_>>(),
            vec![
                ("input.txt", FileAction::Read),
                ("output.txt", FileAction::Modified)
            ]
        );
    }
    #[test]
    fn extensionless_paths_and_option_filter() {
        let a = file_activities(&event("Grep", "-n needle README src/main.rs", ""), "/repo");
        assert_eq!(
            a.iter().map(|a| a.path.as_str()).collect::<Vec<_>>(),
            vec!["README", "src/main.rs"]
        );
    }
    #[test]
    fn incremental_files_survive_journal_eviction() {
        let journal = EventJournal::new(1);
        let mut tracker = FilesTracker::default();
        journal.append("s", Some("t1"), "turn_started", HashMap::new());
        journal.append("s", Some("t1"), "tool_use", event("Edit", "", "a.rs").data);
        tracker.update(Some(&journal), &[], "/repo");
        journal.append("s", Some("t2"), "turn_started", HashMap::new());
        tracker.update(Some(&journal), &[], "/repo");
        assert!(tracker.files.contains("a.rs"));
        assert!(tracker.current_files.is_empty());
        let n = tracker.timeline["a.rs"].len();
        tracker.update(Some(&journal), &[], "/repo");
        assert_eq!(tracker.timeline["a.rs"].len(), n);
    }
    #[test]
    fn completed_blocks_only_record_once() {
        let mut block = CommandBlock::new("touch x.rs", 0);
        block.changed_files = vec!["x.rs".into()];
        let mut tracker = FilesTracker::default();
        tracker.update(None, &[block.clone()], "/repo");
        assert!(tracker.files.is_empty());
        block.finish_after(0.1);
        tracker.update(None, &[block.clone()], "/repo");
        tracker.update(None, &[block], "/repo");
        assert_eq!(tracker.timeline["x.rs"].len(), 1);
        assert!(tracker.actions["x.rs"].contains(&FileAction::Created));
    }
    #[test]
    fn total_usage_includes_cache() {
        assert_eq!(
            Usage {
                input: 1,
                output: 2,
                cache_creation: 3,
                cache_read: 4
            }
            .total(),
            10
        );
    }
    #[test]
    fn ready_status_requires_prompt() {
        assert_eq!(live_state("done", false), State::Busy);
        assert_eq!(live_state("done", true), State::Ready);
    }
    #[test]
    fn plans_are_isolated_and_ids_cannot_escape() {
        let root = crate::data_root::DataRoot::with_home(
            std::env::temp_dir().join(Uuid::new_v4().to_string()),
            true,
        );
        let repo = "/repo";
        let path = owned_plan_path(&root, repo, &["../../other"]);
        assert!(path.starts_with(root.repo_overlay_dir(Path::new(repo))));
        assert!(!path.starts_with(repo));
        assert_ne!(path, owned_plan_path(&root, repo, &[]));
    }
    #[test]
    fn plan_preparation_preserves_user_contents() {
        let dir = std::env::temp_dir().join(format!("next-plan-{}", Uuid::new_v4()));
        let path = dir.join("plan.md");
        prepare_plan(&path, "Example").unwrap();
        assert!(
            std::fs::read_to_string(&path)
                .unwrap()
                .contains("# Example Runbook")
        );
        std::fs::write(&path, "user plan").unwrap();
        prepare_plan(&path, "Example").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "user plan");
        let _ = std::fs::remove_dir_all(dir);
    }
    #[test]
    fn plan_discovery_and_import_preserve_swift_sources() {
        let dir = std::env::temp_dir().join(format!("next-plan-import-{}", Uuid::new_v4()));
        let repo = dir.join("repository");
        let shared = crate::data_root::DataRoot::repo_metadata_file(&repo)
            .parent()
            .unwrap()
            .to_path_buf();
        std::fs::create_dir_all(shared.join("sessions/session")).unwrap();
        std::fs::write(shared.join("plan.md"), "repo plan").unwrap();
        std::fs::write(shared.join("sessions/session/plan.md"), "session plan").unwrap();
        std::fs::write(repo.join("TODO.markdown"), "- [x] Imported task").unwrap();
        let touched = BTreeSet::from(["TODO.markdown".into()]);
        let source = plan_source(&repo, &touched, &[]).unwrap();
        assert_eq!(source, repo.join("TODO.markdown").canonicalize().unwrap());
        let own = dir.join("next/plan.md");
        prepare_plan_from(&own, "Example", Some(&source)).unwrap();
        assert_eq!(
            std::fs::read_to_string(&own).unwrap(),
            "- [x] Imported task"
        );
        std::fs::write(&own, "Next edit").unwrap();
        prepare_plan_from(&own, "Example", Some(&source)).unwrap();
        assert_eq!(std::fs::read_to_string(&own).unwrap(), "Next edit");
        assert_eq!(
            std::fs::read_to_string(&source).unwrap(),
            "- [x] Imported task"
        );
        assert_eq!(
            plan_source(&repo, &touched, &["session"]),
            Some(
                shared
                    .join("sessions/session/plan.md")
                    .canonicalize()
                    .unwrap()
            )
        );
        assert_eq!(plan_source(&repo, &touched, &["missing"]), None);
        assert_eq!(plan_source(&repo, &touched, &["../other"]), None);
        let _ = std::fs::remove_dir_all(dir);
    }
    #[cfg(unix)]
    #[test]
    fn plan_discovery_does_not_follow_outside_symlinks() {
        let dir = std::env::temp_dir().join(format!("next-plan-link-{}", Uuid::new_v4()));
        let repo = dir.join("repository");
        std::fs::create_dir_all(&repo).unwrap();
        std::fs::write(dir.join("outside.md"), "private").unwrap();
        std::os::unix::fs::symlink(dir.join("outside.md"), repo.join("plan.md")).unwrap();
        assert_eq!(
            plan_source(&repo, &BTreeSet::from(["plan.md".into()]), &[]),
            None
        );
        let _ = std::fs::remove_dir_all(dir);
    }
    #[test]
    fn commit_paths_are_literal_unique_and_bounded() {
        assert_eq!(
            commit_paths("/repo", &["x.rs".into(), "/repo/x.rs".into()]).unwrap(),
            vec!["x.rs"]
        );
        for invalid in ["../outside", ":(glob)*", ".git/config", "/elsewhere/x.rs"] {
            assert!(
                commit_paths("/repo", &[invalid.into()]).is_err(),
                "{invalid}"
            );
        }
        assert!(commit_paths("/repo", &[]).is_err());
        assert!(commit_files("/repo", &["x.rs".into()], " ").is_err());
    }
    #[test]
    fn commit_paths_use_git_separators_for_native_nested_files() {
        let repository = std::path::PathBuf::from("/repo");
        let relative = std::path::PathBuf::from("sub").join("file.rs");
        let full = repository.join(&relative);
        assert_eq!(
            commit_paths(
                repository.to_str().unwrap(),
                &[
                    relative.to_string_lossy().into_owned(),
                    full.to_string_lossy().into_owned()
                ]
            )
            .unwrap(),
            vec!["sub/file.rs"]
        );
    }
    #[cfg(unix)]
    #[test]
    fn commit_paths_preserve_literal_unix_backslashes() {
        assert_eq!(
            commit_paths("/repo", &[r"literal\file.rs".into()]).unwrap(),
            vec![r"literal\file.rs"]
        );
    }
    #[cfg(windows)]
    #[test]
    fn commit_paths_bound_windows_drives_and_rooted_paths() {
        assert_eq!(
            commit_paths(
                r"C:\repo",
                &[r"C:\repo\sub\file.rs".into(), r"sub\file.rs".into()]
            )
            .unwrap(),
            vec!["sub/file.rs"]
        );
        assert_eq!(
            commit_paths(r"\repo", &[r"\repo\sub\file.rs".into()]).unwrap(),
            vec!["sub/file.rs"]
        );
        for outside in [
            r"D:\repo\file.rs",
            r"C:\elsewhere\file.rs",
            r"..\outside",
            r".git\config",
            r"C:relative.rs",
        ] {
            assert!(
                commit_paths(r"C:\repo", &[outside.into()]).is_err(),
                "{outside}"
            );
        }
    }
    #[test]
    fn agent_commits_preserve_unrelated_staged_files() {
        let dir = std::env::temp_dir().join(format!("next-commit-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let repo = dir.to_string_lossy();
        for args in [
            &["init"][..],
            &["config", "user.name", "Dashboard Fixture"],
            &["config", "user.email", "dashboard@example.invalid"],
        ] {
            git_checked(
                &repo,
                &args.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            )
            .unwrap();
        }
        git_checked(
            &repo,
            &["config".into(), "commit.gpgSign".into(), "false".into()],
        )
        .unwrap();
        let hooks = dir.join("empty-hooks");
        std::fs::create_dir_all(&hooks).unwrap();
        git_checked(
            &repo,
            &[
                "config".into(),
                "core.hooksPath".into(),
                hooks.to_string_lossy().into_owned(),
            ],
        )
        .unwrap();
        std::fs::write(dir.join("agent.txt"), "a").unwrap();
        std::fs::write(dir.join("other.txt"), "o").unwrap();
        git_checked(&repo, &["add".into(), "other.txt".into()]).unwrap();
        commit_files(&repo, &["agent.txt".into()], "feat: agent change").unwrap();
        let staged = git_checked(
            &repo,
            &["diff".into(), "--cached".into(), "--name-only".into()],
        )
        .unwrap();
        assert_eq!(staged.trim(), "other.txt");
        let committed = git_checked(
            &repo,
            &[
                "show".into(),
                "--format=".into(),
                "--name-only".into(),
                "HEAD".into(),
            ],
        )
        .unwrap();
        assert_eq!(committed.trim(), "agent.txt");
        let _ = std::fs::remove_dir_all(dir);
    }
    #[test]
    fn cleared_files_do_not_replay_completed_journal_events() {
        let journal = EventJournal::default();
        let mut tracker = FilesTracker::default();
        journal.append("s", Some("t1"), "tool_use", event("Edit", "", "a.rs").data);
        tracker.update(Some(&journal), &[], "/repo");
        let cursor = tracker.cursor;
        tracker.clear_committed_files();
        tracker.update(Some(&journal), &[], "/repo");
        assert!(tracker.files.is_empty());
        assert_eq!(tracker.cursor, cursor);
        journal.append("s", Some("t2"), "tool_use", event("Edit", "", "b.rs").data);
        tracker.update(Some(&journal), &[], "/repo");
        assert_eq!(tracker.files, BTreeSet::from(["b.rs".into()]));
    }
    #[test]
    fn current_source_live_status_mappings() {
        assert_eq!(
            live_state("approvalRequired", false),
            State::AwaitingApproval
        );
        assert_eq!(live_state("waitingForInput", true), State::WaitingInput);
        assert_eq!(live_state("idle", true), State::Ready);
        assert_eq!(live_state("done", false), State::Busy);
        assert_eq!(live_state("exited", false), State::Stopped);
    }
}
