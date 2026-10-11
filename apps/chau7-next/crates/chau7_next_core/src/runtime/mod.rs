//! Agent runtime models and pure logic.
//!
//! Ports of `apps/chau7-macos/Sources/Chau7Core/Runtime/*.swift`, plus the
//! app-independent parts of `Sources/Chau7/Runtime/` (backends, sessions,
//! the session registry, the transcript reader).

pub mod agent_backend;
pub mod backends;
pub mod event_journal;
pub mod exit_classifier;
pub mod manager;
pub mod runtime_event;
pub mod session;
pub mod session_state;
pub mod transcript_reader;
pub mod turn_stats;

pub mod code_review;
pub mod delegated_task;
pub mod structured_result;

pub mod launch_readiness;
