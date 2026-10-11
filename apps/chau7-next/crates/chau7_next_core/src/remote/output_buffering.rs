//! Remote output limits and the per-tab pending output buffer.
//!
//! Port of `RemoteOutputBuffering.swift` (`apps/chau7-macos/Sources/Chau7Core`).

use std::collections::{HashMap, HashSet};
use std::time::Duration;

/// Size limits and flush cadence for streaming terminal output to remote clients.
pub struct RemoteOutputTuning;

impl RemoteOutputTuning {
    pub const MAX_RETAINED_BYTES: usize = 200_000;
    pub const MAX_INCOMING_FRAME_BYTES: usize = 65536;
    pub const MAX_PENDING_BYTES_PER_TAB: usize = 32768;
    pub const FLUSH_INTERVAL: Duration = Duration::from_millis(33);

    /// Keep the last [`Self::MAX_RETAINED_BYTES`] UTF-8 bytes. A cut in the
    /// middle of a character becomes U+FFFD, like Swift's `String(decoding:)`.
    pub fn trim_retained_text(input: &str) -> String {
        let bytes = input.as_bytes();
        if bytes.len() <= Self::MAX_RETAINED_BYTES {
            return input.to_string();
        }
        String::from_utf8_lossy(&bytes[bytes.len() - Self::MAX_RETAINED_BYTES..]).into_owned()
    }

    /// Last [`Self::MAX_RETAINED_BYTES`] bytes of a snapshot.
    pub fn cap_snapshot(data: &[u8]) -> Vec<u8> {
        let start = data.len().saturating_sub(Self::MAX_RETAINED_BYTES);
        data[start..].to_vec()
    }

    /// First [`Self::MAX_INCOMING_FRAME_BYTES`] bytes of an incoming input frame.
    pub fn cap_incoming_frame(data: &[u8]) -> Vec<u8> {
        let end = data.len().min(Self::MAX_INCOMING_FRAME_BYTES);
        data[..end].to_vec()
    }

    /// Output batching (`remoteOutputBatchingEnabled`): on unless the
    /// `CHAU7_REMOTE_OUTPUT_BATCH` variable says `0`, `false` or `off`; then
    /// every chunk is sent as soon as it is processed.
    pub fn batching_enabled(raw: Option<&str>) -> bool {
        match raw {
            Some(raw) => {
                let lowered = raw.trim().to_lowercase();
                !(lowered == "0" || lowered == "false" || lowered == "off")
            }
            None => true,
        }
    }
}

/// One pending chunk per tab, merged on append.
#[derive(Debug, Clone)]
pub struct RemotePendingOutputBuffer<Chunk> {
    pending_by_tab_id: HashMap<u32, Chunk>,
}

impl<Chunk> Default for RemotePendingOutputBuffer<Chunk> {
    fn default() -> Self {
        Self {
            pending_by_tab_id: HashMap::new(),
        }
    }
}

