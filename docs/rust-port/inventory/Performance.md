# Performance

Swift: `apps/chau7-macos/Sources/Chau7/Performance/` (7 files, 2929 lines)
Swift tests: `Performance/TripleBufferingTests.swift`, `Performance/SIMDTerminalParserTests.swift`
Wave: 1
Depends on: RustBackend

The Metal renderer the Swift app uses by default: a coordinator pulls the
Rust grid each frame, a bridge converts cells into a triple buffer, and an
instanced Metal renderer draws backgrounds, glyphs from a dynamic atlas,
decorations and the cursor. Also holds the feature profiler shown in the Debug
Console. GPUI renders on the GPU itself, so most of the pipeline is replaced;
the rows below keep the user-visible effects.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| PRF-001 | Terminal text and backgrounds drawn on the GPU | `Performance/RustMetalDisplayCoordinator.swift`, `Performance/MetalTerminalRenderer.swift` | | `chau7_next/src/terminal/view.rs` (GPUI `paint_quad`, `shape_line`) | done | Metal |
| PRF-002 | "Metal Renderer" switches terminal text, backgrounds, decorations and images between GPUI GPU drawing and a bounded CPU BGRA surface; existing tabs refresh font metrics. GPUI window composition still needs a platform graphics device, so startup without one remains unsupported | `Performance/RustMetalDisplayCoordinator.swift` (`init?`), `Settings/Views/ScrollbackPerfSettingsView.swift` | CPU raster/cache tests; native styled-text fixture | chau7_next/src/terminal/cpu_renderer.rs; chau7_next/src/terminal/paint.rs; chau7_next/src/terminal/view.rs | partial | CoreText, Metal |
| PRF-003 | Fallback fonts, double-width/bold/italic glyphs and complete multi-character grapheme clusters with continuation-cell spacing | `Performance/MetalTerminalRenderer.swift`; `RustBackend/RustTerminalView+Rendering.swift` | 17 native GridCopy paint fixtures; isolated macOS CPU/GPU-requested screenshots at e8f32e6014b0 | chau7_next/src/terminal/paint.rs; chau7_next/src/terminal/view.rs | done | CoreText |
| PRF-004 | Crisp text on Retina and when a window moves between screens with different scale factors | `Performance/RustMetalDisplayCoordinator.swift` (`configureFont`), `RustBackend/RustTerminalView.swift` (`viewDidMoveToWindow`) | | GPUI | done | |
| PRF-005 | Rendering paced to the display refresh rate (ProMotion 120 Hz), vsync on, three drawables in flight | `Performance/OptimalMetalView.swift` (`configureForLowLatency`), `RustBackend/RustTerminalView.swift` (`displayRefreshInterval`) | | GPUI | done | CAMetalLayer, CVDisplayLink |
| PRF-006 | Cursor blinks every 500 ms but stays solid for 1 s after typing or output; blink timer paused for suspended tabs | `Performance/RustMetalDisplayCoordinator.swift` (`handleBlinkTick`, `pauseBlinkTimer`, `setNeedsSync`) |  | `chau7_next/src/terminal/view.rs` (`blink_tick`), `chau7_next/src/terminal/paint.rs` (`Overlays::blink_hold`) | done |  |
| PRF-007 | Font ligatures (`terminal.enableLigatures`, Settings > Font Ligatures): 2-3 character ASCII sequences drawn as one ligature glyph across their cells | `Performance/MetalTerminalRenderer.swift` (`lookupLigature`, `tryLigature`), `Settings/Views/FontColorsSettingsView.swift` |  | `chau7_next/src/terminal/paint.rs` (`font_features`), `chau7_next/src/settings_window/text.rs` | done | CoreText |
| PRF-008 | Suspend Background Rendering (Settings > Performance, off by default) with a delay in seconds: hidden tabs stop rendering and only drain output every 500 ms | `RustBackend/RustTerminalView.swift` (`pauseDisplayLink`, `startBackgroundDrain`), `App/AppModel.swift`, `Settings/Views/ScrollbackPerfSettingsView.swift` |  | `chau7_next/src/terminal/session.rs` (`set_render_suspended`), `chau7_next/src/terminal/view.rs` (`blink_tick`), `chau7_next/src/settings_window/rendering.rs` | done |  |
| PRF-009 | Feature totals over 10 s and 60 s, recent numeric events and real paired os_signpost intervals for measured scopes, shown in Debug Console Perf. Current source catalog includes poll, restore, routing, history and stall categories; absent measurements remain absent | `Performance/FeatureProfiler.swift` | feature_profiler scope/catalog tests | chau7_next_core/src/feature_profiler.rs; chau7_next/src/platform/oslog.rs; chau7_next/src/platform/oslog_shim.c; chau7_next/src/debug/tabs/perf.rs | done | os_signpost |
| PRF-010 | Frame pacing modes (vsync, immediate, adaptive, target FPS), immediate render, frame statistics | `Performance/OptimalMetalView.swift` (`setTimingMode`, `setFramePacing`, `statistics`) | | | n/a | CVDisplayLink |
| PRF-011 | Triple-buffered cell storage with dirty-row tracking between grid sync and draw | `Performance/TripleBuffering.swift`, `Performance/RustTermBridge.swift` | `TripleBufferingTests` | | n/a | |
| PRF-012 | SIMD scan of PTY bytes for escape sequences and control characters | `Performance/SIMDTerminalParser.swift` | `SIMDTerminalParserTests` | | n/a | |
| PRF-013 | Glyph atlas bookkeeping: shared shader pipelines, ASCII pre-rasterization, atlas reset when full, atlas PNG dump for debugging | `Performance/MetalTerminalRenderer.swift` (`setupPipelines`, `prerasterizeASCII`, `resetAtlas`, `dumpAtlasToPNG`) | | | n/a | Metal |

