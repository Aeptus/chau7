//! Grid snapshot payload for the phone (`captureRemoteGridSnapshotPayload`,
//! RBK-055): the visible grid in the "CHG2" layout of
//! `chau7_next_core::remote::grid_snapshot`, cells laid out like the
//! emulator's C `CellData` (20 bytes each) with their grapheme clusters.

use chau7_next_core::remote::grid_snapshot::{
    RemoteTerminalGridSnapshot, RemoteTerminalGridSnapshotLayout,
};
use chau7_next_core::work_profiler::{self, Key, Queue};
#[cfg(test)]
use chau7_terminal::{GridCopy, OwnedCell};

/// One cell as `CellData`: `cluster_offset u32 | fg rgb | bg rgb |
/// cluster_len u16 | width u8 | continuation u8 | flags u8 |
/// underline_style u8 | link_id u16 | 2 padding bytes`, its grapheme
/// appended to `clusters`. Like the emulator, the right half of a wide
/// character and a NUL cell carry no cluster.
#[cfg(test)]
fn push_cell(out: &mut Vec<u8>, clusters: &mut Vec<u8>, cell: &OwnedCell, text: &str) {
    let (offset, len) = if cell.continuation || cell.character == '\0' {
        (0u32, 0u16)
    } else {
        let offset = clusters.len() as u32;
        clusters.extend_from_slice(text.as_bytes());
        (offset, text.len() as u16)
    };
    out.extend_from_slice(&offset.to_le_bytes());
    out.extend_from_slice(&[cell.fg.0, cell.fg.1, cell.fg.2]);
    out.extend_from_slice(&[cell.bg.0, cell.bg.1, cell.bg.2]);
    out.extend_from_slice(&len.to_le_bytes());
    out.push(if cell.continuation {
        0
    } else {
        cell.width.max(1)
    });
    out.push(u8::from(cell.continuation));
    out.push(cell.flags);
    out.push(cell.underline);
    out.extend_from_slice(&cell.link_id.to_le_bytes());
    out.extend_from_slice(&[0, 0]);
}

/// The encoded snapshot, or `None` for an empty grid (as Swift).
/// `cursor` is (column, row).
#[cfg(test)]
pub fn encode_grid(grid: &GridCopy, cursor: (u16, u16)) -> Option<Vec<u8>> {
    let count = usize::from(grid.cols) * usize::from(grid.rows);
    if count == 0 || grid.cells.len() < count {
        return None;
    }
    let mut cells = Vec::with_capacity(count * RemoteTerminalGridSnapshotLayout::CELL_STRIDE);
    let mut clusters = Vec::with_capacity(count);
    let mut buf = [0u8; 4];
    for (index, cell) in grid.cells[..count].iter().enumerate() {
        match grid.clusters.get(&index) {
            Some(text) => push_cell(&mut cells, &mut clusters, cell, text),
            None => push_cell(
                &mut cells,
                &mut clusters,
                cell,
                cell.character.encode_utf8(&mut buf),
            ),
        }
    }
    RemoteTerminalGridSnapshot {
        cols: grid.cols,
        rows: grid.rows,
        cursor_col: cursor.0,
        cursor_row: cursor.1,
        cursor_visible: grid.cursor_visible,
        scrollback_rows: grid.scrollback_rows,
        display_offset: grid.display_offset,
        cells,
        clusters,
    }
    .encode()
}

// Native buffers remain inside the worker until converted to owned bytes.
// Every return path uses the public matching destructor; C struct padding
// is never read or transmitted.
struct NativeDelta(Option<Box<chau7_terminal::GridDeltaSnapshot>>);
impl Drop for NativeDelta {
    fn drop(&mut self) {
        if let Some(snapshot) = self.0.take() {
            // SAFETY: this Box owns exactly one snapshot returned by the native
            // producer; its three allocations are released once by its ABI.
            unsafe {
                chau7_terminal::chau7_terminal_free_grid_delta(Box::into_raw(snapshot));
            }
        }
    }
}

