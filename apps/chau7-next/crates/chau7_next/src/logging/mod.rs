//! Logging (`Logging/Log.swift`, `Logging/LogEnhanced.swift`).
//!
//! One rolling log file under the Chau7 Next state folder
//! (`DataRoot::log_file`, `CHAU7_NEXT_LOG_FILE` overrides it), written by a
//! background thread (`writer.rs`). The app logs with the `log` crate:
//!
//! - `log::info!("...")` writes `[Chau7][INFO] 2026-01-15T10:30:45.123Z ...`
//!   (the Chau7 app uses DEBUG by default; TRACE needs `CHAU7_NEXT_TRACE=1` or
//!   `CHAU7_NEXT_VERBOSE=1`). The `chau7_terminal` engine uses WARN by default
//!   to keep per-snapshot diagnostics out of normal logs; TRACE/VERBOSE or
//!   `CHAU7_NEXT_LOG=debug` enables its diagnostics. Other crates are written
//!   from WARN up, with their crate name in front.
//! - [`log_cat!`] writes a category line (`LogCategory`): `2026-01-15T10:30:45.123Z
//!   [WARN][Tabs] message @file.rs:42 module`, mirrored to the macOS unified
//!   log (subsystem `com.chau7.next`, [`crate::platform::oslog`]). Categories can
//!   be switched off with [`set_enabled_categories`]; [`set_structured_output`]
//!   writes JSON lines instead.
//! - [`PerfTracker`] and [`scoped`] log durations and correlated operations.
//!
//! The last lines are also kept in memory ([`recent_lines`]) for the Debug
//! Console. Lines are echoed to stdout when `CHAU7_NEXT_VERBOSE=1`,
//! `CHAU7_NEXT_LOG_STDOUT` is set, or stdout is a terminal.
//!
//! Environment variables use the `CHAU7_NEXT_` prefix (the app removes the
//! `CHAU7_` variables it inherits from the Swift app): `LOG_FILE`,
//! `LOG_MAX_BYTES`, `VERBOSE`, `TRACE`, `PTY_LOG_MAX_BYTES`, `PTY_DUMP`...
//! `CHAU7_NEXT_LOG` names a level for every crate (`debug`, `trace`...).

pub mod ai_pty;
mod perf;
pub(crate) mod writer;

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io::IsTerminal;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock, RwLock};
use std::time::Duration;

use chau7_next_core::data_root::DataRoot;
use chau7_next_core::env_vars::LoggingEnv;
use chau7_next_core::logging::{LogCategory, LogEntry, LogLevel, newest_lines, plain_line};
use chrono::Utc;

#[allow(unused_imports)]
pub use perf::{PerfTracker, current_memory_mb, scoped};

use writer::Writer;

/// Target prefix of category records: `log::info!(target: "chau7::cat::Tabs", ..)`.
pub const CATEGORY_TARGET_PREFIX: &str = "chau7::cat::";

/// Lines kept in memory for the Debug Console.
const FEED_CAPACITY: usize = 2000;

/// Log a category line through the `log` crate:
/// `log_cat!(Tabs, Info, "closed {} tabs", n)`. The category is one of
/// `App Tabs Terminal Render Input Notifications Snippets Network Perf Memory
/// Recovery CTO`; the level one of `Trace Debug Info Warn Error`.
#[allow(unused_macros)]
macro_rules! log_cat {
    ($category:ident, $level:ident, $($arg:tt)+) => {
        log::log!(
            target: concat!("chau7::cat::", stringify!($category)),
            log::Level::$level,
            $($arg)+
        )
    };
}
#[allow(unused_imports)]
pub(crate) use log_cat;

struct State {
    writer: Writer,
    path: PathBuf,
    /// Level for the app's own crates.
    app_level: log::LevelFilter,
    /// Default for the high-volume terminal engine; explicit log settings can
    /// still enable its diagnostic records.
    terminal_engine_level: log::LevelFilter,
    /// Level for every other crate.
    other_level: log::LevelFilter,
    echo: bool,
    #[allow(dead_code)]
    trace: bool,
    structured: AtomicBool,
    categories: RwLock<BTreeSet<LogCategory>>,
    feed: Mutex<VecDeque<String>>,
}

static STATE: OnceLock<State> = OnceLock::new();

