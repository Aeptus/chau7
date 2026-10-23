//! Performance optimization structures: adaptive polling, dirty tracking, output batching.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use parking_lot::Mutex;

// ============================================================================
// Adaptive polling
// ============================================================================

/// Adaptive polling rate controller.
/// Adjusts polling behavior based on terminal activity to reduce CPU usage when idle.
pub struct AdaptivePoller {
    /// Last time data was received
    last_data_time: Mutex<Instant>,
    /// Current activity level (0.0 = idle, 1.0 = very active)
    activity_level: AtomicU64, // Stored as fixed-point * 1000
    /// Consecutive idle polls
    idle_streak: AtomicU64,
    /// Consecutive active polls
    active_streak: AtomicU64,
}

impl AdaptivePoller {
    pub fn new() -> Self {
        Self {
            last_data_time: Mutex::new(Instant::now()),
            activity_level: AtomicU64::new(500), // Start at 0.5
            idle_streak: AtomicU64::new(0),
            active_streak: AtomicU64::new(0),
        }
    }

    /// Record that data was received
    pub fn record_activity(&self, bytes: usize) {
        *self.last_data_time.lock() = Instant::now();
        self.idle_streak.store(0, Ordering::Relaxed);
        self.active_streak.fetch_add(1, Ordering::Relaxed);

        // Increase activity level based on data volume
        let current = self.activity_level.load(Ordering::Relaxed);
        let boost = (bytes as u64).min(100) * 5; // More data = bigger boost
        let new_level = (current + boost).min(1000);
        self.activity_level.store(new_level, Ordering::Relaxed);
    }

    /// Record an idle poll (no data)
    pub fn record_idle(&self) {
        self.active_streak.store(0, Ordering::Relaxed);
        self.idle_streak.fetch_add(1, Ordering::Relaxed);

        // Decay activity level
        let current = self.activity_level.load(Ordering::Relaxed);
        let new_level = current.saturating_sub(10); // Slow decay
        self.activity_level.store(new_level, Ordering::Relaxed);
    }

    /// Get suggested poll timeout in milliseconds.
    /// Returns shorter timeout when active, longer when idle.
    pub fn suggested_timeout_ms(&self) -> u32 {
        let idle_streak = self.idle_streak.load(Ordering::Relaxed);
        let activity = self.activity_level.load(Ordering::Relaxed);

        if activity > 800 {
            // Very active: poll immediately (0ms timeout for non-blocking)
            0
        } else if activity > 500 {
            // Moderately active: short timeout
            1
        } else if idle_streak > 100 {
            // Very idle: let the PTY reader wake us when data arrives. The
            // caller's timeout is still an upper bound, so this does not add
            // output latency; it removes the 60 Hz wake-up tax paid by
            // dormant terminals.
            200
        } else if idle_streak > 10 {
            // Somewhat idle
            8
        } else {
            // Default
            2
        }
    }

    /// Check if we should skip this poll cycle entirely (aggressive power saving)
    pub fn should_skip_poll(&self) -> bool {
        let idle_streak = self.idle_streak.load(Ordering::Relaxed);
        // After 1000 idle polls (~16 seconds at 60fps), skip every other poll
        idle_streak > 1000 && idle_streak.is_multiple_of(2)
    }

    /// Get activity level as percentage (0-100)
    pub fn activity_percent(&self) -> u8 {
        (self.activity_level.load(Ordering::Relaxed) / 10) as u8
    }
}

impl Default for AdaptivePoller {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================================
// Dirty row tracking
// ============================================================================

/// Generation-based viewport damage tracker.
///
/// Every viewport row records the last generation in which it changed. A
/// renderer asks for rows newer than its own generation, so multiple views of
/// the same terminal can consume snapshots independently without one view
/// clearing damage before another sees it.
pub struct DirtyRowTracker {
    state: Mutex<DirtyRowState>,
}

#[derive(Debug)]
struct DirtyRowState {
    generation: u64,
    row_generations: Vec<u64>,
    force_full: bool,
    reported_generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirtyRowsSince {
    pub generation: u64,
    pub rows: Vec<usize>,
    pub full_refresh: bool,
}

impl DirtyRowTracker {
    pub fn new(rows: usize) -> Self {
        Self {
            state: Mutex::new(DirtyRowState {
                generation: 0,
                row_generations: vec![0; rows],
                force_full: true,
                reported_generation: 0,
            }),
        }
    }

    /// Request a full refresh on the next snapshot. Repeated invalidations
    /// coalesce and do not create artificial generations.
    pub fn mark_all_dirty(&self) {
        self.state.lock().force_full = true;
    }

