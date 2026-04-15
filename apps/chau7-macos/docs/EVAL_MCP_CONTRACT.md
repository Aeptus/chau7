# Eval-Critical MCP Contract

This contract defines the Chau7 MCP surfaces that must stay stable and highly deterministic for evaluation workloads.

## In-Scope Tools

- `tab_create`
- `tab_wait_ready`
- `tab_exec`
- `tab_status`
- `tab_output`
- `chau7_state_snapshot`
- `chau7_subscribe`
- `chau7_unsubscribe`

## Deterministic Invariants

### Launch and readiness

- `tab_create` always returns deterministic launch-readiness fields for the new tab.
- `tab_wait_ready` success means `tab_exec` will be accepted immediately.
- `tab_status.can_accept_exec` is the canonical launch gate for eval orchestration.
- `tab_status.ready_for_exec` remains the stricter prompt-ready signal and may be false even when `can_accept_exec` is true.
- `tab_status` must not contradict `tab_exec` acceptance semantics.

### Observation and replay

- `chau7_state_snapshot` is the authoritative aggregated observer read.
- `chau7_subscribe` emits only additive deltas on the existing MCP connection via `notifications/chau7.event`.
- Change replay is monotonic by `seq`.
- If replay is no longer possible, the server returns `snapshot_required` with `latest_seq` and `oldest_available_seq`.

### Subscription health

- Subscription notifications are delivered serially on one connection.
- Heartbeats use event type `heartbeat` and topic `subscription-control`.
- Subscription health is reported in machine-readable fields, never implied by free text.

## Stable Error Codes

- `notifications_unavailable`
- `snapshot_required`
- `rate_limit_exceeded`

## Observer Contract Metadata

Snapshot and subscription payloads expose:

- `observer_contract_version`
- `schema_version`
- `notification_method`
- `supported_topics`
- heartbeat and replay bounds

This metadata is additive and intended to let eval harnesses branch on explicit contract state instead of heuristic behavior.
