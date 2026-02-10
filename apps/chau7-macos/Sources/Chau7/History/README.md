# History

Persistent command history storage, file tailing, and session recording for replay.

## Files

| File | Purpose |
|------|---------|
| `FileTailer.swift` | Generic file tailer that polls a file for new content with memory-bounded buffering |
| `PersistentHistoryStore.swift` | SQLite-backed persistent command history with search and stats queries |
| `SessionRecorder.swift` | Records terminal output frames with timestamps for timeline scrubbing and replay |

## Key Types

- `PersistentHistoryStore` — SQLite store for command history with directory, exit code, and timing
- `FileTailer<T>` — generic file monitor parsing new lines into typed items via a closure
- `SessionRecorder` — ObservableObject capturing terminal frames for session replay

## Dependencies

- **Uses:** Logging, Utilities (BoundedArray), App (AppConstants)
- **Used by:** Analytics, Monitoring, Terminal/Session, Settings/Views
