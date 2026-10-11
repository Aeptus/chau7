//! Port of `Runtime/EventJournal.swift`: a thread-safe in-memory ring buffer
//! of runtime events with cursor-based polling.

use std::collections::HashMap;
use std::sync::Mutex;

use chrono::Utc;

use super::runtime_event::RuntimeEvent;

struct Inner {
    /// Ring buffer storage.
    buffer: Vec<RuntimeEvent>,
    /// Write position in the ring buffer.
    write_index: usize,
    /// Total events ever appended (monotonic). Used as the cursor space.
    total_appended: u64,
    /// Whether the buffer has wrapped around at least once.
    wrapped: bool,
}

impl Inner {
    /// Oldest seq in the buffer (0 when empty).
    fn oldest_seq(&self, capacity: usize) -> u64 {
        if self.buffer.is_empty() {
            return 0;
        }
        if self.wrapped {
            self.buffer[self.write_index % capacity].seq
        } else {
            self.buffer[0].seq
        }
    }
}

/// Result of [`EventJournal::events`].
#[derive(Debug, Clone, PartialEq)]
pub struct EventBatch {
    /// Events with `seq > cursor`, up to the limit.
    pub events: Vec<RuntimeEvent>,
    /// New cursor (seq of the last returned event, or the input cursor if none).
    pub cursor: u64,
    /// Whether more events exist beyond the returned batch.
    pub has_more: bool,
}

/// In-memory ring buffer of runtime events for a session.
pub struct EventJournal {
    /// Maximum events retained. Oldest events are evicted when full.
    capacity: usize,
    inner: Mutex<Inner>,
}

impl Default for EventJournal {
    fn default() -> Self {
        Self::new(1000)
    }
}

