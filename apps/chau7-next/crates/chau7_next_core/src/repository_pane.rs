//! Repository pane state and literal Git operations. Call only off the UI thread.
use crate::data_root::DataRoot;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FileEntry {
    pub path: String,
    pub index: char,
    pub worktree: char,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Status {
    pub staged: Vec<FileEntry>,
    pub modified: Vec<FileEntry>,
    pub untracked: Vec<String>,
    pub conflicted: Vec<String>,
}
/// NUL porcelain preserves whitespace, quotes, newlines and rename destinations.
pub fn parse_status(bytes: &[u8]) -> Status {
    let mut result = Status::default();
    let mut fields = bytes.split(|b| *b == 0);
    while let Some(field) = fields.next() {
        if field.len() < 4 {
            continue;
        }
        let x = field[0] as char;
        let y = field[1] as char;
        let path = String::from_utf8_lossy(&field[3..]).into_owned();
        if x == 'R' || x == 'C' || y == 'R' || y == 'C' {
            fields.next();
        }
        if x == '?' && y == '?' {
            result.untracked.push(path);
            continue;
        }
        if x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D') {
            result.conflicted.push(path);
            continue;
        }
        let entry = FileEntry {
            path,
            index: x,
            worktree: y,
        };
        if x != ' ' && x != '?' {
            result.staged.push(entry.clone());
        }
        if y != ' ' && y != '?' {
            result.modified.push(entry);
        }
    }
    result
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DiffStat {
    pub added: u64,
    pub deleted: u64,
}
pub fn parse_numstat(bytes: &[u8]) -> BTreeMap<String, DiffStat> {
    let mut map = BTreeMap::new();
    let mut fields = bytes.split(|b| *b == 0);
    while let Some(field) = fields.next() {
        let mut parts = field.splitn(3, |b| *b == b'\t');
        let Some(a) = parts.next() else { continue };
        let Some(d) = parts.next() else { continue };
        let Some(p) = parts.next() else { continue };
        let name = if p.is_empty() {
            fields.next();
            fields.next().unwrap_or_default()
        } else {
            p
        };
        let e = map
            .entry(String::from_utf8_lossy(name).into_owned())
            .or_insert(DiffStat::default());
        e.added += String::from_utf8_lossy(a).parse::<u64>().unwrap_or(0);
        e.deleted += String::from_utf8_lossy(d).parse::<u64>().unwrap_or(0);
    }
    map
}
#[derive(Clone, Debug, Default)]
pub struct Branch {
    pub name: String,
    pub hash: String,
    pub message: String,
    pub current: bool,
    pub remote: bool,
}
#[derive(Clone, Debug, Default)]
pub struct Commit {
    pub hash: String,
    pub short_hash: String,
    pub message: String,
    pub author: String,
    pub date: String,
}
impl Commit {
    pub fn full_entry(&self) -> String {
        format!(
            "{}\n{}\n{}\n{}",
            self.hash, self.message, self.author, self.date
        )
    }
}
#[derive(Clone, Debug, Default)]
pub struct Stash {
    pub index: usize,
    pub hash: String,
    pub description: String,
}
#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub status: Status,
    pub stats: BTreeMap<String, DiffStat>,
    pub current_branch: String,
    pub ahead_behind: Option<(u64, u64)>,
    pub branches: Vec<Branch>,
    pub commits: Vec<Commit>,
    pub stashes: Vec<Stash>,
}