| PRF-014 | (dev) Bounded sampled performance JSONL file separate from operational logs, schema_version/timestamp/category/metrics, 8 MB rotation and flush | `Performance/PerformanceTelemetryWriter.swift` | PerformanceTelemetryWriterTests; Next rotation/envelope tests | chau7_next/src/performance.rs (bounded queue, 8 MiB rotation, background quit drain) | done |  |
| PRF-015 | (dev) Render pipeline, terminal work and wakeup aggregate profiling with stage counters/durations, callback/timer sources and idle costs | `Performance/RenderPipelineProfiler.swift`; `Performance/TerminalWorkProfiler.swift`; `Performance/WakeupProfiler.swift` | 4 bounded work aggregation regressions; actual stage caller/native delta tests | chau7_next_core/src/work_profiler.rs; chau7_next/src/performance.rs; chau7_next/src/terminal/{session,view,paint,cpu_renderer}.rs | done |  |
| PRF-016 | Main-thread hang heartbeat/watchdog captures diagnostic evidence, writes breadcrumbs and attempts bounded render recovery; lifetime stops on app shutdown | `Chau7Core/MainThreadHangMonitor.swift`; `Chau7Core/MainThreadHangWatchdogLifetime.swift`; `Performance/MainThreadHangRecoveryController.swift`; `Chau7Core/HangSampleEvidence.swift` | MainThreadHangMonitorTests; MainThreadHangWatchdogLifetimeTests; HangSampleEvidenceTests; native helper acceptance | chau7_next_core/src/hang_monitor.rs; chau7_next/src/hang_watchdog.rs | done |  |
| PRF-017 | Memory pressure coordinator/reclaimer budgets active/warm/hidden scrollback, trims caches under warning/critical pressure and records reclaimed memory | `Performance/MemoryPressureCoordinator.swift`; `Performance/MemoryPressureResponder.swift`; `Performance/TerminalMemoryReclaimer.swift`; `Terminal/ScrollbackMemoryManager.swift`; `Chau7Core/TerminalMemoryBudgetPolicy.swift` | TerminalMemoryBudgetPolicyTests; RenderMemoryPressurePolicyTests; ScrollbackMemoryManagerTests | chau7_next_core/src/memory_pressure.rs; chau7_next/src/memory_pressure.rs; chau7_next/src/terminal/cpu_renderer.rs | done | Dispatch memory pressure, mach task metrics |
| PRF-018 | Hidden/warm scrollback retention flushes to disk, reloads on activation, bounds trackers/configured lines and avoids stale TUI content on restore | `Chau7Core/ScrollbackRetentionPolicy.swift`; `Terminal/ScrollbackMemoryManager.swift`; `Chau7Core/ScrollbackRestoreFilter.swift` | ScrollbackMemoryManagerTests; TerminalSystemRestoreTests | chau7_next_core/src/scrollback_cache.rs; chau7_next_core/src/session_restore.rs; chau7_next/src/memory_pressure.rs; chau7_next/src/restore.rs | done |  |

## Notes

