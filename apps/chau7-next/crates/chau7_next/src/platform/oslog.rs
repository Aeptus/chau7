//! The macOS unified log (`os.log`), so category logs show in Console.app
//! under subsystem `com.chau7.next` with the category name in lowercase
//! (`LogEnhanced.logToOSLog`).
//!
//! `os_log_with_type` is a C macro, so a tiny C shim (`oslog_shim.c`, built
//! by `build.rs` on macOS only) wraps it. Other OSes have no unified log: the
//! call does nothing, the file log already has the line.

/// Level of a unified log message (`OSLogType`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OsLogLevel {
    /// TRACE lines.
    Debug,
    /// INFO and DEBUG lines.
    Info,
    /// WARN lines.
    Default,
    /// ERROR lines.
    Error,
}

/// Map a log level tag to the unified log type (`ERROR` error, `WARN`
/// default, `TRACE` debug, everything else info).
pub fn level_for_tag(tag: &str) -> OsLogLevel {
    match tag {
        "ERROR" => OsLogLevel::Error,
        "WARN" => OsLogLevel::Default,
        "TRACE" => OsLogLevel::Debug,
        _ => OsLogLevel::Info,
    }
}

/// Write one message to the unified log. `category` is already lowercase.
pub fn log(category: &str, level: OsLogLevel, message: &str) {
    imp::log(category, level, message)
}

/// Install real feature intervals in the macOS Instruments performance category.
/// Other platforms keep the numeric profiler without pretending to emit os_signpost.
pub fn install_feature_intervals() {
    #[cfg(target_os = "macos")]
    let _ = chau7_next_core::feature_profiler::install_interval_observer(
        chau7_next_core::feature_profiler::IntervalObserver {
            begin: imp::begin_interval,
            end: imp::end_interval,
        },
    );
}

#[cfg(target_os = "macos")]
mod imp {
    use std::collections::HashMap;
    use std::ffi::{CString, c_char, c_int, c_void};
    use std::sync::{Mutex, OnceLock};

    use super::OsLogLevel;

    unsafe extern "C" {
        fn chau7_os_log_create(subsystem: *const c_char, category: *const c_char) -> *mut c_void;
        fn chau7_os_log(log: *mut c_void, level: c_int, message: *const c_char);
        fn chau7_signpost_begin(log: *mut c_void, feature: u32) -> u64;
        fn chau7_signpost_end(log: *mut c_void, feature: u32, token: u64);
    }

    /// One `os_log_t` per category, created on first use (they live for the
    /// life of the process, like Swift's `osLogs` cache).
    static HANDLES: Mutex<Option<HashMap<String, usize>>> = Mutex::new(None);

    fn handle(category: &str) -> Option<*mut c_void> {
        let mut guard = HANDLES.lock().ok()?;
        let map = guard.get_or_insert_with(HashMap::new);
        if let Some(h) = map.get(category) {
            return Some(*h as *mut c_void);
        }
        let subsystem = CString::new(chau7_next_core::logging::OS_LOG_SUBSYSTEM).ok()?;
        let name = CString::new(category).ok()?;
        // SAFETY: both arguments are valid NUL-terminated strings.
        let created = unsafe { chau7_os_log_create(subsystem.as_ptr(), name.as_ptr()) };
        if created.is_null() {
            return None;
        }
        map.insert(category.to_string(), created as usize);
        Some(created)
    }

    fn performance_handle() -> *mut c_void {
        static HANDLE: OnceLock<usize> = OnceLock::new();
        *HANDLE.get_or_init(|| handle("performance").map_or(0, |log| log as usize)) as *mut c_void
    }
    pub fn begin_interval(feature: chau7_next_core::feature_profiler::Feature) -> u64 {
        // SAFETY: the cached handle is a lifetime os_log_t; the C shim checks
        // availability and uses a static name selected by the enum key.
        unsafe { chau7_signpost_begin(performance_handle(), feature as u32) }
    }
    pub fn end_interval(feature: chau7_next_core::feature_profiler::Feature, token: u64) {
        // SAFETY: token was generated for this same log by begin_interval.
        unsafe { chau7_signpost_end(performance_handle(), feature as u32, token) };
    }

    pub fn log(category: &str, level: OsLogLevel, message: &str) {
        let Some(log) = handle(category) else {
            return;
        };
        // A NUL inside the message would cut it short: drop those bytes.
        let Ok(text) = CString::new(message.replace('\0', "")) else {
            return;
        };
        let level = match level {
            OsLogLevel::Debug => 0,
            OsLogLevel::Info => 1,
            OsLogLevel::Default => 2,
            OsLogLevel::Error => 3,
        };
        // SAFETY: `log` came from `os_log_create` and `text` is NUL terminated.
        unsafe { chau7_os_log(log, level, text.as_ptr()) };
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::OsLogLevel;

    pub fn log(_category: &str, _level: OsLogLevel, _message: &str) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels_follow_swift() {
        assert_eq!(level_for_tag("ERROR"), OsLogLevel::Error);
        assert_eq!(level_for_tag("WARN"), OsLogLevel::Default);
        assert_eq!(level_for_tag("TRACE"), OsLogLevel::Debug);
        assert_eq!(level_for_tag("INFO"), OsLogLevel::Info);
        assert_eq!(level_for_tag("DEBUG"), OsLogLevel::Info);
    }

    #[test]
    fn logging_never_panics() {
        log("app", OsLogLevel::Info, "test line");
    }
}
