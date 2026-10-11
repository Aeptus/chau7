//! Telemetry models and transcript parsers.
//!
//! Ports of `apps/chau7-macos/Sources/Chau7Core/Telemetry/*.swift`.

pub mod claude_transcript;
pub mod codex_rollout;
pub mod date_codec;
pub mod evidence;
pub mod metrics_sanitizer;
pub mod providers;
pub mod recorder;
pub mod remote_client_event;
pub mod run;
pub mod run_content;
pub mod store;
pub mod token_metrics;
mod transcript_util;
pub mod turn;

pub mod jsonl_tail;
pub mod latency;
pub mod pricing;
pub mod provider_health;
pub mod query_projection;
pub mod quota;
pub mod token_rate;

pub mod retention;
