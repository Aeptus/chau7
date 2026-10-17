//! Follow the Claude and Codex history files and the PTY wrapper logs
//! (`AppModel.startIdleMonitors`, `startTerminalMonitors`, `HistoryIdleMonitor`).
//!
//! The files are only read: `~/.claude/history.jsonl` and
//! `~/.codex/history.jsonl` belong to those tools, and the PTY logs to the
//! wrapper that writes them. A tailer thread per file parses lines and sends
//! them over a channel; a timer on the main thread applies them, keeps the
//! session list the settings window shows, and queues the "idle" and
//! "Session completed (history)" events for the notification pipeline
//! ([`take_notices`]).
//!
//! Terminal log lines are kept per tool (250 lines) for the log viewer;
//! history entries per tool (200), as Swift keeps them in `AppModel`.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chau7_next_core::env_vars;
use chau7_next_core::file_tailer::{FileTailer, TailerConfig, TailerHandle};
use chau7_next_core::history_events::{
    HistoryEntry, HistorySessionState, parse_entry, sanitize_summary,
};
use chau7_next_core::history_monitor::{
    HistoryIdleTracker, SessionStatus, SessionStatuses, TrackerOutput,
};
use gpui::{App, BorrowAppContext, Global};

use crate::monitoring_status::MonitoringStatus;
use crate::settings::{HistorySettings, Settings};

/// Entries kept per tool (`maxHistoryEntries`).
const MAX_HISTORY_ENTRIES: usize = 200;
/// Terminal lines kept per tool (`maxTerminalLines`).
const MAX_TERMINAL_LINES: usize = 250;
/// Lines read from the end of a PTY log at start (`terminalPrefillLines`).
const TERMINAL_PREFILL_LINES: usize = 200;
/// Entries and sessions older than this are dropped hourly (`maxEntryAgeSeconds`).
const MAX_ENTRY_AGE_SECONDS: f64 = 7.0 * 24.0 * 3600.0;
/// Pending notices kept if nobody takes them.
const MAX_NOTICES: usize = 100;

/// The two tools whose files are followed.
const TOOLS: [&str; 2] = ["Codex", "Claude"];

/// What the notification pipeline is told.
#[derive(Debug, Clone, PartialEq)]
pub struct HistoryNotice {
    /// `idle` or `finished`.
    pub kind: &'static str,
    /// Display name: `Claude` or `Codex`.
    pub tool: String,
    pub session_id: String,
    pub message: String,
    /// Not known from the history file alone; filled once the Claude and
    /// Codex session lookups exist.
    pub directory: Option<String>,
    /// Unix seconds.
    pub timestamp: f64,
}

enum Msg {
    Entry {
        generation: u64,
        tool: usize,
        entry: HistoryEntry,
    },
    Line {
        generation: u64,
        tool: usize,
        line: String,
    },
}

struct HistoryFollower {
    tool: &'static str,
    path: PathBuf,
    tracker: HistoryIdleTracker,
    _handle: TailerHandle,
}

/// The running monitors and what they have seen.
pub struct HistoryMonitors {
    tx: Sender<Msg>,
    rx: Receiver<Msg>,
    generation: u64,
    followers: Vec<HistoryFollower>,
    terminals: Vec<TailerHandle>,
    history_config: Option<Vec<(String, PathBuf)>>,
    terminal_config: Option<Vec<(String, PathBuf)>>,
    pub statuses: SessionStatuses,
    /// Provider key (`claude`, `codex`) to its latest entries.
    pub entries: HashMap<String, Vec<HistoryEntry>>,
    /// Provider key to its latest PTY log lines.
    pub terminal_lines: HashMap<String, VecDeque<String>>,
    notices: VecDeque<HistoryNotice>,
    last_cleanup: f64,
}

impl Global for HistoryMonitors {}

fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn provider_key(tool: &str) -> String {
    chau7_next_core::ai::tool_registry::resume_provider_key_for(tool)
        .map_or_else(|| tool.to_lowercase(), str::to_string)
}

/// `~` and `~/...` in a settings path.
pub fn expand_home(path: &str, home: &Path) -> PathBuf {
    let path = path.trim();
    if path == "~" {
        home.to_path_buf()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(path)
    }
}

fn env_path(new: &str, legacy: &str) -> Option<String> {
    crate::logging::env_override(new, Some(legacy))
}

/// `CHAU7_IDLE_STALE_SECONDS` (legacy `AI_IDLE_STALE_SECONDS`) beats the
/// stale setting.
fn stale_secs(settings: &HistorySettings) -> f64 {
    env_path(env_vars::IDLE_STALE_SECONDS, env_vars::LEGACY_STALE_SECONDS)
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|v| *v > 0.0)
        .unwrap_or_else(|| settings.stale_secs())
}

