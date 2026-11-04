//! One bounded restore writer: at most one running and one pending capture.
//! The UI never waits for disk I/O. Final captures cannot be replaced by a
//! later periodic save, and shutdown drains the pending capture off the UI.
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubmitResult {
    Queued,
    Coalesced,
    Closed,
    FinalAlreadyQueued,
}
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WriterStats {
    pub accepted: u64,
    pub coalesced: u64,
    pub completed: u64,
    pub failed: u64,
}
struct Pending<T> {
    value: T,
}
struct State<T> {
    pending: Option<Pending<T>>,
    closing: bool,
    final_seen: bool,
    stats: WriterStats,
}
struct Queue<T> {
    state: Mutex<State<T>>,
    ready: Condvar,
}
pub struct RestoreWriter<T: Send + 'static> {
    queue: Arc<Queue<T>>,
    handle: Option<JoinHandle<WriterStats>>,
}
impl<T: Send + 'static> RestoreWriter<T> {
    pub fn start(mut commit: impl FnMut(T) -> bool + Send + 'static) -> std::io::Result<Self> {
        let queue = Arc::new(Queue {
            state: Mutex::new(State {
                pending: None,
                closing: false,
                final_seen: false,
                stats: WriterStats::default(),
            }),
            ready: Condvar::new(),
        });
        let work = queue.clone();
        let handle = std::thread::Builder::new()
            .name("next-restore-writer".into())
            .spawn(move || {
                loop {
                    let next = {
                        let mut state = work.state.lock().unwrap_or_else(|e| e.into_inner());
                        while state.pending.is_none() && !state.closing {
                            state = work.ready.wait(state).unwrap_or_else(|e| e.into_inner());
                        }
                        if let Some(next) = state.pending.take() {
                            next
                        } else {
                            return state.stats;
                        }
                    };
                    let okay = commit(next.value);
                    let mut state = work.state.lock().unwrap_or_else(|e| e.into_inner());
                    if okay {
                        state.stats.completed += 1;
                    } else {
                        state.stats.failed += 1;
                    }
                }
            })?;
        Ok(Self {
            queue,
            handle: Some(handle),
        })
    }
    pub fn submit(&self, value: T, final_capture: bool) -> SubmitResult {
        let mut state = self.queue.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.closing {
            return SubmitResult::Closed;
        }
        if state.final_seen {
            return SubmitResult::FinalAlreadyQueued;
        }
        let coalesced = state.pending.is_some();
        state.final_seen |= final_capture;
        state.pending = Some(Pending { value });
        state.stats.accepted += 1;
        if coalesced {
            state.stats.coalesced += 1;
        }
        self.queue.ready.notify_one();
        if coalesced {
            SubmitResult::Coalesced
        } else {
            SubmitResult::Queued
        }
    }
    /// Close the queue only. The caller joins this handle on the existing
    /// background quit future, before incidents shutdown and clean marking.
    pub fn shutdown(mut self) -> JoinHandle<WriterStats> {
        self.close();
        self.handle.take().expect("restore writer handle")
    }
    fn close(&self) {
        self.queue
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .closing = true;
        self.queue.ready.notify_all();
    }
}
impl<T: Send + 'static> Drop for RestoreWriter<T> {
    fn drop(&mut self) {
        // Dropping an app service must not join on the UI. The worker keeps its
        // queue alive long enough to drain any accepted pending capture.
        self.close();
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    #[test]
    fn one_running_one_pending_and_final_capture_wins() {
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let output = Arc::new(Mutex::new(Vec::new()));
        let captured = output.clone();
        let writer = RestoreWriter::start(move |value| {
            if value == 1 {
                started_tx.send(()).unwrap();
                release_rx
                    .recv_timeout(std::time::Duration::from_secs(10))
                    .unwrap();
            }
            captured.lock().unwrap().push(value);
            true
        })
        .unwrap();
        assert_eq!(writer.submit(1, false), SubmitResult::Queued);
        started_rx
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap();
        assert_eq!(writer.submit(2, false), SubmitResult::Queued);
        assert_eq!(writer.submit(3, false), SubmitResult::Coalesced);
        assert_eq!(writer.submit(4, true), SubmitResult::Coalesced);
        assert_eq!(writer.submit(5, false), SubmitResult::FinalAlreadyQueued);
        let handle = writer.shutdown();
        release_tx.send(()).unwrap();
        let stats = handle.join().unwrap();
        assert_eq!(*output.lock().unwrap(), vec![1, 4]);
        assert_eq!(
            stats,
            WriterStats {
                accepted: 4,
                coalesced: 2,
                completed: 2,
                failed: 0
            }
        );
    }
    #[test]
    fn shutdown_without_captures_is_nonblocking_and_drains() {
        let writer = RestoreWriter::<u64>::start(|_| true).unwrap();
        assert_eq!(writer.shutdown().join().unwrap(), WriterStats::default());
    }
    #[test]
    fn failed_capture_does_not_stop_future_captures() {
        let (tx, rx) = mpsc::channel();
        let writer = RestoreWriter::start(move |value| {
            tx.send(value).unwrap();
            value != 1
        })
        .unwrap();
        writer.submit(1, false);
        assert_eq!(
            rx.recv_timeout(std::time::Duration::from_secs(10)).unwrap(),
            1
        );
        writer.submit(2, true);
        assert_eq!(
            rx.recv_timeout(std::time::Duration::from_secs(10)).unwrap(),
            2
        );
        let stats = writer.shutdown().join().unwrap();
        assert_eq!(stats.failed, 1);
        assert_eq!(stats.completed, 1);
    }
}

