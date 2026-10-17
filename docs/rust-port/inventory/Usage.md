# Usage

Swift: `apps/chau7-macos/Sources/Usage/, ProviderStatus/, Chau7Core/Usage/`
Swift tests: see each row
Wave: 3
Depends on: Telemetry, Notifications

Provider quotas, remaining budget, health and latency analytics. Existing CTO consumption totals are not quota snapshots.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| USG-001 | Claude status-line capture and Codex rollout rate_limits produce provider plan/credits/quota windows with used/remaining percentage and reset time | `Usage/UsageMonitor.swift`; `Chau7Core/Usage/ProviderQuota.swift` | ProviderQuotaEvaluatorTests | chau7_next_core/src/telemetry/quota.rs; chau7_next_core/src/telemetry/quota_discovery.rs; chau7_next/src/usage.rs | done |  |
| USG-002 | Persist deduplicated quota snapshots and reload them without replaying all files; refresh automatically every 30 seconds when enabled | `Usage/ProviderQuotaSnapshotLog.swift`; `Usage/UsageMonitor.swift` | ProviderQuotaSnapshotLogTests | chau7_next_core/src/telemetry/quota.rs (QuotaHistory); chau7_next/src/usage.rs; chau7_next/src/settings/general.rs | done |  |
| USG-003 | Compute recent quota burn, sustainable pace, estimated remaining minutes; emit reset-window-deduplicated 20%, 10%, 5% remaining and unsustainable-pace warnings | `Chau7Core/Usage/ProviderQuota.swift`; `Usage/UsageMonitor.swift` | ProviderQuotaEvaluatorTests | chau7_next_core/src/telemetry/quota.rs (metrics, warnings); chau7_next/src/usage.rs | done |  |
| USG-004 | Debug Usage tab shows provider quotas, recent run consumption, status/error and capture install/uninstall controls | `Debug/DebugUsageTabView.swift` | UsageNumberFormattingTests | chau7_next/src/debug/tabs/usage.rs; chau7_next/src/usage.rs | done |  |
| USG-005 | Latency analytics distinguish API request duration and first-response latency; aggregate p50/p95 with sampled count and interaction count | `Chau7Core/Usage/ProviderLatency.swift`; `Usage/UsageMonitor.swift` | ProviderLatencyAnalyticsTests | chau7_next_core/src/telemetry/latency.rs; chau7_next_core/src/telemetry/store.rs; chau7_next/src/telemetry.rs | done |  |
| USG-006 | Debug Usage latency range Today/7/14/30/90 Days/All Time, provider selector, charts by day, weekday, day period and hour, separate activity buckets | `Debug/DebugUsageTabView.swift`; `Chau7Core/Usage/ProviderLatency.swift` | ProviderLatencyAnalyticsTests | chau7_next/src/debug/tabs/usage.rs; chau7_next_core/src/telemetry/latency.rs | done |  |
| USG-007 | Estimate first-response latency from CLI output with prompt/response matching, record source and avoid confusing terminal control traffic with responses | `Chau7Core/Usage/ProviderLatencyOutputHeuristics.swift`; `Terminal/Session/TerminalSessionModel+Telemetry.swift` | ProviderLatencyOutputHeuristicsTests | chau7_next_core/src/telemetry/latency.rs; chau7_next/src/telemetry.rs; chau7_next/src/terminal/session.rs (note_prompt, note_output) | done |  |
| USG-008 | Provider status polling exposes degraded/outage indicators, incident URLs, five-minute freshness and retry backoff after failures | `ProviderStatus/ProviderStatusMonitor.swift`; `Chau7Core/ProviderHealth.swift` | ProviderStatusMonitorTests; ProviderHealthTests | chau7_next_core/src/telemetry/provider_health.rs; chau7_next/src/usage.rs; chau7_next/src/debug/tabs/usage.rs | done |  |

## Current-source verification
Quota evidence remains absent when unknown; cached render snapshots are independent from off-main-thread file/database work. Capture installation restores the exact original user configuration and refuses invalid or subsequently modified configuration. Recent consumption is cached; bounded Claude history and cached Codex rollout discovery avoid full-history reads on each tick.
Latency views expose the current Swift range/provider/metric controls, chart buckets, observed API/TTFT samples, and separately counted activity. Prompt and meaningful output hooks are connected in TerminalSession; authoritative transcript rounds replace estimates. Provider health uses the four current Swift official feeds, bounded parallel requests, failure backoff and five-minute freshness. The weekday chart uses Monday-first ordering; locale-dependent visual ordering and real provider/native UI acceptance remain to verify.
Evidence: telemetry::quota::tests::{history_deduplicates_without_replay_and_reloads,parse_usage_and_reset_scoped_warnings,pace_excludes_different_reset_window}; telemetry::latency::tests::{percentiles_and_unknowns,controls_and_spinner_are_not_responses,authoritative_rounds_replace_estimates,prompt_measurement_is_bounded_and_consumed_once,activity_survives_absent_request_latency}; telemetry::provider_health::tests::{component_filtering_unknown_and_freshness,active_google_incidents_and_backoff}; usage::tests::{rendering_snapshot_stays_readable_while_worker_is_busy,capture_restores_exact_original_and_preserves_unrelated_settings,capture_leaves_invalid_or_user_modified_settings_intact}. These rows record source parity, not manual acceptance of live provider accounts.