- Cell attribute rendering shared by both Swift renderers (dim, inverse,
  hidden, strikethrough, underline styles, cursor shapes, dangerous-row tint)
  is listed once in RustBackend (RBK-033 to RBK-037). The Metal path converts
  cells in `RustTermBridge.convertCell` (dim at 60 %, hidden as fg = bg, tint
  blended into the background, underline variant in flag bits 8-10) and draws
  decorations in the fragment shader with the underline Y taken from
  `CTFontGetUnderlinePosition`.
- PRF-002: CPU rasterization is implemented, with 64 MiB/8192-pixel surface
  bounds, 32 MiB/4096-glyph cache bounds and release on renderer/window changes.
  GPUI still composes the resulting surface in its platform graphics pipeline.
  The source switch works; automatic app startup without a graphics device is
  the remaining partial facet. The earlier claim that off only disabled
  ligatures is obsolete.
- PRF-003: native macOS acceptance on `e8f32e6014b0` passes colors,
  bold/italic/underline, combining accents, composed woman-technologist skin
  tone, one family glyph, French flag and CJK. The fix reconstructs extended
  grapheme clusters across native cells before shaping; following text retains
  its grid-column position. Both CPU-off/GPU-on settings were checked in an
  isolated test bundle/profile, with screenshots preserved in the parity
  recovery evidence. The earlier `175fd1ee3b1e` split-emoji failure is fixed.
  That build predates actual-backend diagnostics; settings are recorded as
  requested backend, with no inferred claim about a silent fallback.
- PRF-014: history records use schema_version/timestamp/category/metrics,
  with 8 MiB live and archive bounds and a 1 MiB record bound. The latest
  snapshot keeps the live MCP/UI shape. Accepted records drain on the quit
  worker; disk failures log once until successful recovery.
- PRF-016: pure stall/lifetime/evidence tests and the actual macOS helper
  acceptance pass. The helper samples only its target, records progress
  advanced during a five-second capture, exits after recovery, and never
  initializes GUI/integrations. An actual stalled GUI recovery remains on
  the manual acceptance checklist; a successful sample is not proof of a
  deadlock diagnosis.
- PRF-017/018: warning/critical dispatch source and proactive physical-footprint
  policy drive a serial worker. CRC/size-verified caches are durable before
  ring reduction, with output-counter and selected-promotion rechecks under
  the parser lock. Reload preserves output received since the flush. Tests
  cover interrupted/changed transactions and alternate-screen handling.
  Native pressure and reveal testing remain manual acceptance items.
- PRF-006: Next blinks every 500 ms (or `terminal.cursorBlinkRate`), stays
  solid for 1 s after output (typed text echoes as output), and stops
  toggling while the tab is not painted. Quirk: the Swift Metal renderer
  never reads `terminal.cursorBlink` (`cursorBlinkEnabled` stays true), so
  with Metal the cursor always blinks; Next honors the setting like the Swift
  CPU renderer.
- PRF-007: the Swift renderer never sets `ligaturesEnabled` from the setting,
  so ligatures are off in practice. Next turns the font's `calt` and `liga`
  features on or off from the setting; with `force_width` shaping a ligature
  glyph starts in its first cell and spans the others.
- PRF-008: GPUI never paints a hidden tab. With the setting on, a tab not
  painted for the delay is suspended: its session refreshes the grid at most
  every 500 ms (output is still parsed); painting it again resumes.
- Text blink (SGR 5) has shader support (flag 16, `blinkVisible`) but the
  bridge never sets that bit (`metalStyleMask` is 0x0F and bit 4 is inverse in
  the Rust flags), so blinking text does not exist in the Swift app.
- No GPU selection, low-power GPU preference, minimum contrast or smooth
  scrolling exists in the Swift app; nothing to port.
- n/a rows: PRF-010 has no caller (the coordinator keeps the view paused and
  calls `draw()` itself); PRF-011 and PRF-013 are Metal pipeline plumbing that
  GPUI replaces; PRF-012 has no caller outside its tests.

### Actual work and wakeup measurements

PRF-015 records actual PTY poll/parse, output extraction and UI dispatch latency,
grid/cursor capture, shape/prepaint/draw, CPU glyph/cache/raster/line rendering,
remote delta/copy/encoding and memory save/replay/persist work. The
`work_profile` performance snapshot exposes lifetime and 10/60-second windows,
queue/context and idle wakeup costs. Retention is bounded to 256 contexts and
120 time buckets. Overlapping stages are explicitly identified. GPUI-private
GPU completion and CPU-time values remain unavailable, rather than being
inferred from command submission duration. Native idle comparisons are separate
acceptance evidence, not universal benchmark claims.
