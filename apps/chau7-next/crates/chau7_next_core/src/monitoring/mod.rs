//! Monitoring logic without UI or timers: Claude Code hook events and
//! sessions, AI history idle detection, Codex session lookup, shell events,
//! dev servers, cross-tab file conflicts, git helpers and a read-only file
//! tailer. Ports `apps/chau7-macos/Sources/Chau7/Monitoring`.

pub mod claude_code;
pub mod codex_feedback;
pub mod codex_sessions;
pub mod conflicts;
pub mod dev_server;
pub mod git;
pub mod process_tree;
pub mod shell_events;
pub mod tailer;
