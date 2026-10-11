//! Timing of the resume prefill (`TerminalSessionModel.prefillInput`,
//! `flushPendingPrefillInputIfReady`): after a restore, the AI resume command
//! is typed at the first prompt. What is saved and restored (layout,
//! scrollback, AI sessions) is in [`crate::session_restore`].

/// Prefill attempts before waiting for the next prompt.
pub const PREFILL_MAX_RETRIES: u32 = 20;
/// After this many attempts the shell is considered started even without a
/// prompt mark.
pub const PREFILL_FORCE_READY_AFTER: u32 = 4;

/// Delay before prefill attempt `retry` (1-based): 0.3 s more each time, at
/// most 3 s.
pub fn prefill_retry_delay_secs(retry: u32) -> f64 {
    (0.3 + retry as f64 * 0.3).min(3.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefill_delays() {
        assert!((prefill_retry_delay_secs(1) - 0.6).abs() < 1e-9);
        assert_eq!(prefill_retry_delay_secs(20), 3.0);
    }
}