/// A boolean variable that beats a setting: anything but "0" is on.
fn env_flag(new: &str, legacy: &str, setting: bool) -> bool {
    env_path(new, legacy).map_or(setting, |v| v != "0")
}

/// "Normalize Output" (`CHAU7_TERMINAL_NORMALIZE` beats the setting).
pub fn terminal_normalize(cx: &App) -> bool {
    env_flag(
        env_vars::TERMINAL_NORMALIZE,
        env_vars::LEGACY_TERMINAL_NORMALIZE,
        Settings::get(cx).history.terminal_normalize,
    )
}

/// "Render ANSI" in the log view (`CHAU7_TERMINAL_ANSI` beats the setting).
pub fn terminal_ansi(cx: &App) -> bool {
    env_flag(
        env_vars::TERMINAL_ANSI,
        env_vars::LEGACY_TERMINAL_ANSI,
        Settings::get(cx).history.terminal_ansi,
    )
}

/// History files to follow: the setting (environment first), or nothing for
/// an empty path.
fn history_paths(settings: &HistorySettings, home: &Path) -> Vec<(String, PathBuf)> {
    let codex = env_path(
        env_vars::CODEX_HISTORY_LOG,
        env_vars::LEGACY_CODEX_HISTORY_LOG,
    )
    .unwrap_or_else(|| settings.codex_history_path.clone());
    let claude = env_path(
        env_vars::CLAUDE_HISTORY_LOG,
        env_vars::LEGACY_CLAUDE_HISTORY_LOG,
    )
    .unwrap_or_else(|| settings.claude_history_path.clone());
    [("Codex", codex), ("Claude", claude)]
        .into_iter()
        .filter(|(_, path)| !path.trim().is_empty())
        .map(|(tool, path)| (tool.to_string(), expand_home(&path, home)))
        .collect()
}

/// PTY logs to follow; an empty setting means the default file.
fn terminal_paths(
    settings: &HistorySettings,
    logs_dir: &Path,
    home: &Path,
) -> Vec<(String, PathBuf)> {
    let codex = env_path(
        env_vars::CODEX_TERMINAL_LOG,
        env_vars::LEGACY_CODEX_TERMINAL_LOG,
    )
    .unwrap_or_else(|| settings.codex_terminal_log.clone());
    let claude = env_path(
        env_vars::CLAUDE_TERMINAL_LOG,
        env_vars::LEGACY_CLAUDE_TERMINAL_LOG,
    )
    .unwrap_or_else(|| settings.claude_terminal_log.clone());
    [
        ("Codex", codex, "codex-pty.log"),
        ("Claude", claude, "claude-pty.log"),
    ]
    .into_iter()
    .map(|(tool, path, default)| {
        let resolved = if path.trim().is_empty() {
            logs_dir.join(default)
        } else {
            expand_home(&path, home)
        };
        (tool.to_string(), resolved)
    })
    .collect()
}

impl HistoryMonitors {
    fn new() -> Self {
        let (tx, rx) = channel();
        Self {
            tx,
            rx,
            generation: 0,
            followers: Vec::new(),
            terminals: Vec::new(),
            history_config: None,
            terminal_config: None,
            statuses: SessionStatuses::new(),
            entries: HashMap::new(),
            terminal_lines: HashMap::new(),
            notices: VecDeque::new(),
            last_cleanup: now_secs(),
        }
    }

    fn tool_index(tool: &str) -> usize {
        TOOLS.iter().position(|t| *t == tool).unwrap_or(0)
    }

    fn stop_history(&mut self) {
        self.followers.clear();
        self.history_config = None;
        self.generation += 1;
    }

    fn start_history(&mut self, paths: Vec<(String, PathBuf)>) {
        self.stop_history();
        let generation = self.generation;
        for (tool, path) in &paths {
            log::info!("starting {tool} history monitor at {}", path.display());
            let index = Self::tool_index(tool);
            let tailer = FileTailer::new(TailerConfig::history(path), |line| {
                parse_entry(line).map_err(|e| format!("{e:?}"))
            });
            let tx = self.tx.clone();
            let handle = TailerHandle::spawn(tailer, 0, move |entry| {
                let _ = tx.send(Msg::Entry {
                    generation,
                    tool: index,
                    entry,
                });
            });
            self.followers.push(HistoryFollower {
                tool: TOOLS[index],
                path: path.clone(),
                tracker: HistoryIdleTracker::new(),
                _handle: handle,
            });
        }
        self.history_config = Some(paths);
    }