/// A bounded ledger retains captured text until its exact generation commits.
/// Replacing/coalescing queued captures cannot discard a closed tab's history.
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
pub const MAX_PENDING_CONTEXT_BYTES: usize = 128 * 1024 * 1024;
pub const MAX_CONTEXT_ENTRIES: usize = 4096;
#[derive(Debug, Clone)]
pub struct ContextBuffer {
    pub version: u64,
    pub text: Option<Arc<String>>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CaptureSource {
    Fingerprint([u8; 32]),
    Revision([u64; 3]),
}

/// Identity of terminal content and capture policy. Retains no history.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScrollbackCaptureKey {
    source: CaptureSource,
    max_lines: usize,
}
impl ScrollbackCaptureKey {
    pub fn new(source: &str, max_lines: usize) -> Self {
        use sha2::{Digest, Sha256};
        Self {
            source: CaptureSource::Fingerprint(Sha256::digest(source.as_bytes()).into()),
            max_lines,
        }
    }

    /// Terminal identity/content revision and retained-history epoch, without
    /// exporting or hashing terminal text. Distinct from source fingerprints.
    pub fn from_revision(revision: [u64; 3], max_lines: usize) -> Self {
        Self {
            source: CaptureSource::Revision(revision),
            max_lines,
        }
    }
}

struct BufferEntry {
    capture_key: Option<ScrollbackCaptureKey>,
    export_key: Option<ScrollbackCaptureKey>,
    version: u64,
    hash: Option<u64>,
    text: Option<Arc<String>>,
    pending: bool,
    persisted: bool,
}
#[derive(Default)]
pub struct BufferLedger {
    entries: HashMap<u64, BufferEntry>,
    next_version: u64,
    pending_bytes: usize,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CaptureBoundExceeded;
impl BufferLedger {
    pub fn reuse_export(&self, pane: u64, key: ScrollbackCaptureKey) -> Option<bool> {
        self.entries
            .get(&pane)
            .filter(|entry| entry.export_key == Some(key) && (entry.pending || entry.persisted))
            .map(|entry| entry.hash.is_some())
    }

    /// A parser revision may change without changing exported text. Preserve
    /// source reuse too, and associate the accepted export with its new revision.
    pub fn reuse_source(
        &mut self,
        pane: u64,
        export: ScrollbackCaptureKey,
        source: ScrollbackCaptureKey,
    ) -> Option<bool> {
        let present = self.reuse_capture(pane, source)?;
        self.entries.get_mut(&pane)?.export_key = Some(export);
        Some(present)
    }

    pub fn record_export(
        &mut self,
        pane: u64,
        export: ScrollbackCaptureKey,
        source: ScrollbackCaptureKey,
        text: Option<String>,
    ) -> Result<bool, CaptureBoundExceeded> {
        let present = self.record_capture(pane, source, text)?;
        self.entries
            .get_mut(&pane)
            .expect("accepted capture")
            .export_key = Some(export);
        Ok(present)
    }

    /// Reuse only accepted captures still pending or successfully persisted.
    pub fn reuse_capture(&self, pane: u64, key: ScrollbackCaptureKey) -> Option<bool> {
        self.entries
            .get(&pane)
            .filter(|entry| entry.capture_key == Some(key) && (entry.pending || entry.persisted))
            .map(|entry| entry.hash.is_some())
    }

