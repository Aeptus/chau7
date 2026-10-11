//! Remote relay binary frame.
//!
//! Port of `RemoteFrame.swift` (`apps/chau7-macos/Sources/Chau7Core`).
//!
//! Layout (all integers little endian), 20 byte header then payload:
//! `version u8 | type u8 | flags u8 | reserved u8 | tab_id u32 | seq u64 | payload_len u32`.
//! Flag bit 0 marks an encrypted payload. Matches `services/chau7-remote`
//! (`internal/protocol/frame.go`) and `docs/remote-control/SPEC-Remote-Control.md`.

use std::fmt;

/// Failure decoding a [`RemoteFrame`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteFrameError {
    InsufficientData,
    InvalidLength,
    UnsupportedVersion(u8),
}

impl fmt::Display for RemoteFrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InsufficientData => write!(f, "Insufficient data to decode remote frame"),
            Self::InvalidLength => write!(
                f,
                "Remote frame payload length does not match available data"
            ),
            Self::UnsupportedVersion(v) => write!(f, "Unsupported remote frame version: {v}"),
        }
    }
}

impl std::error::Error for RemoteFrameError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteFrame {
    pub version: u8,
    pub type_: u8,
    pub flags: u8,
    pub reserved: u8,
    pub tab_id: u32,
    pub seq: u64,
    pub payload: Vec<u8>,
}

impl RemoteFrame {
    pub const HEADER_SIZE: usize = 20;
    pub const FLAG_ENCRYPTED: u8 = 0x01;

    /// Version 1 frame with zero flags and reserved byte (Swift init defaults).
    pub fn new(type_: u8, tab_id: u32, seq: u64, payload: Vec<u8>) -> Self {
        Self {
            version: 1,
            type_,
            flags: 0,
            reserved: 0,
            tab_id,
            seq,
            payload,
        }
    }

    pub fn frame_type(&self) -> Option<RemoteFrameType> {
        RemoteFrameType::from_u8(self.type_)
    }

    pub fn is_encrypted(&self) -> bool {
        self.flags & Self::FLAG_ENCRYPTED != 0
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut data = Vec::with_capacity(Self::HEADER_SIZE + self.payload.len());
        data.extend_from_slice(&self.header_bytes(self.payload.len() as u32));
        data.extend_from_slice(&self.payload);
        data
    }

    /// The 20 header bytes with an explicit payload length (used as AAD when
    /// the payload is encrypted and its length differs from `self.payload`).
    pub fn header_bytes(&self, payload_len: u32) -> Vec<u8> {
        let mut data = Vec::with_capacity(Self::HEADER_SIZE);
        data.push(self.version);
        data.push(self.type_);
        data.push(self.flags);
        data.push(self.reserved);
        data.extend_from_slice(&self.tab_id.to_le_bytes());
        data.extend_from_slice(&self.seq.to_le_bytes());
        data.extend_from_slice(&payload_len.to_le_bytes());
        data
    }

    /// Decode one frame. Bytes after the declared payload are ignored.
    pub fn decode(data: &[u8]) -> Result<Self, RemoteFrameError> {
        if data.len() < Self::HEADER_SIZE {
            return Err(RemoteFrameError::InsufficientData);
        }
        let version = data[0];
        if version != 1 {
            return Err(RemoteFrameError::UnsupportedVersion(version));
        }
        let tab_id = u32::from_le_bytes(data[4..8].try_into().expect("4 bytes"));
        let seq = u64::from_le_bytes(data[8..16].try_into().expect("8 bytes"));
        let payload_len = u32::from_le_bytes(data[16..20].try_into().expect("4 bytes")) as usize;
        let expected = Self::HEADER_SIZE
            .checked_add(payload_len)
            .ok_or(RemoteFrameError::InvalidLength)?;
        if data.len() < expected {
            return Err(RemoteFrameError::InvalidLength);
        }
        Ok(Self {
            version,
            type_: data[1],
            flags: data[2],
            reserved: data[3],
            tab_id,
            seq,
            payload: data[Self::HEADER_SIZE..expected].to_vec(),
        })
    }
}

