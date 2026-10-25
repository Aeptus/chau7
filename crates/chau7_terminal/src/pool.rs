//! Memory pool for CellData buffers to reduce allocation overhead.

use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};

use parking_lot::Mutex;

use crate::types::CellData;

/// Global cell buffer pool for GridSnapshot memory reuse.
/// Using OnceLock for lazy thread-safe initialization.
static CELL_BUFFER_POOL: OnceLock<CellBufferPool> = OnceLock::new();

pub fn get_cell_buffer_pool() -> &'static CellBufferPool {
    // 16 buffers covers heavy multi-tab usage (5+ tabs with Metal rendering).
    // Each buffer is ~36KB (3000 cells × 12 bytes) → max ~576KB pool overhead.
    // Previously 4 buffers caused 98% miss rate in multi-tab scenarios.
    CELL_BUFFER_POOL.get_or_init(|| CellBufferPool::new(16))
}

/// Buffers larger than this are dropped instead of pooled.
///
/// The comment above sizes the pool for a *typical* grid (~3000 cells). But
/// `release` accepted any buffer while the pool had room, so a single transient
/// oversized layout was retained for the life of the process: a 2000x500 grid is
/// 1M cells, and 16 of those is roughly 190 MB pinned with no reclamation path
/// and no entry in any memory report. `CellBufferPool` is a process-lifetime
/// `OnceLock` with no `Drop`, so "for the life of the process" is literal.
///
/// The limit is set above any real working set (2000x500 is the Swift-side
/// clamp, so a *legitimate* full-size grid would be dropped rather than pooled —
/// accepted deliberately: re-allocating a buffer once is far cheaper than
/// pinning 190 MB forever, and the oversized case is rare).
const MAX_POOLED_CELLS: usize = 128 * 1024;

/// Memory pool for CellData buffers to reduce allocation overhead.
/// GridSnapshot creation is frequent during rendering; pooling buffers
/// avoids repeated allocations and deallocations.
pub struct CellBufferPool {
    /// Pool of available buffers (Vec<CellData>)
    pool: Mutex<Vec<Vec<CellData>>>,
    /// Maximum number of buffers to keep in pool
    max_pooled: usize,
    /// Statistics: total buffers acquired
    acquired: AtomicU64,
    /// Statistics: buffers returned to pool
    returned: AtomicU64,
    /// Statistics: new allocations (pool miss)
    allocated: AtomicU64,
    /// Statistics: buffers refused by the size cap and dropped. A non-zero value
    /// means the app really did see a grid larger than `MAX_POOLED_CELLS`.
    oversized_dropped: AtomicU64,
}

impl CellBufferPool {
    pub fn new(max_pooled: usize) -> Self {
        Self {
            pool: Mutex::new(Vec::with_capacity(max_pooled)),
            max_pooled,
            acquired: AtomicU64::new(0),
            returned: AtomicU64::new(0),
            allocated: AtomicU64::new(0),
            oversized_dropped: AtomicU64::new(0),
        }
    }

    /// Acquire a buffer from the pool, or allocate a new one.
    /// The buffer is cleared and has at least the requested capacity.
    pub fn acquire(&self, min_capacity: usize) -> Vec<CellData> {
        self.acquired.fetch_add(1, Ordering::Relaxed);

        let mut pool = self.pool.lock();
        // Try to find a buffer with sufficient capacity
        if let Some(idx) = pool.iter().position(|b| b.capacity() >= min_capacity) {
            let mut buffer = pool.swap_remove(idx);
            buffer.clear();
            return buffer;
        }
        // No suitable buffer in pool, allocate new
        drop(pool);
        self.allocated.fetch_add(1, Ordering::Relaxed);
        Vec::with_capacity(min_capacity)
    }

    /// Return a buffer to the pool for reuse.
    ///
    /// Oversized buffers are dropped rather than pooled — see
    /// `MAX_POOLED_CELLS` for why retaining them was a ~190 MB leak.
    pub fn release(&self, mut buffer: Vec<CellData>) {
        self.returned.fetch_add(1, Ordering::Relaxed);
        buffer.clear();

        if buffer.capacity() > MAX_POOLED_CELLS {
            self.oversized_dropped.fetch_add(1, Ordering::Relaxed);
            return;
        }

        let mut pool = self.pool.lock();
        if pool.len() < self.max_pooled {
            pool.push(buffer);
        }
        // If pool is full, buffer is dropped here
    }