    pub fn record_capture(
        &mut self,
        pane: u64,
        key: ScrollbackCaptureKey,
        text: Option<String>,
    ) -> Result<bool, CaptureBoundExceeded> {
        let present = self.record(pane, text)?;
        self.entries
            .get_mut(&pane)
            .expect("accepted capture")
            .capture_key = Some(key);
        Ok(present)
    }

    pub fn record(
        &mut self,
        pane: u64,
        text: Option<String>,
    ) -> Result<bool, CaptureBoundExceeded> {
        self.record_with_budget(pane, text, MAX_PENDING_CONTEXT_BYTES)
    }
    fn record_with_budget(
        &mut self,
        pane: u64,
        text: Option<String>,
        budget: usize,
    ) -> Result<bool, CaptureBoundExceeded> {
        if !self.entries.contains_key(&pane) && self.entries.len() >= MAX_CONTEXT_ENTRIES {
            return Err(CaptureBoundExceeded);
        }
        let bytes = text.as_ref().map_or(0, String::len);
        if bytes > super::MAX_SCROLLBACK_BYTES {
            return Err(CaptureBoundExceeded);
        }
        let hash = text.as_ref().map(|text| {
            let mut value = std::collections::hash_map::DefaultHasher::new();
            text.hash(&mut value);
            value.finish()
        });
        if self
            .entries
            .get(&pane)
            .is_some_and(|entry| entry.hash == hash && (entry.pending || entry.persisted))
        {
            let entry = self.entries.get_mut(&pane).expect("existing capture");
            entry.capture_key = None;
            entry.export_key = None;
            return Ok(hash.is_some());
        }
        let previous_bytes = self
            .entries
            .get(&pane)
            .and_then(|entry| entry.text.as_ref())
            .map_or(0, |text| text.len());
        let pending_bytes = self
            .pending_bytes
            .saturating_sub(previous_bytes)
            .saturating_add(bytes);
        if pending_bytes > budget {
            return Err(CaptureBoundExceeded);
        }
        self.next_version = self.next_version.wrapping_add(1);
        self.entries.insert(
            pane,
            BufferEntry {
                capture_key: None,
                export_key: None,
                version: self.next_version,
                hash,
                text: text.map(Arc::new),
                pending: true,
                persisted: false,
            },
        );
        self.pending_bytes = pending_bytes;
        Ok(hash.is_some())
    }
    pub fn has_context(&self, pane: u64) -> bool {
        self.entries
            .get(&pane)
            .is_some_and(|entry| entry.hash.is_some() && (entry.pending || entry.persisted))
    }
    pub fn snapshot(&self) -> HashMap<u64, ContextBuffer> {
        self.entries
            .iter()
            .filter(|(_, entry)| entry.pending)
            .map(|(pane, entry)| {
                (
                    *pane,
                    ContextBuffer {
                        version: entry.version,
                        text: entry.text.clone(),
                    },
                )
            })
            .collect()
    }
    /// Only pending in-memory text overrides the durable canonical context.
    pub fn contexts_for(&self, panes: &[u64]) -> HashMap<u64, Option<Arc<String>>> {
        panes
            .iter()
            .filter_map(|pane| {
                self.entries
                    .get(pane)
                    .filter(|entry| entry.pending)
                    .map(|entry| (*pane, entry.text.clone()))
            })
            .collect()
    }
    pub fn pending_ids(&self) -> HashSet<u64> {
        self.entries
            .iter()
            .filter_map(|(id, entry)| entry.pending.then_some(*id))
            .collect()
    }
    pub fn acknowledge(&mut self, committed: &HashMap<u64, ContextBuffer>) {
        for (pane, buffer) in committed {
            if let Some(entry) = self.entries.get_mut(pane)
                && entry.pending
                && entry.version == buffer.version
            {
                self.pending_bytes = self
                    .pending_bytes
                    .saturating_sub(entry.text.as_ref().map_or(0, |text| text.len()));
                entry.text = None;
                entry.pending = false;
                entry.persisted = true;
            }
        }
    }
    /// Retry contexts on the next live capture after an I/O failure. Pending
    /// newer versions remain available to closed/reopened and parked tabs.
    pub fn invalidate_persisted(&mut self, panes: &HashSet<u64>) {
        for pane in panes {
            if let Some(entry) = self.entries.get_mut(pane) {
                entry.persisted = false;
            }
        }
    }
    pub fn retain(&mut self, keep: &HashSet<u64>) {
        self.entries
            .retain(|pane, entry| entry.pending || keep.contains(pane));
    }
    pub fn pending_bytes(&self) -> usize {
        self.pending_bytes
    }
}

#[cfg(test)]
mod ledger_tests {
    use super::*;