/// A variable of the app: `CHAU7_X` is read as `CHAU7_NEXT_X`, then `CHAU7_X`.
pub fn env_var(name: &str) -> Option<String> {
    let next = name.replacen("CHAU7_", "CHAU7_NEXT_", 1);
    std::env::var(next)
        .ok()
        .or_else(|| std::env::var(name).ok())
        .filter(|v| !v.is_empty())
}

/// A developer variable (`EnvVars.get`): its `CHAU7_NEXT_` name, its
/// `CHAU7_` name, then its legacy `AI_*` or `SMART_OVERLAY_*` name.
pub fn env_override(name: &str, legacy: Option<&str>) -> Option<String> {
    chau7_next_core::env_vars::get(&|key| env_var(key), name, legacy)
}

fn logging_env() -> LoggingEnv {
    LoggingEnv::from_lookup(&|name| env_var(name))
}

/// Where the log goes: `CHAU7_LOG_FILE`, else the state folder's log.
pub fn log_file_path(root: &DataRoot) -> PathBuf {
    logging_env()
        .file
        .map(PathBuf::from)
        .unwrap_or_else(|| root.log_file())
}

struct Logger;

static LOGGER: Logger = Logger;

impl Logger {
    fn is_app_target(target: &str) -> bool {
        target.starts_with("chau7")
    }

    fn is_terminal_engine_target(target: &str) -> bool {
        target == "chau7_terminal" || target.starts_with("chau7_terminal::")
    }

    fn terminal_engine_level(forced: Option<log::LevelFilter>, trace: bool) -> log::LevelFilter {
        forced.unwrap_or(if trace {
            log::LevelFilter::Trace
        } else {
            log::LevelFilter::Warn
        })
    }

    fn level_for_target(
        target: &str,
        app_level: log::LevelFilter,
        terminal_engine_level: log::LevelFilter,
        other_level: log::LevelFilter,
    ) -> log::LevelFilter {
        if Self::is_terminal_engine_target(target) {
            terminal_engine_level
        } else if Self::is_app_target(target) {
            app_level
        } else {
            other_level
        }
    }
}

impl log::Log for Logger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        let Some(state) = STATE.get() else {
            return false;
        };
        let limit = Self::level_for_target(
            metadata.target(),
            state.app_level,
            state.terminal_engine_level,
            state.other_level,
        );
        metadata.level() <= limit
    }

    fn log(&self, record: &log::Record) {
        let Some(state) = STATE.get() else {
            return;
        };
        if !self.enabled(record.metadata()) {
            return;
        }
        let target = record.target();
        let message_text = record.args().to_string();
        let level = if is_closed_window_race(target, record.file(), &message_text) {
            LogLevel::Debug
        } else {
            level_of(record.level())
        };
        if let Some(category) = target
            .strip_prefix(CATEGORY_TARGET_PREFIX)
            .and_then(LogCategory::from_label)
        {
            let mut entry = LogEntry::new(Utc::now(), level, category, record.args().to_string());
            entry.file = record.file().map(str::to_string);
            entry.function = record.module_path().map(str::to_string);
            entry.line = record.line();
            emit_entry(state, entry, category);
            return;
        }
        let message = if Self::is_app_target(target) {
            message_text
        } else {
            format!(
                "{}: {message_text}",
                source_label(target, record.file(), record.line())
            )
        };
        let line = plain_line(level, Utc::now(), &message);
        output(state, line);
    }

    fn flush(&self) {
        flush();
    }
}

/// A library record's label: its target, or for GPUI's caller-located
/// errors (whose target is empty outside a `crates/` tree) the source
/// location, so a line never starts with a bare ": ".
fn source_label(target: &str, file: Option<&str>, line: Option<u32>) -> String {
    if !target.is_empty() {
        return target.to_string();
    }
    let Some(file) = file else {
        return "unknown".into();
    };
    let short = file.rsplit_once("vendor/").map_or(file, |(_, rest)| rest);
    match line {
        Some(line) => format!("{short}:{line}"),
        None => short.to_string(),
    }
}

/// GPUI's window event senders report "window not found" when a closed
/// window's last events arrive after it is gone. That is expected on every
/// window close, not an error worth surfacing.
fn is_closed_window_race(target: &str, file: Option<&str>, message: &str) -> bool {
    target.is_empty()
        && message == "window not found"
        && file.is_some_and(|file| file.contains("gpui"))
}