impl EventJournal {
    /// Panics if `capacity` is zero (the Swift `precondition`).
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "EventJournal capacity must be positive");
        Self {
            capacity,
            inner: Mutex::new(Inner {
                buffer: Vec::with_capacity(capacity),
                write_index: 0,
                total_appended: 0,
                wrapped: false,
            }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Append a new event. Returns the created event with its sequence number.
    pub fn append(
        &self,
        session_id: &str,
        turn_id: Option<&str>,
        event_type: &str,
        data: HashMap<String, String>,
    ) -> RuntimeEvent {
        let mut inner = self.lock();

        inner.total_appended += 1;
        let event = RuntimeEvent {
            seq: inner.total_appended,
            session_id: session_id.to_string(),
            turn_id: turn_id.map(str::to_string),
            timestamp: Utc::now(),
            event_type: event_type.to_string(),
            data,
        };

        if inner.buffer.len() < self.capacity {
            inner.buffer.push(event.clone());
        } else {
            let idx = inner.write_index;
            inner.buffer[idx] = event.clone();
            inner.wrapped = true;
        }
        inner.write_index = (inner.write_index + 1) % self.capacity;

        event
    }

    /// Read events after the given cursor (exclusive).
    ///
    /// If the cursor is too old (events evicted), returns events from the
    /// oldest available.
    pub fn events(&self, cursor: u64, limit: usize) -> EventBatch {
        let inner = self.lock();

        if inner.buffer.is_empty() {
            return EventBatch {
                events: Vec::new(),
                cursor,
                has_more: false,
            };
        }

        let oldest = inner.oldest_seq(self.capacity);
        let newest = inner.total_appended;

        // Nothing new
        if cursor >= newest {
            return EventBatch {
                events: Vec::new(),
                cursor,
                has_more: false,
            };
        }

        // Effective start (-1 because we want seq > cursor)
        let effective_start = cursor.max(oldest.saturating_sub(1));

        let count = inner.buffer.len();
        let mut result: Vec<RuntimeEvent> = Vec::with_capacity(limit.min(count));

        // Iterate through the buffer in chronological order
        let start_read_index = if inner.wrapped { inner.write_index } else { 0 };

        for i in 0..count {
            let idx = (start_read_index + i) % count;
            let event = &inner.buffer[idx];
            if event.seq > effective_start {
                result.push(event.clone());
                if result.len() >= limit {
                    let has_more = (i + 1) < count;
                    let new_cursor = result.last().map_or(cursor, |e| e.seq);
                    return EventBatch {
                        events: result,
                        cursor: new_cursor,
                        has_more,
                    };
                }
            }
        }

        let new_cursor = result.last().map_or(cursor, |e| e.seq);
        EventBatch {
            events: result,
            cursor: new_cursor,
            has_more: false,
        }
    }

    /// [`events`](Self::events) with the Swift default limit of 100.
    pub fn events_default(&self, cursor: u64) -> EventBatch {
        self.events(cursor, 100)
    }

    /// The sequence number of the most recent event (0 if empty).
    pub fn latest_cursor(&self) -> u64 {
        self.lock().total_appended
    }

    /// The oldest available sequence number (0 if empty).
    pub fn oldest_available_cursor(&self) -> u64 {
        self.lock().oldest_seq(self.capacity)
    }

    /// Current number of events in the buffer.
    pub fn count(&self) -> usize {
        self.lock().buffer.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    fn add(journal: &EventJournal, event_type: &str) -> RuntimeEvent {
        journal.append("s1", None, event_type, HashMap::new())
    }

    fn types(events: &[RuntimeEvent]) -> Vec<&str> {
        events.iter().map(|e| e.event_type.as_str()).collect()
    }

    // MARK: Basic operations

    #[test]
    fn empty_journal() {
        let journal = EventJournal::default();
        assert_eq!(journal.latest_cursor(), 0);
        assert_eq!(journal.count(), 0);

        let batch = journal.events_default(0);
        assert!(batch.events.is_empty());
        assert_eq!(batch.cursor, 0);
        assert!(!batch.has_more);
    }

    #[test]
    fn append_and_read() {
        let journal = EventJournal::default();
        let e1 = add(&journal, "session_ready");
        assert_eq!(e1.seq, 1);
        assert_eq!(e1.session_id, "s1");
        assert_eq!(e1.event_type, "session_ready");

        let e2 = journal.append("s1", Some("t1"), "turn_started", HashMap::new());
        assert_eq!(e2.seq, 2);

        assert_eq!(journal.latest_cursor(), 2);
        assert_eq!(journal.count(), 2);
    }

    #[test]
    fn cursor_based_reading() {
        let journal = EventJournal::default();
        add(&journal, "a");
        add(&journal, "b");
        add(&journal, "c");

        // Read all from start
        let all = journal.events_default(0);
        assert_eq!(all.events.len(), 3);
        assert_eq!(types(&all.events), ["a", "b", "c"]);
        assert_eq!(all.cursor, 3);

        // Read after cursor 2: only "c"
        let tail = journal.events_default(2);
        assert_eq!(tail.events.len(), 1);
        assert_eq!(tail.events[0].event_type, "c");
        assert_eq!(tail.cursor, 3);

        // Read after latest: nothing new
        let empty = journal.events_default(3);
        assert!(empty.events.is_empty());
        assert_eq!(empty.cursor, 3);
    }

    #[test]
    fn limit_parameter() {
        let journal = EventJournal::default();
        for i in 1..=10 {
            add(&journal, &format!("e{i}"));
        }

        let batch = journal.events(0, 3);
        assert_eq!(batch.events.len(), 3);
        assert_eq!(types(&batch.events), ["e1", "e2", "e3"]);
        assert_eq!(batch.cursor, 3);
        assert!(batch.has_more);

        // Continue from cursor
        let batch2 = journal.events(batch.cursor, 3);
        assert_eq!(batch2.events.len(), 3);
        assert_eq!(types(&batch2.events), ["e4", "e5", "e6"]);
        assert_eq!(batch2.cursor, 6);
        assert!(batch2.has_more);
    }

    // MARK: Ring buffer eviction

    #[test]
    fn ring_buffer_eviction() {
        let journal = EventJournal::new(5);

        // Fill exactly to capacity
        for i in 1..=5 {
            add(&journal, &format!("e{i}"));
        }
        assert_eq!(journal.count(), 5);
        assert_eq!(journal.latest_cursor(), 5);

        // Add 3 more: first 3 should be evicted
        for i in 6..=8 {
            add(&journal, &format!("e{i}"));
        }
        assert_eq!(journal.count(), 5);
        assert_eq!(journal.latest_cursor(), 8);

        // Reading from 0 should get the 5 surviving events
        let batch = journal.events_default(0);
        assert_eq!(batch.events.len(), 5);
        assert_eq!(types(&batch.events), ["e4", "e5", "e6", "e7", "e8"]);
        assert_eq!(batch.cursor, 8);
    }

    #[test]
    fn old_cursor_gets_oldest_available() {
        let journal = EventJournal::new(3);

        for i in 1..=10 {
            add(&journal, &format!("e{i}"));
        }

        // Cursor 2 is long gone: should get from oldest available
        let batch = journal.events_default(2);
        assert!(batch.events.len() <= 3);
        // The 3 retained are 8, 9, 10
        for event in &batch.events {
            assert!(event.seq > 7);
        }
    }

    // MARK: Data payload

    #[test]
    fn event_data_payload() {
        let journal = EventJournal::default();
        let event = journal.append(
            "s1",
            Some("t1"),
            "tool_use",
            HashMap::from([
                ("tool".to_string(), "Write".to_string()),
                ("file".to_string(), "main.swift".to_string()),
            ]),
        );
        assert_eq!(event.data["tool"], "Write");
        assert_eq!(event.data["file"], "main.swift");
        assert_eq!(event.turn_id.as_deref(), Some("t1"));
    }

    // MARK: Thread safety

    #[test]
    fn concurrent_append_and_read() {
        let journal = Arc::new(EventJournal::new(100));
        let iterations = 500;

        let writer = |tag: &'static str| {
            let journal = Arc::clone(&journal);
            thread::spawn(move || {
                for i in 0..iterations {
                    journal.append("s1", None, &format!("{tag}_{i}"), HashMap::new());
                }
            })
        };
        let w1 = writer("w1");
        let w2 = writer("w2");

        let reader = {
            let journal = Arc::clone(&journal);
            thread::spawn(move || {
                let mut cursor = 0u64;
                for _ in 0..200 {
                    let batch = journal.events(cursor, 50);
                    cursor = batch.cursor;
                    // Verify monotonic sequence
                    for pair in batch.events.windows(2) {
                        assert!(pair[1].seq > pair[0].seq);
                    }
                }
            })
        };

        w1.join().unwrap();
        w2.join().unwrap();
        reader.join().unwrap();
        assert_eq!(journal.latest_cursor(), (iterations * 2) as u64);
    }

    // MARK: Edge cases

    #[test]
    fn single_capacity() {
        let journal = EventJournal::new(1);
        add(&journal, "first");
        add(&journal, "second");

        assert_eq!(journal.count(), 1);
        let batch = journal.events_default(0);
        assert_eq!(batch.events.len(), 1);
        assert_eq!(batch.events[0].event_type, "second");
    }

    #[test]
    fn oldest_available_cursor() {
        let journal = EventJournal::new(3);

        assert_eq!(journal.oldest_available_cursor(), 0);

        add(&journal, "a");
        assert_eq!(journal.oldest_available_cursor(), 1);

        add(&journal, "b");
        add(&journal, "c");
        assert_eq!(journal.oldest_available_cursor(), 1);

        // Wrap around: oldest should advance
        add(&journal, "d");
        assert_eq!(journal.oldest_available_cursor(), 2);
    }

    #[test]
    #[should_panic]
    fn zero_capacity_panics() {
        let _ = EventJournal::new(0);
    }
}