    #[test]
    fn revision_reuse_requires_identity_content_retention_and_policy_and_retries_io() {
        let mut ledger = BufferLedger::default();
        let key = ScrollbackCaptureKey::from_revision([7, 1, 0], 500);
        let source = ScrollbackCaptureKey::new("raw ANSI", 500);
        ledger
            .record_export(1, key, source, Some("accepted".into()))
            .unwrap();
        assert_eq!(ledger.reuse_export(1, key), Some(true));
        for changed in [
            ScrollbackCaptureKey::from_revision([8, 1, 0], 500),
            ScrollbackCaptureKey::from_revision([7, 2, 0], 500),
            ScrollbackCaptureKey::from_revision([7, 1, 1], 500),
            ScrollbackCaptureKey::from_revision([7, 1, 0], 10),
            source,
        ] {
            assert_eq!(ledger.reuse_export(1, changed), None);
        }
        let next = ScrollbackCaptureKey::from_revision([7, 2, 0], 500);
        assert_eq!(ledger.reuse_source(1, next, source), Some(true));
        assert_eq!(ledger.reuse_export(1, next), Some(true));
        let pending = ledger.snapshot();
        ledger.acknowledge(&pending);
        assert_eq!(ledger.reuse_export(1, next), Some(true));
        ledger.invalidate_persisted(&HashSet::from([1]));
        assert_eq!(ledger.reuse_export(1, next), None);
        assert_eq!(ledger.reuse_source(1, key, source), None);
        ledger
            .record_export(1, next, source, Some("accepted".into()))
            .unwrap();
        assert!(ledger.snapshot().contains_key(&1));
        ledger.record(1, None).unwrap();
        assert_eq!(ledger.reuse_export(1, next), None);
        assert_eq!(ledger.reuse_capture(1, source), None);
    }

    #[test]
    fn unchanged_capture_survives_ack_but_retries_after_failed_persistence() {
        let mut ledger = BufferLedger::default();
        let key = ScrollbackCaptureKey::new("raw ANSI", 500);
        assert_eq!(ledger.reuse_capture(1, key), None);
        ledger.record_capture(1, key, Some("clean".into())).unwrap();
        assert_eq!(ledger.reuse_capture(1, key), Some(true));
        assert_eq!(ledger.reuse_capture(2, key), None);
        assert_eq!(
            ledger.reuse_capture(1, ScrollbackCaptureKey::new("new ANSI", 500)),
            None
        );
        assert_eq!(
            ledger.reuse_capture(1, ScrollbackCaptureKey::new("raw ANSI", 10)),
            None
        );
        let pending = ledger.snapshot();
        ledger.acknowledge(&pending);
        assert_eq!(ledger.pending_bytes(), 0);
        assert_eq!(ledger.reuse_capture(1, key), Some(true));
        ledger.invalidate_persisted(&HashSet::from([1]));
        assert_eq!(ledger.reuse_capture(1, key), None);
        ledger.record_capture(1, key, Some("clean".into())).unwrap();
        assert!(ledger.snapshot().contains_key(&1));
    }

