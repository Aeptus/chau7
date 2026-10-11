//! Session recording and the timeline scrubber's data
//! (`History/SessionRecorder.swift`, `Analytics/TimelineScrubberView.swift`).
//!
//! A recording is two files in `DataRoot::recordings_dir`: `<UUID>.bin` with
//! the frames and `<UUID>.json` with the metadata
//! ([`SessionRecordingMeta`](crate::session_recording::SessionRecordingMeta)).
//!
//! Frame file: the bytes `CH7R`, a version byte (1), then per frame a
//! little-endian f64 Unix timestamp, one event type byte (0 output, 1 input,
//! 2 resize, 3 command start, 4 command end, 5 marker), a big-endian u32
//! length and the data. Older recordings are a JSON array of frames and are
//! still read.
//!
//! Chau7 Next records command boundaries as frames too (the Swift recorder is
//! never fed any): a `CommandStart` frame carries the command text and a
//! `CommandEnd` frame the exit code as text, so the scrubber can draw the
//! commands from the recording alone.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::iso8601::{adding_seconds, seconds_between};
use crate::session_recording::{FrameEventType, RecordedFrame, SessionRecordingMeta};

/// Largest recording (`maxRecordingBytes`: 50 MB).
pub const MAX_RECORDING_BYTES: usize = 50 * 1024 * 1024;

const MAGIC: [u8; 4] = *b"CH7R";
const FORMAT_VERSION: u8 = 1;
/// Timestamp (8) + type (1) + length (4).
const FRAME_HEADER: usize = 13;

fn type_byte(t: FrameEventType) -> u8 {
    match t {
        FrameEventType::Output => 0,
        FrameEventType::Input => 1,
        FrameEventType::Resize => 2,
        FrameEventType::CommandStart => 3,
        FrameEventType::CommandEnd => 4,
        FrameEventType::Marker => 5,
    }
}

/// Unknown bytes read as output, as in Swift.
fn byte_type(b: u8) -> FrameEventType {
    match b {
        1 => FrameEventType::Input,
        2 => FrameEventType::Resize,
        3 => FrameEventType::CommandStart,
        4 => FrameEventType::CommandEnd,
        5 => FrameEventType::Marker,
        _ => FrameEventType::Output,
    }
}

fn unix_seconds(date: DateTime<Utc>) -> f64 {
    date.timestamp() as f64 + f64::from(date.timestamp_subsec_nanos()) / 1e9
}

fn from_unix_seconds(seconds: f64) -> DateTime<Utc> {
    let whole = seconds.floor();
    let nanos = (((seconds - whole) * 1e9).round() as u32).min(999_999_999);
    DateTime::from_timestamp(whole as i64, nanos).unwrap_or_default()
}

/// `SessionRecorder.encodeFrames`.
pub fn encode_frames(frames: &[RecordedFrame]) -> Vec<u8> {
    let total: usize = frames.iter().map(|f| FRAME_HEADER + f.data.len()).sum();
    let mut out = Vec::with_capacity(5 + total);
    out.extend_from_slice(&MAGIC);
    out.push(FORMAT_VERSION);
    for frame in frames {
        out.extend_from_slice(&unix_seconds(frame.timestamp).to_le_bytes());
        out.push(type_byte(frame.event_type));
        out.extend_from_slice(&(frame.data.len() as u32).to_be_bytes());
        out.extend_from_slice(&frame.data);
    }
    out
}

/// `SessionRecorder.decodeFrames`: a truncated last frame is dropped.
pub fn decode_frames(raw: &[u8]) -> Vec<RecordedFrame> {
    if raw.len() < 5 {
        return Vec::new();
    }
    if raw[..4] != MAGIC {
        // Legacy recordings are JSON.
        return serde_json::from_slice(raw).unwrap_or_default();
    }
    let mut offset = 5;
    let mut frames = Vec::new();
    while offset + FRAME_HEADER <= raw.len() {
        let ts = f64::from_le_bytes(raw[offset..offset + 8].try_into().unwrap_or([0; 8]));
        let kind = byte_type(raw[offset + 8]);
        let len =
            u32::from_be_bytes(raw[offset + 9..offset + 13].try_into().unwrap_or([0; 4])) as usize;
        offset += FRAME_HEADER;
        if offset + len > raw.len() {
            break;
        }
        frames.push(RecordedFrame {
            id: Uuid::new_v4(),
            timestamp: from_unix_seconds(ts),
            data: raw[offset..offset + len].to_vec(),
            event_type: kind,
        });
        offset += len;
    }
    frames
}

