//! Performance optimization structures: adaptive polling, dirty tracking, output batching.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
            // Very idle: can wait longer
            16 // ~60fps
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

/// Tracks whether the grid needs a redraw. In production the tracker is only
/// ever driven all-or-nothing (mark_all_dirty / clear), so this is a full-dirty
/// flag plus the current row count; dirty_count() reports 0 or `rows`.
pub struct DirtyRowTracker {
    /// Number of rows being tracked
    rows: AtomicU64,
    /// Whether all rows should be considered dirty
    full_dirty: AtomicBool,
}

impl DirtyRowTracker {
    pub fn new(rows: usize) -> Self {
        Self {
            rows: AtomicU64::new(rows as u64),
            full_dirty: AtomicBool::new(true), // Start fully dirty
        }
    }

    /// Mark all rows as dirty
    pub fn mark_all_dirty(&self) {
        self.full_dirty.store(true, Ordering::Relaxed);
    }

    /// Clear the dirty flag
    pub fn clear(&self) {
        self.full_dirty.store(false, Ordering::Relaxed);
    }

    /// Count of dirty rows (0 when clear, `rows` when fully dirty)
    pub fn dirty_count(&self) -> usize {
        if self.full_dirty.load(Ordering::Relaxed) {
            self.rows.load(Ordering::Relaxed) as usize
        } else {
            0
        }
    }

    /// Update the tracked row count (e.g. on resize); forces a full redraw.
    pub fn set_rows(&self, rows: usize) {
        self.rows.store(rows as u64, Ordering::Relaxed);
        self.full_dirty.store(true, Ordering::Relaxed);
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

// (DirtyRowTracker is now a simple full-dirty flag + row count; its former
// per-row bitmap tests were removed with the bitmap.)
