//! Debug contexts (`Logging/DebugContext.swift`): a correlated context with a
//! short id for tracing one operation across the app.
//!
//! ```ignore
//! let ctx = DebugContext::new("command-detection", &[("input", &line)]);
//! ctx.log("Starting detection", &[], ContextLevel::Trace);
//! ctx.complete(true, &[("result", "claude")]);
//! ```
//!
//! Active contexts and the last 100 completed ones are kept for bug reports
//! and the state snapshot. Trace lines go through the `log` crate, so they
//! are written only when TRACE is enabled.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Instant;

use chrono::{DateTime, Utc};

/// Level of a line written by [`DebugContext::log`] (`DebugContext.LogLevel`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextLevel {
    Trace,
    Info,
    Warn,
    Error,
}

/// Completed contexts kept (`maxHistory`).
pub const MAX_HISTORY: usize = 100;

/// Characters of a context id (no 0, 1, I, O).
const ID_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

#[derive(Debug, Clone)]
pub struct ContextEvent {
    pub timestamp: DateTime<Utc>,
    pub message: String,
    pub metadata: BTreeMap<String, String>,
}

#[derive(Debug, Default)]
struct Inner {
    metadata: BTreeMap<String, String>,
    events: Vec<ContextEvent>,
}

#[derive(Debug)]
pub struct DebugContext {
    pub id: String,
    pub operation: String,
    pub start_time: DateTime<Utc>,
    started: Instant,
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Registry {
    active: HashMap<String, Arc<DebugContext>>,
    completed: Vec<Arc<DebugContext>>,
}

fn registry() -> MutexGuard<'static, Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY
        .get_or_init(|| Mutex::new(Registry::default()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

/// `[k=v, k2=v2]` in braces, empty for no metadata (`formatMetadata`).
pub fn format_metadata(meta: &BTreeMap<String, String>) -> String {
    if meta.is_empty() {
        return String::new();
    }
    let pairs: Vec<String> = meta.iter().map(|(k, v)| format!("{k}={v}")).collect();
    format!("{{{}}}", pairs.join(", "))
}

fn to_map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

fn generate_id() -> String {
    let bytes = uuid::Uuid::new_v4().into_bytes();
    bytes[..6]
        .iter()
        .map(|b| ID_ALPHABET[(*b as usize) % ID_ALPHABET.len()] as char)
        .collect()
}

impl DebugContext {
    /// Start a context and register it as active.
    pub fn new(operation: &str, metadata: &[(&str, &str)]) -> Arc<DebugContext> {
        let meta = to_map(metadata);
        let ctx = Arc::new(DebugContext {
            id: generate_id(),
            operation: operation.to_string(),
            start_time: Utc::now(),
            started: Instant::now(),
            inner: Mutex::new(Inner {
                metadata: meta.clone(),
                events: Vec::new(),
            }),
        });
        registry().active.insert(ctx.id.clone(), ctx.clone());
        log::trace!("[{}] START {operation} {}", ctx.id, format_metadata(&meta));
        ctx
    }

    fn inner(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// An event inside this context.
    pub fn log(&self, message: &str, metadata: &[(&str, &str)], level: ContextLevel) {
        let meta = to_map(metadata);
        self.inner().events.push(ContextEvent {
            timestamp: Utc::now(),
            message: message.to_string(),
            metadata: meta.clone(),
        });
        let suffix = if meta.is_empty() {
            String::new()
        } else {
            format!(" {}", format_metadata(&meta))
        };
        let line = format!("[{}] {message}{suffix}", self.id);
        match level {
            ContextLevel::Trace => log::trace!("{line}"),
            ContextLevel::Info => log::info!("{line}"),
            ContextLevel::Warn => log::warn!("{line}"),
            ContextLevel::Error => log::error!("{line}"),
        }
    }

    /// End the context; it moves to the history.
    pub fn complete(self: &Arc<Self>, success: bool, metadata: &[(&str, &str)]) {
        let millis = self.started.elapsed().as_millis() as u64;
        let extra = to_map(metadata);
        {
            let mut inner = self.inner();
            inner.metadata.extend(extra.clone());
            inner
                .metadata
                .insert("_duration_ms".to_string(), millis.to_string());
            inner
                .metadata
                .insert("_success".to_string(), success.to_string());
        }
        let status = if success { "SUCCESS" } else { "FAILURE" };
        log::trace!(
            "[{}] END {} {status} ({millis}ms) {}",
            self.id,
            self.operation,
            format_metadata(&extra)
        );
        let mut registry = registry();
        registry.active.remove(&self.id);
        registry.completed.push(self.clone());
        if registry.completed.len() > MAX_HISTORY {
            registry.completed.remove(0);
        }
    }

    /// A nested context named `parent/operation` (`child`).
    pub fn child(&self, operation: &str, metadata: &[(&str, &str)]) -> Arc<DebugContext> {
        let mut meta = to_map(metadata);
        meta.insert("_parent".to_string(), self.id.clone());
        let pairs: Vec<(&str, &str)> = meta.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        DebugContext::new(&format!("{}/{operation}", self.operation), &pairs)
    }

    pub fn metadata(&self) -> BTreeMap<String, String> {
        self.inner().metadata.clone()
    }

    pub fn events(&self) -> Vec<ContextEvent> {
        self.inner().events.clone()
    }

    pub fn running_ms(&self) -> u64 {
        self.started.elapsed().as_millis() as u64
    }

    /// Contexts still running.
    pub fn active() -> Vec<Arc<DebugContext>> {
        let mut list: Vec<_> = registry().active.values().cloned().collect();
        list.sort_by_key(|c| c.start_time);
        list
    }

    /// The last 100 completed contexts, oldest first.
    pub fn history() -> Vec<Arc<DebugContext>> {
        registry().completed.clone()
    }

    pub fn find(id: &str) -> Option<Arc<DebugContext>> {
        let registry = registry();
        registry
            .active
            .get(id)
            .cloned()
            .or_else(|| registry.completed.iter().find(|c| c.id == id).cloned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_moves_from_active_to_history() {
        let ctx = DebugContext::new("unit-test-op", &[("input", "x")]);
        assert_eq!(ctx.id.len(), 6);
        assert!(ctx.id.bytes().all(|b| ID_ALPHABET.contains(&b)));
        assert!(DebugContext::active().iter().any(|c| c.id == ctx.id));
        ctx.log("step", &[("k", "v")], ContextLevel::Trace);
        assert_eq!(ctx.events().len(), 1);

        ctx.complete(true, &[("result", "ok")]);
        assert!(!DebugContext::active().iter().any(|c| c.id == ctx.id));
        assert!(DebugContext::history().iter().any(|c| c.id == ctx.id));
        let meta = ctx.metadata();
        assert_eq!(meta["_success"], "true");
        assert_eq!(meta["result"], "ok");
        assert!(meta.contains_key("_duration_ms"));
        assert!(DebugContext::find(&ctx.id).is_some());
    }

    #[test]
    fn child_names_and_parent() {
        let parent = DebugContext::new("parent", &[]);
        let child = parent.child("sub", &[]);
        assert_eq!(child.operation, "parent/sub");
        assert_eq!(child.metadata()["_parent"], parent.id);
        child.complete(false, &[]);
        parent.complete(true, &[]);
        assert_eq!(child.metadata()["_success"], "false");
    }

    #[test]
    fn metadata_format() {
        assert_eq!(format_metadata(&BTreeMap::new()), "");
        let meta = to_map(&[("b", "2"), ("a", "1")]);
        assert_eq!(format_metadata(&meta), "{a=1, b=2}");
    }

    #[test]
    fn history_is_capped() {
        for _ in 0..(MAX_HISTORY + 5) {
            DebugContext::new("cap", &[]).complete(true, &[]);
        }
        assert!(DebugContext::history().len() <= MAX_HISTORY);
    }
}