fn file_stem(id: Uuid) -> String {
    id.hyphenated().to_string().to_uppercase()
}

/// The recorder and its folder of recordings.
pub struct SessionRecorder {
    dir: PathBuf,
    pub is_recording: bool,
    pub current: Option<SessionRecordingMeta>,
    /// Finished recordings, newest first.
    pub recordings: Vec<SessionRecordingMeta>,
    pub max_recording_bytes: usize,
    frames: Vec<RecordedFrame>,
    total_bytes: usize,
}

impl SessionRecorder {
    /// Open the folder (created when missing) and list its recordings.
    pub fn new(dir: PathBuf) -> Self {
        if let Err(err) = std::fs::create_dir_all(&dir) {
            log::error!("session recorder: cannot create {}: {err}", dir.display());
        }
        let mut recorder = Self {
            dir,
            is_recording: false,
            current: None,
            recordings: Vec::new(),
            max_recording_bytes: MAX_RECORDING_BYTES,
            frames: Vec::new(),
            total_bytes: 0,
        };
        recorder.load_recordings_list();
        log::info!(
            "session recorder: {} existing recordings",
            recorder.recordings.len()
        );
        recorder
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// `startRecording`: a running recording is stopped and saved first.
    pub fn start_recording(&mut self, title: &str, directory: Option<String>) {
        if self.is_recording {
            self.stop_recording();
        }
        let mut meta = SessionRecordingMeta::new(title);
        meta.directory = directory;
        self.current = Some(meta);
        self.frames.clear();
        self.total_bytes = 0;
        self.is_recording = true;
        log::info!("session recorder: started recording '{title}'");
    }

    /// `recordFrame`: ignored when not recording. A frame that would pass the
    /// size limit stops the recording instead (returns false).
    pub fn record_frame(&mut self, data: &[u8], event_type: FrameEventType) -> bool {
        self.record_frame_at(data, event_type, Utc::now())
    }

    pub fn record_frame_at(
        &mut self,
        data: &[u8],
        event_type: FrameEventType,
        at: DateTime<Utc>,
    ) -> bool {
        if !self.is_recording {
            return false;
        }
        if self.total_bytes + data.len() > self.max_recording_bytes {
            log::warn!("session recorder: maximum size reached, stopping");
            self.stop_recording();
            return false;
        }
        self.frames.push(RecordedFrame {
            id: Uuid::new_v4(),
            timestamp: at,
            data: data.to_vec(),
            event_type,
        });
        self.total_bytes += data.len();
        if let Some(meta) = self.current.as_mut() {
            meta.frame_count = self.frames.len() as i64;
            meta.total_bytes = self.total_bytes as i64;
        }
        true
    }

    /// `stopRecording`: save the files and list the recording first.
    pub fn stop_recording(&mut self) -> Option<SessionRecordingMeta> {
        if !self.is_recording {
            return None;
        }
        let mut meta = self.current.take()?;
        meta.end_time = Some(Utc::now());
        meta.frame_count = self.frames.len() as i64;
        meta.total_bytes = self.total_bytes as i64;
        self.save(&meta);
        self.recordings.insert(0, meta.clone());
        self.is_recording = false;
        self.frames.clear();
        log::info!(
            "session recorder: stopped, {} frames, {} bytes",
            meta.frame_count,
            meta.total_bytes
        );
        self.total_bytes = 0;
        Some(meta)
    }

    fn save(&self, meta: &SessionRecordingMeta) {
        let stem = file_stem(meta.id);
        match serde_json::to_vec(meta) {
            Ok(json) => {
                if let Err(err) = std::fs::write(self.dir.join(format!("{stem}.json")), json) {
                    log::error!("session recorder: cannot save metadata: {err}");
                }
            }
            Err(err) => log::error!("session recorder: cannot encode metadata: {err}"),
        }
        if let Err(err) = std::fs::write(
            self.dir.join(format!("{stem}.bin")),
            encode_frames(&self.frames),
        ) {
            log::error!("session recorder: cannot save frames: {err}");
        }
    }

    /// `deleteRecording`: both files and the list entry.
    pub fn delete_recording(&mut self, id: Uuid) {
        self.recordings.retain(|m| m.id != id);
        let stem = file_stem(id);
        for ext in ["json", "bin"] {
            if let Err(err) = std::fs::remove_file(self.dir.join(format!("{stem}.{ext}"))) {
                log::error!("session recorder: cannot delete {stem}.{ext}: {err}");
            }
        }
        log::info!("session recorder: deleted recording {id}");
    }

    /// `loadFrames`: empty when the file is missing.
    pub fn load_frames(&self, id: Uuid) -> Vec<RecordedFrame> {
        std::fs::read(self.dir.join(format!("{}.bin", file_stem(id))))
            .map(|raw| decode_frames(&raw))
            .unwrap_or_default()
    }

    /// `loadRecordingsList`: newest first.
    pub fn load_recordings_list(&mut self) {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return;
        };
        let mut list: Vec<SessionRecordingMeta> = entries
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|e| e == "json"))
            .filter_map(|p| std::fs::read(p).ok())
            .filter_map(|data| serde_json::from_slice(&data).ok())
            .collect();
        list.sort_by_key(|m| std::cmp::Reverse(m.start_time));
        self.recordings = list;
    }
}

