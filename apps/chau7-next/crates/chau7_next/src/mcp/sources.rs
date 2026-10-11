//! Data the MCP tools read from modules that are not ported yet. The
//! Telemetry port (`TelemetryStore`, `TelemetryRecorder`) and the History
//! port (`PersistentHistoryStore`, `RepoStatsProvider`) register their
//! stores here with [`set_telemetry`] and [`set_history`]; until then the
//! tools answer from empty stores (no runs, no sessions, no frequent
//! commands, zero stats), which is what Swift answers on a fresh install.
//!
//! Implementations are called from MCP client threads, never the main
//! thread.

use std::sync::{Arc, RwLock};

use chau7_next_core::history_record::FrequentCommand;
use chau7_next_core::telemetry::run::{TelemetryRun, TelemetryRunFilter};
use chau7_next_core::telemetry::turn::{TelemetryToolCall, TelemetryTurn};
use serde_json::{Map, Value};

/// `TelemetryStore` and `TelemetryRecorder` as the MCP tools use them.
pub trait TelemetrySource: Send + Sync {
    /// A stored run (`TelemetryStore.getRun`).
    fn run(&self, run_id: &str) -> Option<TelemetryRun>;
    /// Stored runs matching a filter, newest first (`listRuns(filter:)`).
    fn runs(&self, filter: &TelemetryRunFilter) -> Vec<TelemetryRun>;
    fn tool_calls(&self, run_id: &str) -> Vec<TelemetryToolCall>;
    fn turns(&self, run_id: &str) -> Vec<TelemetryTurn>;
    fn set_tags(&self, run_id: &str, tags: &[String]);
    fn latest_run_for_repo(&self, repo_path: &str, provider: Option<&str>) -> Option<TelemetryRun>;
    /// Session rows (`listSessions(repoPath:)`): objects with at least
    /// `session_id`.
    fn sessions(&self, repo_path: Option<&str>) -> Vec<Map<String, Value>>;
    /// Runs in progress (`TelemetryRecorder.allActiveRuns`).
    fn active_runs(&self) -> Vec<TelemetryRun>;
    /// The run in progress in a terminal session (`activeRunForTab`), keyed
    /// by the tab UUID.
    fn active_run_for_tab(&self, tab_uuid: &str) -> Option<TelemetryRun>;
}

/// Aggregated repository numbers (`RepoStatsProvider.stats(for:)`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RepoStats {
    pub total_commands: i64,
    pub successful_commands: i64,
    pub failed_commands: i64,
    pub success_rate: f64,
    pub average_command_duration: f64,
    pub total_runs: i64,
    pub total_tokens: i64,
    pub total_cost: f64,
    pub total_turns: i64,
    pub providers: Vec<String>,
    /// (tool, count), most used first.
    pub top_tools: Vec<(String, i64)>,
    /// ISO 8601.
    pub last_command_at: Option<String>,
    pub last_run_at: Option<String>,
}

/// `PersistentHistoryStore` and `RepoStatsProvider` as the MCP tools use them.
pub trait HistorySource: Send + Sync {
    /// Commands run in a repository, by frecency (`frequentCommandsForRepo`).
    fn frequent_commands(&self, repo_root: &str, limit: usize) -> Vec<FrequentCommand>;
    fn repo_stats(&self, repo_root: &str) -> RepoStats;
}

struct Empty;

impl TelemetrySource for Empty {
    fn run(&self, _: &str) -> Option<TelemetryRun> {
        None
    }
    fn runs(&self, _: &TelemetryRunFilter) -> Vec<TelemetryRun> {
        Vec::new()
    }
    fn tool_calls(&self, _: &str) -> Vec<TelemetryToolCall> {
        Vec::new()
    }
    fn turns(&self, _: &str) -> Vec<TelemetryTurn> {
        Vec::new()
    }
    fn set_tags(&self, _: &str, _: &[String]) {}
    fn latest_run_for_repo(&self, _: &str, _: Option<&str>) -> Option<TelemetryRun> {
        None
    }
    fn sessions(&self, _: Option<&str>) -> Vec<Map<String, Value>> {
        Vec::new()
    }
    fn active_runs(&self) -> Vec<TelemetryRun> {
        Vec::new()
    }
    fn active_run_for_tab(&self, _: &str) -> Option<TelemetryRun> {
        None
    }
}

impl HistorySource for Empty {
    fn frequent_commands(&self, _: &str, _: usize) -> Vec<FrequentCommand> {
        Vec::new()
    }
    fn repo_stats(&self, _: &str) -> RepoStats {
        RepoStats::default()
    }
}

static TELEMETRY: RwLock<Option<Arc<dyn TelemetrySource>>> = RwLock::new(None);
static HISTORY: RwLock<Option<Arc<dyn HistorySource>>> = RwLock::new(None);

/// Plug in the telemetry store (Telemetry port).
#[allow(dead_code)]
pub fn set_telemetry(source: Arc<dyn TelemetrySource>) {
    *TELEMETRY.write().unwrap_or_else(|e| e.into_inner()) = Some(source);
}

/// Plug in the command history store (History port).
pub fn set_history(source: Arc<dyn HistorySource>) {
    *HISTORY.write().unwrap_or_else(|e| e.into_inner()) = Some(source);
}

pub fn telemetry() -> Arc<dyn TelemetrySource> {
    TELEMETRY
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_else(|| Arc::new(Empty))
}

pub fn history() -> Arc<dyn HistorySource> {
    HISTORY
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_else(|| Arc::new(Empty))
}
