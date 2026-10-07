# Swift Concurrency Rollout

SwiftPM enables `StrictConcurrency` for every macOS target while Chau7 remains
in Swift 5 language mode. The compiler diagnostics are warnings during this
first migration stage; this does not claim the package is Swift 6-clean.

Run the strict diagnostic build with:

```sh
cd apps/chau7-macos
swift build
```

The historical first clean build with the rollout setting on Swift 6.4 emitted 1,625
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

## Current inventory — 2026-10-07

[The machine-readable inventory](swift-concurrency-inventory.json) contains
1,425 distinct `(path, line, column, message)` diagnostics captured while a fresh
native test build compiled source baseline `c4d3f52c036d6d41c27503090ff711edda817e00`.
The only working change was the repository-stats test ordering fixture. Compiler:
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), Xcode 27.0 (`27A266a`), Swift 5 language
mode with StrictConcurrency. Command: `swift test --jobs 3 --filter RepositoryStatsCacheTests`.
The compiler compiles the whole native test target before applying this filter.
An incremental build can omit diagnostics and is unsuitable for comparing totals.
The earlier 1,625 figure is historical; neither number measures runtime races.

Owners below name the component responsible for establishing an isolation
boundary, not an assigned person. Main-owned UI objects must stay on main;
workers should receive immutable values and publish results with an epoch or
explicit completion owner. A warning about a captured UI model is a migration
blocker to investigate, not proof of a simultaneously accessed mutable value.

| Component owner | Bounded next work | Required evidence |
|---|---|---|
| TerminalSessionModel and backend adapters | Audit PTY callbacks and ownership of captured session/view state before moving the next callback. | Session exit, late output, pane replacement and main progress. |
| FeatureProfiler / performance workers | Separate synchronized measurements from main-owned presentation and cancellation. | Concurrent recording, teardown and bounded delivery. |
| Repository/query workers | Preserve cache and request-generation owners; transfer query results as owned values. | Selection invalidation, in-flight completion and result publication. |
| Split-pane and overlay UI models | Establish main ownership around model mutation and notification callbacks. | Pane/tab replacement and out-of-order callbacks; no worker-side UI mutation. |
| File/process/usage monitoring | Retain existing serial worker caches and stable callback identities. | Watch recovery, cancellation, stale selection and no idle polling. |
| MCP consent and control plane | Replace sampled blocking tab-consent waits with a main-owned asynchronous presentation and a bounded worker decision. | Main progress, consent timeout, late response, settings change and exact target revalidation. Tracked in #142. |
| Remote grid lifecycle | Extract coalescing, admission and epoch invalidation into one main-owned collaborator, extending the existing immutable worker. | Reconnect, pane/tab/cursor change, forced checkpoints and unchanged-frame suppression. Tracked in #183. |
| Settings, snippets, dashboard and debug UI | Convert one callback boundary at a time to main ownership; do not globally assert Sendable on view models. | Actual lifetime and order tests for each changed callback. |
| Test fixtures | Isolate singleton overrides and asynchronous observation; distinguish fixture warnings from production owners. | Restore state and wait for published results rather than worker counters. |

The sampled MCP modal stacks in #142 are confirmed blocking paths. The remaining
inventory does not establish their hang causality, an Objective-C teardown bug,
or a race in each component. Existing command-consent, usage-cache and
per-device Metal pipeline owners remain in place.

Each ownership change is a separate reviewed PR with full native tests and build.
Keep warnings visible: no blanket `@preconcurrency`, `@unchecked Sendable`,
`nonisolated(unsafe)`, lint exclusion, or warnings-as-errors/Swift 6 promotion
until the remaining blockers have been resolved. Re-capture with the same
compiler and mode after an ownership batch; compare diagnostic identities and
inspect new owners instead of interpreting a lower total as a performance gain.