fn level_of(level: log::Level) -> LogLevel {
    match level {
        log::Level::Error => LogLevel::Error,
        log::Level::Warn => LogLevel::Warn,
        log::Level::Info => LogLevel::Info,
        log::Level::Debug => LogLevel::Debug,
        log::Level::Trace => LogLevel::Trace,
    }
}

/// A line to every destination: live feed, stdout, file.
fn output(state: &State, line: String) {
    {
        let mut feed = state.feed.lock().unwrap_or_else(|e| e.into_inner());
        if feed.len() >= FEED_CAPACITY {
            feed.pop_front();
        }
        feed.push_back(line.clone());
    }
    if state.echo {
        println!("{line}");
    }
    state.writer.write(line);
}

fn emit_entry(state: &State, entry: LogEntry, category: LogCategory) {
    if !state
        .categories
        .read()
        .map(|c| c.contains(&category))
        .unwrap_or(true)
    {
        return;
    }
    let line = if state.structured.load(Ordering::Relaxed) {
        entry
            .json_string()
            .unwrap_or_else(|| entry.formatted_text())
    } else {
        entry.formatted_text()
    };
    // Also to the unified log, for Console.app.
    crate::platform::oslog::log(
        &category.os_log_category(),
        crate::platform::oslog::level_for_tag(&entry.level),
        &entry.message,
    );
    output(state, line);
}

/// Log a structured entry (duration, memory, metadata, correlation id).
/// Used by [`PerfTracker`] and [`scoped`].
#[allow(dead_code)]
pub fn log_entry(entry: LogEntry) {
    let Some(state) = STATE.get() else {
        return;
    };
    let Some(category) = LogCategory::from_label(&entry.category) else {
        return;
    };
    // TRACE lines only when tracing is on.
    if entry.level == "TRACE" && !state.trace {
        return;
    }
    emit_entry(state, entry, category);
}

/// Whether TRACE lines are written (`Log.isTraceEnabled`).
#[allow(dead_code)]
pub fn trace_enabled() -> bool {
    STATE.get().is_some_and(|s| s.trace)
}

/// Start logging: install the logger, open the file and fill the live feed
/// with the end of the existing log.
pub fn init(root: &DataRoot) {
    let env = logging_env();
    // `CHAU7_NEXT_LOG` names a level for every crate.
    let forced: Option<log::LevelFilter> = env_var("CHAU7_LOG").and_then(|l| l.parse().ok());
    let app_level = forced.unwrap_or(if env.trace {
        log::LevelFilter::Trace
    } else {
        log::LevelFilter::Debug
    });
    let terminal_engine_level = Logger::terminal_engine_level(forced, env.trace);
    let other_level = forced.unwrap_or(log::LevelFilter::Warn);
    let path = log_file_path(root);
    let echo = env.verbose
        || std::env::var_os("CHAU7_NEXT_LOG_STDOUT").is_some()
        || std::io::stdout().is_terminal();

    // The end of the existing log first, so the console shows earlier runs.
    let mut feed = VecDeque::new();
    if let Ok(text) = std::fs::read_to_string(&path) {
        let mut lines = newest_lines(text.trim_end_matches('\n'), 200);
        lines.reverse();
        feed.extend(lines);
    }
    let state = State {
        writer: Writer::spawn(path.clone(), env.max_bytes),
        path,
        app_level,
        terminal_engine_level,
        other_level,
        echo,
        trace: env.trace,
        structured: AtomicBool::new(false),
        categories: RwLock::new(LogCategory::ALL.into_iter().collect()),
        feed: Mutex::new(feed),
    };
    if STATE.set(state).is_err() {
        return;
    }
    if log::set_logger(&LOGGER).is_ok() {
        log::set_max_level(app_level.max(terminal_engine_level).max(other_level));
    }
}

/// Path of the log file, once logging is on.
pub fn file_path() -> Option<PathBuf> {
    STATE.get().map(|s| s.path.clone())
}

/// The newest `count` lines kept in memory, oldest first.
pub fn recent_lines(count: usize) -> Vec<String> {
    let Some(state) = STATE.get() else {
        return Vec::new();
    };
    let feed = state.feed.lock().unwrap_or_else(|e| e.into_inner());
    let skip = feed.len().saturating_sub(count);
    feed.iter().skip(skip).cloned().collect()
}

