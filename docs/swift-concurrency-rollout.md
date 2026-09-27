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
| `TerminalControlService` captures mutable `iosResult` in the escaping pending-approval callback. | Blocking follow-up; the callback's ownership needs an explicit synchronization or actor contract. | Resolve and add a race-focused test before concurrency warnings become errors. |
| `UsageMonitor` mutates its latency/activity caches from both background work and a main-thread timer. | Blocking follow-up; give the caches one synchronized owner. | Resolve and add a concurrency-focused test before warning promotion. |
| `MetalTerminalRenderer` shares mutable pipeline state across renderer instances without device-specific ownership. | Blocking follow-up; synchronize and key cached pipelines by `MTLDevice`. | Resolve and test multiple devices before warning promotion. |
| Remaining non-Sendable captures and actor-isolation diagnostics across legacy callbacks and UI models. | Non-blocking migration backlog; warnings remain visible in builds. | Triage by subsystem and fix before adopting Swift 6 language mode or treating concurrency warnings as errors. |

The two dashboard fixes close the known unchecked main-actor calls immediately.
The three shared-state findings remain explicit blockers for promoting the
warning set; enabling diagnostics is not a claim that those races are fixed.