    /// Clear only the diagnostic dirty-count baseline. Consumer generations
    /// are never cleared globally.
    pub fn clear(&self) {
        let mut state = self.state.lock();
        state.reported_generation = state.generation;
    }

    /// Count of rows changed since the diagnostic baseline.
    pub fn dirty_count(&self) -> usize {
        let state = self.state.lock();
        if state.force_full {
            return state.row_generations.len();
        }
        state
            .row_generations
            .iter()
            .filter(|generation| **generation > state.reported_generation)
            .count()
    }

    /// Update the tracked row count (e.g. on resize); forces a full redraw.
    pub fn set_rows(&self, rows: usize) {
        let mut state = self.state.lock();
        if state.row_generations.len() != rows {
            state.row_generations.resize(rows, 0);
        }
        state.force_full = true;
    }

    /// Merge Alacritty's damage accumulated since its last reset, then return
    /// the rows required to advance `consumer_generation` to the current grid.
    pub fn record_and_snapshot(
        &self,
        rows: usize,
        damaged_rows: &[usize],
        terminal_reported_full_damage: bool,
        consumer_generation: u64,
    ) -> DirtyRowsSince {
        let mut state = self.state.lock();
        if state.row_generations.len() != rows {
            state.row_generations.resize(rows, 0);
            state.force_full = true;
        }

        let needs_full = state.force_full || terminal_reported_full_damage;
        let has_partial_damage = damaged_rows.iter().any(|row| *row < rows);
        if needs_full || has_partial_damage {
            state.generation = state.generation.wrapping_add(1).max(1);
            let generation = state.generation;
            if needs_full {
                state.row_generations.fill(generation);
            } else {
                for row in damaged_rows.iter().copied().filter(|row| *row < rows) {
                    state.row_generations[row] = generation;
                }
            }
            state.force_full = false;
        }

        let generation = state.generation;
        let consumer_is_invalid = consumer_generation == 0 || consumer_generation > generation;
        let changed_rows: Vec<usize> = if consumer_is_invalid {
            (0..rows).collect()
        } else {
            state
                .row_generations
                .iter()
                .enumerate()
                .filter_map(|(row, changed_at)| (*changed_at > consumer_generation).then_some(row))
                .collect()
        };
        DirtyRowsSince {
            generation,
            full_refresh: changed_rows.len() == rows,
            rows: changed_rows,
        }
    }
}

impl Default for DirtyRowTracker {
    fn default() -> Self {
        Self::new(24) // Default terminal height
    }
}

// ============================================================================
// Output batching
// ============================================================================

// Output buffer with batching support.

#[cfg(test)]
mod dirty_row_tests {
    use super::*;

    #[test]
    fn consumers_advance_independently_across_generations() {
        let tracker = DirtyRowTracker::new(4);
        let first = tracker.record_and_snapshot(4, &[], false, 0);
        assert!(first.full_refresh);
        assert_eq!(first.rows, vec![0, 1, 2, 3]);

        let second = tracker.record_and_snapshot(4, &[2], false, first.generation);
        assert_eq!(second.rows, vec![2]);
        assert!(!second.full_refresh);

        let lagging = tracker.record_and_snapshot(4, &[], false, first.generation);
        assert_eq!(lagging.rows, vec![2]);
        assert_eq!(lagging.generation, second.generation);
    }

    #[test]
    fn resize_and_explicit_invalidation_force_full_refresh() {
        let tracker = DirtyRowTracker::new(2);
        let first = tracker.record_and_snapshot(2, &[], false, 0);
        tracker.set_rows(3);
        let resized = tracker.record_and_snapshot(3, &[], false, first.generation);
        assert!(resized.full_refresh);
        assert_eq!(resized.rows, vec![0, 1, 2]);

        tracker.mark_all_dirty();
        let invalidated = tracker.record_and_snapshot(3, &[], false, resized.generation);
        assert!(invalidated.full_refresh);
    }
}

#[cfg(test)]
mod adaptive_poller_tests {
    use super::*;

    #[test]
    fn very_idle_terminals_use_blocking_timeout() {
        let poller = AdaptivePoller::new();
        for _ in 0..=100 {
            poller.record_idle();
        }

        assert_eq!(poller.suggested_timeout_ms(), 200);
    }

    #[test]
    fn activity_keeps_timeout_short_before_decay() {
        let poller = AdaptivePoller::new();
        poller.record_activity(1_024);

        assert_eq!(poller.suggested_timeout_ms(), 0);
        poller.record_idle();
        assert_eq!(poller.suggested_timeout_ms(), 0);
    }
}