/// Wait until the queued lines are written (before quitting).
pub fn flush() {
    if let Some(state) = STATE.get() {
        state.writer.flush(Duration::from_secs(2));
    }
}

/// Which categories are written (`setEnabledCategories`).
#[allow(dead_code)]
pub fn set_enabled_categories(categories: BTreeSet<LogCategory>) {
    if let Some(state) = STATE.get()
        && let Ok(mut current) = state.categories.write()
    {
        *current = categories;
    }
}

#[allow(dead_code)]
pub fn enabled_categories() -> BTreeSet<LogCategory> {
    STATE
        .get()
        .and_then(|s| s.categories.read().ok().map(|c| c.clone()))
        .unwrap_or_else(|| LogCategory::ALL.into_iter().collect())
}

/// JSON lines instead of text for category entries (`enableStructuredOutput`).
#[allow(dead_code)]
pub fn set_structured_output(enabled: bool) {
    if let Some(state) = STATE.get() {
        state.structured.store(enabled, Ordering::Relaxed);
    }
}

/// Key-value pairs as the metadata of an entry.
#[allow(dead_code)]
pub fn metadata(pairs: &[(&str, &str)]) -> Option<BTreeMap<String, String>> {
    if pairs.is_empty() {
        None
    } else {
        Some(
            pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn library_records_without_a_target_are_labelled_by_location() {
        let file = "/Users/me/chau7/apps/chau7-next/vendor/gpui-pre/src/window.rs";
        assert_eq!(
            source_label("", Some(file), Some(1720)),
            "gpui-pre/src/window.rs:1720"
        );
        assert_eq!(
            source_label("hyper::client", Some(file), Some(1)),
            "hyper::client"
        );
        assert_eq!(source_label("", None, None), "unknown");
    }

    #[test]
    fn only_gpuis_closed_window_race_is_demoted() {
        let gpui = Some("/x/vendor/gpui-pre/src/window.rs");
        assert!(is_closed_window_race("", gpui, "window not found"));
        assert!(!is_closed_window_race("", gpui, "failed to render"));
        assert!(!is_closed_window_race(
            "chau7_next::workspace",
            gpui,
            "window not found"
        ));
        assert!(!is_closed_window_race(
            "",
            Some("/x/other/src/lib.rs"),
            "window not found"
        ));
    }

    #[test]
    fn env_prefix_is_next() {
        // Unset names give nothing.
        assert_eq!(env_var("CHAU7_SURELY_NOT_SET_FOR_TESTS"), None);
    }

    #[test]
    fn metadata_helper() {
        assert_eq!(metadata(&[]), None);
        let meta = metadata(&[("a", "1")]).unwrap();
        assert_eq!(meta["a"], "1");
    }

    #[test]
    fn level_mapping() {
        assert_eq!(level_of(log::Level::Warn), LogLevel::Warn);
        assert_eq!(level_of(log::Level::Trace), LogLevel::Trace);
    }

    #[test]
    fn app_targets() {
        assert!(Logger::is_app_target("chau7_next::tabs"));
        assert!(Logger::is_app_target("chau7::cat::Tabs"));
        assert!(!Logger::is_app_target("gpui::window"));
    }

    #[test]
    fn terminal_engine_uses_quiet_default_and_explicit_diagnostic_levels() {
        use log::LevelFilter;

        assert!(Logger::is_terminal_engine_target(
            "chau7_terminal::terminal"
        ));
        assert_eq!(
            Logger::level_for_target(
                "chau7_terminal::terminal",
                LevelFilter::Debug,
                Logger::terminal_engine_level(None, false),
                LevelFilter::Warn,
            ),
            LevelFilter::Warn,
        );
        assert_eq!(
            Logger::level_for_target(
                "chau7_terminal::terminal",
                LevelFilter::Debug,
                Logger::terminal_engine_level(None, true),
                LevelFilter::Warn,
            ),
            LevelFilter::Trace,
        );
        assert_eq!(
            Logger::terminal_engine_level(Some(LevelFilter::Debug), true),
            LevelFilter::Debug,
        );
        assert_eq!(
            Logger::level_for_target(
                "chau7_next::terminal",
                LevelFilter::Debug,
                LevelFilter::Warn,
                LevelFilter::Warn,
            ),
            LevelFilter::Debug,
        );
    }
}
