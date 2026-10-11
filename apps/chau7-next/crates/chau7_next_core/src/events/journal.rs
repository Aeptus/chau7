//! SQLite backing for current Swift SpineJournalStore; isolated callers supply the path.
use super::EventEnvelope;
use rusqlite::{Connection, params};
use std::path::Path;
use std::sync::Mutex;

pub struct SpineJournalStore {
    connection: Mutex<Connection>,
    retention: u64,
}
impl SpineJournalStore {
    pub fn open(path: &Path, retention: u64) -> rusqlite::Result<Self> {
        let connection = Connection::open(path)?;
        connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS envelopes (seq INTEGER PRIMARY KEY, event_id TEXT NOT NULL, correlation_id TEXT, ingested_at REAL NOT NULL, envelope_json BLOB NOT NULL);")?;
        Ok(Self {
            connection: Mutex::new(connection),
            retention: retention.max(1),
        })
    }
    pub fn persist(&self, envelope: &EventEnvelope) -> rusqlite::Result<()> {
        let bytes = serde_json::to_vec(envelope)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
        let seq = i64::try_from(envelope.seq)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
        let mut connection = self.connection.lock().unwrap_or_else(|e| e.into_inner());
        let transaction = connection.transaction()?;
        transaction.execute("INSERT OR IGNORE INTO envelopes(seq,event_id,correlation_id,ingested_at,envelope_json) VALUES (?,?,?,?,?)", params![seq, envelope.event_id.to_string(), envelope.correlation_id, envelope.ingested_at.timestamp_millis() as f64 / 1000.0, bytes])?;
        transaction.execute(
            "DELETE FROM envelopes WHERE seq <= (SELECT COALESCE(MAX(seq),0) - ? FROM envelopes)",
            [self.retention.min(i64::MAX as u64) as i64],
        )?;
        transaction.commit()
    }
    pub fn high_water_seq(&self) -> rusqlite::Result<u64> {
        self.connection
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .query_row("SELECT COALESCE(MAX(seq),0) FROM envelopes", [], |row| {
                row.get(0)
            })
    }
    pub fn count(&self) -> rusqlite::Result<u64> {
        self.connection
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .query_row("SELECT COUNT(*) FROM envelopes", [], |row| row.get(0))
    }
    pub fn envelopes(&self, after: u64, limit: usize) -> rusqlite::Result<Vec<EventEnvelope>> {
        if after > i64::MAX as u64 {
            return Ok(Vec::new());
        }
        let connection = self.connection.lock().unwrap_or_else(|e| e.into_inner());
        let mut statement = connection.prepare(
            "SELECT envelope_json FROM envelopes WHERE seq > ? ORDER BY seq ASC LIMIT ?",
        )?;
        let rows = statement.query_map(params![after as i64, limit.min(50_000) as i64], |row| {
            row.get::<_, Vec<u8>>(0)
        })?;
        let mut result = Vec::new();
        for row in rows {
            let bytes = row?;
            // A damaged retained payload must not hide later valid events.
            match serde_json::from_slice(&bytes) {
                Ok(envelope) => result.push(envelope),
                Err(error) => log::warn!("event journal: invalid retained payload: {error}"),
            }
        }
        Ok(result)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::{EventSpine, StructuralEvent};
    #[test]
    fn replay_skips_corrupt_payloads_without_losing_later_events() {
        let store = SpineJournalStore::open(Path::new(":memory:"), 8).unwrap();
        let spine = EventSpine::new(8, 0);
        for _ in 0..3 {
            store
                .persist(&spine.ingest_structural(
                    StructuralEvent::new("test", "tests"),
                    None,
                    None,
                    None,
                ))
                .unwrap();
        }
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE envelopes SET envelope_json = ? WHERE seq = 2",
                [b"broken".as_slice()],
            )
            .unwrap();
        assert_eq!(
            store
                .envelopes(0, 8)
                .unwrap()
                .iter()
                .map(|event| event.seq)
                .collect::<Vec<_>>(),
            [1, 3]
        );
    }
    #[test]
    fn persisted_replay_is_idempotent_bounded_and_continues_across_restart() {
        let dir = std::env::temp_dir().join(format!("chau7-next-spine-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("journal.db");
        let spine = EventSpine::new(4, 0);
        {
            let store = SpineJournalStore::open(&path, 3).unwrap();
            for _ in 0..6 {
                let event = spine.ingest_structural(
                    StructuralEvent::new("tab_created", "tabs"),
                    None,
                    None,
                    None,
                );
                store.persist(&event).unwrap();
                store.persist(&event).unwrap();
            }
            assert_eq!(store.count().unwrap(), 3);
            assert_eq!(
                store
                    .envelopes(0, 10)
                    .unwrap()
                    .iter()
                    .map(|e| e.seq)
                    .collect::<Vec<_>>(),
                [4, 5, 6]
            );
        }
        {
            let store = SpineJournalStore::open(&path, 3).unwrap();
            let spine = EventSpine::new(4, store.high_water_seq().unwrap());
            let event = spine.ingest_structural(
                StructuralEvent::new("app_launched", "app"),
                None,
                None,
                None,
            );
            assert_eq!(event.seq, 7);
            store.persist(&event).unwrap();
            assert_eq!(store.high_water_seq().unwrap(), 7);
            assert_eq!(store.envelopes(6, 1).unwrap(), [event]);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
}
