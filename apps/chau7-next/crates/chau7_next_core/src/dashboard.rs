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
    pub backend: String,
    pub directory: String,
    pub purpose: Option<String>,
    pub parent_id: Option<String>,
    pub delegation_depth: usize,
    pub state: State,
    pub turns: u64,
    pub usage: Option<Usage>,
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
#[cfg(test)]
mod tests {
    use super::*;
    fn agent(id: &str, tab: Uuid) -> Agent {
        Agent {
            id: id.into(),
            tab_id: tab,
            backend: "claude".into(),
            directory: "/repo".into(),
            purpose: None,
            parent_id: None,
            delegation_depth: 0,
            state: State::Ready,
            turns: 0,
            usage: None,
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
}
