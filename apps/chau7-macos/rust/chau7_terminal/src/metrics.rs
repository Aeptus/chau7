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
    activity_level: AtomicU64,  // Stored as fixed-point * 1000
    /// Consecutive idle polls
    idle_streak: AtomicU64,
    /// Consecutive active polls
    active_streak: AtomicU64,
}

impl AdaptivePoller {
    pub fn new() -> Self {
        Self {
            last_data_time: Mutex::new(Instant::now()),
            activity_level: AtomicU64::new(500),  // Start at 0.5
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
        let boost = (bytes as u64).min(100) * 5;  // More data = bigger boost
        let new_level = (current + boost).min(1000);
        self.activity_level.store(new_level, Ordering::Relaxed);
    }

    /// Record an idle poll (no data)
    pub fn record_idle(&self) {
        self.active_streak.store(0, Ordering::Relaxed);
        self.idle_streak.fetch_add(1, Ordering::Relaxed);

        // Decay activity level
        let current = self.activity_level.load(Ordering::Relaxed);
        let new_level = current.saturating_sub(10);  // Slow decay
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
            16  // ~60fps
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
        idle_streak > 1000 && idle_streak % 2 == 0
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

/// Dirty row tracker for partial updates.
/// Uses a bitmap to track which rows have been modified since last sync.
pub struct DirtyRowTracker {
    /// Bitmap of dirty rows (each bit represents one row)
    /// Supports up to 512 rows (8 * 64 bits)
    dirty_bits: [AtomicU64; 8],
    /// Number of rows being tracked
    rows: AtomicU64,
    /// Whether all rows should be considered dirty
    full_dirty: AtomicBool,
}

impl DirtyRowTracker {
    pub fn new(rows: usize) -> Self {
        Self {
            dirty_bits: Default::default(),
            rows: AtomicU64::new(rows as u64),
            full_dirty: AtomicBool::new(true),  // Start fully dirty
        }
    }

    /// Mark a specific row as dirty
    pub fn mark_dirty(&self, row: usize) {
        if row >= 512 {
            self.full_dirty.store(true, Ordering::Relaxed);
            return;
        }
        let word = row / 64;
        let bit = row % 64;
        self.dirty_bits[word].fetch_or(1 << bit, Ordering::Relaxed);
    }

    /// Mark a range of rows as dirty using word-level bitmask batching.
    /// Uses at most 3 atomic ops instead of N per-row ops.
    pub fn mark_range_dirty(&self, start: usize, end: usize) {
        let end = end.min(511);
        if start > end || start >= 512 {
            return;
        }
        let start_word = start / 64;
        let end_word = end / 64;

        if start_word == end_word {
            // Single word — compute mask covering [start_bit..=end_bit]
            let start_bit = start % 64;
            let end_bit = end % 64;
            let mask = if end_bit == 63 {
                !0u64 << start_bit
            } else {
                ((1u64 << (end_bit + 1)) - 1) & !((1u64 << start_bit) - 1)
            };
            self.dirty_bits[start_word].fetch_or(mask, Ordering::Relaxed);
        } else {
            // First partial word
            let start_bit = start % 64;
            self.dirty_bits[start_word].fetch_or(!0u64 << start_bit, Ordering::Relaxed);

            // Full middle words
            for word in (start_word + 1)..end_word {
                self.dirty_bits[word].store(u64::MAX, Ordering::Relaxed);
            }

            // Last partial word
            let end_bit = end % 64;
            let mask = if end_bit == 63 { !0u64 } else { (1u64 << (end_bit + 1)) - 1 };
            self.dirty_bits[end_word].fetch_or(mask, Ordering::Relaxed);
        }
    }

    /// Mark all rows as dirty
    pub fn mark_all_dirty(&self) {
        self.full_dirty.store(true, Ordering::Relaxed);
    }

    /// Check if a row is dirty
    pub fn is_dirty(&self, row: usize) -> bool {
        if self.full_dirty.load(Ordering::Relaxed) {
            return true;
        }
        if row >= 512 {
            return true;
        }
        let word = row / 64;
        let bit = row % 64;
        (self.dirty_bits[word].load(Ordering::Relaxed) & (1 << bit)) != 0
    }

    /// Get list of dirty row indices (for partial updates)
    pub fn get_dirty_rows(&self) -> Vec<usize> {
        if self.full_dirty.load(Ordering::Relaxed) {
            return (0..self.rows.load(Ordering::Relaxed) as usize).collect();
        }

        let mut dirty = Vec::new();
        let rows = self.rows.load(Ordering::Relaxed) as usize;
        for row in 0..rows.min(512) {
            if self.is_dirty(row) {
                dirty.push(row);
            }
        }
        dirty
    }

    /// Clear all dirty flags
    pub fn clear(&self) {
        self.full_dirty.store(false, Ordering::Relaxed);
        for bits in &self.dirty_bits {
            bits.store(0, Ordering::Relaxed);
        }
    }

    /// Get count of dirty rows
    pub fn dirty_count(&self) -> usize {
        if self.full_dirty.load(Ordering::Relaxed) {
            return self.rows.load(Ordering::Relaxed) as usize;
        }
        self.dirty_bits.iter()
            .map(|bits| bits.load(Ordering::Relaxed).count_ones() as usize)
            .sum()
    }

    /// Update row count (e.g., on resize)
    pub fn set_rows(&self, rows: usize) {
        self.rows.store(rows as u64, Ordering::Relaxed);
        self.mark_all_dirty();  // Resize requires full redraw
    }
}

impl Default for DirtyRowTracker {
    fn default() -> Self {
        Self::new(24)  // Default terminal height
    }
}

// ============================================================================
// Output batching
// ============================================================================

/// Output buffer with batching support.
/// Accumulates small outputs into larger batches to reduce FFI overhead.
/// Uses a single Mutex (buffer) + AtomicU64 for flush timestamp to avoid double-lock.
pub struct OutputBatcher {
    /// Accumulated output data
    buffer: Mutex<Vec<u8>>,
    /// Buffer capacity (pre-allocated)
    capacity: usize,
    /// Minimum batch size before flushing (unless timeout)
    min_batch_size: usize,
    /// Immutable baseline instant (set at construction)
    baseline: Instant,
    /// Last flush time as elapsed microseconds since baseline (atomic, no lock needed)
    last_flush_us: AtomicU64,
    /// Maximum time to hold data before flushing (microseconds)
    max_hold_us: u64,
}

impl OutputBatcher {
    pub fn new() -> Self {
        let now = Instant::now();
        Self {
            buffer: Mutex::new(Vec::with_capacity(32 * 1024)),  // 32KB initial capacity
            capacity: 32 * 1024,
            min_batch_size: 256,  // Batch at least 256 bytes
            baseline: now,
            last_flush_us: AtomicU64::new(0),
            max_hold_us: 2000,  // Max 2ms hold time
        }
    }

    /// Add data to the batch
    pub fn push(&self, data: &[u8]) {
        let mut buffer = self.buffer.lock();
        buffer.extend_from_slice(data);
    }

    /// Check if batch is ready to flush (single lock only)
    pub fn should_flush(&self) -> bool {
        let buffer = self.buffer.lock();
        if buffer.is_empty() {
            return false;
        }

        // Flush if buffer is large enough
        if buffer.len() >= self.min_batch_size {
            return true;
        }

        // Flush if held too long
        let now_us = self.baseline.elapsed().as_micros() as u64;
        let last_us = self.last_flush_us.load(Ordering::Relaxed);
        now_us.saturating_sub(last_us) >= self.max_hold_us
    }

    /// Flush and return the batched data (single lock only)
    pub fn flush(&self) -> Vec<u8> {
        let mut buffer = self.buffer.lock();
        self.last_flush_us.store(
            self.baseline.elapsed().as_micros() as u64,
            Ordering::Relaxed,
        );

        // Take the buffer and replace with a new one
        let mut new_buffer = Vec::with_capacity(self.capacity);
        std::mem::swap(&mut *buffer, &mut new_buffer);
        new_buffer
    }

    /// Get current buffer size
    pub fn len(&self) -> usize {
        self.buffer.lock().len()
    }

    /// Check if buffer is empty
    pub fn is_empty(&self) -> bool {
        self.buffer.lock().is_empty()
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dirty_range_single_word() {
        let tracker = DirtyRowTracker::new(80);
        tracker.clear();
        tracker.mark_range_dirty(2, 5);
        assert!(tracker.is_dirty(2));
        assert!(tracker.is_dirty(3));
        assert!(tracker.is_dirty(5));
        assert!(!tracker.is_dirty(1));
        assert!(!tracker.is_dirty(6));
        assert_eq!(tracker.dirty_count(), 4);
    }

    #[test]
    fn test_dirty_range_cross_word() {
        let tracker = DirtyRowTracker::new(200);
        tracker.clear();
        tracker.mark_range_dirty(60, 130);
        for row in 60..=130 {
            assert!(tracker.is_dirty(row), "row {} should be dirty", row);
        }
        assert!(!tracker.is_dirty(59));
        assert!(!tracker.is_dirty(131));
        assert_eq!(tracker.dirty_count(), 71);
    }

    #[test]
    fn test_dirty_range_full_word() {
        let tracker = DirtyRowTracker::new(128);
        tracker.clear();
        tracker.mark_range_dirty(0, 63);
        assert_eq!(tracker.dirty_count(), 64);
        for row in 0..64 {
            assert!(tracker.is_dirty(row));
        }
        assert!(!tracker.is_dirty(64));
    }
}
