# Observability

Swift: `apps/chau7-macos/Sources/Observability/, Chau7Core/Events/`
Swift tests: see each row
Wave: 3
Depends on: Events, MCP

Canonical event sequences, timer inventory and per-client change subscriptions, distinct from the historical AI event feed.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| OBS-001 | Canonical envelope monotonic sequence with AI/structural payloads, topic tags and terminal/session/repository correlation; one shared spine for runtime/notification feeds | `Chau7Core/Events/EventEnvelope.swift`; `Chau7Core/Events/EventSpine.swift`; `Events/EventSpineHost.swift` | EventSpineTests; SpineOrderingIntegrationTests | chau7_next/src/ai/hub.rs; chau7_next_core/src/ai/events.rs | partial |  |
| OBS-002 | Bounded envelope journal supports cursor polling and durable JSONL reload/rotation; preserve single ordered event sequence across producers | `Chau7Core/Events/RingJournal.swift`; `Events/SpineJournalStore.swift` | SpineJournalStoreTests; EventSpineTests |  | missing |  |
| OBS-003 | Runtime event query returns capped chronological event records, cursor/sequence, since timestamp and correlation fields | `Observability/Chau7ObservabilityService.swift` | Chau7ObservabilityServiceTests; ObservabilitySpineProjectionTests |  | missing |  |
| OBS-004 | Timer inventory records subsystem, interval, state, fire/registration times and updates/removes timers consistently under concurrent access | `Observability/Chau7ObservabilityService.swift` | Chau7ObservabilityServiceTests |  | missing |  |
| OBS-005 | Subscriptions filter topics and changes, support cancellation and bounded client delivery; runtime identity, MCP session metadata and whole-app snapshots are queryable | `MCP/MCPSession.swift`; `MCP/MCPClientConnections.swift`; `MCP/Chau7StateSnapshotService.swift` | MCPSessionTests; MCPClientConnectionsTests; Chau7ObservabilityServiceTests |  | missing |  |
