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

## Follow-up: terminal scroll and selection

The terminal wheel handler rounded each event independently. Precise macOS
trackpad deltas below half a terminal line became zero and were discarded.
The handler must retain fractional movement across events, consume vertical
movement intended for the terminal, and reset residual movement at gesture
boundaries or cancellation.

The selection review also found that GPUI's div mouse-move handler only runs
while its hitbox is hovered. Leaving the terminal during a drag therefore
stopped pointer tracking. Double/triple clicks did not keep the semantic
selection active for dragging, and wheel selection extension read the grid's
cached display offset before refresh. The fixes use an owned drag listener,
keep semantic selection active, and read the current backend offset.

Pane clipping and the split separator do not intercept terminal wheel events.
No renderer or restored history format change is needed for these fixes.

Follow-up validation:

- Six new mouse tests pass: four scroll-accumulator tests and two rendered GPUI
  interaction fixtures using a temporary profile and an isolated `/bin/cat` PTY.
- The rendered fixtures cover fractional pixels, gesture boundaries, wheel
  propagation, normal shell scrolling, mouse-reporting overrides, selection in
  scrolled history, outside dragging and auto-scroll, missed release recovery,
  Shift anchor preservation, double/triple-click extension, copy and paste,
  and Option-drag copy suppression.
- Full Rust app/core suites: 3,194 passed, 0 failed, 2 ignored.
- Cargo formatting and strict app/core Clippy passed.
- Legacy Swift: 4,594 tests executed, 3 skipped, 0 failures; build passed.

These are automated interaction tests, not a physical trackpad or native-window
hand test. The app under /Applications is not replaced or relaunched by this
workflow. Packaging verifies a separate production bundle against its clean
source revision and seven executable hashes.


## Follow-up: complete wheel failure in Codex

The user clarified that both wheel and trackpad were completely ineffective
in Codex, although Page Up/Down worked. Fractional delta handling alone does
not fix that failure.

The saved performance snapshot at 2026-10-15T18:34:38Z showed both selected
terminal panes using the alternate screen with zero active history rows.
The pre-fix handler gated wheel reports behind the click/drag setting (off by
default), then consumed the event while trying to scroll that empty history.
Page keys instead reached the foreground application.

[Codex 0.162.1's alternate-screen input implementation](https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/tui/src/tui/alternate_screen.rs)
requests mouse tracking with SGR reports for its owned transcript. When mouse
capture is unavailable, it requests DEC 1007 alternate scrolling instead.
Chau7 now routes wheel input according to those terminal modes, with no
provider-name heuristic:

- Requested mouse reports take precedence in the alternate screen, independently
  of the click/drag setting. Normal-screen reporting still follows that setting.
- Without requested mouse tracking, ALT_SCREEN plus DEC 1007 sends SS3 Up/Down,
  matching [Alacritty's input implementation](https://github.com/alacritty/alacritty/blob/master/alacritty/src/input/mod.rs).
  Leaving the alternate screen or disabling DEC 1007 removes that route.
- Shift, Ctrl, and an active local selection gesture keep wheel input local.
  Stored selections after mouse release do not disable application scrolling.
- Fractional movement resets when switching between history, mouse reports, and
  alternate keys, preventing a prior route's remainder from becoming input.
- Settings explain the wheel behavior; numeric snapshots expose raw mouse mode,
  the click/drag setting, and alternate-scroll state without terminal text.

The old running build does not expose raw mouse modes in its numeric snapshot.
The diagnosis combines the observed screen/history state with code and isolated
protocol reproduction; it is not a capture of the user's actual input stream.


Codex follow-up validation:

- The new rendered SGR regression fails against the previous `mouse.rs` with
  an empty PTY receipt, then passes with the fixed handler. Its child is an
  isolated raw/no-echo shell and `cat`, with no provider or user profile.
- All nine terminal mouse tests pass. They verify line and pixel input in both
  directions, actual SGR/SS3 delivery, protocol precedence, local selection,
  Shift/Ctrl overrides, event consumption, and return to primary scrollback.
- Full Rust app/core suites: 3,197 passed, 0 failed, 2 ignored. The shared native
  terminal adds 161 passing tests and one ignored documentation example.
- Strict Clippy for app, core and native terminal, plus Cargo formatting, passed.
- Legacy Swift: 4,594 tests executed, 3 skipped, 0 failures; build passed.

These checks do not constitute a physical trackpad/mouse hand test in the
user's running Codex session. A separate production bundle is built from the
clean committed source; the running application and restoration data remain
untouched.
