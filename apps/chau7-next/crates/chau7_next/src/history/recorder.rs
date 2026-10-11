//! Session recording for the timeline scrubber
//! (`History/SessionRecorder.swift`).
//!
//! One recording runs at a time and follows one terminal session. The
//! sessions feed it from their poll threads, so the state is a process-wide
//! mutex behind an atomic "who is recorded" check: sessions that are not
//! recorded pay one atomic load per chunk of output.

use std::sync::atomic::{AtomicU64, Ordering};

use chau7_next_core::session_recorder::SessionRecorder;
use chau7_next_core::session_recording::{FrameEventType, RecordedFrame, SessionRecordingMeta};
use gpui::App;
use parking_lot::Mutex;
use uuid::Uuid;

/// Session id being recorded; 0 for none.
static TARGET: AtomicU64 = AtomicU64::new(0);
static RECORDER: Mutex<Option<SessionRecorder>> = Mutex::new(None);

/// Open the recordings folder and list what is in it.
pub fn init(cx: &mut App) {
    let dir = cx
        .global::<crate::workspace::AppData>()
        .root
        .recordings_dir();
    *RECORDER.lock() = Some(SessionRecorder::new(dir));
}

fn with<R>(f: impl FnOnce(&mut SessionRecorder) -> R) -> Option<R> {
    RECORDER.lock().as_mut().map(f)
}

/// The session being recorded.
pub fn recording_session() -> Option<u64> {
    match TARGET.load(Ordering::Relaxed) {
        0 => None,
        id => Some(id),
    }
}

/// Whether this session is the one being recorded.
pub fn is_recording(session: u64) -> bool {
    TARGET.load(Ordering::Relaxed) == session
}

/// Start recording a session; a running recording is saved first.
pub fn start(session: u64, title: &str, directory: Option<String>) {
    with(|r| r.start_recording(title, directory));
    TARGET.store(session, Ordering::Relaxed);
}

/// Stop and save the recording.
pub fn stop() -> Option<SessionRecordingMeta> {
    TARGET.store(0, Ordering::Relaxed);
    with(SessionRecorder::stop_recording).flatten()
}

fn feed(session: u64, data: &[u8], kind: FrameEventType) {
    if !is_recording(session) {
        return;
    }
    let kept = with(|r| r.record_frame(data, kind)).unwrap_or(false);
    if !kept && !with(|r| r.is_recording).unwrap_or(false) {
        // The size limit stopped the recording.
        TARGET.store(0, Ordering::Relaxed);
    }
}

/// Bytes the terminal printed.
pub fn output(session: u64, data: &[u8]) {
    feed(session, data, FrameEventType::Output);
}

/// Bytes typed into the terminal.
pub fn input(session: u64, data: &[u8]) {
    feed(session, data, FrameEventType::Input);
}

/// The grid changed size (`cols x rows`).
pub fn resize(session: u64, cols: u16, rows: u16) {
    feed(
        session,
        format!("{cols}x{rows}").as_bytes(),
        FrameEventType::Resize,
    );
}

/// A command started (OSC 133 C); the frame carries its text.
pub fn command_start(session: u64, command: &str) {
    feed(session, command.as_bytes(), FrameEventType::CommandStart);
}

/// A command ended; the frame carries the exit code as text (empty when
/// unknown).
pub fn command_end(session: u64, exit_code: Option<i32>) {
    let text = exit_code.map(|c| c.to_string()).unwrap_or_default();
    feed(session, text.as_bytes(), FrameEventType::CommandEnd);
}

/// A marker frame (a label the user adds while recording).
#[allow(dead_code)]
pub fn marker(session: u64, label: &str) {
    feed(session, label.as_bytes(), FrameEventType::Marker);
}

/// Finished recordings, newest first.
pub fn list() -> Vec<SessionRecordingMeta> {
    with(|r| {
        r.load_recordings_list();
        r.recordings.clone()
    })
    .unwrap_or_default()
}

/// The frames of a finished recording.
pub fn load_frames(id: Uuid) -> Vec<RecordedFrame> {
    with(|r| r.load_frames(id)).unwrap_or_default()
}

pub fn delete(id: Uuid) {
    with(|r| r.delete_recording(id));
}

/// Save a running recording when the app quits.
pub fn flush_on_quit() {
    if recording_session().is_some() {
        stop();
    }
}