// MARK: timeline

/// A command drawn on the timeline.
#[derive(Debug, Clone, PartialEq)]
pub struct TimelineBlock {
    pub command: String,
    pub start: DateTime<Utc>,
    pub end: Option<DateTime<Utc>>,
    pub exit_code: Option<i64>,
}

impl TimelineBlock {
    pub fn is_running(&self) -> bool {
        self.end.is_none()
    }

    pub fn is_success(&self) -> bool {
        self.exit_code == Some(0)
    }

    pub fn duration(&self) -> Option<f64> {
        self.end.map(|end| seconds_between(end, self.start))
    }

    /// `CommandBlock.durationString`.
    pub fn duration_string(&self) -> String {
        let Some(d) = self.duration() else {
            return String::new();
        };
        if d < 1.0 {
            format!("{:.0}ms", d * 1000.0)
        } else if d < 60.0 {
            format!("{d:.1}s")
        } else if d < 3600.0 {
            format!("{}m {}s", d as i64 / 60, d as i64 % 60)
        } else {
            format!("{}h {}m", d as i64 / 3600, (d as i64 % 3600) / 60)
        }
    }
}

/// Command blocks from the `CommandStart` and `CommandEnd` frames of a
/// recording. `CommandEnd` data is the exit code as text.
pub fn blocks_from_frames(frames: &[RecordedFrame]) -> Vec<TimelineBlock> {
    let mut blocks: Vec<TimelineBlock> = Vec::new();
    for frame in frames {
        match frame.event_type {
            FrameEventType::CommandStart => blocks.push(TimelineBlock {
                command: String::from_utf8_lossy(&frame.data).into_owned(),
                start: frame.timestamp,
                end: None,
                exit_code: None,
            }),
            FrameEventType::CommandEnd => {
                if let Some(block) = blocks.iter_mut().rev().find(|b| b.end.is_none()) {
                    block.end = Some(frame.timestamp);
                    block.exit_code = String::from_utf8_lossy(&frame.data).trim().parse().ok();
                }
            }
            _ => {}
        }
    }
    blocks
}

/// Geometry of the timeline for one session span.
#[derive(Debug, Clone, Copy)]
pub struct Timeline {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

impl Timeline {
    /// Seconds shown, at least 1.
    pub fn total_duration(&self) -> f64 {
        seconds_between(self.end, self.start).max(1.0)
    }

