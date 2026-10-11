//! What a terminal session reports beyond its own state
//! (`ShellEventDetector`, `DevServerMonitor` and the AI PTY log of
//! `TerminalSessionModel`): shell events for the notification pipeline,
//! the dev server running in the tab, and AI run logging.

use chau7_next_core::ai::event::{AiEvent, AiEventSource};
use chau7_next_core::command_detection::detect_dev_server;
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::iso8601;
use chau7_next_core::monitoring::dev_server::{
    CheckRequest, DevServerInfo, DevServerTracker, OUTPUT_SCAN_BYTES,
};
use chau7_next_core::monitoring::shell_events::{ShellEvent, ShellEventConfig, ShellEventDetector};

use crate::ai::session_log::AiSessionLog;

/// Monitors of one session.
pub struct SessionMonitor {
    pub shell_events: ShellEventDetector,
    pub dev_server: DevServerTracker,
    pub ai_log: AiSessionLog,
}

impl SessionMonitor {
    pub fn new(session: u64, root: &DataRoot, config: ShellEventConfig) -> Self {
        Self {
            shell_events: ShellEventDetector::new(config),
            dev_server: DevServerTracker::new(),
            ai_log: AiSessionLog::new(session, root),
        }
    }

    /// The dev server shown in the tab.
    pub fn dev_server(&self) -> Option<&DevServerInfo> {
        self.dev_server.current()
    }

    /// A typed command line: hint for dev server detection
    /// (`updateActiveAppName`).
    pub fn command_typed(&mut self, command: &str) -> Option<CheckRequest> {
        let name = detect_dev_server(command)?;
        log::trace!("Dev server command detected: {name}");
        self.dev_server.set_command_hint(Some(name))
    }

    /// PTY output: shell patterns, dev server banners (first 2 KB) and the
    /// AI log. Returns (events, dev server changed, check to schedule, AI
    /// exit code).
    pub fn output(
        &mut self,
        data: &[u8],
        now: f64,
    ) -> (Vec<ShellEvent>, bool, Option<CheckRequest>, Option<i32>) {
        let exit = self.ai_log.output(data);
        let text = String::from_utf8_lossy(data);
        let events = self.shell_events.process_output(&text, now);
        let (changed, check) = if self.dev_server.current().is_none() {
            let head = &data[..data.len().min(OUTPUT_SCAN_BYTES)];
            match std::str::from_utf8(head) {
                Ok(text) => self.dev_server.check_output(text),
                // A multi-byte character cut at 2 KB: use the valid part.
                Err(e) => self
                    .dev_server
                    .check_output(std::str::from_utf8(&head[..e.valid_up_to()]).unwrap_or("")),
            }
        } else {
            (false, None)
        };
        (events, changed, check, exit)
    }
}

/// A shell event as an AI event (`emitEvent`: source shell, tool Shell).
pub fn shell_ai_event(event: ShellEvent) -> AiEvent {
    let mut ai = AiEvent::new(
        AiEventSource::shell(),
        event.event_type,
        "Shell",
        event.message,
        iso8601::now_iso8601(),
    );
    ai.directory = event.directory;
    ai
}
