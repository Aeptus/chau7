//! AI PTY log of one terminal session (`startAILoggingIfNeeded`,
//! `finishAILogging`, `processAILogOutput` in
//! `TerminalSessionModel+ShellIntegration.swift`).
//!
//! While an AI tool runs, typed lines (not sensitive ones) and all output go
//! to a unique `<ai logs>/<tool>-<session>-<run>-pty.log`, and Started / Finished / Failed lines to
//! the AI events log, both in Chau7 Next's data root. Files are written by
//! one writer thread, in order, so the terminal never waits on the disk.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::sync::mpsc::{Sender, channel};

use chau7_next_core::ai::event::AiEventSource;
use chau7_next_core::ai::pty_log::{
    AiLogSession, ExitMarkerFilter, append_event, finished_event, max_bytes_from_env, pty_log_path,
    started_message, tool_slug,
};
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::sensitive_input;

enum Msg {
    Start {
        session: u64,
        tool: String,
        path: PathBuf,
        events_log: PathBuf,
        message: String,
    },
    Output(u64, Vec<u8>),
    Input(u64, String),
    Finish {
        session: u64,
        events_log: PathBuf,
        kind: &'static str,
        tool: String,
        message: String,
    },
}

/// The legacy aggregate remains the explicit provider-wide history source.
/// Only the unique run file is used as an attributed run transcript. Separate
/// per-session input buffers prevent simultaneous prompts from being joined.
struct RunLogs {
    run: AiLogSession,
    history: AiLogSession,
}
impl RunLogs {
    fn new(tool: &str, path: PathBuf, max_bytes: u64) -> Self {
        let aggregate = pty_log_path(path.parent().expect("run log directory"), tool);
        Self {
            run: AiLogSession::new(tool, path, max_bytes),
            history: AiLogSession::new(tool, aggregate, max_bytes),
        }
    }
    fn record_output(&mut self, data: &[u8]) {
        self.run.record_output(data);
        self.history.record_output(data);
    }
    fn record_input(&mut self, text: &str) {
        self.run.record_input(text);
        self.history.record_input(text);
    }
    fn close(&mut self) {
        self.run.close();
        self.history.close();
    }
}

fn writer() -> &'static Sender<Msg> {
    static WRITER: OnceLock<Sender<Msg>> = OnceLock::new();
    WRITER.get_or_init(|| {
        let (tx, rx) = channel::<Msg>();
        let max_bytes = max_bytes_from_env(|k| std::env::var(k).ok());
        std::thread::Builder::new()
            .name("chau7-next-ai-log".into())
            .spawn(move || {
                let source = AiEventSource::TERMINAL_SESSION;
                let mut logs: HashMap<u64, RunLogs> = HashMap::new();
                while let Ok(msg) = rx.recv() {
                    match msg {
                        Msg::Start {
                            session,
                            tool,
                            path,
                            events_log,
                            message,
                        } => {
                            logs.insert(session, RunLogs::new(&tool, path, max_bytes));
                            append_event(&events_log, "info", &tool, &message, source);
                        }
                        Msg::Output(session, data) => {
                            if let Some(log) = logs.get_mut(&session) {
                                log.record_output(&data);
                            }
                        }
                        Msg::Input(session, text) => {
                            if let Some(log) = logs.get_mut(&session) {
                                log.record_input(&text);
                            }
                        }
                        Msg::Finish {
                            session,
                            events_log,
                            kind,
                            tool,
                            message,
                        } => {
                            if let Some(mut log) = logs.remove(&session) {
                                log.close();
                            }
                            append_event(&events_log, kind, &tool, &message, source);
                        }
                    }
                }
            })
            .expect("spawn AI log writer");
        tx
    })
}

struct Context {
    tool: String,
    command: Option<String>,
}

/// One session's AI logging state.
pub struct AiSessionLog {
    session: u64,
    logs_dir: PathBuf,
    events_log: PathBuf,
    context: Option<Context>,
    filter: ExitMarkerFilter,
    /// The PTY log of the current or last AI run (`lastPTYLogPath`, for MCP).
    pub last_log_path: Option<PathBuf>,
}

impl AiSessionLog {
    pub fn new(session: u64, root: &DataRoot) -> Self {
        Self {
            session,
            logs_dir: root.ai_logs_dir(),
            events_log: root.ai_events_log(),
            context: None,
            filter: ExitMarkerFilter::new(),
            last_log_path: None,
        }
    }

