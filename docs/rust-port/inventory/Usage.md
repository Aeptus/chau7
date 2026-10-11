# Usage

Swift: `apps/chau7-macos/Sources/Usage/, ProviderStatus/, Chau7Core/Usage/`
Swift tests: see each row
Wave: 3
Depends on: Telemetry, Notifications

Provider quotas, remaining budget, health and latency analytics. Existing CTO consumption totals are not quota snapshots.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| USG-001 | Claude status-line capture and Codex rollout rate_limits produce provider plan/credits/quota windows with used/remaining percentage and reset time | `Usage/UsageMonitor.swift`; `Chau7Core/Usage/ProviderQuota.swift` | ProviderQuotaEvaluatorTests |  | missing |  |
| USG-002 | Persist deduplicated quota snapshots and reload them without replaying all files; refresh automatically every 30 seconds when enabled | `Usage/ProviderQuotaSnapshotLog.swift`; `Usage/UsageMonitor.swift` | ProviderQuotaSnapshotLogTests |  | missing |  |
| USG-003 | Compute recent quota burn, sustainable pace, estimated remaining minutes; emit reset-window-deduplicated 20%, 10%, 5% remaining and unsustainable-pace warnings | `Chau7Core/Usage/ProviderQuota.swift`; `Usage/UsageMonitor.swift` | ProviderQuotaEvaluatorTests |  | missing |  |
| USG-004 | Debug Usage tab shows provider quotas, recent run consumption, status/error and capture install/uninstall controls | `Debug/DebugUsageTabView.swift`; `Debug/DebugUsageTabView.swift` | UsageNumberFormattingTests |  | missing |  |
| USG-005 | Latency analytics distinguish API request duration and first-response latency; aggregate p50/p95 with sampled count and interaction count | `Chau7Core/Usage/ProviderLatency.swift`; `Usage/UsageMonitor.swift` | ProviderLatencyAnalyticsTests |  | missing |  |
| USG-006 | Debug Usage latency range Today/7/14/30/90 Days/All Time, provider selector, charts by day, weekday, day period and hour, separate activity buckets | `Debug/DebugUsageTabView.swift`; `Chau7Core/Usage/ProviderLatency.swift` | ProviderLatencyAnalyticsTests |  | missing |  |
| USG-007 | Estimate first-response latency from CLI output with prompt/response matching, record source and avoid confusing terminal control traffic with responses | `Chau7Core/Usage/ProviderLatencyOutputHeuristics.swift`; `Terminal/Session/TerminalSessionModel+Telemetry.swift` | ProviderLatencyOutputHeuristicsTests |  | missing |  |
| USG-008 | Provider status polling exposes degraded/outage indicators, incident URLs, five-minute freshness and retry backoff after failures | `ProviderStatus/ProviderStatusMonitor.swift`; `Chau7Core/ProviderHealth.swift` | ProviderStatusMonitorTests; ProviderHealthTests |  | missing |  |
