//! Session recording types.
//!
//! Ports `apps/chau7-macos/Sources/Chau7Core/SessionRecording.swift`:
//! recorded frames (terminal output, input, resize, markers) and the metadata
//! stored as a JSON sidecar next to the binary frame data.
//!
//! JSON matches Swift's default `Codable` output: camelCase keys, `Date` as
//! seconds since 2001-01-01, `Data` as base64, uppercase UUID, nil optionals
//! omitted, event types by name.

use crate::iso8601::{adding_seconds, reference_date, reference_date_opt, seconds_between};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// What a recorded frame captured.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FrameEventType {
    /// Terminal output data.
    Output,
    /// User input.
    Input,
    /// Terminal resize.
    Resize,
    /// Command started.
    CommandStart,
    /// Command ended.
    CommandEnd,
    /// User-placed marker.
    Marker,
}

/// One recorded frame: terminal bytes at a point in time, for replay.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordedFrame {
    #[serde(with = "crate::iso8601::uuid_upper")]
    pub id: Uuid,
    #[serde(with = "reference_date")]
    pub timestamp: DateTime<Utc>,
    #[serde(with = "crate::iso8601::data_base64")]
    pub data: Vec<u8>,
    pub event_type: FrameEventType,
}

impl RecordedFrame {
    /// An output frame stamped now with a fresh id.
    pub fn new(data: Vec<u8>) -> Self {
        Self::with_event_type(data, FrameEventType::Output)
    }

    pub fn with_event_type(data: Vec<u8>, event_type: FrameEventType) -> Self {
        Self {
            id: Uuid::new_v4(),
            timestamp: Utc::now(),
            data,
            event_type,
        }
    }
}

/// Metadata for a session recording.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecordingMeta {
    #[serde(with = "crate::iso8601::uuid_upper")]
    pub id: Uuid,
    #[serde(with = "reference_date")]
    pub start_time: DateTime<Utc>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "reference_date_opt"
    )]
    pub end_time: Option<DateTime<Utc>>,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shell_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
    pub frame_count: i64,
    pub total_bytes: i64,
}

impl SessionRecordingMeta {
    /// A recording that starts now.
    pub fn new(title: impl Into<String>) -> Self {
        Self::with_start_time(Utc::now(), title)
    }

    pub fn with_start_time(start_time: DateTime<Utc>, title: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            start_time,
            end_time: None,
            title: title.into(),
            shell_type: None,
            directory: None,
            frame_count: 0,
            total_bytes: 0,
        }
    }

    /// Swift's default title.
    pub const DEFAULT_TITLE: &'static str = "Recording";

    /// Wall-clock duration in seconds, once finished.
    pub fn duration(&self) -> Option<f64> {
        self.end_time
            .map(|end| seconds_between(end, self.start_time))
    }

    /// `m:ss` (minutes are not wrapped at 60), or `recording...` while open.
    pub fn duration_string(&self) -> String {
        let Some(d) = self.duration() else {
            return "recording...".to_string();
        };
        let whole = d as i64;
        format!("{}:{:02}", whole / 60, whole % 60)
    }

    /// End the recording `seconds` after it started.
    pub fn finish_after(&mut self, seconds: f64) {
        self.end_time = Some(adding_seconds(self.start_time, seconds));
    }
}

impl Default for SessionRecordingMeta {
    fn default() -> Self {
        Self::new(Self::DEFAULT_TITLE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recorded_frame_creation() {
        let data = b"hello world".to_vec();
        let frame = RecordedFrame::new(data.clone());
        assert_eq!(frame.data, data);
        assert_eq!(frame.event_type, FrameEventType::Output);
        assert!(!frame.id.is_nil());
    }

    #[test]
    fn recorded_frame_with_event_type() {
        let data = vec![0x1B, 0x5B];
        let frame = RecordedFrame::with_event_type(data.clone(), FrameEventType::Resize);
        assert_eq!(frame.event_type, FrameEventType::Resize);
        assert_eq!(frame.data, data);
    }

    #[test]
    fn recorded_frame_with_custom_id() {
        let id = Uuid::new_v4();
        let ts = Utc::now();
        let frame = RecordedFrame {
            id,
            timestamp: ts,
            data: b"test".to_vec(),
            event_type: FrameEventType::CommandStart,
        };
        assert_eq!(frame.id, id);
        assert_eq!(frame.timestamp, ts);
        assert_eq!(frame.event_type, FrameEventType::CommandStart);
    }

    #[test]
    fn recorded_frame_encode_decode() {
        let original =
            RecordedFrame::with_event_type(b"encode test".to_vec(), FrameEventType::Input);
        let json = serde_json::to_string(&original).unwrap();
        let decoded: RecordedFrame = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.id, original.id);
        assert_eq!(decoded.data, original.data);
        assert_eq!(decoded.event_type, original.event_type);
        let diff = seconds_between(decoded.timestamp, original.timestamp).abs();
        assert!(diff < 0.001);
    }

    #[test]
    fn recorded_frame_array_encode_decode() {
        let frames = vec![
            RecordedFrame::with_event_type(b"frame1".to_vec(), FrameEventType::Output),
            RecordedFrame::with_event_type(b"frame2".to_vec(), FrameEventType::CommandStart),
            RecordedFrame::with_event_type(b"frame3".to_vec(), FrameEventType::CommandEnd),
        ];
        let json = serde_json::to_string(&frames).unwrap();
        let decoded: Vec<RecordedFrame> = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.len(), 3);
        assert_eq!(decoded[0].event_type, FrameEventType::Output);
        assert_eq!(decoded[1].event_type, FrameEventType::CommandStart);
        assert_eq!(decoded[2].event_type, FrameEventType::CommandEnd);
    }