    /// An AI tool was detected (`startAILoggingIfNeeded`). `command` is the
    /// typed line; secrets are redacted before it is written anywhere.
    pub fn start(&mut self, tool: &str, command: Option<&str>) {
        if self.context.is_some() {
            return;
        }
        let path = session_log_path(&self.logs_dir, tool, self.session);
        let command =
            command.and_then(|c| sensitive_input::sanitized_command_for_persistence(c, false));
        let message = started_message(command.as_deref());
        self.last_log_path = Some(path.clone());
        self.filter.clear();
        self.context = Some(Context {
            tool: tool.to_string(),
            command,
        });
        let _ = writer().send(Msg::Start {
            session: self.session,
            tool: tool.to_string(),
            path,
            events_log: self.events_log.clone(),
            message,
        });
    }

    /// PTY output. Returns the exit code of an AI exit marker, when one
    /// arrived (the caller then finishes the run).
    pub fn output(&mut self, data: &[u8]) -> Option<i32> {
        if self.context.is_none() && self.filter.is_empty() {
            return None;
        }
        let (loggable, code) = self.filter.feed(data);
        if !loggable.is_empty() && self.context.is_some() {
            let _ = writer().send(Msg::Output(self.session, loggable));
        }
        code
    }

    /// Typed text (`handleInput`): logged unless it looks secret.
    pub fn input(&mut self, text: &str, echo_disabled: bool) {
        if self.context.is_none() || !sensitive_input::should_persist_input(text, echo_disabled) {
            return;
        }
        let _ = writer().send(Msg::Input(self.session, text.to_string()));
    }

    /// The AI run ended (`finishAILogging`): prompt back, exit marker or
    /// shell exit.
    pub fn finish(&mut self, exit_code: Option<i32>) {
        self.filter.clear();
        let Some(context) = self.context.take() else {
            return;
        };
        let (kind, message) = finished_event(exit_code, context.command.as_deref());
        let _ = writer().send(Msg::Finish {
            session: self.session,
            events_log: self.events_log.clone(),
            kind,
            tool: context.tool,
            message,
        });
    }
}

impl Drop for AiSessionLog {
    fn drop(&mut self) {
        self.finish(None);
    }
}

fn session_log_path(logs: &std::path::Path, tool: &str, session: u64) -> PathBuf {
    logs.join(format!(
        "{}-{}-{}-pty.log",
        tool_slug(tool),
        session,
        uuid::Uuid::new_v4()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn attributed_logs_remain_separate_and_legacy_history_still_receives_output() {
        let root =
            std::env::temp_dir().join(format!("chau7-next-log-copies-{}", uuid::Uuid::new_v4()));
        let first_path = session_log_path(&root, "Claude", 1);
        let second_path = session_log_path(&root, "Claude", 2);
        let mut first = RunLogs::new("Claude", first_path.clone(), 1024 * 1024);
        let mut second = RunLogs::new("Claude", second_path.clone(), 1024 * 1024);
        first.record_output(b"first output\n");
        second.record_output(b"second output\n");
        first.record_input("first prompt");
        second.record_input("second prompt\n");
        first.record_input("\n");
        first.close();
        second.close();
        let a = std::fs::read_to_string(&first_path).unwrap();
        let b = std::fs::read_to_string(&second_path).unwrap();
        assert!(a.contains("first output") && a.contains("first prompt"));
        assert!(!a.contains("second"));
        assert!(b.contains("second output") && b.contains("second prompt"));
        assert!(!b.contains("first"));
        let aggregate = std::fs::read_to_string(pty_log_path(&root, "Claude")).unwrap();
        assert!(aggregate.contains("first output") && aggregate.contains("second output"));
        assert!(!aggregate.contains("first promptsecond prompt"));
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn simultaneous_and_restarted_runs_have_distinct_log_files() {
        let root = std::path::Path::new("/isolated-test-logs");
        let first = session_log_path(root, "Claude Code", 1);
        let second = session_log_path(root, "Claude Code", 2);
        let restarted = session_log_path(root, "Claude Code", 1);
        assert_ne!(first, second);
        assert_ne!(first, restarted);
        assert_eq!(first.parent(), Some(root));
        assert!(
            first
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with("claude-code-1-")
        );
        assert!(
            first
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .ends_with("-pty.log")
        );
    }
}
