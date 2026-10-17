//! Duration and correlation logging (`PerfTracker`, `LogCorrelation` in
//! `LogEnhanced.swift`).

// Tracing helpers for the modules that follow.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::Instant;

use chau7_next_core::logging::{
    CorrelationStack, LogCategory, LogEntry, LogLevel, memory_delta_text, new_correlation_id,
    perf_level,
};
use chrono::Utc;

static CORRELATION: Mutex<Option<CorrelationStack>> = Mutex::new(None);

fn with_stack<T>(f: impl FnOnce(&mut CorrelationStack) -> T) -> T {
    let mut guard = CORRELATION.lock().unwrap_or_else(|e| e.into_inner());
    f(guard.get_or_insert_with(CorrelationStack::default))
}

/// The id of the innermost running [`scoped`] operation.
pub fn current_correlation_id() -> Option<String> {
    with_stack(|s| s.current().map(str::to_string))
}

/// Resident memory of this process in MB (`PerfTracker.currentMemoryMB`).
pub fn current_memory_mb() -> Option<f64> {
    crate::platform::process::own_resident_bytes().map(|b| b as f64 / 1024.0 / 1024.0)
}

/// Run `block` as a named operation: begin and end lines (TRACE) share a
/// correlation id, which every entry logged inside it also gets.
pub fn scoped<T>(operation: &str, block: impl FnOnce() -> T) -> T {
    let id = with_stack(|s| s.begin(operation, new_correlation_id()));
    trace_line(format!("Begin: {operation}"), &id);
    let result = block();
    trace_line(format!("End: {operation}"), &id);
    with_stack(|s| s.end());
    result
}

fn trace_line(message: String, id: &str) {
    let mut entry = LogEntry::new(Utc::now(), LogLevel::Trace, LogCategory::App, message);
    entry.correlation_id = Some(id.to_string());
    super::log_entry(entry);
}

/// Times one operation and logs its duration when it ends: a WARN over
/// 100 ms, else a TRACE line.
pub struct PerfTracker {
    operation: String,
    category: LogCategory,
    correlation_id: Option<String>,
    start: Instant,
    start_memory: Option<f64>,
    metadata: BTreeMap<String, String>,
}

impl PerfTracker {
    pub fn new(operation: &str, category: LogCategory) -> Self {
        Self {
            operation: operation.to_string(),
            category,
            correlation_id: current_correlation_id(),
            start: Instant::now(),
            start_memory: current_memory_mb(),
            metadata: BTreeMap::new(),
        }
    }

    pub fn add(&mut self, key: &str, value: &str) {
        self.metadata.insert(key.to_string(), value.to_string());
    }

    /// Log the result when at least `threshold` seconds passed.
    pub fn end(mut self, threshold: f64) {
        let duration = self.start.elapsed().as_secs_f64();
        if duration < threshold {
            return;
        }
        let end_memory = current_memory_mb();
        if let (Some(start), Some(end)) = (self.start_memory, end_memory)
            && let Some(delta) = memory_delta_text(start, end)
        {
            self.metadata.insert("memDelta".into(), delta);
        }
        let mut entry = LogEntry::new(
            Utc::now(),
            perf_level(duration),
            self.category,
            self.operation,
        );
        entry.correlation_id = self.correlation_id;
        entry.metadata = (!self.metadata.is_empty()).then_some(self.metadata);
        entry.duration = Some(duration);
        entry.memory_mb = end_memory;
        super::log_entry(entry);
    }

    /// `PerfTracker.measure`: time a block under the Perf category.
    pub fn measure<T>(operation: &str, block: impl FnOnce() -> T) -> T {
        let tracker = PerfTracker::new(operation, LogCategory::Performance);
        let result = block();
        tracker.end(0.0);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scoped_sets_and_clears_the_correlation_id() {
        assert_eq!(current_correlation_id(), None);
        let inside = scoped("outer", || {
            let outer = current_correlation_id();
            let inner = scoped("inner", current_correlation_id);
            assert_ne!(outer, inner);
            assert_eq!(current_correlation_id(), outer);
            outer
        });
        assert!(inside.is_some());
        assert_eq!(current_correlation_id(), None);
    }

    #[test]
    fn measure_returns_the_block_value() {
        assert_eq!(PerfTracker::measure("sum", || 2 + 2), 4);
    }
}