    fn stop_terminal(&mut self) {
        self.terminals.clear();
        self.terminal_config = None;
    }

    fn start_terminal(&mut self, paths: Vec<(String, PathBuf)>) {
        self.stop_terminal();
        let generation = self.generation;
        for (tool, path) in &paths {
            log::info!("starting {tool} terminal tailer at {}", path.display());
            let index = Self::tool_index(tool);
            let tailer = FileTailer::new(TailerConfig::text(path), |line| Ok(line.to_string()));
            let tx = self.tx.clone();
            self.terminals.push(TailerHandle::spawn(
                tailer,
                TERMINAL_PREFILL_LINES,
                move |line| {
                    let _ = tx.send(Msg::Line {
                        generation,
                        tool: index,
                        line,
                    });
                },
            ));
        }
        self.terminal_config = Some(paths);
    }

    /// `handleHistoryEntry` and the tracker's reaction to it.
    fn on_entry(&mut self, tool_index: usize, entry: HistoryEntry, settings: &HistorySettings) {
        let tool = TOOLS[tool_index];
        let summary = sanitize_summary(&entry.summary, entry.is_exit);
        if summary.is_empty() && !entry.summary.is_empty() {
            log::trace!("dropping truncated history summary from {tool}");
        }
        log::info!(
            "history entry: tool={tool} session={} summary=\"{summary}\"",
            entry.session_id
        );
        let stored = HistoryEntry {
            summary,
            ..entry.clone()
        };
        let list = self.entries.entry(provider_key(tool)).or_default();
        list.push(stored);
        if list.len() > MAX_HISTORY_ENTRIES {
            list.drain(..list.len() - MAX_HISTORY_ENTRIES);
        }
        let now = now_secs();
        let outputs = match self.followers.iter_mut().find(|f| f.tool == tool) {
            Some(follower) => follower.tracker.record(&entry, now),
            None => return,
        };
        self.apply(tool, outputs, settings, now);
    }

    fn apply(
        &mut self,
        tool: &'static str,
        outputs: Vec<TrackerOutput>,
        _settings: &HistorySettings,
        now: f64,
    ) {
        for output in outputs {
            match output {
                TrackerOutput::Idle { entry, idle_for } => {
                    let short: String = entry.session_id.chars().take(8).collect();
                    let secs = idle_for.round() as i64;
                    let summary = if entry.summary.is_empty() {
                        "Session idle."
                    } else {
                        entry.summary.as_str()
                    };
                    log::info!("idle detected for {tool} session={short} idleFor={secs}s");
                    self.push_notice(HistoryNotice {
                        kind: "idle",
                        tool: tool.to_string(),
                        session_id: entry.session_id.clone(),
                        message: format!("No new history for {secs}s (session {short}). {summary}"),
                        directory: None,
                        timestamp: now,
                    });
                }
                TrackerOutput::StateChange {
                    session_id,
                    state,
                    last_seen,
                    last_entry,
                    ..
                } => {
                    log::info!(
                        "session state: tool={tool} session={session_id} state={}",
                        state.raw_value()
                    );
                    let kind = last_entry.as_ref().map_or(
                        chau7_next_core::history_events::HistoryEntryActivityKind::Unknown,
                        |e| e.activity_kind,
                    );
                    let update =
                        self.statuses
                            .update(tool, &session_id, state, last_seen, kind, now);
                    if update.is_reactivation {
                        log::trace!("history session reactivated after close: {tool} {session_id}");
                    }
                    if update.emits_finished {
                        self.push_notice(HistoryNotice {
                            kind: "finished",
                            tool: tool.to_string(),
                            session_id,
                            message: format!("{tool} finished"),
                            directory: None,
                            timestamp: now,
                        });
                    }
                }
            }
        }
    }

    fn push_notice(&mut self, notice: HistoryNotice) {
        self.notices.push_back(notice);
        while self.notices.len() > MAX_NOTICES {
            self.notices.pop_front();
        }
    }

    /// The periodic idle and stale check, and the hourly cleanup.
    fn check(&mut self, settings: &HistorySettings) {
        let now = now_secs();
        let (idle, stale) = (settings.idle_secs(), stale_secs(settings));
        let mut work = Vec::new();
        for follower in &mut self.followers {
            let outputs = follower.tracker.check(now, idle, stale);
            if !outputs.is_empty() {
                work.push((follower.tool, outputs));
            }
        }
        for (tool, outputs) in work {
            self.apply(tool, outputs, settings, now);
        }
        if now - self.last_cleanup >= 3600.0 {
            self.last_cleanup = now;
            let cutoff = now - MAX_ENTRY_AGE_SECONDS;
            for list in self.entries.values_mut() {
                list.retain(|e| e.timestamp >= cutoff);
            }
            self.statuses.prune_older_than(cutoff);
        }
    }

