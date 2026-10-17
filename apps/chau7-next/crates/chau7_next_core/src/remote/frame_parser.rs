//! Length-prefixed frame stream parser for the remote relay.
//!
//! Port of `FrameParser.swift` (`apps/chau7-macos/Sources/Chau7Core`).
//! Each frame on the stream is a 4 byte little endian length followed by that
//! many bytes of an encoded [`RemoteFrame`].

use super::frame::{RemoteFrame, RemoteFrameError};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameParsingError {
    /// Length prefix was zero or above the maximum. Carries the declared length.
    InvalidFrameLength(usize),
}

impl fmt::Display for FrameParsingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidFrameLength(len) => write!(f, "Invalid frame length: {len}"),
        }
    }
}

impl std::error::Error for FrameParsingError {}

/// Error collected while parsing (Swift used `[Error]`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameParseError {
    Length(FrameParsingError),
    Decode(RemoteFrameError),
}

impl fmt::Display for FrameParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Length(e) => e.fmt(f),
            Self::Decode(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for FrameParseError {}

#[derive(Debug, Default, PartialEq)]
pub struct ParseResult {
    pub frames: Vec<RemoteFrame>,
    pub errors: Vec<FrameParseError>,
}

pub const DEFAULT_MAX_FRAME_SIZE: usize = 5 * 1024 * 1024;
pub const LENGTH_PREFIX_SIZE: usize = 4;

/// Parse frames with [`DEFAULT_MAX_FRAME_SIZE`].
pub fn parse_frames(buffer: &mut Vec<u8>) -> ParseResult {
    parse_frames_with_max(buffer, DEFAULT_MAX_FRAME_SIZE)
}

/// Parse length-prefixed frames from `buffer`, removing consumed bytes in place.
///
/// On an invalid length (zero or above `max_frame_size`) the 4 byte prefix is
/// skipped and parsing continues. A decode failure is collected and parsing
/// continues with the next frame. Incomplete trailing data stays in the buffer.
pub fn parse_frames_with_max(buffer: &mut Vec<u8>, max_frame_size: usize) -> ParseResult {
    let mut result = ParseResult::default();
    let mut pos = 0usize;

    while buffer.len() - pos >= LENGTH_PREFIX_SIZE {
        let frame_len = u32::from_le_bytes(
            buffer[pos..pos + LENGTH_PREFIX_SIZE]
                .try_into()
                .expect("4 bytes"),
        ) as usize;

        if frame_len == 0 || frame_len > max_frame_size {
            result.errors.push(FrameParseError::Length(
                FrameParsingError::InvalidFrameLength(frame_len),
            ));
            pos += LENGTH_PREFIX_SIZE;
            continue;
        }

        let total_needed = LENGTH_PREFIX_SIZE + frame_len;
        if buffer.len() - pos < total_needed {
            break;
        }

        let frame_data = &buffer[pos + LENGTH_PREFIX_SIZE..pos + total_needed];
        let decoded = RemoteFrame::decode(frame_data);
        pos += total_needed;

        match decoded {
            Ok(frame) => result.frames.push(frame),
            Err(e) => result.errors.push(FrameParseError::Decode(e)),
        }
    }

    buffer.drain(..pos);
    result
}

/// Encode a frame with a 4 byte little endian length prefix for transport.
pub fn pack_for_transport(frame: &RemoteFrame) -> Vec<u8> {
    let encoded = frame.encode();
    let mut data = Vec::with_capacity(LENGTH_PREFIX_SIZE + encoded.len());
    data.extend_from_slice(&(encoded.len() as u32).to_le_bytes());
    data.extend_from_slice(&encoded);
    data
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote::frame::RemoteFrameType;

    fn make_frame(tab_id: u32, seq: u64, payload: Vec<u8>) -> RemoteFrame {
        RemoteFrame::new(RemoteFrameType::Output.raw_value(), tab_id, seq, payload)
    }

    fn default_frame() -> RemoteFrame {
        make_frame(1, 0, vec![0xAA])
    }

    #[test]
    fn parses_single_complete_frame() {
        let frame = default_frame();
        let mut buffer = pack_for_transport(&frame);
        let result = parse_frames(&mut buffer);
        assert_eq!(result.frames, vec![frame]);
        assert!(result.errors.is_empty());
        assert!(buffer.is_empty());
    }

    #[test]
    fn parses_multiple_frames() {
        let f1 = make_frame(1, 10, vec![0xAA]);
        let f2 = make_frame(2, 20, vec![0xAA]);
        let f3 = make_frame(3, 30, vec![0xAA]);
        let mut buffer = [&f1, &f2, &f3]
            .iter()
            .flat_map(|f| pack_for_transport(f))
            .collect::<Vec<u8>>();
        let result = parse_frames(&mut buffer);
        assert_eq!(result.frames, vec![f1, f2, f3]);
        assert!(result.errors.is_empty());
        assert!(buffer.is_empty());
    }

    #[test]
    fn preserves_incomplete_frame() {
        let packed = pack_for_transport(&default_frame());
        let mut buffer = packed[..packed.len() - 1].to_vec();
        let original = buffer.clone();
        let result = parse_frames(&mut buffer);
        assert!(result.frames.is_empty());
        assert!(result.errors.is_empty());
        assert_eq!(buffer, original);
    }

    #[test]
    fn preserves_incomplete_length_prefix() {
        let mut buffer = vec![0x01, 0x02];
        let result = parse_frames(&mut buffer);
        assert!(result.frames.is_empty());
        assert!(result.errors.is_empty());
        assert_eq!(buffer, vec![0x01, 0x02]);
    }

    #[test]
    fn empty_buffer() {
        let mut buffer = Vec::new();
        let result = parse_frames(&mut buffer);
        assert!(result.frames.is_empty());
        assert!(result.errors.is_empty());
    }

    #[test]
    fn rejects_zero_length_frame() {
        let mut buffer = vec![0, 0, 0, 0];
        let result = parse_frames(&mut buffer);
        assert!(result.frames.is_empty());
        assert!(!result.errors.is_empty());
        assert!(buffer.len() < LENGTH_PREFIX_SIZE);
        assert_eq!(
            result.errors[0],
            FrameParseError::Length(FrameParsingError::InvalidFrameLength(0))
        );
    }

    #[test]
    fn rejects_oversized_frame() {
        let oversized = (DEFAULT_MAX_FRAME_SIZE + 1) as u32;
        let mut buffer = oversized.to_le_bytes().to_vec();
        let result = parse_frames(&mut buffer);
        assert!(result.frames.is_empty());
        assert!(!result.errors.is_empty());
        assert!(buffer.len() < LENGTH_PREFIX_SIZE);
    }

    #[test]
    fn custom_max_frame_size() {
        let frame = make_frame(1, 0, vec![0xFF; 100]);
        let mut buffer = pack_for_transport(&frame);
        let result = parse_frames_with_max(&mut buffer, 10);
        assert!(result.frames.is_empty());
        assert!(!result.errors.is_empty());
        assert!(buffer.len() < LENGTH_PREFIX_SIZE);
    }

    #[test]
    fn decode_error_continues_parsing() {
        let mut buffer = vec![0x02, 0x00, 0x00, 0x00, 0xFF, 0xFF];
        let valid = make_frame(99, 0, vec![0xAA]);
        buffer.extend(pack_for_transport(&valid));
        let result = parse_frames(&mut buffer);
        assert_eq!(result.frames, vec![valid]);
        assert_eq!(result.errors.len(), 1);
        assert_eq!(
            result.errors[0],
            FrameParseError::Decode(RemoteFrameError::InsufficientData)
        );
        assert!(buffer.is_empty());
    }

    #[test]
    fn invalid_length_skips_and_continues() {
        let valid = default_frame();
        let mut buffer = pack_for_transport(&valid);
        buffer.extend_from_slice(&[0, 0, 0, 0]);
        buffer.extend(std::iter::repeat_n(0xBB, 52));
        let result = parse_frames(&mut buffer);
        assert_eq!(result.frames, vec![valid]);
        assert!(!result.errors.is_empty());
        assert!(buffer.len() < LENGTH_PREFIX_SIZE);
    }

    #[test]
    fn pack_for_transport_round_trip() {
        let frame = RemoteFrame::new(
            RemoteFrameType::Ping.raw_value(),
            42,
            12345,
            b"hello".to_vec(),
        );
        let mut buffer = pack_for_transport(&frame);
        let result = parse_frames(&mut buffer);
        assert_eq!(result.frames, vec![frame]);
        assert!(buffer.is_empty());
    }

    #[test]
    fn pack_for_transport_length_prefix() {
        let frame = make_frame(1, 0, vec![0; 50]);
        let packed = pack_for_transport(&frame);
        let expected_len = frame.encode().len() as u32;
        let actual = u32::from_le_bytes(packed[..4].try_into().unwrap());
        assert_eq!(actual, expected_len);
        assert_eq!(packed.len(), 4 + expected_len as usize);
    }

    // Mirrors PropertyBasedTests.testFrameParserRoundTrip with a deterministic
    // generator instead of Swift's random one.
    #[test]
    fn frame_parser_round_trip_varied_frames() {
        let mut state = 0x9E37_79B9_7F4A_7C15u64;
        let mut next = || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for _ in 0..50 {
            let size = (next() % 201) as usize;
            let payload: Vec<u8> = (0..size).map(|_| next() as u8).collect();
            let frame = RemoteFrame {
                version: 1,
                type_: (next() % 6) as u8,
                flags: next() as u8,
                reserved: 0,
                tab_id: next() as u32,
                seq: next(),
                payload,
            };
            let mut buffer = pack_for_transport(&frame);
            let result = parse_frames(&mut buffer);
            assert_eq!(result.frames, vec![frame]);
            assert!(result.errors.is_empty());
            assert!(buffer.is_empty());
        }
    }

    #[test]
    fn golden_bytes_packed_frame() {
        let frame = RemoteFrame {
            version: 1,
            type_: 0x30,
            flags: 0,
            reserved: 0,
            tab_id: 1,
            seq: 2,
            payload: vec![0x68, 0x69],
        };
        let expected: Vec<u8> = vec![
            0x16, 0x00, 0x00, 0x00, // length 22
            0x01, 0x30, 0x00, 0x00, // header
            0x01, 0x00, 0x00, 0x00, // tab_id
            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // seq
            0x02, 0x00, 0x00, 0x00, // payload_len
            0x68, 0x69,
        ];
        assert_eq!(pack_for_transport(&frame), expected);
    }
}
