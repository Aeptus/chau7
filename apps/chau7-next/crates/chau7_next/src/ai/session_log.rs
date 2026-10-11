//! AI PTY log of one terminal session (`startAILoggingIfNeeded`,
//! `finishAILogging`, `processAILogOutput` in
//! `TerminalSessionModel+ShellIntegration.swift`).
//!
//! While an AI tool runs, typed lines (not sensitive ones) and all output go
//! to `<ai logs>/<tool>-pty.log`, and Started / Finished / Failed lines to
//! the AI events log, both in Chau7 Next's data root. Files are written by
//! one writer thread, in order, so the terminal never waits on the disk.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::sync::mpsc::{Sender, channel};

use chau7_next_core::ai::event::AiEventSource;
use chau7_next_core::ai::pty_log::{
    AiLogSession, ExitMarkerFilter, append_event, finished_event, max_bytes_from_env, pty_log_path,
    started_message,
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

fn writer() -> &'static Sender<Msg> {
    static WRITER: OnceLock<Sender<Msg>> = OnceLock::new();
    WRITER.get_or_init(|| {
        let (tx, rx) = channel::<Msg>();
        let max_bytes = max_bytes_from_env(|k| std::env::var(k).ok());
        std::thread::Builder::new()
            .name("chau7-next-ai-log".into())
            .spawn(move || {
                let source = AiEventSource::TERMINAL_SESSION;
                let mut logs: HashMap<u64, AiLogSession> = HashMap::new();
                while let Ok(msg) = rx.recv() {
                    match msg {
                        Msg::Start {
                            session,
                            tool,
                            path,
                            events_log,
                            message,
                        } => {
                            logs.insert(session, AiLogSession::new(&tool, path, max_bytes));
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
        let path = pty_log_path(&self.logs_dir, tool);
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
