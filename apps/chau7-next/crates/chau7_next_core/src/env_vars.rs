//! Developer environment variables that override log and monitor settings
//! (`EnvVars` in `Utilities.swift`). Every variable has a `CHAU7_` name and,
//! for some, a legacy `AI_*` or `SMART_OVERLAY_*` name that still works.
//! Features read their variable through [`get`]; the lookup function is a
//! parameter so tests need no real environment.

// Logging
pub const LOG_FILE: &str = "CHAU7_LOG_FILE";
pub const LOG_MAX_BYTES: &str = "CHAU7_LOG_MAX_BYTES";
pub const VERBOSE: &str = "CHAU7_VERBOSE";
pub const TRACE: &str = "CHAU7_TRACE";
// Event monitoring
pub const EVENTS_LOG: &str = "CHAU7_EVENTS_LOG";
// History monitoring
pub const CODEX_HISTORY_LOG: &str = "CHAU7_CODEX_HISTORY_LOG";
pub const CLAUDE_HISTORY_LOG: &str = "CHAU7_CLAUDE_HISTORY_LOG";
pub const IDLE_STALE_SECONDS: &str = "CHAU7_IDLE_STALE_SECONDS";
// Terminal monitoring
pub const CODEX_TERMINAL_LOG: &str = "CHAU7_CODEX_TERMINAL_LOG";
pub const CLAUDE_TERMINAL_LOG: &str = "CHAU7_CLAUDE_TERMINAL_LOG";
pub const TERMINAL_NORMALIZE: &str = "CHAU7_TERMINAL_NORMALIZE";
pub const TERMINAL_ANSI: &str = "CHAU7_TERMINAL_ANSI";
pub const IDLE_SECONDS: &str = "CHAU7_IDLE_SECONDS";
pub const COMMAND_FALLBACK_SECONDS: &str = "CHAU7_COMMAND_FALLBACK_SECONDS";
pub const CLEAR_ON_LAUNCH: &str = "CHAU7_CLEAR_ON_LAUNCH";
// Debug output capture
pub const PTY_DUMP_MAX_BYTES: &str = "CHAU7_PTY_DUMP_MAX_BYTES";
pub const PTY_LOG_MAX_BYTES: &str = "CHAU7_PTY_LOG_MAX_BYTES";
pub const REMOTE_OUTPUT_BATCH: &str = "CHAU7_REMOTE_OUTPUT_BATCH";

// Legacy names
pub const LEGACY_EVENTS_LOG: &str = "AI_EVENTS_LOG";
pub const LEGACY_CODEX_HISTORY_LOG: &str = "AI_CODEX_HISTORY_LOG";
pub const LEGACY_CLAUDE_HISTORY_LOG: &str = "AI_CLAUDE_HISTORY_LOG";
pub const LEGACY_STALE_SECONDS: &str = "AI_IDLE_STALE_SECONDS";
pub const LEGACY_CODEX_TERMINAL_LOG: &str = "AI_CODEX_TTY_LOG";
pub const LEGACY_CLAUDE_TERMINAL_LOG: &str = "AI_CLAUDE_TTY_LOG";
pub const LEGACY_TERMINAL_NORMALIZE: &str = "AI_TTY_NORMALIZE";
pub const LEGACY_TERMINAL_ANSI: &str = "AI_TTY_ANSI";
pub const LEGACY_VERBOSE: &str = "AI_NOTIFIER_VERBOSE";
pub const LEGACY_TRACE: &str = "AI_NOTIFIER_TRACE";
pub const LEGACY_LOG_FILE: &str = "AI_NOTIFIER_LOG_FILE";
pub const LEGACY_IDLE_SECONDS: &str = "SMART_OVERLAY_IDLE_SECONDS";
pub const LEGACY_COMMAND_FALLBACK_SECONDS: &str = "SMART_OVERLAY_COMMAND_FALLBACK_SECONDS";
pub const LEGACY_CLEAR_ON_LAUNCH: &str = "SMART_OVERLAY_CLEAR_ON_LAUNCH";

/// A variable's value: the new name first, then the legacy one. Empty values
/// count as unset (`EnvVars.get`).
pub fn get(
    lookup: &dyn Fn(&str) -> Option<String>,
    new_name: &str,
    legacy: Option<&str>,
) -> Option<String> {
    lookup(new_name)
        .filter(|v| !v.is_empty())
        .or_else(|| legacy.and_then(lookup).filter(|v| !v.is_empty()))
}

/// The logging variables.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoggingEnv {
    /// `CHAU7_LOG_FILE`: log here instead of the default file.
    pub file: Option<String>,
    /// `CHAU7_LOG_MAX_BYTES`: size after which the log starts over.
    pub max_bytes: u64,
    /// `CHAU7_VERBOSE=1`.
    pub verbose: bool,
    /// `CHAU7_TRACE=1`, or verbose (which includes trace output).
    pub trace: bool,
}

/// Default size limit of the log file.
pub const DEFAULT_LOG_MAX_BYTES: u64 = 10 * 1024 * 1024;

impl LoggingEnv {
    pub fn from_lookup(lookup: &dyn Fn(&str) -> Option<String>) -> Self {
        let verbose = get(lookup, VERBOSE, Some(LEGACY_VERBOSE)).as_deref() == Some("1");
        let trace = get(lookup, TRACE, Some(LEGACY_TRACE)).as_deref() == Some("1") || verbose;
        Self {
            file: get(lookup, LOG_FILE, Some(LEGACY_LOG_FILE)),
            max_bytes: get(lookup, LOG_MAX_BYTES, None)
                .and_then(|v| v.parse::<u64>().ok())
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_LOG_MAX_BYTES),
            verbose,
            trace,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |key| map.get(key).cloned()
    }

    #[test]
    fn new_name_wins_over_legacy_and_empty_is_unset() {
        let lookup = env(&[(EVENTS_LOG, "/new"), (LEGACY_EVENTS_LOG, "/old")]);
        assert_eq!(
            get(&lookup, EVENTS_LOG, Some(LEGACY_EVENTS_LOG)).as_deref(),
            Some("/new")
        );
        let lookup = env(&[(EVENTS_LOG, ""), (LEGACY_EVENTS_LOG, "/old")]);
        assert_eq!(
            get(&lookup, EVENTS_LOG, Some(LEGACY_EVENTS_LOG)).as_deref(),
            Some("/old")
        );
        assert_eq!(get(&env(&[]), EVENTS_LOG, None), None);
    }

    #[test]
    fn logging_variables() {
        let none = LoggingEnv::from_lookup(&env(&[]));
        assert_eq!(none.max_bytes, DEFAULT_LOG_MAX_BYTES);
        assert!(!none.verbose && !none.trace && none.file.is_none());

        let verbose = LoggingEnv::from_lookup(&env(&[(LEGACY_VERBOSE, "1")]));
        assert!(verbose.verbose && verbose.trace);

        let custom = LoggingEnv::from_lookup(&env(&[
            (LOG_FILE, "/tmp/x.log"),
            (LOG_MAX_BYTES, "2048"),
            (TRACE, "1"),
        ]));
        assert_eq!(custom.file.as_deref(), Some("/tmp/x.log"));
        assert_eq!(custom.max_bytes, 2048);
        assert!(custom.trace && !custom.verbose);

        // Not a positive number: the default.
        let bad = LoggingEnv::from_lookup(&env(&[(LOG_MAX_BYTES, "0")]));
        assert_eq!(bad.max_bytes, DEFAULT_LOG_MAX_BYTES);
    }
}
