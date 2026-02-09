//! Memory pool for CellData buffers to reduce allocation overhead.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

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
}

impl CellBufferPool {
    pub fn new(max_pooled: usize) -> Self {
        Self {
            pool: Mutex::new(Vec::with_capacity(max_pooled)),
            max_pooled,
            acquired: AtomicU64::new(0),
            returned: AtomicU64::new(0),
            allocated: AtomicU64::new(0),
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
    pub fn release(&self, mut buffer: Vec<CellData>) {
        self.returned.fetch_add(1, Ordering::Relaxed);
        buffer.clear();

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
}

impl Default for CellBufferPool {
    fn default() -> Self {
        Self::new(16)  // Keep up to 16 buffers pooled (multi-tab friendly)
    }
}
