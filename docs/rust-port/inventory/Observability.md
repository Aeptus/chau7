# Observability

Swift: `apps/chau7-macos/Sources/Observability/, Chau7Core/Events/`
Swift tests: see each row
Wave: 3
Depends on: Events, MCP

Canonical event sequences, timer inventory and per-client change subscriptions, distinct from the historical AI event feed.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| OBS-001 | Canonical envelope monotonic sequence with AI/structural payloads, topic tags and terminal/session/repository correlation; one shared spine for runtime/notification feeds | `Chau7Core/Events/EventEnvelope.swift`; `Chau7Core/Events/EventSpine.swift`; `Events/EventSpineHost.swift` | EventSpineTests; SpineOrderingIntegrationTests | chau7_next_core/src/events/mod.rs; chau7_next/src/observability/mod.rs; chau7_next/src/ai/events_out.rs | done |  |
| OBS-002 | Bounded envelope journal supports cursor polling and durable reload/retention; preserve one ordered sequence across producers | `Chau7Core/Events/RingJournal.swift`; `Events/SpineJournalStore.swift` | SpineJournalStoreTests; EventSpineTests | chau7_next_core/src/events/journal.rs; chau7_next/src/observability/mod.rs | done |  |
| OBS-003 | Runtime event query returns capped chronological event records, cursor/sequence, since timestamp and correlation fields | `Observability/Chau7ObservabilityService.swift` | Chau7ObservabilityServiceTests; ObservabilitySpineProjectionTests | chau7_next/src/observability/mod.rs (runtime_events, runtime_projection); chau7_next/src/mcp/tools/observability.rs | done |  |
| OBS-004 | Timer inventory exposes ID, kind, label, subsystem, queue, active state and optional interval/leeway/tab/session; concurrent replacement and cancellation preserve current owner | `Observability/Chau7ObservabilityService.swift` | Chau7ObservabilityServiceTests | chau7_next/src/observability/mod.rs (TimerRegistry, TimerGuard, timer_inventory) | done |  |
| OBS-005 | Subscriptions filter topics and changes, support cancellation and bounded client delivery; runtime identity, MCP session metadata and whole-app snapshots are queryable | `MCP/MCPSession.swift`; `MCP/MCPClientConnections.swift`; `MCP/Chau7StateSnapshotService.swift` | MCPSessionTests; MCPClientConnectionsTests; Chau7ObservabilityServiceTests | chau7_next/src/mcp/observer.rs; chau7_next/src/mcp/tools/observability.rs; chau7_next/src/performance.rs | done |  |

## Current-source verification
The shared spine orders AI and structural events once, persists producer/public tab identities, and projects notifications/runtime events from that same stream. Durable storage is Next-owned SQLite with bounded retention and restart high-water sequence; Swift uses JSONL. This is a storage architecture difference with equivalent replay behavior.
Current Swift timerDictionary does not promise registration/fire timestamps. The row follows its actual optional fields. Next registers actual background tasks and guard lifetime; it does not claim to enumerate arbitrary operating-system timers. Registration-generation tokens prevent an old guard from cancelling its replacement, without adding private tokens to the wire schema.
Evidence: events::tests::concurrent_ingest_stream_and_replay_have_the_same_dense_order; events::journal::tests::persisted_replay_is_idempotent_bounded_and_continues_across_restart; observer::tests::{topic_normalization_and_replay_gap_are_explicit,concurrent_responses_and_notifications_never_interleave_frames,slow_dribbling_writes_share_one_total_frame_deadline}; observability::tests::{dropping_replaced_timer_does_not_deactivate_or_emit_for_its_new_owner,concurrent_timer_replacements_only_publish_current_owner_cancellation}. Timer checkpoint a4c537a6 passes six focused observability tests, 317 app tests (one ignored), and strict release workspace/all-target Clippy. Native subscription acceptance remains separate from source completion.