    /// Apply what the tailer threads sent.
    fn drain(&mut self, settings: &HistorySettings) {
        while let Ok(msg) = self.rx.try_recv() {
            match msg {
                Msg::Entry {
                    generation,
                    tool,
                    entry,
                } if generation == self.generation => self.on_entry(tool, entry, settings),
                Msg::Line {
                    generation,
                    tool,
                    line,
                } if generation == self.generation => {
                    let line = line.trim_end_matches(['\r', '\n']).to_string();
                    if line.trim().is_empty() {
                        continue;
                    }
                    let lines = self
                        .terminal_lines
                        .entry(provider_key(TOOLS[tool]))
                        .or_default();
                    lines.push_back(line);
                    while lines.len() > MAX_TERMINAL_LINES {
                        lines.pop_front();
                    }
                }
                _ => {}
            }
        }
    }
}

/// The monitors' sessions, newest first (Settings > Logs & History).
pub fn session_statuses(cx: &App) -> Vec<SessionStatus> {
    cx.try_global::<HistoryMonitors>()
        .map(|m| m.statuses.sorted().into_iter().cloned().collect())
        .unwrap_or_default()
}

/// Events for the notification pipeline since the last call.
pub fn take_notices(cx: &mut App) -> Vec<HistoryNotice> {
    if cx.try_global::<HistoryMonitors>().is_none() {
        return Vec::new();
    }
    cx.global_mut::<HistoryMonitors>()
        .notices
        .drain(..)
        .collect()
}