    #[test]
    fn capture_reuse_handles_tombstones_rejections_and_newer_generations() {
        let mut ledger = BufferLedger::default();
        let old_key = ScrollbackCaptureKey::new("old", 500);
        let new_key = ScrollbackCaptureKey::new("new", 500);
        ledger
            .record_capture(1, old_key, Some("old".into()))
            .unwrap();
        let old_pending = ledger.snapshot();
        assert!(
            ledger
                .record_capture(
                    1,
                    new_key,
                    Some("x".repeat(super::super::MAX_SCROLLBACK_BYTES + 1))
                )
                .is_err()
        );
        assert_eq!(ledger.reuse_capture(1, new_key), None);
        assert_eq!(ledger.reuse_capture(1, old_key), Some(true));
        ledger
            .record_capture(1, new_key, Some("new".into()))
            .unwrap();
        ledger.acknowledge(&old_pending);
        assert_eq!(ledger.reuse_capture(1, new_key), Some(true));
        assert_eq!(ledger.reuse_capture(1, old_key), None);
        ledger.record_capture(1, old_key, None).unwrap();
        assert_eq!(ledger.reuse_capture(1, old_key), Some(false));
        let pending = ledger.snapshot();
        ledger.acknowledge(&pending);
        assert_eq!(ledger.reuse_capture(1, old_key), Some(false));
        ledger
            .record(1, Some("external replacement".into()))
            .unwrap();
        assert_eq!(ledger.reuse_capture(1, old_key), None);
        ledger.acknowledge(&ledger.snapshot());
        ledger.retain(&HashSet::new());
        assert_eq!(ledger.reuse_capture(1, old_key), None);
    }
    #[test]
    fn acknowledgement_cannot_discard_a_newer_capture() {
        let mut ledger = BufferLedger::default();
        ledger.record(1, Some("old".into())).unwrap();
        let old = ledger.snapshot();
        ledger.record(1, Some("new".into())).unwrap();
        ledger.acknowledge(&old);
        assert_eq!(
            ledger.contexts_for(&[1])[&1].as_deref().map(String::as_str),
            Some("new")
        );
        assert_eq!(ledger.pending_bytes(), 3);
        let new = ledger.snapshot();
        ledger.acknowledge(&new);
        assert!(ledger.snapshot().is_empty());
        assert_eq!(ledger.pending_bytes(), 0);
        assert!(ledger.record(1, Some("new".into())).unwrap());
        assert!(ledger.snapshot().is_empty());
    }
    #[test]
    fn closed_and_parked_context_survives_until_matching_commit() {
        let mut ledger = BufferLedger::default();
        ledger.record(42, Some("closed history".into())).unwrap();
        ledger.retain(&HashSet::new());
        assert_eq!(
            ledger.contexts_for(&[42])[&42]
                .as_deref()
                .map(String::as_str),
            Some("closed history")
        );
        ledger.invalidate_persisted(&HashSet::from([42]));
        let snapshot = ledger.snapshot();
        ledger.acknowledge(&snapshot);
        ledger.retain(&HashSet::from([42]));
        assert!(ledger.has_context(42));
        ledger.retain(&HashSet::new());
        assert!(!ledger.has_context(42));
    }
    #[test]
    fn explicit_empty_history_is_a_tombstone_and_oversized_capture_keeps_previous() {
        let mut ledger = BufferLedger::default();
        ledger.record(1, Some("safe".into())).unwrap();
        assert!(
            ledger
                .record(1, Some("x".repeat(super::super::MAX_SCROLLBACK_BYTES + 1)))
                .is_err()
        );
        assert_eq!(
            ledger.contexts_for(&[1])[&1].as_deref().map(String::as_str),
            Some("safe")
        );
        assert!(!ledger.record(1, None).unwrap());
        assert!(ledger.snapshot()[&1].text.is_none());
        assert_eq!(ledger.pending_bytes(), 0);
        let snapshot = ledger.snapshot();
        ledger.acknowledge(&snapshot);
        assert!(!ledger.record(1, None).unwrap());
        assert!(ledger.snapshot().is_empty());
    }
    #[test]
    fn failure_retries_identical_previously_persisted_text() {
        let mut ledger = BufferLedger::default();
        ledger.record(1, Some("safe".into())).unwrap();
        let snapshot = ledger.snapshot();
        ledger.acknowledge(&snapshot);
        ledger.invalidate_persisted(&HashSet::from([1]));
        ledger.record(1, Some("safe".into())).unwrap();
        assert!(ledger.snapshot().contains_key(&1));
    }
    #[test]
    fn zero_byte_entries_are_bounded_too() {
        let mut ledger = BufferLedger::default();
        for id in 0..MAX_CONTEXT_ENTRIES {
            ledger.record(id as u64, None).unwrap();
        }
        assert!(ledger.record(MAX_CONTEXT_ENTRIES as u64, None).is_err());
        assert_eq!(ledger.snapshot().len(), MAX_CONTEXT_ENTRIES);
    }
    #[test]
    fn total_context_budget_preserves_all_accepted_entries() {
        let mut ledger = BufferLedger::default();
        let text = "x".repeat(128);
        let budget = 1024;
        let count = budget / text.len();
        for id in 0..count {
            ledger
                .record_with_budget(id as u64, Some(text.clone()), budget)
                .unwrap();
        }
        assert!(
            ledger
                .record_with_budget(count as u64, Some(text), budget)
                .is_err()
        );
        assert_eq!(ledger.snapshot().len(), count);
        assert!(ledger.pending_bytes() <= MAX_PENDING_CONTEXT_BYTES);
    }
}