pub(crate) fn capture_update(
    terminal: &std::sync::Arc<parking_lot::RwLock<chau7_terminal::Chau7Terminal>>,
    generation: u64,
) -> Option<chau7_next_core::remote::grid_cache::RemoteGridUpdate> {
    use chau7_next_core::remote::grid_cache::RemoteGridUpdate;
    let (native, cursor) = {
        // Parser polling, resize and cursor metadata share this brief guard.
        // Native owns all returned buffers, so copying/encoding needs no lock.
        let _native = work_profiler::begin(Key::work(
            "get_grid_delta",
            "capture",
            "unobserved",
            "remote_grid_worker",
            Queue::Background,
        ));
        let terminal = terminal.write();
        (
            NativeDelta(Some(Box::new(terminal.get_grid_delta_snapshot(generation)))),
            terminal.cursor_position(),
        )
    };
    let mut copy = work_profiler::begin(Key::work(
        "copy_grid_delta",
        "capture",
        "unobserved",
        "remote_grid_worker",
        Queue::Background,
    ));
    let snapshot = native.0.as_ref()?;
    let count = usize::try_from(snapshot.row_count)
        .ok()?
        .checked_mul(usize::from(snapshot.cols))?;
    if snapshot.cols == 0
        || snapshot.rows == 0
        || snapshot.row_count > u32::from(snapshot.rows)
        || count > snapshot.cells_capacity
        || snapshot.clusters_len > snapshot.clusters_capacity
        || snapshot.row_count as usize > snapshot.row_indices_capacity
    {
        return None;
    }
    copy.items(snapshot.row_count as usize);
    copy.bytes(
        count
            .saturating_mul(20)
            .saturating_add(snapshot.clusters_len),
    );
    let cells = if count == 0 {
        &[][..]
    } else {
        if snapshot.cells.is_null() {
            return None;
        }
        // SAFETY: the native producer owns count initialized CellData values.
        unsafe { std::slice::from_raw_parts(snapshot.cells, count) }
    };
    let mut encoded_cells =
        Vec::with_capacity(count.checked_mul(RemoteTerminalGridSnapshotLayout::CELL_STRIDE)?);
    for cell in cells {
        encoded_cells.extend_from_slice(&cell.cluster_offset.to_le_bytes());
        encoded_cells.extend_from_slice(&[
            cell.fg_r, cell.fg_g, cell.fg_b, cell.bg_r, cell.bg_g, cell.bg_b,
        ]);
        encoded_cells.extend_from_slice(&cell.cluster_len.to_le_bytes());
        encoded_cells.extend_from_slice(&[
            cell.width,
            cell.continuation,
            cell.flags,
            cell.underline_style,
        ]);
        encoded_cells.extend_from_slice(&cell.link_id.to_le_bytes());
        encoded_cells.extend_from_slice(&[0, 0]);
    }
    let clusters = if snapshot.clusters_len == 0 {
        Vec::new()
    } else {
        if snapshot.clusters_utf8.is_null() {
            return None;
        }
        // SAFETY: length/capacity belong to the live native snapshot above.
        unsafe {
            std::slice::from_raw_parts(snapshot.clusters_utf8, snapshot.clusters_len).to_vec()
        }
    };
    let indices = if snapshot.row_count == 0 {
        Vec::new()
    } else {
        if snapshot.row_indices.is_null() {
            return None;
        }
        // SAFETY: native allocated exactly row_count initialized row indices.
        unsafe {
            std::slice::from_raw_parts(snapshot.row_indices, snapshot.row_count as usize).to_vec()
        }
    };
    Some(RemoteGridUpdate {
        base_generation: generation,
        generation: snapshot.generation,
        full_refresh: snapshot.full_refresh != 0,
        row_indices: indices,
        snapshot: RemoteTerminalGridSnapshot {
            cols: snapshot.cols,
            rows: snapshot.rows,
            cursor_col: cursor.0,
            cursor_row: cursor.1,
            cursor_visible: snapshot.cursor_visible != 0,
            scrollback_rows: snapshot.scrollback_rows,
            display_offset: snapshot.display_offset,
            cells: encoded_cells,
            clusters,
        },
    })
}