    /// Get pool statistics for debugging
    pub fn stats(&self) -> (u64, u64, u64, usize) {
        let pool = self.pool.lock();
        (
            self.acquired.load(Ordering::Relaxed),
            self.returned.load(Ordering::Relaxed),
            self.allocated.load(Ordering::Relaxed),
            pool.len(),
        )
    }

    /// Count of buffers refused by `MAX_POOLED_CELLS`. Exposed so the memory
    /// report can show whether the cap is actually being hit in the field,
    /// rather than being an untested theoretical bound.
    pub fn oversized_dropped(&self) -> u64 {
        self.oversized_dropped.load(Ordering::Relaxed)
    }
}

impl Default for CellBufferPool {
    fn default() -> Self {
        Self::new(16) // Keep up to 16 buffers pooled (multi-tab friendly)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffer_with_capacity(n: usize) -> Vec<CellData> {
        Vec::with_capacity(n)
    }

    /// The bug: `release` accepted any buffer while the pool had room, so a
    /// single transient oversized layout stayed pinned for the life of the
    /// process. `CellBufferPool` is a process-lifetime `OnceLock` with no
    /// `Drop`, so 16 retained 1M-cell buffers is ~190 MB with no reclamation
    /// path and no entry in any memory report.
    #[test]
    fn oversized_buffers_are_not_pooled() {
        let pool = CellBufferPool::new(16);
        pool.release(buffer_with_capacity(MAX_POOLED_CELLS + 1));

        let (_, _, _, pooled) = pool.stats();
        assert_eq!(pooled, 0, "an oversized buffer must not enter the pool");
        assert_eq!(pool.oversized_dropped(), 1);
    }

    /// A 2000x500 grid is 1M cells — the Swift-side clamp — so this is the
    /// real-world shape of the leak.
    #[test]
    fn full_size_grid_is_not_retained() {
        let pool = CellBufferPool::new(16);
        for _ in 0..16 {
            pool.release(buffer_with_capacity(1_000_000));
        }
        let (_, _, _, pooled) = pool.stats();
        assert_eq!(pooled, 0, "16 x 1M-cell buffers must not be pinned");
    }

    /// The cap must not break the pooling it exists to support: normal grids
    /// still round-trip.
    #[test]
    fn normal_buffers_still_pool_and_reuse() {
        let pool = CellBufferPool::new(16);
        let buffer = buffer_with_capacity(3000);
        let expected_capacity = buffer.capacity();
        pool.release(buffer);

        let (_, returned, _, pooled) = pool.stats();
        assert_eq!(returned, 1);
        assert_eq!(pooled, 1, "a normal buffer must be pooled");
        assert_eq!(pool.oversized_dropped(), 0);

        let reused = pool.acquire(3000);
        assert!(
            reused.capacity() >= expected_capacity,
            "the pooled buffer must satisfy the acquire"
        );
    }

    /// A buffer exactly at the cap is still poolable — the limit is exclusive
    /// so the boundary is not off by one in the strict direction.
    #[test]
    fn buffer_exactly_at_cap_is_pooled() {
        let pool = CellBufferPool::new(16);
        pool.release(buffer_with_capacity(MAX_POOLED_CELLS));
        let (_, _, _, pooled) = pool.stats();
        assert_eq!(pooled, 1);
        assert_eq!(pool.oversized_dropped(), 0);
    }

    /// `acquire` must still hand back a buffer with at least the requested
    /// capacity even when a large request cannot be satisfied from the pool.
    #[test]
    fn acquire_honours_min_capacity() {
        let pool = CellBufferPool::new(16);
        let small = pool.acquire(10);
        assert!(small.capacity() >= 10);

        pool.release(buffer_with_capacity(10));
        let large = pool.acquire(100_000);
        assert!(
            large.capacity() >= 100_000,
            "a miss must allocate rather than return an undersized buffer"
        );
    }
}
