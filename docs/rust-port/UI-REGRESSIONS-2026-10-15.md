# Rust UI latency and regression note, 2026-10-15

## Baseline before the new build

The saved numeric snapshot was captured at 2026-10-15T14:17:48Z, before compilation, from source `198adecb221b43704c8cf73dca1975617b7ec69f`:

- Active terminal UI input dispatch: under 1 ms. Input to first PTY output: 8 ms, **one sample**. This is too little input data to rule out intermittent lag and includes shell/CLI response time.
- Active terminal output capture to grid paint: average 11 ms, p95 17 ms, maximum 18 ms, **35 samples**. This ends at grid paint and does not measure GPU presentation or physical display latency.
- An unfocused terminal on the 42 FPS warm path: output p95 60 ms, maximum 76 ms, 105 samples.
- Main-thread watchdog stalls: 0. The main-thread timer's maximum delay was about 98 ms over 188 samples.
- A separate pre-compilation log count contained 18,247 lines, including 17,801 DEBUG lines (about 97.5%).
- The telemetry writer reported 10 accepted jobs, 9 completed, 1 pending, and 9 rejected with `WorkerUnavailable`, while still reporting `accepting: true`. The original worker-exit cause was not established; panic containment is a resilience fix, not proof that a panic caused this runtime failure.

Earlier live samples had lower input and paint timings. The saved snapshot above is the reproducible reference; neither constitutes a controlled keystroke-to-display benchmark.

These are pre-change measurements. They do not establish a post-build performance improvement.

## Source changes for review

- Terminal engine DEBUG logging now requires an explicit `CHAU7_NEXT_LOG` DEBUG/TRACE setting or trace/verbose mode. WARN and ERROR remain visible, and the existing DEBUG policy for other app targets is preserved.
- Repository and dashboard panes track focus entering child controls. Pane selection preserves that child input instead of moving keyboard focus back to the pane root. Split-divider hit targets and repository-group tab lines/backgrounds were adjusted while keeping pane content clipped to its cell.
- Runtime metadata selects the build channel and matching revision key; hang manifests use the same channel-aware revision.
- The telemetry writer contains per-job panics, continues draining later jobs, and reconciles pending accepted jobs when its worker becomes unavailable.

## Validation status

- `cargo test -p chau7_next -p chau7_next_core --locked`: 3,188 passed, 0 failed, 2 ignored (one app test and one documentation example).
- The new GPUI interaction regression uses a temporary profile and an isolated `/bin/cat` PTY. It checks initial terminal typing, repository search focus and input, then terminal typing after a real pointer click, with the repository field unchanged.
- Geometry/color tests cover group-line continuity, waiting-outline bounds, repository tints, nested split borders, and divider drag offsets. Telemetry tests cover panic containment, later-job persistence, and accurate failure accounting.
- `cargo fmt --all --check` passed, including a formatting-only correction to an inherited restoration test fixture.

`cargo clippy -p chau7_next -p chau7_next_core --all-targets --locked --no-deps -- -D warnings` passed. Production packaging is verified separately against its source revision and artifact receipt.

Native visual validation and comparable post-change runtime measurements have not been performed. The running app was left untouched; no install or profile write was performed. Do not report a measured latency gain until comparable post-build measurements are available.