use chau7_next_core::remote::grid_delivery::GridCaptureScope;
use chau7_terminal::Chau7Terminal;
use parking_lot::{Condvar, Mutex, RwLock};
use std::sync::Arc;

struct CaptureRequest {
    scope: GridCaptureScope,
    terminal: Arc<RwLock<Chau7Terminal>>,
    force: bool,
}
#[derive(Debug)]
pub(crate) struct GridCaptureResult {
    pub scope: GridCaptureScope,
    pub generation: u64,
    pub payload: Option<Vec<u8>>,
}
#[derive(Default)]
struct Mailbox {
    version: u64,
    stopped: bool,
    in_flight: bool,
    pending: Option<CaptureRequest>,
    result: Option<GridCaptureResult>,
    captures: u64,
    coalesced: u64,
    discarded: u64,
    retained_bytes: usize,
    last_capture_micros: Option<u64>,
    last_dirty_rows: Option<usize>,
    last_full_refresh: Option<bool>,
    last_error: Option<String>,
}
struct Shared {
    state: Mutex<Mailbox>,
    ready: Condvar,
}
/// Lazy, event-driven worker. There is one pending request and one latest result.
/// Dropping/stopping signals cancellation without joining disk/parser work on UI.
pub(crate) struct GridSnapshotWorker {
    shared: Arc<Shared>,
    started: bool,
}
impl Default for GridSnapshotWorker {
    fn default() -> Self {
        Self {
            shared: Arc::new(Shared {
                state: Mutex::new(Mailbox::default()),
                ready: Condvar::new(),
            }),
            started: false,
        }
    }
}
impl Drop for GridSnapshotWorker {
    fn drop(&mut self) {
        let mut state = self.shared.state.lock();
        state.stopped = true;
        state.pending = None;
        state.result = None;
        self.shared.ready.notify_one();
    }
}
impl GridSnapshotWorker {
    pub fn request(
        &mut self,
        scope: GridCaptureScope,
        terminal: Arc<RwLock<Chau7Terminal>>,
        force: bool,
    ) -> bool {
        if !self.started {
            let shared = self.shared.clone();
            match std::thread::Builder::new()
                .name("chau7-next-remote-grid".into())
                .spawn(move || run_worker(shared))
            {
                Ok(_) => self.started = true,
                Err(error) => {
                    self.shared.state.lock().last_error = Some(error.to_string());
                    return false;
                }
            }
        }
        let mut state = self.shared.state.lock();
        if state.stopped {
            return false;
        }
        let force = force
            || state
                .pending
                .as_ref()
                .is_some_and(|old| old.scope == scope && old.force);
        if state.pending.is_some() {
            state.coalesced += 1;
        }
        state.pending = Some(CaptureRequest {
            scope,
            terminal,
            force,
        });
        self.shared.ready.notify_one();
        true
    }
    pub fn has_result(&self) -> bool {
        self.shared.state.lock().result.is_some()
    }
    pub fn take_result(&mut self) -> Option<GridCaptureResult> {
        self.shared.state.lock().result.take()
    }
    pub fn invalidate(&mut self) {
        let mut state = self.shared.state.lock();
        state.version = state.version.wrapping_add(1);
        state.pending = None;
        state.result = None;
        self.shared.ready.notify_one();
    }
    pub fn stop(&mut self) {
        *self = Self::default();
    }
    pub fn diagnostics(&self) -> serde_json::Value {
        let state = self.shared.state.lock();
        serde_json::json!({"worker_started":self.started,"in_flight":state.in_flight,"pending":state.pending.is_some(),"result_pending":state.result.is_some(),
            "captures":state.captures,"coalesced_requests":state.coalesced,"discarded_results":state.discarded,"retained_cache_bytes":state.retained_bytes,
            "last_capture_micros":state.last_capture_micros,"last_dirty_rows":state.last_dirty_rows,"last_full_refresh":state.last_full_refresh,"last_error":state.last_error})
    }
}
fn latest_result(
    previous: Option<GridCaptureResult>,
    mut next: GridCaptureResult,
) -> GridCaptureResult {
    // A forced/full payload must survive an unchanged capture before UI drains it.
    // Every actual payload is already a full CHG2 viewport, so newer payloads win.
    if next.payload.is_none()
        && next.generation != 0
        && let Some(old) = previous
        && old.scope == next.scope
    {
        next.payload = old.payload;
    }
    next
}
fn run_worker(shared: Arc<Shared>) {
    use chau7_next_core::remote::grid_cache::RemoteGridSnapshotCache;
    let mut cache = RemoteGridSnapshotCache::default();
    let mut scope = None;
    let mut version = 0;
    loop {
        let (request, job_version) = {
            let mut state = shared.state.lock();
            while !state.stopped && state.pending.is_none() && state.version == version {
                shared.ready.wait(&mut state);
            }
            if state.stopped {
                break;
            }
            if state.version != version {
                version = state.version;
                cache.reset();
                scope = None;
                state.retained_bytes = 0;
            }
            let Some(request) = state.pending.take() else {
                continue;
            };
            state.in_flight = true;
            (request, state.version)
        };
        let mut wake = work_profiler::begin(Key::wakeup(
            "remote_grid_worker",
            "unobserved",
            Queue::Background,
        ));
        if scope != Some(request.scope) {
            cache.reset();
            scope = Some(request.scope);
        }
        let started = std::time::Instant::now();
        let base = if request.force { 0 } else { cache.generation() };
        let update = capture_update(&request.terminal, base);
        let row_count = update.as_ref().map(|u| u.row_indices.len());
        let full = update.as_ref().map(|u| u.full_refresh);
        let payload = match update {
            Some(update) => {
                let mut encode = work_profiler::begin(Key::work(
                    "remote_grid_encode",
                    "encode",
                    "unobserved",
                    "remote_grid_worker",
                    Queue::Background,
                ));
                encode.items(update.row_indices.len());
                let payload = cache.encode(&update);
                encode.bytes(payload.as_ref().map_or(0, Vec::len));
                payload
            }
            None => {
                cache.reset();
                None
            }
        };
        wake.items(row_count.unwrap_or(0));
        wake.bytes(payload.as_ref().map_or(0, Vec::len));
        wake.idle(payload.is_none());
        let result = GridCaptureResult {
            scope: request.scope,
            generation: cache.generation(),
            payload,
        };
        let mut state = shared.state.lock();
        state.in_flight = false;
        state.captures += 1;
        state.last_capture_micros =
            Some(started.elapsed().as_micros().min(u128::from(u64::MAX)) as u64);
        state.last_dirty_rows = row_count;
        state.last_full_refresh = full;
        state.retained_bytes = cache.retained_bytes();
        if !state.stopped && state.version == job_version {
            state.result = Some(latest_result(state.result.take(), result));
        } else {
            state.discarded += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wait_until(mut predicate: impl FnMut() -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while !predicate() {
            assert!(
                std::time::Instant::now() < deadline,
                "remote worker did not complete"
            );
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
    }
    #[test]
    fn native_delta_capture_matches_full_wire_and_preserves_metadata() {
        use chau7_next_core::remote::grid_cache::RemoteGridSnapshotCache;
        let term = Arc::new(RwLock::new(Chau7Terminal::new_headless(30, 3).unwrap()));
        term.read().inject_output(
            "\x1b[1;3;4;38;2;10;20;30;48;2;40;50;60mé👩🏽‍💻\x1b[0m\r\n界\x1b[?25l".as_bytes(),
        );
        let update = capture_update(&term, 0).unwrap();
        assert!(update.full_refresh);
        let measurements = work_profiler::snapshot();
        if measurements["instrumentation_enabled"] == true {
            let entries = measurements["entries"].as_array().unwrap();
            for operation in ["get_grid_delta", "copy_grid_delta"] {
                let actual = entries
                    .iter()
                    .find(|entry| entry["operation"] == operation)
                    .expect("native capture must record actual stages");
                assert_eq!(actual["queue"], "background");
                assert!(actual["lifetime"]["sample_count"].as_u64().unwrap() > 0);
            }
        }

        assert_eq!(update.row_indices.len(), 3);
        let mut cache = RemoteGridSnapshotCache::default();
        let bytes = cache.encode(&update).unwrap();
        let expected =
            encode_grid(&term.read().grid_copy(), term.read().cursor_position()).unwrap();
        let mut actual = RemoteTerminalGridSnapshot::decode(&bytes).unwrap();
        let mut expected = RemoteTerminalGridSnapshot::decode(&expected).unwrap();
        // Current Swift's cache rebases empty clusters to the local pool end;
        // their offsets are immaterial because length is zero. All other cell
        // bytes, Unicode pools and metadata must match the native full frame.
        for cells in [&mut actual.cells, &mut expected.cells] {
            for cell in cells
                .as_chunks_mut::<{ RemoteTerminalGridSnapshotLayout::CELL_STRIDE }>()
                .0
            {
                if cell[10..12] == [0, 0] {
                    cell[..4].fill(0);
                }
            }
        }
        assert_eq!(actual, expected);
        let unchanged = capture_update(&term, cache.generation()).unwrap();
        // Alacritty retains the cursor row as damage even while idle.
        assert!(!unchanged.full_refresh);
        assert!(unchanged.row_indices.len() <= 1);
        assert!(cache.encode(&unchanged).is_some());
        term.read().inject_output(b"\x1b[1;1HZ");
        let dirty = capture_update(&term, cache.generation()).unwrap();
        assert!(dirty.row_indices.len() < 3);
        assert!(cache.encode(&dirty).is_some());
        term.read().inject_output(b"\x1b[2;1H\x1b[?25h");
        let changed = capture_update(&term, cache.generation()).unwrap();
        let bytes = cache.encode(&changed).unwrap();
        let decoded = RemoteTerminalGridSnapshot::decode(&bytes).unwrap();
        assert!(decoded.cursor_visible);
        assert_eq!(decoded.cursor_row, 1);
        term.read().resize(13, 4);
        let resized = capture_update(&term, cache.generation()).unwrap();
        assert!(resized.full_refresh);
        let resized = RemoteTerminalGridSnapshot::decode(&cache.encode(&resized).unwrap()).unwrap();
        assert_eq!((resized.cols, resized.rows), (13, 4));
        term.read().inject_output(b"\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6");
        term.read().scroll_lines(2);
        let scrolled = capture_update(&term, cache.generation()).unwrap();
        let scrolled =
            RemoteTerminalGridSnapshot::decode(&cache.encode(&scrolled).unwrap()).unwrap();
        assert!(scrolled.scrollback_rows > 0);
        assert_eq!(scrolled.display_offset, 2);
        // Repeat ownership/destruction paths with different native buffer sizes.
        for _ in 0..32 {
            assert!(capture_update(&term, 0).is_some());
        }
    }
    #[test]
    fn latest_mailbox_keeps_full_resync_when_next_frame_is_unchanged() {
        let scope = GridCaptureScope {
            epoch: 1,
            tab: 2,
            session: 3,
        };
        let old = GridCaptureResult {
            scope,
            generation: 1,
            payload: Some(vec![7]),
        };
        let next = GridCaptureResult {
            scope,
            generation: 2,
            payload: None,
        };
        let merged = latest_result(Some(old), next);
        assert_eq!(merged.payload, Some(vec![7]));
        assert_eq!(merged.generation, 2);
        let new_scope = GridCaptureScope { epoch: 2, ..scope };
        assert!(
            latest_result(
                Some(merged),
                GridCaptureResult {
                    scope: new_scope,
                    generation: 3,
                    payload: None
                }
            )
            .payload
            .is_none()
        );
    }
    #[test]
    fn worker_is_lazy_cancels_inflight_and_coalesces_only_one_pending_request() {
        let term = Arc::new(RwLock::new(Chau7Terminal::new_headless(20, 3).unwrap()));
        term.read().inject_output(b"first");
        let scope = GridCaptureScope {
            epoch: 1,
            tab: 2,
            session: 3,
        };
        let mut worker = GridSnapshotWorker::default();
        assert_eq!(worker.diagnostics()["worker_started"], false);
        assert!(worker.diagnostics()["last_capture_micros"].is_null());
        let lock = term.write();
        worker.request(scope, term.clone(), true);
        wait_until(|| worker.diagnostics()["in_flight"] == true);
        worker.invalidate();
        drop(lock);
        wait_until(|| worker.diagnostics()["discarded_results"] == 1);
        assert!(worker.take_result().is_none());
        let lock = term.write();
        let next_scope = GridCaptureScope { epoch: 2, ..scope };
        worker.request(next_scope, term.clone(), true);
        wait_until(|| worker.diagnostics()["in_flight"] == true);
        worker.request(next_scope, term.clone(), true);
        worker.request(next_scope, term.clone(), false);
        {
            let state = worker.shared.state.lock();
            assert!(state.pending.as_ref().unwrap().force);
        }
        drop(lock);
        wait_until(|| worker.diagnostics()["captures"] == 3);
        let reply = worker.take_result().unwrap();
        assert_eq!(reply.scope, next_scope);
        assert!(reply.payload.is_some());
        assert_eq!(worker.diagnostics()["coalesced_requests"], 1);
        assert!(worker.take_result().is_none());
        worker.invalidate();
        wait_until(|| worker.diagnostics()["retained_cache_bytes"] == 0);
        worker.stop();
        assert_eq!(worker.diagnostics()["worker_started"], false);
    }

    #[test]
    fn encodes_cells_like_cell_data() {
        let cell = OwnedCell {
            character: '\u{e9}',
            fg: (1, 2, 3),
            bg: (4, 5, 6),
            flags: 0x11,
            link_id: 0x0203,
            underline: 3,
            width: 1,
            continuation: false,
        };
        let wide = OwnedCell {
            character: '\u{2764}',
            width: 2,
            ..cell
        };
        let right_half = OwnedCell {
            character: ' ',
            width: 0,
            continuation: true,
            ..cell
        };
        let mut grid = GridCopy {
            cols: 3,
            rows: 1,
            cursor_visible: true,
            scrollback_rows: 40,
            display_offset: 2,
            cells: vec![cell, wide, right_half],
            ..GridCopy::default()
        };
        grid.clusters.insert(1, "\u{2764}\u{fe0f}".to_string());
        let data = encode_grid(&grid, (1, 0)).unwrap();
        let decoded = RemoteTerminalGridSnapshot::decode(&data).unwrap();
        assert_eq!((decoded.cols, decoded.rows), (3, 1));
        assert_eq!((decoded.cursor_col, decoded.cursor_row), (1, 0));
        assert!(decoded.cursor_visible);
        assert_eq!(decoded.scrollback_rows, 40);
        assert_eq!(decoded.display_offset, 2);
        assert_eq!(
            &decoded.cells[..20],
            &[
                0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 2, 0, 1, 0, 0x11, 3, 0x03, 0x02, 0, 0
            ]
        );
        // The heart with VS16 starts after the two bytes of the first cell.
        assert_eq!(&decoded.cells[20..24], &[2, 0, 0, 0]);
        assert_eq!(&decoded.cells[30..34], &[6, 0, 2, 0]);
        // The right half has no cluster, width 0 and the continuation flag.
        assert_eq!(&decoded.cells[50..54], &[0, 0, 0, 1]);
        assert_eq!(decoded.clusters, "\u{e9}\u{2764}\u{fe0f}".as_bytes());
    }

    #[test]
    fn empty_grid_gives_nothing() {
        assert!(encode_grid(&GridCopy::default(), (0, 0)).is_none());
    }
}