    /// `blockStartFraction`.
    pub fn block_start_fraction(&self, block: &TimelineBlock) -> f64 {
        (seconds_between(block.start, self.start) / self.total_duration()).clamp(0.0, 1.0)
    }

    /// `blockWidthFraction`: a running block extends to `now`; at least 0.5%.
    pub fn block_width_fraction(&self, block: &TimelineBlock, now: DateTime<Utc>) -> f64 {
        let duration = block
            .duration()
            .unwrap_or_else(|| seconds_between(now, block.start));
        (duration / self.total_duration()).clamp(0.005, 1.0)
    }

    /// The moment at a scrub position (0 to 1).
    pub fn date_at(&self, fraction: f64) -> DateTime<Utc> {
        adding_seconds(self.start, fraction.clamp(0.0, 1.0) * self.total_duration())
    }

    /// `timestampAtPosition`: elapsed time as `m:ss`.
    pub fn label_at(&self, fraction: f64) -> String {
        let elapsed = (fraction.clamp(0.0, 1.0) * self.total_duration()) as i64;
        format!("{}:{:02}", elapsed / 60, elapsed % 60)
    }

    /// `activityDensityOverlay`: how many blocks cover each of `buckets`
    /// columns, for the mini-map shading.
    pub fn density(
        &self,
        blocks: &[TimelineBlock],
        buckets: usize,
        now: DateTime<Utc>,
    ) -> Vec<u32> {
        let buckets = buckets.max(1);
        let mut counts = vec![0u32; buckets];
        for block in blocks {
            let start = self.block_start_fraction(block);
            let end = start + self.block_width_fraction(block, now);
            let first = ((start * buckets as f64) as usize).min(buckets - 1);
            let last = ((end * buckets as f64) as usize).min(buckets - 1);
            for slot in counts.iter_mut().take(last + 1).skip(first) {
                *slot += 1;
            }
        }
        counts
    }
}

/// What the replay area shows at a scrub position: the output frames up to
/// `until`, drawn as plain text lines (carriage returns overwrite, backspace
/// deletes, colors and cursor sequences are dropped). The newest
/// `max_lines` lines are returned.
pub fn replay_text(
    frames: &[RecordedFrame],
    until: DateTime<Utc>,
    max_lines: usize,
) -> Vec<String> {
    let mut lines: Vec<Vec<char>> = vec![Vec::new()];
    let mut col = 0usize;
    for frame in frames {
        if frame.timestamp > until {
            break;
        }
        if frame.event_type != FrameEventType::Output {
            continue;
        }
        feed_plain(&mut lines, &mut col, &String::from_utf8_lossy(&frame.data));
    }
    let mut out: Vec<String> = lines.into_iter().map(|l| l.into_iter().collect()).collect();
    while out.last().is_some_and(String::is_empty) && out.len() > 1 {
        out.pop();
    }
    let skip = out.len().saturating_sub(max_lines);
    out.split_off(skip)
}

fn feed_plain(lines: &mut Vec<Vec<char>>, col: &mut usize, text: &str) {
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.peek() {
                Some('[') => {
                    chars.next();
                    // CSI: parameters, then a final byte 0x40..=0x7e.
                    for n in chars.by_ref() {
                        if ('\u{40}'..='\u{7e}').contains(&n) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    chars.next();
                    // OSC: up to BEL or ESC \.
                    while let Some(n) = chars.next() {
                        if n == '\u{7}' {
                            break;
                        }
                        if n == '\u{1b}' {
                            chars.next();
                            break;
                        }
                    }
                }
                Some(_) => {
                    chars.next();
                }
                None => {}
            },
            '\n' => {
                lines.push(Vec::new());
                *col = 0;
            }
            '\r' => *col = 0,
            '\u{8}' => *col = col.saturating_sub(1),
            '\t' => {
                let next = (*col / 8 + 1) * 8;
                while *col < next {
                    put(lines, col, ' ');
                }
            }
            c if c.is_control() => {}
            c => put(lines, col, c),
        }
    }
}