/// Known frame type codes (`RemoteFrameType`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum RemoteFrameType {
    Hello = 0x01,
    PairRequest = 0x02,
    PairAccept = 0x03,
    PairReject = 0x04,
    SessionReady = 0x05,
    PairingInfo = 0x40,
    SessionStatus = 0x41,
    RemoteTelemetry = 0x42,
    ClientState = 0x43,
    TabList = 0x10,
    TabSwitch = 0x11,
    ActivityState = 0x12,
    ActivityCleared = 0x13,
    CachedTabList = 0x14,
    InteractivePromptList = 0x15,
    Output = 0x20,
    Input = 0x21,
    Snapshot = 0x22,
    TerminalGridSnapshot = 0x23,
    KeyInput = 0x24,
    InteractivePromptResponse = 0x26,
    PaneInput = 0x27,
    ApprovalRequest = 0x50,
    ApprovalResponse = 0x51,
    /// Read-only viewers (RMT-027, `docs/remote-control/VIEWER-PROTOCOL.md`);
    /// Chau7 Next and the Go agent only, the Swift app never sends them.
    ViewerShare = 0x60,
    ViewerJoin = 0x61,
    ViewerDecision = 0x62,
    ViewerLeave = 0x63,
    ViewerOutput = 0x64,
    Ping = 0x30,
    Pong = 0x31,
    Error = 0x7F,
}

impl RemoteFrameType {
    /// Every case, in Swift declaration order.
    pub const ALL: [RemoteFrameType; 32] = [
        Self::Hello,
        Self::PairRequest,
        Self::PairAccept,
        Self::PairReject,
        Self::SessionReady,
        Self::PairingInfo,
        Self::SessionStatus,
        Self::RemoteTelemetry,
        Self::ClientState,
        Self::TabList,
        Self::TabSwitch,
        Self::ActivityState,
        Self::ActivityCleared,
        Self::CachedTabList,
        Self::InteractivePromptList,
        Self::Output,
        Self::Input,
        Self::Snapshot,
        Self::TerminalGridSnapshot,
        Self::KeyInput,
        Self::InteractivePromptResponse,
        Self::PaneInput,
        Self::ApprovalRequest,
        Self::ApprovalResponse,
        Self::ViewerShare,
        Self::ViewerJoin,
        Self::ViewerDecision,
        Self::ViewerLeave,
        Self::ViewerOutput,
        Self::Ping,
        Self::Pong,
        Self::Error,
    ];

    pub fn raw_value(self) -> u8 {
        self as u8
    }

