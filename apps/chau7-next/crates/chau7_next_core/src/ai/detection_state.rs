//! Port of `apps/chau7-macos/Sources/Chau7Core/AIDetectionState.swift`.
//!
//! Pure state machine for AI tool detection in a terminal session: scanning,
//! detected, cooldown after prompt return, re-detection locked to the same
//! tool, and restoration from persisted tab state.
//!
//! Times are `f64` seconds (Swift `Date`, any consistent clock); callers pass
//! `now` explicitly, use [`now_secs`] for wall-clock time.
//!
//! One known difference: Swift counts grapheme clusters for the sliding
//! buffer caps (2048 and 256); this port counts Unicode scalar values.

use super::resume::normalize_provider_name;
use std::time::{SystemTime, UNIX_EPOCH};

/// Detection lifecycle phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// No AI tool detected. Scanning output and commands for patterns.
    Scanning,
    /// An AI tool is actively detected. Output scanning is paused.
    Detected,
    /// After prompt return, within the re-detection window. Only the
    /// previously detected tool can be re-detected from output.
    Redetecting,
    /// AI metadata restored from persisted tab state (dimmed logo in UI).
    Restored,
}

/// Current wall-clock time in seconds since the Unix epoch.
pub fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Don't clear detection within this many seconds of the last detection event.
const COOLDOWN_SECONDS: f64 = 3.0;
/// After entering `Redetecting`, keep scanning output for this many seconds.
const REDETECTION_WINDOW_SECONDS: f64 = 5.0;
/// Maximum character count of the sliding buffer tail kept across chunks.
const BUFFER_TAIL_CAPACITY: usize = 256;
/// Maximum bytes of a chunk that is decoded, and characters of the haystack.
const CHUNK_LIMIT: usize = 2048;

/// Per-session AI tool detection state (`AIDetectionState`).
#[derive(Debug, Clone, PartialEq)]
pub struct AiDetectionState {
    current_app: Option<String>,
    last_detected_app: Option<String>,
    phase: Phase,
    utf8_decode_failures: u32,
    detected_at: Option<f64>,
    redetection_deadline: Option<f64>,
    sliding_buffer_tail: String,
}

impl Default for AiDetectionState {
    fn default() -> Self {
        Self::new()
    }
}

impl AiDetectionState {
    pub fn new() -> Self {
        Self {
            current_app: None,
            last_detected_app: None,
            phase: Phase::Scanning,
            utf8_decode_failures: 0,
            detected_at: None,
            redetection_deadline: None,
            sliding_buffer_tail: String::new(),
        }
    }

    /// The currently active AI app name (for example "Claude"), `None` when scanning.
    pub fn current_app(&self) -> Option<&str> {
        self.current_app.as_deref()
    }

    /// Whether the current state came from persistence rather than live detection.
    pub fn is_restored(&self) -> bool {
        self.phase == Phase::Restored
    }