impl<Chunk> RemotePendingOutputBuffer<Chunk> {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.pending_by_tab_id.is_empty()
    }

    pub fn tab_ids(&self) -> Vec<u32> {
        self.pending_by_tab_id.keys().copied().collect()
    }

    pub fn get(&self, tab_id: u32) -> Option<&Chunk> {
        self.pending_by_tab_id.get(&tab_id)
    }

    /// Store `chunk` for the tab, or merge it into the existing chunk.
    pub fn append(&mut self, chunk: Chunk, tab_id: u32, merging: impl FnOnce(&mut Chunk, Chunk)) {
        match self.pending_by_tab_id.get_mut(&tab_id) {
            Some(existing) => merging(existing, chunk),
            None => {
                self.pending_by_tab_id.insert(tab_id, chunk);
            }
        }
    }

    pub fn drain(&mut self, tab_id: u32) -> Option<Chunk> {
        self.pending_by_tab_id.remove(&tab_id)
    }

    pub fn drain_all(&mut self, sorted_by_tab_id: bool) -> Vec<(u32, Chunk)> {
        let mut drained: Vec<(u32, Chunk)> = self.pending_by_tab_id.drain().collect();
        if sorted_by_tab_id {
            drained.sort_by_key(|(tab_id, _)| *tab_id);
        }
        drained
    }

    pub fn retain_only(&mut self, tab_ids: &HashSet<u32>) {
        self.pending_by_tab_id.retain(|k, _| tab_ids.contains(k));
    }

    pub fn remove_all(&mut self) {
        self.pending_by_tab_id.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batching_is_on_unless_turned_off() {
        assert!(RemoteOutputTuning::batching_enabled(None));
        assert!(RemoteOutputTuning::batching_enabled(Some("1")));
        assert!(RemoteOutputTuning::batching_enabled(Some("yes")));
        for off in ["0", "false", " OFF ", "False"] {
            assert!(!RemoteOutputTuning::batching_enabled(Some(off)), "{off}");
        }
    }

    #[test]
    fn trim_retained_text_keeps_suffix_within_byte_limit() {
        let oversized = "a".repeat(RemoteOutputTuning::MAX_RETAINED_BYTES + 10);
        let trimmed = RemoteOutputTuning::trim_retained_text(&oversized);
        assert_eq!(trimmed.len(), RemoteOutputTuning::MAX_RETAINED_BYTES);
        assert_eq!(trimmed, "a".repeat(RemoteOutputTuning::MAX_RETAINED_BYTES));
    }

    #[test]
    fn trim_retained_text_leaves_short_input_alone() {
        assert_eq!(RemoteOutputTuning::trim_retained_text("héllo"), "héllo");
    }

    #[test]
    fn trim_retained_text_repairs_split_character() {
        // 3 byte characters: 200_000 is not a multiple of 3, so the cut lands inside one.
        let input = "€".repeat(70_000);
        let trimmed = RemoteOutputTuning::trim_retained_text(&input);
        assert!(trimmed.starts_with('\u{FFFD}'));
        assert!(trimmed.ends_with('€'));
    }

    #[test]
    fn cap_incoming_frame_respects_frame_limit() {
        let data = vec![0x41u8; RemoteOutputTuning::MAX_INCOMING_FRAME_BYTES + 10];
        let capped = RemoteOutputTuning::cap_incoming_frame(&data);
        assert_eq!(capped.len(), RemoteOutputTuning::MAX_INCOMING_FRAME_BYTES);
    }

    #[test]
    fn cap_snapshot_keeps_suffix() {
        let mut data = vec![0u8; 10];
        data.extend(vec![1u8; RemoteOutputTuning::MAX_RETAINED_BYTES]);
        let capped = RemoteOutputTuning::cap_snapshot(&data);
        assert_eq!(capped.len(), RemoteOutputTuning::MAX_RETAINED_BYTES);
        assert!(capped.iter().all(|b| *b == 1));
    }

    #[test]
    fn tuning_constants_match_swift() {
        assert_eq!(RemoteOutputTuning::MAX_RETAINED_BYTES, 200_000);
        assert_eq!(RemoteOutputTuning::MAX_INCOMING_FRAME_BYTES, 65536);
        assert_eq!(RemoteOutputTuning::MAX_PENDING_BYTES_PER_TAB, 32768);
        assert_eq!(RemoteOutputTuning::FLUSH_INTERVAL.as_millis(), 33);
    }

    #[test]
    fn pending_buffer_drain_all_returns_sorted_pairs() {
        let mut buffer: RemotePendingOutputBuffer<Vec<u8>> = RemotePendingOutputBuffer::new();
        buffer.append(b"b".to_vec(), 2, |existing, chunk| existing.extend(chunk));
        buffer.append(b"a".to_vec(), 1, |existing, chunk| existing.extend(chunk));

        let drained = buffer.drain_all(true);
        assert_eq!(
            drained.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
            vec![1, 2]
        );
        assert_eq!(
            drained
                .iter()
                .map(|(_, c)| String::from_utf8_lossy(c).into_owned())
                .collect::<Vec<_>>(),
            vec!["a", "b"]
        );
        assert!(buffer.is_empty());
    }

    #[test]
    fn pending_buffer_retain_drops_hidden_tabs() {
        let mut buffer: RemotePendingOutputBuffer<String> = RemotePendingOutputBuffer::new();
        buffer.append("one".into(), 1, |e, c| e.push_str(&c));
        buffer.append("two".into(), 2, |e, c| e.push_str(&c));

        buffer.retain_only(&HashSet::from([2]));

        assert!(buffer.get(1).is_none());
        assert_eq!(buffer.get(2).map(String::as_str), Some("two"));
    }

    #[test]
    fn pending_buffer_merges_and_drains_one_tab() {
        let mut buffer: RemotePendingOutputBuffer<String> = RemotePendingOutputBuffer::new();
        buffer.append("ab".into(), 5, |e, c| e.push_str(&c));
        buffer.append("cd".into(), 5, |e, c| e.push_str(&c));
        assert_eq!(buffer.tab_ids(), vec![5]);
        assert_eq!(buffer.drain(5).as_deref(), Some("abcd"));
        assert_eq!(buffer.drain(5), None);
        buffer.append("x".into(), 1, |e, c| e.push_str(&c));
        buffer.remove_all();
        assert!(buffer.is_empty());
    }
}