/// The latest PTY log lines of a tool (`claude`, `codex`), shown as typed
/// or with escape sequences removed when "Normalize Output" is on.
pub fn terminal_lines(provider: &str, cx: &App) -> Vec<String> {
    let normalize = terminal_normalize(cx);
    cx.try_global::<HistoryMonitors>()
        .and_then(|m| m.terminal_lines.get(provider))
        .map(|lines| {
            lines
                .iter()
                .map(|l| {
                    if normalize {
                        chau7_next_core::escape_sanitizer::sanitize(l)
                    } else {
                        l.clone()
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The latest parsed history entries of a tool (`claude`, `codex`).
pub fn history_entries(provider: &str, cx: &App) -> Vec<HistoryEntry> {
    cx.try_global::<HistoryMonitors>()
        .and_then(|m| m.entries.get(provider))
        .cloned()
        .unwrap_or_default()
}

pub fn init(cx: &mut App) {
    cx.set_global(HistoryMonitors::new());
    apply_settings(cx);
    // Apply tailer output and run the idle check twice a second.
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor()
                .timer(Duration::from_millis(500))
                .await;
            cx.update(|cx| {
                let settings = Settings::get(cx).history.clone();
                cx.update_global(|m: &mut HistoryMonitors, _| {
                    m.drain(&settings);
                    m.check(&settings);
                });
            });
        }
    })
    .detach();
}

fn logs_dir(cx: &App) -> PathBuf {
    cx.global::<crate::workspace::AppData>().root.ai_logs_dir()
}

fn home(cx: &App) -> PathBuf {
    cx.global::<crate::workspace::AppData>()
        .root
        .home()
        .to_path_buf()
}

/// Start, stop or restart the monitors to match the settings (also after the
/// config file changed): a monitor restarts only when its paths changed.
pub fn apply_settings(cx: &mut App) {
    if cx.try_global::<HistoryMonitors>().is_none() {
        return;
    }
    let settings = Settings::get(cx).history.clone();
    let home = home(cx);
    let logs = logs_dir(cx);
    let history = settings
        .monitor_history_logs
        .then(|| history_paths(&settings, &home));
    let terminal = settings
        .monitor_terminal_logs
        .then(|| terminal_paths(&settings, &logs, &home));
    cx.update_global(|m: &mut HistoryMonitors, _| {
        match history {
            Some(paths) if m.history_config.as_ref() != Some(&paths) => m.start_history(paths),
            None if m.history_config.is_some() || !m.followers.is_empty() => m.stop_history(),
            _ => {}
        }
        match terminal {
            Some(paths) if m.terminal_config.as_ref() != Some(&paths) => m.start_terminal(paths),
            None if m.terminal_config.is_some() => m.stop_terminal(),
            _ => {}
        }
    });
    let (history_on, terminal_on) = {
        let m = cx.global::<HistoryMonitors>();
        (m.history_config.is_some(), m.terminal_config.is_some())
    };
    MonitoringStatus::update(cx, |s| {
        s.history = history_on;
        s.terminal = terminal_on;
    });
}

/// "Restart Monitors" (history): stop and start again.
pub fn restart_history(cx: &mut App) {
    log::info!("restarting idle monitors");
    cx.update_global(|m: &mut HistoryMonitors, _| m.stop_history());
    apply_settings(cx);
}

/// "Restart Monitors" (terminal).
pub fn restart_terminal(cx: &mut App) {
    log::info!("restarting terminal monitors");
    cx.update_global(|m: &mut HistoryMonitors, _| m.stop_terminal());
    apply_settings(cx);
}

/// "Reload Last Lines": clear the lines and read the end of the logs again.
pub fn reload_terminal_prefill(cx: &mut App) {
    log::info!("reloading terminal logs (prefill)");
    clear_terminal_logs(cx);
    restart_terminal(cx);
}

/// "Clear History": forget the entries and sessions shown.
pub fn clear_history(cx: &mut App) {
    cx.update_global(|m: &mut HistoryMonitors, _| {
        m.entries.clear();
        m.statuses.clear();
    });
    cx.refresh_windows();
}

/// "Clear Logs".
pub fn clear_terminal_logs(cx: &mut App) {
    cx.update_global(|m: &mut HistoryMonitors, _| m.terminal_lines.clear());
    cx.refresh_windows();
}

/// For the settings window: the paths being followed.
#[allow(dead_code)]
pub fn followed_history_paths(cx: &App) -> Vec<(String, PathBuf)> {
    cx.try_global::<HistoryMonitors>()
        .map(|m| {
            m.followers
                .iter()
                .map(|f| (f.tool.to_string(), f.path.clone()))
                .collect()
        })
        .unwrap_or_default()
}

#[allow(dead_code)]
fn _state_names(_: HistorySessionState) {}

#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::history_events::HistoryEntryActivityKind;

    #[test]
    fn home_is_expanded() {
        let home = Path::new("/Users/me");
        assert_eq!(
            expand_home("~/.codex/history.jsonl", home),
            Path::new("/Users/me/.codex/history.jsonl")
        );
        assert_eq!(expand_home("~", home), home);
        assert_eq!(expand_home(" /abs/x ", home), Path::new("/abs/x"));
    }

    #[test]
    fn paths_follow_the_settings() {
        let home = Path::new("/h");
        let mut s = HistorySettings::default();
        let paths = history_paths(&s, home);
        assert_eq!(paths.len(), 2);
        assert!(
            paths
                .iter()
                .any(|(t, p)| t == "Claude" && p == Path::new("/h/.claude/history.jsonl"))
        );
        s.claude_history_path.clear();
        assert_eq!(history_paths(&s, home).len(), 1);
        let logs = Path::new("/logs");
        let t = terminal_paths(&s, logs, home);
        assert!(
            t.iter()
                .any(|(tool, p)| tool == "Codex" && p == Path::new("/logs/codex-pty.log"))
        );
        s.claude_terminal_log = "~/c.log".into();
        let t = terminal_paths(&s, logs, home);
        assert!(
            t.iter()
                .any(|(tool, p)| tool == "Claude" && p == Path::new("/h/c.log"))
        );
    }

    #[test]
    fn entries_drive_sessions_and_notices() {
        let mut m = HistoryMonitors::new();
        let dir = std::env::temp_dir().join(format!("chau7-next-mon-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("history.jsonl");
        m.start_history(vec![("Claude".into(), path)]);
        let settings = HistorySettings::default();
        let response = HistoryEntry {
            session_id: "abc12345-xyz".into(),
            timestamp: 0.0,
            summary: "Done, here is the result".into(),
            is_exit: false,
            activity_kind: HistoryEntryActivityKind::Response,
        };
        m.on_entry(1, response, &settings);
        assert_eq!(m.statuses.list.len(), 1);
        assert_eq!(m.statuses.list[0].state, HistorySessionState::Active);
        assert_eq!(m.entries["claude"].len(), 1);
        // A truncated fragment is stored without its summary.
        m.on_entry(
            1,
            HistoryEntry::new("abc12345-xyz", 0.0, "rror", false),
            &settings,
        );
        assert_eq!(m.entries["claude"][1].summary, "");
        // Exit closes the session; a response before it had made it finish.
        let exit = HistoryEntry {
            is_exit: true,
            ..HistoryEntry::new("abc12345-xyz", 0.0, "/exit", true)
        };
        m.on_entry(1, exit, &settings);
        assert_eq!(m.statuses.list[0].state, HistorySessionState::Closed);
        m.stop_history();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