    /// The last live-detected app name. Survives phase transitions.
    pub fn last_detected_app(&self) -> Option<&str> {
        self.last_detected_app.as_deref()
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    /// Number of times UTF-8 decoding failed in [`Self::prepare_haystack`].
    pub fn utf8_decode_failures(&self) -> u32 {
        self.utf8_decode_failures
    }

    /// Appends `chunk` to the sliding buffer and returns the lowercased
    /// combined string (up to 2048 characters) to run pattern matching
    /// against. Returns `None` in the `Detected` phase, after the
    /// re-detection window expired (which also moves to `Scanning`).
    pub fn prepare_haystack(&mut self, chunk: &[u8], now: f64) -> Option<String> {
        if self.phase == Phase::Detected {
            return None;
        }

        if self.phase == Phase::Redetecting
            && let Some(deadline) = self.redetection_deadline
            && now >= deadline
        {
            self.phase = Phase::Scanning;
            self.current_app = None;
            self.detected_at = None;
            self.redetection_deadline = None;
            return None;
        }

        let prefix = &chunk[..chunk.len().min(CHUNK_LIMIT)];
        let chunk_string: String = match std::str::from_utf8(prefix) {
            Ok(s) => s.to_string(),
            Err(_) => {
                self.utf8_decode_failures += 1;
                String::from_utf8_lossy(prefix).into_owned()
            }
        };

        let combined = format!("{}{}", self.sliding_buffer_tail, chunk_string);
        let combined_len = combined.chars().count();
        let haystack: String = if combined_len > CHUNK_LIMIT {
            combined.chars().skip(combined_len - CHUNK_LIMIT).collect()
        } else {
            combined
        };

        let chunk_len = chunk_string.chars().count();
        self.sliding_buffer_tail = chunk_string
            .chars()
            .skip(chunk_len.saturating_sub(BUFFER_TAIL_CAPACITY))
            .collect();

        Some(haystack.to_lowercase())
    }

    /// Called when pattern matching completes on the prepared haystack.
    /// `authoritative_app_name` is an already established tool identity;
    /// output matching only confirms it when it agrees with that provider.
    /// Returns true if the state changed.
    pub fn handle_output_match(
        &mut self,
        app_name: Option<&str>,
        authoritative_app_name: Option<&str>,
        now: f64,
    ) -> bool {
        let Some(app_name) = app_name else {
            return false;
        };
        if !Self::should_accept_output_match(Some(app_name), authoritative_app_name) {
            return false;
        }

        match self.phase {
            Phase::Scanning => {
                // Output matching can only re-confirm the last tool, never
                // switch to a different one (only command detection can).
                if let Some(last) = &self.last_detected_app
                    && app_name != last
                {
                    return false;
                }
                self.set_detected(app_name, now)
            }
            Phase::Redetecting => {
                if self.last_detected_app.as_deref() != Some(app_name) {
                    return false;
                }
                self.set_detected(app_name, now)
            }
            // Live detection overrides restoration.
            Phase::Restored => self.set_detected(app_name, now),
            Phase::Detected => false,
        }
    }

    /// Called when a command line matches a known AI tool. Always overrides
    /// the current state. Returns true if the state changed.
    pub fn handle_command(&mut self, app_name: Option<&str>, now: f64) -> bool {
        match app_name {
            Some(app_name) => self.set_detected(app_name, now),
            None => false,
        }
    }

    /// Called when the shell prompt returns (AI tool exited to the prompt).
    /// No-op within the cooldown of the last detection. Returns true if the
    /// state changed.
    pub fn handle_prompt_return(&mut self, now: f64) -> bool {
        if self.phase != Phase::Detected && self.phase != Phase::Restored {
            return false;
        }
        if self.current_app.is_none() {
            return false;
        }

        // Restored sessions stay restored (dimmed logo); only the app clears
        // so output scanning can detect a new live tool.
        if self.phase == Phase::Restored {
            self.current_app = None;
            return true;
        }

        if let Some(detected_at) = self.detected_at
            && now - detected_at < COOLDOWN_SECONDS
        {
            return false;
        }

        if self.last_detected_app.is_some() {
            self.phase = Phase::Redetecting;
            self.redetection_deadline = Some(now + REDETECTION_WINDOW_SECONDS);
        } else {
            self.phase = Phase::Scanning;
        }
        self.current_app = None;
        self.detected_at = None;
        self.sliding_buffer_tail.clear();
        true
    }

    /// Called when restoring AI metadata from persisted tab state. Does not
    /// set `last_detected_app`, so restored sessions do not lock re-detection.
    pub fn handle_restore(&mut self, app_name: &str) -> bool {
        self.current_app = Some(app_name.to_string());
        self.phase = Phase::Restored;
        self.detected_at = None;
        true
    }

    /// Called when an exit/logout/quit command is detected. Clears detection
    /// immediately with no cooldown. Returns true if the state changed.
    pub fn handle_exit(&mut self) -> bool {
        if self.current_app.is_none() {
            return false;
        }
        self.current_app = None;
        self.phase = Phase::Scanning;
        self.detected_at = None;
        self.redetection_deadline = None;
        self.sliding_buffer_tail.clear();
        true
    }

    /// `AIDetectionState.shouldAcceptOutputMatch`.
    pub fn should_accept_output_match(
        matched_app_name: Option<&str>,
        authoritative_app_name: Option<&str>,
    ) -> bool {
        let Some(matched) = matched_app_name else {
            return false;
        };
        let Some(authoritative) = authoritative_app_name else {
            return true;
        };
        match (
            normalize_provider_name(matched),
            normalize_provider_name(authoritative),
        ) {
            (Some(m), Some(a)) => m == a,
            _ => true,
        }
    }

    fn set_detected(&mut self, app_name: &str, now: f64) -> bool {
        self.current_app = Some(app_name.to_string());
        self.last_detected_app = Some(app_name.to_string());
        self.phase = Phase::Detected;
        self.detected_at = Some(now);
        self.redetection_deadline = None;
        self.sliding_buffer_tail.clear();
        true
    }

    /// Creates a state in `Redetecting` for tests (`makeRedetecting`).
    #[cfg(test)]
    fn make_redetecting(last_tool: &str, deadline: f64) -> Self {
        let mut state = Self::new();
        state.last_detected_app = Some(last_tool.to_string());
        state.phase = Phase::Redetecting;
        state.redetection_deadline = Some(deadline);
        state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn force_redetecting(last_tool: &str) -> AiDetectionState {
        AiDetectionState::make_redetecting(last_tool, now_secs() + 5.0)
    }

    fn om(s: &mut AiDetectionState, name: Option<&str>) -> bool {
        s.handle_output_match(name, None, now_secs())
    }

    // MARK: Initial state

    #[test]
    fn initial_state() {
        let state = AiDetectionState::new();
        assert_eq!(state.current_app(), None);
        assert_eq!(state.last_detected_app(), None);
        assert_eq!(state.phase(), Phase::Scanning);
        assert!(!state.is_restored());
        assert_eq!(state.utf8_decode_failures(), 0);
    }

    // MARK: Command detection

    #[test]
    fn handle_command_sets_detected() {
        let mut state = AiDetectionState::new();
        assert!(state.handle_command(Some("Claude"), now_secs()));
        assert_eq!(state.current_app(), Some("Claude"));
        assert_eq!(state.phase(), Phase::Detected);
        assert_eq!(state.last_detected_app(), Some("Claude"));
        assert!(!state.is_restored());
    }

    #[test]
    fn handle_command_nil_is_no_op() {
        let mut state = AiDetectionState::new();
        assert!(!state.handle_command(None, now_secs()));
        assert_eq!(state.current_app(), None);
        assert_eq!(state.phase(), Phase::Scanning);
    }

    #[test]
    fn handle_command_overrides_restored() {
        let mut state = AiDetectionState::new();
        state.handle_restore("Codex");
        assert!(state.is_restored());
        state.handle_command(Some("Claude"), now_secs());
        assert_eq!(state.current_app(), Some("Claude"));
        assert_eq!(state.phase(), Phase::Detected);
        assert!(!state.is_restored());
    }

    // MARK: Output detection

    #[test]
    fn handle_output_match_from_scanning() {
        let mut state = AiDetectionState::new();
        assert!(om(&mut state, Some("Gemini")));
        assert_eq!(state.current_app(), Some("Gemini"));
        assert_eq!(state.phase(), Phase::Detected);
    }

    #[test]
    fn handle_output_match_nil_is_no_op() {
        let mut state = AiDetectionState::new();
        assert!(!om(&mut state, None));
        assert_eq!(state.phase(), Phase::Scanning);
    }

    #[test]
    fn handle_output_match_overrides_restored() {
        let mut state = AiDetectionState::new();
        state.handle_restore("Codex");
        om(&mut state, Some("Claude"));
        assert_eq!(state.current_app(), Some("Claude"));
        assert!(!state.is_restored());
    }

    #[test]
    fn handle_output_match_rejects_different_provider_when_tool_already_known() {
        let mut state = AiDetectionState::new();
        state.handle_restore("Codex");
        let changed = state.handle_output_match(Some("Claude"), Some("Codex"), now_secs());
        assert!(!changed);
        assert_eq!(state.current_app(), Some("Codex"));
        assert!(state.is_restored());
    }

    #[test]
    fn handle_output_match_accepts_same_provider_when_tool_already_known() {
        let mut state = AiDetectionState::new();
        let changed = state.handle_output_match(Some("Codex"), Some("Codex"), now_secs());
        assert!(changed);
        assert_eq!(state.current_app(), Some("Codex"));
        assert_eq!(state.phase(), Phase::Detected);
    }

    // MARK: Prompt return

    #[test]
    fn prompt_return_within_cooldown_is_no_op() {
        let mut state = AiDetectionState::new();
        state.handle_command(Some("Claude"), now_secs());
        assert!(!state.handle_prompt_return(now_secs()));
        assert_eq!(state.current_app(), Some("Claude"));
        assert_eq!(state.phase(), Phase::Detected);
    }

    #[test]
    fn prompt_return_after_cooldown_transitions_to_redetecting() {
        let mut state = AiDetectionState::new();
        state.handle_command(Some("Claude"), now_secs());
        assert!(state.handle_prompt_return(now_secs() + 5.0));
        assert_eq!(state.current_app(), None);
        assert_eq!(state.phase(), Phase::Redetecting);
        assert_eq!(state.last_detected_app(), Some("Claude"));
    }

    #[test]
    fn prompt_return_from_scanning_is_no_op() {
        let mut state = AiDetectionState::new();
        assert!(!state.handle_prompt_return(now_secs()));
        assert_eq!(state.phase(), Phase::Scanning);
    }

    // MARK: Re-detection

    #[test]
    fn redetection_locked_to_same_tool() {
        let mut state = force_redetecting("Claude");
        assert!(om(&mut state, Some("Claude")));
        assert_eq!(state.current_app(), Some("Claude"));
        assert_eq!(state.phase(), Phase::Detected);
    }

    #[test]
    fn redetection_rejects_different_tool() {
        let mut state = force_redetecting("Claude");
        assert!(!om(&mut state, Some("Codex")));
        assert_eq!(state.current_app(), None);
        assert_eq!(state.phase(), Phase::Redetecting);
    }

    #[test]
    fn redetection_window_exhaustion() {
        let t0 = 1000.0;
        let mut state = AiDetectionState::make_redetecting("Claude", t0 + 1.0);
        let chunk = b"some random output";
        assert!(state.prepare_haystack(chunk, t0 + 0.5).is_some());
        assert_eq!(state.phase(), Phase::Redetecting);

        assert!(state.prepare_haystack(chunk, t0 + 2.0).is_none());
        assert_eq!(state.phase(), Phase::Scanning);
        assert_eq!(state.current_app(), None);
    }

    #[test]
    fn command_overrides_redetection() {
        let mut state = force_redetecting("Claude");
        state.handle_command(Some("Codex"), now_secs());
        assert_eq!(state.current_app(), Some("Codex"));
        assert_eq!(state.phase(), Phase::Detected);
    }

    // MARK: Restoration

    #[test]
    fn handle_restore() {
        let mut state = AiDetectionState::new();
        assert!(state.handle_restore("Claude"));
        assert_eq!(state.current_app(), Some("Claude"));
        assert!(state.is_restored());
        assert_eq!(state.phase(), Phase::Restored);
        assert_eq!(state.last_detected_app(), None);
    }

    #[test]
    fn prompt_return_from_restored_keeps_dimmed_logo() {
        let mut state = AiDetectionState::new();
        state.handle_restore("Claude");
        assert!(state.is_restored());
        assert!(state.handle_prompt_return(now_secs()));
        assert_eq!(state.current_app(), None);
        assert!(state.is_restored());
        assert_eq!(state.phase(), Phase::Restored);
    }

    #[test]
    fn restored_session_can_be_overridden_by_output_after_prompt_return() {
        let mut state = AiDetectionState::new();
        state.handle_restore("Codex");
        state.handle_prompt_return(now_secs());
        assert!(state.is_restored());
        assert_eq!(state.current_app(), None);

        om(&mut state, Some("Claude"));
        assert!(!state.is_restored());
        assert_eq!(state.current_app(), Some("Claude"));
        assert_eq!(state.phase(), Phase::Detected);
    }

    // MARK: Exit

    #[test]
    fn handle_exit() {
        let mut state = AiDetectionState::new();
        state.handle_command(Some("Claude"), now_secs());
        assert!(state.handle_exit());
        assert_eq!(state.current_app(), None);
        assert_eq!(state.phase(), Phase::Scanning);
    }

    #[test]
    fn handle_exit_from_scanning_is_no_op() {
        let mut state = AiDetectionState::new();
        assert!(!state.handle_exit());
    }

    #[test]
    fn handle_exit_preserves_last_detected_app() {
        let mut state = AiDetectionState::new();
        state.handle_command(Some("Claude"), now_secs());
        state.handle_exit();
        assert_eq!(state.last_detected_app(), Some("Claude"));
    }

    // MARK: Sliding buffer

    #[test]
    fn prepare_haystack_returns_nil_when_detected() {
        let mut state = AiDetectionState::new();
        state.handle_command(Some("Claude"), now_secs());
        assert!(state.prepare_haystack(b"hello world", now_secs()).is_none());
    }

    #[test]
    fn prepare_haystack_returns_lowercased_string() {
        let mut state = AiDetectionState::new();
        assert_eq!(
            state.prepare_haystack(b"Hello WORLD", now_secs()),
            Some("hello world".to_string())
        );
    }

    #[test]
    fn prepare_haystack_stitches_across_chunks() {
        let mut state = AiDetectionState::new();
        let _ = state.prepare_haystack("╭─ clau".as_bytes(), now_secs());
        let result = state.prepare_haystack(b"de code", now_secs()).unwrap();
        assert!(
            result.contains("claude code") || result.contains("clau") && result.contains("de code")
        );
    }

    // MARK: UTF-8 safety

    #[test]
    fn prepare_haystack_handles_invalid_utf8() {
        let mut state = AiDetectionState::new();
        let mut data = vec![0xFF, 0xC0];
        data.extend_from_slice(b"claude code");
        let result = state.prepare_haystack(&data, now_secs());
        assert!(result.as_deref().unwrap().contains("claude code"));
        assert_eq!(state.utf8_decode_failures(), 1);
    }

    #[test]
    fn prepare_haystack_multi_byte_character_across_chunks() {
        let mut state = AiDetectionState::new();
        let _ = state.prepare_haystack("╭─ claude".as_bytes(), now_secs());
        let result = state
            .prepare_haystack(b" code detected", now_secs())
            .unwrap();
        assert!(result.contains("╭─ claude"));
        assert_eq!(state.utf8_decode_failures(), 0);
    }

    #[test]
    fn utf8_decode_failure_count_accumulates() {
        let mut state = AiDetectionState::new();
        let invalid = [0xFF, 0xFE, 0xFD];
        for _ in 0..3 {
            let _ = state.prepare_haystack(&invalid, now_secs());
        }
        assert_eq!(state.utf8_decode_failures(), 3);
    }

    // MARK: Full lifecycle

    #[test]
    fn full_lifecycle() {
        let mut state = AiDetectionState::new();
        assert_eq!(state.phase(), Phase::Scanning);

        state.handle_command(Some("Claude"), now_secs());
        assert_eq!(state.phase(), Phase::Detected);
        assert_eq!(state.current_app(), Some("Claude"));

        assert!(!state.handle_prompt_return(now_secs()));
        assert_eq!(state.phase(), Phase::Detected);

        state.handle_exit();
        assert_eq!(state.phase(), Phase::Scanning);
        assert_eq!(state.current_app(), None);
        assert_eq!(state.last_detected_app(), Some("Claude"));

        om(&mut state, Some("Claude"));
        assert_eq!(state.phase(), Phase::Detected);

        state.handle_restore("Codex");
        assert!(state.is_restored());
        assert_eq!(state.current_app(), Some("Codex"));

        om(&mut state, Some("Aider"));
        assert!(!state.is_restored());
        assert_eq!(state.current_app(), Some("Aider"));
    }

    #[test]
    fn cooldown_then_redetection_with_injectable_clock() {
        let mut state = AiDetectionState::new();
        let t0 = 1000.0;

        state.handle_command(Some("Claude"), t0);
        assert!(!state.handle_prompt_return(t0 + 1.0));
        assert_eq!(state.phase(), Phase::Detected);

        assert!(state.handle_prompt_return(t0 + 4.0));
        assert_eq!(state.phase(), Phase::Redetecting);

        let haystack = state.prepare_haystack("╭─ claude code".as_bytes(), t0 + 5.0);
        assert!(haystack.is_some());
        assert!(state.handle_output_match(Some("Claude"), None, t0 + 5.0));
        assert_eq!(state.phase(), Phase::Detected);
        assert_eq!(state.current_app(), Some("Claude"));
    }

    // MARK: Redetection deadline boundary

    #[test]
    fn redetection_exactly_at_deadline_expires() {
        let deadline = 1001.0;
        let mut state = AiDetectionState::make_redetecting("Claude", deadline);
        assert!(state.prepare_haystack(b"some output", deadline).is_none());
        assert_eq!(state.phase(), Phase::Scanning);
    }

    #[test]
    fn redetection_one_nanosecond_before_deadline_still_active() {
        let deadline = 1001.0;
        let mut state = AiDetectionState::make_redetecting("Claude", deadline);
        assert!(
            state
                .prepare_haystack(b"some output", deadline - 0.001)
                .is_some()
        );
        assert_eq!(state.phase(), Phase::Redetecting);
    }

    // MARK: Raw multi-byte byte split

    #[test]
    fn prepare_haystack_raw_byte_split_across_chunks() {
        let mut state = AiDetectionState::new();
        let chunk1 = [0xE2, 0x95];
        let mut chunk2 = vec![0xAD];
        chunk2.extend_from_slice("─ claude code".as_bytes());

        let result1 = state.prepare_haystack(&chunk1, now_secs());
        assert!(result1.is_some());
        assert_eq!(state.utf8_decode_failures(), 1);

        let result2 = state.prepare_haystack(&chunk2, now_secs());
        assert!(result2.unwrap().contains("claude code"));
    }

    // MARK: Extra branch coverage

    #[test]
    fn scanning_with_last_detected_rejects_other_tool() {
        let mut state = AiDetectionState::new();
        state.handle_command(Some("Claude"), now_secs());
        state.handle_exit();
        assert!(!om(&mut state, Some("ChatGPT")));
        assert_eq!(state.current_app(), None);
    }

    #[test]
    fn haystack_is_capped_at_2048_characters() {
        let mut state = AiDetectionState::new();
        let big = "a".repeat(3000);
        let result = state.prepare_haystack(big.as_bytes(), now_secs()).unwrap();
        assert_eq!(result.chars().count(), 2048);
    }

    // MARK: AIEvent tests that live next to the detection tests in Swift
    // are in `event.rs`.
}
