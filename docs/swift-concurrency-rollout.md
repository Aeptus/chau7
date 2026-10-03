# Swift Concurrency Rollout

SwiftPM enables `StrictConcurrency` for every macOS target while Chau7 remains
in Swift 5 language mode. The compiler diagnostics are warnings during this
first migration stage; this does not claim the package is Swift 6-clean.

Run the strict diagnostic build with:

```sh
cd apps/chau7-macos
swift build
```

The first clean build with the rollout setting on Swift 6.4 emitted 1,625
source diagnostics and succeeded. This is a compiler-version-specific warning
baseline, not a count of independently confirmed races; conservative
Sendable/capture diagnostics can cascade from the same isolation boundary.

## Triage

| Finding | Status | Promotion requirement |
|---|---|---|
| `AgentDashboardModel.fetchCommandBlocks` called a main-actor API from a main-queue closure without an isolation assertion. | Fixed here with `MainActor.assumeIsolated`. | None. |
| `AgentDashboardSessionController.liveTabs` called its main-actor helper from a main-queue closure without an isolation assertion. | Fixed here with `MainActor.assumeIsolated`. | None. |
| `TerminalControlService` captures mutable `iosResult` in the escaping pending-approval callback. | Fixed: asynchronous command sheets and local/remote decisions have one main-actor owner; only the MCP worker waits, with an expiring decision latch. | Decision-order, worker/main progress, timeout and late-response regressions are present. |
| `UsageMonitor` mutates its latency/activity caches from both background work and a main-thread timer. | Fixed: one serial usage worker owns caches/cursors, with generation checks rejecting stale selections. | Queue ownership is asserted and generation races are covered. |
| `MetalTerminalRenderer` shares mutable pipeline state across renderer instances without device-specific ownership. | Fixed: synchronized, atomic pipeline pairs are keyed by the retained device identity. | Distinct keys, concurrent factory admission and compilation failure retry are covered. |
| Remaining non-Sendable captures and actor-isolation diagnostics across legacy callbacks and UI models. | Non-blocking migration backlog; warnings remain visible in builds. | Triage by subsystem and fix before adopting Swift 6 language mode or treating concurrency warnings as errors. |

The two dashboard fixes close the known unchecked main-actor calls immediately.
The three named shared-state findings now have explicit ownership and regression
coverage. Remaining subsystem diagnostics still block blanket warning promotion;
this does not claim the entire application is Swift 6-clean.