    fn raw(event_type: FrameEventType) -> String {
        match serde_json::to_value(event_type).unwrap() {
            serde_json::Value::String(s) => s,
            other => panic!("not a string: {other}"),
        }
    }

    #[test]
    fn frame_event_type_raw_values() {
        assert_eq!(raw(FrameEventType::Output), "output");
        assert_eq!(raw(FrameEventType::Input), "input");
        assert_eq!(raw(FrameEventType::Resize), "resize");
        assert_eq!(raw(FrameEventType::CommandStart), "commandStart");
        assert_eq!(raw(FrameEventType::CommandEnd), "commandEnd");
        assert_eq!(raw(FrameEventType::Marker), "marker");
    }

    #[test]
    fn frame_event_type_codable() {
        for event_type in [
            FrameEventType::Output,
            FrameEventType::Input,
            FrameEventType::Resize,
            FrameEventType::CommandStart,
            FrameEventType::CommandEnd,
            FrameEventType::Marker,
        ] {
            let json = serde_json::to_string(&event_type).unwrap();
            let decoded: FrameEventType = serde_json::from_str(&json).unwrap();
            assert_eq!(decoded, event_type);
        }
    }

    fn meta(start: DateTime<Utc>) -> SessionRecordingMeta {
        SessionRecordingMeta::with_start_time(start, "Test")
    }

    #[test]
    fn duration_nil_when_no_end_time() {
        assert_eq!(SessionRecordingMeta::new("Test").duration(), None);
    }

    #[test]
    fn duration_calculation() {
        let mut m = meta(Utc::now());
        m.finish_after(125.0);
        assert!((m.duration().unwrap() - 125.0).abs() < 0.001);
    }

    #[test]
    fn duration_zero_when_same_time() {
        let start = Utc::now();
        let mut m = meta(start);
        m.end_time = Some(start);
        assert!(m.duration().unwrap().abs() < 0.001);
    }

    #[test]
    fn duration_string_recording() {
        assert_eq!(
            SessionRecordingMeta::new("Test").duration_string(),
            "recording..."
        );
    }

    #[test]
    fn duration_string_zero() {
        let start = Utc::now();
        let mut m = meta(start);
        m.end_time = Some(start);
        assert_eq!(m.duration_string(), "0:00");
    }

    #[test]
    fn duration_string_seconds() {
        let mut m = meta(Utc::now());
        m.finish_after(45.0);
        assert_eq!(m.duration_string(), "0:45");
    }

    #[test]
    fn duration_string_minutes() {
        let mut m = meta(Utc::now());
        m.finish_after(125.0);
        assert_eq!(m.duration_string(), "2:05");
    }

    #[test]
    fn duration_string_long() {
        let mut m = meta(Utc::now());
        m.finish_after(3661.0);
        assert_eq!(m.duration_string(), "61:01");
    }

    #[test]
    fn meta_encode_decode() {
        let mut original = SessionRecordingMeta::new("My Recording");
        original.finish_after(300.0);
        original.shell_type = Some("zsh".into());
        original.directory = Some("/Users/test".into());
        original.frame_count = 42;
        original.total_bytes = 1024;

        let json = serde_json::to_string(&original).unwrap();
        let decoded: SessionRecordingMeta = serde_json::from_str(&json).unwrap();

        assert_eq!(decoded.id, original.id);
        assert_eq!(decoded.title, "My Recording");
        assert_eq!(decoded.shell_type.as_deref(), Some("zsh"));
        assert_eq!(decoded.directory.as_deref(), Some("/Users/test"));
        assert_eq!(decoded.frame_count, 42);
        assert_eq!(decoded.total_bytes, 1024);
    }

    #[test]
    fn meta_defaults() {
        let m = SessionRecordingMeta::default();
        assert_eq!(m.title, "Recording");
        assert_eq!(m.frame_count, 0);
        assert_eq!(m.total_bytes, 0);
        assert_eq!(m.end_time, None);
        assert_eq!(m.shell_type, None);
        assert_eq!(m.directory, None);
    }

    #[test]
    fn meta_custom_title() {
        assert_eq!(
            SessionRecordingMeta::new("Debug Session").title,
            "Debug Session"
        );
    }

    // Branch without a Swift test: the exact JSON keys and encodings.

    #[test]
    fn json_matches_swift_default_coding() {
        let frame = RecordedFrame {
            id: Uuid::parse_str("e621e1f8-c36c-495a-93fc-0c247a3e6e5f").unwrap(),
            timestamp: DateTime::from_timestamp(1_700_000_000, 0).unwrap(),
            data: b"hi".to_vec(),
            event_type: FrameEventType::CommandEnd,
        };
        let value = serde_json::to_value(&frame).unwrap();
        assert_eq!(value["id"], "E621E1F8-C36C-495A-93FC-0C247A3E6E5F");
        assert_eq!(value["timestamp"], 721_692_800.0);
        assert_eq!(value["data"], "aGk=");
        assert_eq!(value["eventType"], "commandEnd");

        let m = serde_json::to_value(SessionRecordingMeta::new("t")).unwrap();
        assert!(m.get("endTime").is_none());
        assert_eq!(m["frameCount"], 0);
        assert_eq!(m["totalBytes"], 0);
    }
}
