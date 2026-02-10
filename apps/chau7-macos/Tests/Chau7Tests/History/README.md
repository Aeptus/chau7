# History Tests

Tests for command history tracking, parsing, and persistence.

## Files

| File | Tests |
|------|-------|
| `HistoryEntryParserTests.swift` | JSON parsing for history entries and field extraction |
| `HistoryRecordTests.swift` | History record model initialization and properties |
| `PersistentHistoryStoreTests.swift` | SQLite-based history storage and retrieval operations |
| `SessionRecordingTests.swift` | Session frame recording and event type handling |

## Corresponding Source

- `Sources/Chau7Core/History/` — the history tracking and persistence module