    pub fn from_u8(raw: u8) -> Option<Self> {
        Self::ALL.iter().copied().find(|t| t.raw_value() == raw)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_decode_round_trip() {
        let frame = RemoteFrame {
            version: 1,
            type_: RemoteFrameType::Output.raw_value(),
            flags: 0,
            reserved: 0,
            tab_id: 42,
            seq: 9,
            payload: vec![1, 2, 3, 4],
        };
        let decoded = RemoteFrame::decode(&frame.encode()).unwrap();
        assert_eq!(decoded, frame);
    }

    #[test]
    fn decode_rejects_short_data() {
        assert!(RemoteFrame::decode(&[0x01, 0x02]).is_err());
    }

    #[test]
    fn decode_rejects_invalid_length() {
        let mut data = vec![1, 2, 3, 4];
        data.extend_from_slice(&[0, 0, 0, 0]);
        data.extend_from_slice(&[0; 8]);
        data.extend_from_slice(&[10, 0, 0, 0]);
        data.extend_from_slice(&[1, 2]);
        assert_eq!(
            RemoteFrame::decode(&data),
            Err(RemoteFrameError::InvalidLength)
        );
    }

    #[test]
    fn header_bytes_matches_encoded_header() {
        let payload = vec![0xAA, 0xBB, 0xCC];
        let frame = RemoteFrame {
            version: 1,
            type_: RemoteFrameType::Output.raw_value(),
            flags: RemoteFrame::FLAG_ENCRYPTED,
            reserved: 0,
            tab_id: 7,
            seq: 99,
            payload: payload.clone(),
        };
        let header = frame.header_bytes(payload.len() as u32);
        assert_eq!(header, frame.encode()[..RemoteFrame::HEADER_SIZE]);
    }

    #[test]
    fn empty_payload_round_trip() {
        let frame = RemoteFrame::new(RemoteFrameType::Ping.raw_value(), 1, 0, vec![]);
        let decoded = RemoteFrame::decode(&frame.encode()).unwrap();
        assert_eq!(decoded, frame);
        assert!(decoded.payload.is_empty());
    }

    #[test]
    fn u32_max_tab_id() {
        let frame = RemoteFrame::new(RemoteFrameType::Output.raw_value(), u32::MAX, 0, vec![1]);
        assert_eq!(
            RemoteFrame::decode(&frame.encode()).unwrap().tab_id,
            u32::MAX
        );
    }

    #[test]
    fn u64_max_seq() {
        let frame = RemoteFrame::new(RemoteFrameType::Output.raw_value(), 1, u64::MAX, vec![1]);
        assert_eq!(RemoteFrame::decode(&frame.encode()).unwrap().seq, u64::MAX);
    }

    #[test]
    fn all_frame_types_round_trip() {
        for frame_type in RemoteFrameType::ALL {
            let frame = RemoteFrame::new(frame_type.raw_value(), 1, 1, vec![0]);
            let decoded = RemoteFrame::decode(&frame.encode()).unwrap();
            assert_eq!(decoded.type_, frame_type.raw_value(), "{frame_type:?}");
            assert_eq!(decoded.frame_type(), Some(frame_type));
        }
    }

    #[test]
    fn boundary_values_all_fields() {
        let frame = RemoteFrame {
            version: 1,
            type_: u8::MAX,
            flags: u8::MAX,
            reserved: u8::MAX,
            tab_id: u32::MAX,
            seq: u64::MAX,
            payload: vec![0xFF],
        };
        let decoded = RemoteFrame::decode(&frame.encode()).unwrap();
        assert_eq!(decoded, frame);
        assert_eq!(decoded.frame_type(), None);
    }

    #[test]
    fn decode_rejects_unsupported_version() {
        let mut frame = RemoteFrame::new(RemoteFrameType::Output.raw_value(), 1, 0, vec![1]);
        frame.version = 2;
        assert_eq!(
            RemoteFrame::decode(&frame.encode()),
            Err(RemoteFrameError::UnsupportedVersion(2))
        );
    }

    // Golden bytes, computed by hand from RemoteFrame.encode().
    #[test]
    fn golden_bytes_encrypted_output_frame() {
        let frame = RemoteFrame {
            version: 1,
            type_: 0x20,
            flags: RemoteFrame::FLAG_ENCRYPTED,
            reserved: 0,
            tab_id: 0x0102_0304,
            seq: 0x0102_0304_0506_0708,
            payload: vec![0xAA, 0xBB],
        };
        let expected: Vec<u8> = vec![
            0x01, 0x20, 0x01, 0x00, // version, type, flags, reserved
            0x04, 0x03, 0x02, 0x01, // tab_id LE
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, // seq LE
            0x02, 0x00, 0x00, 0x00, // payload_len LE
            0xAA, 0xBB,
        ];
        assert_eq!(frame.encode(), expected);
        assert!(frame.is_encrypted());
        assert_eq!(RemoteFrame::decode(&expected).unwrap(), frame);
    }

    #[test]
    fn frame_type_codes_match_go_client() {
        // services/chau7-remote/internal/protocol/frame.go
        let expected: [(RemoteFrameType, u8); 29] = [
            (RemoteFrameType::Hello, 0x01),
            (RemoteFrameType::PairRequest, 0x02),
            (RemoteFrameType::PairAccept, 0x03),
            (RemoteFrameType::PairReject, 0x04),
            (RemoteFrameType::SessionReady, 0x05),
            (RemoteFrameType::TabList, 0x10),
            (RemoteFrameType::TabSwitch, 0x11),
            (RemoteFrameType::ActivityState, 0x12),
            (RemoteFrameType::ActivityCleared, 0x13),
            (RemoteFrameType::CachedTabList, 0x14),
            (RemoteFrameType::InteractivePromptList, 0x15),
            (RemoteFrameType::Output, 0x20),
            (RemoteFrameType::Input, 0x21),
            (RemoteFrameType::Snapshot, 0x22),
            (RemoteFrameType::TerminalGridSnapshot, 0x23),
            (RemoteFrameType::Ping, 0x30),
            (RemoteFrameType::Pong, 0x31),
            (RemoteFrameType::PairingInfo, 0x40),
            (RemoteFrameType::SessionStatus, 0x41),
            (RemoteFrameType::RemoteTelemetry, 0x42),
            (RemoteFrameType::ClientState, 0x43),
            (RemoteFrameType::ApprovalRequest, 0x50),
            (RemoteFrameType::ApprovalResponse, 0x51),
            (RemoteFrameType::ViewerShare, 0x60),
            (RemoteFrameType::ViewerJoin, 0x61),
            (RemoteFrameType::ViewerDecision, 0x62),
            (RemoteFrameType::ViewerLeave, 0x63),
            (RemoteFrameType::ViewerOutput, 0x64),
            (RemoteFrameType::Error, 0x7F),
        ];
        for (t, code) in expected {
            assert_eq!(t.raw_value(), code);
            assert_eq!(RemoteFrameType::from_u8(code), Some(t));
        }
    }
}