const OUTPUT_LIMIT: u64 = 8 * 1024 * 1024;
fn bounded_read(mut reader: impl Read) -> Vec<u8> {
    let mut out = Vec::new();
    let mut chunk = [0; 8192];
    loop {
        match reader.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let remaining = (OUTPUT_LIMIT as usize).saturating_sub(out.len());
                out.extend_from_slice(&chunk[..n.min(remaining)]);
            }
        }
    }
    out
}
/// Read both pipes concurrently, bound retained output and disable interactive credential prompts.
pub fn git(repo: &Path, args: &[String]) -> Result<Vec<u8>, String> {
    let mut child = Command::new("git")
        .arg("--literal-pathspecs")
        .args(args)
        .current_dir(repo)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_PAGER", "cat")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let stdout = child.stdout.take().ok_or("Missing Git output")?;
    let stderr = child.stderr.take().ok_or("Missing Git error stream")?;
    let out = std::thread::spawn(move || bounded_read(stdout));
    let err = std::thread::spawn(move || bounded_read(stderr));
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Ok(s),
            Ok(None) => {
                if start.elapsed() > Duration::from_secs(60) {
                    let _ = child.kill();
                    let _ = child.wait();
                    break Err("Git operation timed out".to_string());
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(e) => break Err(e.to_string()),
        }
    };
    let out = out.join().unwrap_or_default();
    let err = err.join().unwrap_or_default();
    let status = status?;
    if status.success() {
        Ok(out)
    } else {
        let message = if err.is_empty() { &out } else { &err };
        Err(if message.is_empty() {
            format!("Git failed ({status})")
        } else {
            String::from_utf8_lossy(message).trim().to_string()
        })
    }
}
fn args(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}
fn text(repo: &Path, items: &[&str]) -> Result<String, String> {
    git(repo, &args(items)).map(|s| String::from_utf8_lossy(&s).trim().to_string())
}
pub fn snapshot(repo: &Path, limit: usize) -> Result<Snapshot, String> {
    let status = parse_status(&git(repo, &args(&["status", "--porcelain=v1", "-z"]))?);
    let current_branch = text(repo, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default();
    let mut stats =
        parse_numstat(&git(repo, &args(&["diff", "--numstat", "-z"])).unwrap_or_default());
    for (k, v) in parse_numstat(
        &git(repo, &args(&["diff", "--cached", "--numstat", "-z"])).unwrap_or_default(),
    ) {
        let entry = stats.entry(k).or_default();
        entry.added += v.added;
        entry.deleted += v.deleted;
    }
    let ahead_behind = text(
        repo,
        &["rev-list", "--count", "--left-right", "@{upstream}...HEAD"],
    )
    .ok()
    .and_then(|s| {
        let mut p = s.split_whitespace();
        let behind = p.next()?.parse().ok()?;
        let ahead = p.next()?.parse().ok()?;
        Some((ahead, behind))
    });
    let raw = text(
        repo,
        &[
            "for-each-ref",
            "--format=%(refname)%00%(objectname:short)%00%(subject)%00%(HEAD)",
            "refs/heads",
            "refs/remotes",
        ],
    )
    .unwrap_or_default();
    let branches = raw
        .lines()
        .filter_map(|l| {
            let p: Vec<_> = l.split('\0').collect();
            (p.len() == 4 && !p[0].ends_with("/HEAD")).then(|| Branch {
                name: p[0]
                    .trim_start_matches("refs/heads/")
                    .trim_start_matches("refs/remotes/")
                    .into(),
                hash: p[1].into(),
                message: p[2].into(),
                current: p[3] == "*",
                remote: p[0].starts_with("refs/remotes/"),
            })
        })
        .collect();
    let max = format!("-{}", limit.clamp(50, 5000));
    let raw = git(
        repo,
        &args(&["log", &max, "--format=%H%x00%h%x00%s%x00%an%x00%aI%x00"]),
    )
    .unwrap_or_default();
    let mut commits = Vec::new();
    let mut p = raw.split(|b| *b == 0);
    while let Some(h) = p.next() {
        let hash = String::from_utf8_lossy(h).trim().to_string();
        if hash.is_empty() {
            continue;
        }
        let mut next = || String::from_utf8_lossy(p.next().unwrap_or_default()).to_string();
        commits.push(Commit {
            hash,
            short_hash: next(),
            message: next(),
            author: next(),
            date: next(),
        });
    }
    Ok(Snapshot {
        status,
        stats,
        current_branch,
        ahead_behind,
        branches,
        commits,
        stashes: stashes(repo)?,
    })
}
pub fn stashes(repo: &Path) -> Result<Vec<Stash>, String> {
    let raw = text(repo, &["stash", "list", "--format=%H%x00%gs"])?;
    Ok(raw
        .lines()
        .enumerate()
        .filter_map(|(index, l)| {
            l.split_once('\0').map(|(hash, description)| Stash {
                index,
                hash: hash.into(),
                description: description.into(),
            })
        })
        .collect())
}

#[derive(Clone, Debug)]
pub enum Operation {
    Stage(Vec<String>),
    Unstage(Vec<String>),
    StageAll,
    UnstageAll,
    Commit { message: String, amend: bool },
    Switch(String),
    Create(String),
    Delete(String),
    Push,
    Pull,
    StashSave(String),
    StashPop { index: usize, hash: String },
    StashDrop { index: usize, hash: String },
    Resolve { file: String, ours: bool },
}
fn branch(repo: &Path, name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() || name.starts_with('-') {
        return Err("Branch name cannot be empty or start with '-'".into());
    }
    git(repo, &args(&["check-ref-format", "--branch", name]))?;
    Ok(name.into())
}
pub fn perform(repo: &Path, op: &Operation) -> Result<(), String> {
    let command = match op {
        Operation::Stage(p) => {
            let mut a = args(&["add", "--"]);
            a.extend(p.clone());
            a
        }
        Operation::Unstage(p) => {
            let mut a = args(&["restore", "--staged", "--"]);
            a.extend(p.clone());
            a
        }
        Operation::StageAll => args(&["add", "-A"]),
        Operation::UnstageAll => args(&["restore", "--staged", "--", "."]),
        Operation::Commit { message, amend } => {
            if message.trim().is_empty() {
                return Err("Commit message cannot be empty".into());
            }
            let mut a = args(&["commit", "-m", message.trim()]);
            if *amend {
                a.push("--amend".into());
            }
            a
        }
        Operation::Switch(n) => args(&["checkout", &branch(repo, n)?]),
        Operation::Create(n) => args(&["checkout", "-b", &branch(repo, n)?]),
        Operation::Delete(n) => args(&["branch", "-d", &branch(repo, n)?]),
        Operation::Push => args(&["push"]),
        Operation::Pull => args(&["pull"]),
        Operation::StashSave(m) => {
            let mut a = args(&["stash", "push"]);
            if !m.trim().is_empty() {
                a.extend(args(&["-m", m]));
            }
            a
        }
        Operation::StashPop { index, hash } | Operation::StashDrop { index, hash } => {
            let fresh = stashes(repo)?;
            if fresh.get(*index).is_none_or(|s| s.hash != *hash) {
                return Err("Stash changed since it was displayed; refresh before retrying".into());
            }
            args(&[
                "stash",
                if matches!(op, Operation::StashPop { .. }) {
                    "pop"
                } else {
                    "drop"
                },
                &format!("stash@{{{index}}}"),
            ])
        }
        Operation::Resolve { file, ours } => {
            git(
                repo,
                &args(&[
                    "checkout",
                    if *ours { "--ours" } else { "--theirs" },
                    "--",
                    file,
                ]),
            )?;
            args(&["add", "--", file])
        }
    };
    git(repo, &command).map(|_| ())
}
pub const PREFIXES: [&str; 7] = ["feat", "fix", "docs", "style", "refactor", "test", "chore"];
pub fn apply_prefix(prefix: &str, message: &str) -> String {
    let trim = message.trim_start_matches([' ', '\t']);
    if trim.starts_with(&format!("{prefix}:")) || trim.starts_with(&format!("{prefix}(")) {
        message.into()
    } else {
        format!("{prefix}: {trim}")
    }
}
#[derive(Default, Serialize, Deserialize)]
struct Draft {
    message: String,
}
fn draft_path(root: &DataRoot, repo: &Path) -> PathBuf {
    root.repo_overlay_dir(repo).join("commit-draft.json")
}
pub fn load_draft(root: &DataRoot, repo: &Path) -> String {
    std::fs::read(draft_path(root, repo))
        .ok()
        .and_then(|b| serde_json::from_slice::<Draft>(&b).ok())
        .unwrap_or_default()
        .message
}
pub fn save_draft(root: &DataRoot, repo: &Path, message: &str) -> Result<(), String> {
    let path = draft_path(root, repo);
    if message.trim().is_empty() {
        match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    } else {
        std::fs::create_dir_all(path.parent().ok_or("Missing draft directory")?)
            .map_err(|e| e.to_string())?;
        let bytes = serde_json::to_vec(&Draft {
            message: message.into(),
        })
        .map_err(|e| e.to_string())?;
        {
            let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
            std::fs::write(&temporary, &bytes)
                .and_then(|_| std::fs::rename(&temporary, &path))
                .map_err(|e| {
                    let _ = std::fs::remove_file(&temporary);
                    e.to_string()
                })
        }
    }
}

/// Serial background writer coalesces per-repository drafts and drains on drop.
/// UI callers perform no filesystem IO and closing a pane cannot cancel its last edit.
pub struct DraftWriter {
    owners: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    state: std::sync::Arc<(std::sync::Mutex<DraftState>, std::sync::Condvar)>,
}
#[derive(Default)]
struct DraftState {
    pending: BTreeMap<PathBuf, String>,
    closed: bool,
    error: Option<String>,
}
impl DraftWriter {
    pub fn new(root: DataRoot) -> Self {
        let state = std::sync::Arc::new((
            std::sync::Mutex::new(DraftState::default()),
            std::sync::Condvar::new(),
        ));
        let worker = state.clone();
        std::thread::spawn(move || {
            loop {
                let (lock, ready) = &*worker;
                let mut inner = lock.lock().unwrap_or_else(|e| e.into_inner());
                while inner.pending.is_empty() && !inner.closed {
                    inner = ready.wait(inner).unwrap_or_else(|e| e.into_inner());
                }
                if inner.pending.is_empty() && inner.closed {
                    break;
                }
                let pending = std::mem::take(&mut inner.pending);
                drop(inner);
                for (directory, message) in pending {
                    if let Err(error) = save_draft(&root, &directory, &message) {
                        let mut inner = lock.lock().unwrap_or_else(|e| e.into_inner());
                        inner.error = Some(error);
                    }
                }
            }
        });
        Self {
            state,
            owners: std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(1)),
        }
    }
    pub fn save(&self, directory: PathBuf, message: String) -> Result<(), String> {
        let (lock, ready) = &*self.state;
        let mut inner = lock.lock().unwrap_or_else(|e| e.into_inner());
        if inner.pending.len() >= 128 && !inner.pending.contains_key(&directory) {
            return Err("Too many pending repository drafts".into());
        }
        inner.pending.insert(directory, message);
        ready.notify_one();
        Ok(())
    }
    pub fn take_error(&self) -> Option<String> {
        self.state
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .error
            .take()
    }
}
impl Clone for DraftWriter {
    fn clone(&self) -> Self {
        self.owners
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        Self {
            state: self.state.clone(),
            owners: self.owners.clone(),
        }
    }
}
impl Drop for DraftWriter {
    fn drop(&mut self) {
        if self
            .owners
            .fetch_sub(1, std::sync::atomic::Ordering::AcqRel)
            != 1
        {
            return;
        }
        let (lock, ready) = &*self.state;
        lock.lock().unwrap_or_else(|e| e.into_inner()).closed = true;
        ready.notify_one();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn status_preserves_literal_names_and_rename_destination() {
        let s = parse_status(
            b"MM two words\0?? quote\"file\0R  new\nname\0old\0UU conflict\0AA both\0",
        );
        assert_eq!(s.staged[1].path, "new\nname");
        assert_eq!(s.modified[0].path, "two words");
        assert_eq!(s.untracked, ["quote\"file"]);
        assert_eq!(s.conflicted, ["conflict", "both"]);
    }
    #[test]
    fn numstat_binary_and_renames() {
        let s = parse_numstat(b"2\t3\tname\0-\t-\tbinary\0");
        assert_eq!(
            s["name"],
            DiffStat {
                added: 2,
                deleted: 3
            }
        );
        assert_eq!(s["binary"], DiffStat::default());
        let s = parse_numstat(b"4\t1\t\0old\0new\0");
        assert_eq!(s["new"].added, 4);
    }
    #[test]
    fn conventional_prefix_matches_swift() {
        assert_eq!(
            apply_prefix("feat", " feat(scope): message"),
            " feat(scope): message"
        );
        assert_eq!(apply_prefix("fix", " feat: old"), "fix: feat: old");
    }
    #[test]
    fn actual_git_ops_and_stash_identity() {
        let home = std::env::temp_dir().join(format!("next-repo-pane-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&home).unwrap();
        git(&home, &args(&["init", "-b", "main"])).unwrap();
        git(&home, &args(&["config", "user.name", "Next Test"])).unwrap();
        git(
            &home,
            &args(&["config", "user.email", "next-test@example.invalid"]),
        )
        .unwrap();
        std::fs::write(home.join("--literal name"), "first").unwrap();
        let s = snapshot(&home, 50).unwrap();
        assert_eq!(s.status.untracked, ["--literal name"]);
        perform(&home, &Operation::Stage(vec!["--literal name".into()])).unwrap();
        perform(
            &home,
            &Operation::Commit {
                message: "initial".into(),
                amend: false,
            },
        )
        .unwrap();
        assert_eq!(snapshot(&home, 50).unwrap().commits[0].message, "initial");
        perform(&home, &Operation::Create("feature".into())).unwrap();
        std::fs::write(home.join("--literal name"), "changed").unwrap();
        perform(&home, &Operation::StashSave("test".into())).unwrap();
        let stash = stashes(&home).unwrap().remove(0);
        assert!(
            perform(
                &home,
                &Operation::StashDrop {
                    index: 0,
                    hash: "wrong".into()
                }
            )
            .is_err()
        );
        perform(
            &home,
            &Operation::StashPop {
                index: 0,
                hash: stash.hash,
            },
        )
        .unwrap();
        assert_eq!(
            std::fs::read_to_string(home.join("--literal name")).unwrap(),
            "changed"
        );
        assert!(perform(&home, &Operation::Create("--detach".into())).is_err());
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn drafts_are_isolated_and_latest_edit_survives_writer_drop() {
        let home = std::env::temp_dir().join(format!("next-draft-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&home).unwrap();
        let root = DataRoot::with_home(home.clone(), true);
        let directory = home.join("repo");
        let writer = DraftWriter::new(root.clone());
        let command = writer.clone();
        for i in 0..100 {
            writer
                .save(directory.clone(), format!("draft {i}"))
                .unwrap();
        }
        drop(writer);
        command
            .save(directory.clone(), "final edit".into())
            .unwrap();
        drop(command);
        let deadline = Instant::now() + Duration::from_secs(5);
        while load_draft(&root, &directory) != "final edit" {
            assert!(
                Instant::now() < deadline,
                "final queued draft must be drained"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!directory.join(".chau7").exists());
        save_draft(&root, &directory, "").unwrap();
        assert_eq!(load_draft(&root, &directory), "");
        std::fs::remove_dir_all(home).unwrap();
    }
}