fn put(lines: &mut [Vec<char>], col: &mut usize, c: char) {
    let Some(line) = lines.last_mut() else { return };
    while line.len() < *col {
        line.push(' ');
    }
    if *col < line.len() {
        line[*col] = c;
    } else {
        line.push(c);
    }
    *col += 1;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("chau7-next-rec-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn frames_round_trip_through_the_binary_format() {
        let frames = vec![
            RecordedFrame::with_event_type(b"hello".to_vec(), FrameEventType::Output),
            RecordedFrame::with_event_type(b"ls".to_vec(), FrameEventType::CommandStart),
            RecordedFrame::with_event_type(Vec::new(), FrameEventType::Marker),
        ];
        let raw = encode_frames(&frames);
        assert_eq!(&raw[..4], b"CH7R");
        assert_eq!(raw[4], 1);
        let back = decode_frames(&raw);
        assert_eq!(back.len(), 3);
        assert_eq!(back[0].data, b"hello");
        assert_eq!(back[1].event_type, FrameEventType::CommandStart);
        assert_eq!(back[2].event_type, FrameEventType::Marker);
        assert!(seconds_between(back[0].timestamp, frames[0].timestamp).abs() < 0.001);
    }

    #[test]
    fn decode_keeps_swift_layout_and_survives_damage() {
        // 0x40E5_0000_0000_0000 is 40960.0; little-endian on disk.
        let mut raw = b"CH7R\x01".to_vec();
        raw.extend_from_slice(&40960.0f64.to_le_bytes());
        raw.push(1);
        raw.extend_from_slice(&[0, 0, 0, 2]);
        raw.extend_from_slice(b"ab");
        let frames = decode_frames(&raw);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].timestamp.timestamp(), 40960);
        assert_eq!(frames[0].event_type, FrameEventType::Input);
        // A frame cut short is dropped.
        assert!(decode_frames(&raw[..raw.len() - 1]).is_empty());
        assert!(decode_frames(b"CH7").is_empty());
        // Unknown type bytes read as output.
        let mut odd = raw.clone();
        odd[5 + 8] = 99;
        assert_eq!(decode_frames(&odd)[0].event_type, FrameEventType::Output);
    }

    #[test]
    fn legacy_json_recordings_still_load() {
        let frames = vec![RecordedFrame::new(b"old".to_vec())];
        let json = serde_json::to_vec(&frames).unwrap();
        let back = decode_frames(&json);
        assert_eq!(back[0].data, b"old");
    }

    #[test]
    fn record_stop_list_load_delete() {
        let dir = temp("cycle");
        let mut rec = SessionRecorder::new(dir.clone());
        assert!(!rec.record_frame(b"ignored", FrameEventType::Output));
        rec.start_recording("Work", Some("/tmp".into()));
        assert!(rec.record_frame(b"one", FrameEventType::Output));
        assert!(rec.record_frame(b"two", FrameEventType::Input));
        let meta = rec.stop_recording().unwrap();
        assert_eq!((meta.frame_count, meta.total_bytes), (2, 6));
        assert!(meta.end_time.is_some());
        assert!(!rec.is_recording);
        assert_eq!(rec.recordings[0].id, meta.id);
        assert_eq!(rec.load_frames(meta.id).len(), 2);
        // A second launch finds it.
        let again = SessionRecorder::new(dir.clone());
        assert_eq!(again.recordings.len(), 1);
        assert_eq!(again.recordings[0].title, "Work");
        assert_eq!(again.recordings[0].directory.as_deref(), Some("/tmp"));
        rec.delete_recording(meta.id);
        assert!(rec.recordings.is_empty());
        assert!(rec.load_frames(meta.id).is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn size_cap_stops_the_recording() {
        let dir = temp("cap");
        let mut rec = SessionRecorder::new(dir.clone());
        rec.max_recording_bytes = 10;
        rec.start_recording("Big", None);
        assert!(rec.record_frame(b"123456", FrameEventType::Output));
        assert!(!rec.record_frame(b"123456", FrameEventType::Output));
        assert!(!rec.is_recording);
        assert_eq!(rec.recordings.len(), 1);
        assert_eq!(rec.recordings[0].frame_count, 1);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn starting_again_saves_the_running_recording() {
        let dir = temp("restart");
        let mut rec = SessionRecorder::new(dir.clone());
        rec.start_recording("A", None);
        rec.record_frame(b"x", FrameEventType::Output);
        rec.start_recording("B", None);
        assert_eq!(rec.recordings.len(), 1);
        assert!(rec.is_recording);
        let _ = std::fs::remove_dir_all(dir);
    }

    fn frame_at(start: DateTime<Utc>, secs: f64, data: &str, t: FrameEventType) -> RecordedFrame {
        RecordedFrame {
            id: Uuid::new_v4(),
            timestamp: adding_seconds(start, secs),
            data: data.as_bytes().to_vec(),
            event_type: t,
        }
    }

    #[test]
    fn blocks_and_timeline_geometry() {
        let t0 = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        let frames = vec![
            frame_at(t0, 0.0, "ls", FrameEventType::CommandStart),
            frame_at(t0, 2.0, "0", FrameEventType::CommandEnd),
            frame_at(t0, 4.0, "make", FrameEventType::CommandStart),
            frame_at(t0, 8.0, "2", FrameEventType::CommandEnd),
            frame_at(t0, 9.0, "top", FrameEventType::CommandStart),
        ];
        let blocks = blocks_from_frames(&frames);
        assert_eq!(blocks.len(), 3);
        assert!(blocks[0].is_success());
        assert_eq!(blocks[1].exit_code, Some(2));
        assert!(blocks[2].is_running());
        assert_eq!(blocks[0].duration_string(), "2.0s");
        let line = Timeline {
            start: t0,
            end: adding_seconds(t0, 10.0),
        };
        assert!((line.block_start_fraction(&blocks[1]) - 0.4).abs() < 1e-9);
        assert!((line.block_width_fraction(&blocks[1], t0) - 0.4).abs() < 1e-9);
        // Running: extends to now, at least 0.5%.
        assert!(
            (line.block_width_fraction(&blocks[2], adding_seconds(t0, 10.0)) - 0.1).abs() < 1e-9
        );
        assert_eq!(line.block_width_fraction(&blocks[2], t0), 0.005);
        assert_eq!(line.label_at(0.5), "0:05");
        assert_eq!(line.label_at(2.0), "0:10");
        assert_eq!(line.date_at(0.5), adding_seconds(t0, 5.0));
        let d = line.density(&blocks[..2], 10, t0);
        assert_eq!(d.len(), 10);
        assert_eq!(d[0], 1);
        assert_eq!(d[9], 0);
        // Spans below one second count as one second.
        let tiny = Timeline { start: t0, end: t0 };
        assert_eq!(tiny.total_duration(), 1.0);
    }

    #[test]
    fn replay_text_draws_plain_text_until_the_scrub_position() {
        let t0 = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        let frames = vec![
            frame_at(
                t0,
                0.0,
                "\u{1b}[32mhello\u{1b}[0m\r\n",
                FrameEventType::Output,
            ),
            frame_at(
                t0,
                1.0,
                "progress 10%\rprogress 50%\r\n",
                FrameEventType::Output,
            ),
            frame_at(t0, 2.0, "typed", FrameEventType::Input),
            frame_at(t0, 3.0, "late\r\n", FrameEventType::Output),
        ];
        let at = |s: f64| replay_text(&frames, adding_seconds(t0, s), 10);
        assert_eq!(at(0.5), ["hello"]);
        assert_eq!(at(1.5), ["hello", "progress 50%"]);
        assert_eq!(at(5.0), ["hello", "progress 50%", "late"]);
        assert_eq!(
            replay_text(&frames, adding_seconds(t0, 5.0), 2),
            ["progress 50%", "late"]
        );
        let bs = vec![frame_at(
            t0,
            0.0,
            "abc\u{8}\u{8}X\u{1b}]0;title\u{7}",
            FrameEventType::Output,
        )];
        assert_eq!(replay_text(&bs, t0, 5), ["aXc"]);
    }
}
