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
| PRF-002 | "Metal Renderer" setting (`feature.useMetalRenderer`, default on) switches new tabs between GPU and CPU rendering, with CPU fallback when Metal is unavailable. Chau7 Next: GPUI has no CPU path; the switch is saved and shown with that explanation, and off draws like the CPU renderer (no ligatures) | `Performance/RustMetalDisplayCoordinator.swift` (`init?`), `Settings/Views/ScrollbackPerfSettingsView.swift` |  | `chau7_next/src/settings/appearance.rs` (`RenderingOptions`), `chau7_next/src/settings_window/rendering.rs`, `chau7_next/src/terminal/paint.rs` (`terminal_font`) | partial | Metal |
| PRF-003 | Any character renders: glyphs rasterized on demand, missing glyphs taken from a fallback font (box drawing, symbols, emoji, CJK), double-width glyphs get two cells, bold/italic variants | `Performance/MetalTerminalRenderer.swift` (`rasterizeGlyph`, `lookupGlyph`, `setFont`) | | `chau7_next/src/terminal/view.rs` (`CellMetrics`, `fallback_fonts`) | done | CoreText |
| PRF-004 | Crisp text on Retina and when a window moves between screens with different scale factors | `Performance/RustMetalDisplayCoordinator.swift` (`configureFont`), `RustBackend/RustTerminalView.swift` (`viewDidMoveToWindow`) | | GPUI | done | |
| PRF-005 | Rendering paced to the display refresh rate (ProMotion 120 Hz), vsync on, three drawables in flight | `Performance/OptimalMetalView.swift` (`configureForLowLatency`), `RustBackend/RustTerminalView.swift` (`displayRefreshInterval`) | | GPUI | done | CAMetalLayer, CVDisplayLink |
| PRF-006 | Cursor blinks every 500 ms but stays solid for 1 s after typing or output; blink timer paused for suspended tabs | `Performance/RustMetalDisplayCoordinator.swift` (`handleBlinkTick`, `pauseBlinkTimer`, `setNeedsSync`) |  | `chau7_next/src/terminal/view.rs` (`blink_tick`), `chau7_next/src/terminal/paint.rs` (`Overlays::blink_hold`) | done |  |
| PRF-007 | Font ligatures (`terminal.enableLigatures`, Settings > Font Ligatures): 2-3 character ASCII sequences drawn as one ligature glyph across their cells | `Performance/MetalTerminalRenderer.swift` (`lookupLigature`, `tryLigature`), `Settings/Views/FontColorsSettingsView.swift` |  | `chau7_next/src/terminal/paint.rs` (`font_features`), `chau7_next/src/settings_window/text.rs` | done | CoreText |
| PRF-008 | Suspend Background Rendering (Settings > Performance, off by default) with a delay in seconds: hidden tabs stop rendering and only drain output every 500 ms | `RustBackend/RustTerminalView.swift` (`pauseDisplayLink`, `startBackgroundDrain`), `App/AppModel.swift`, `Settings/Views/ScrollbackPerfSettingsView.swift` |  | `chau7_next/src/terminal/session.rs` (`set_render_suspended`), `chau7_next/src/terminal/view.rs` (`blink_tick`), `chau7_next/src/settings_window/rendering.rs` | done |  |
| PRF-009 | (dev) Feature profiler: timings per feature (output, render, highlight, danger scan, local echo, AI detect, Metal render...) over 10 s and 60 s, recent events, os_signpost intervals for Instruments; shown in the Debug Console Performance tab. Chau7 Next: profiler with Render, Output Main and Danger Scan timings, shown by Window > Feature Profiler (debug) until the Debug Console is ported; no os_signpost | `Performance/FeatureProfiler.swift` |  | chau7_next/src/debug/tabs/perf.rs, chau7_next_core/src/feature_profiler.rs | done | os_signpost |
| PRF-010 | Frame pacing modes (vsync, immediate, adaptive, target FPS), immediate render, frame statistics | `Performance/OptimalMetalView.swift` (`setTimingMode`, `setFramePacing`, `statistics`) | | | n/a | CVDisplayLink |
| PRF-011 | Triple-buffered cell storage with dirty-row tracking between grid sync and draw | `Performance/TripleBuffering.swift`, `Performance/RustTermBridge.swift` | `TripleBufferingTests` | | n/a | |
| PRF-012 | SIMD scan of PTY bytes for escape sequences and control characters | `Performance/SIMDTerminalParser.swift` | `SIMDTerminalParserTests` | | n/a | |
| PRF-013 | Glyph atlas bookkeeping: shared shader pipelines, ASCII pre-rasterization, atlas reset when full, atlas PNG dump for debugging | `Performance/MetalTerminalRenderer.swift` (`setupPipelines`, `prerasterizeASCII`, `resetAtlas`, `dumpAtlasToPNG`) | | | n/a | Metal |

## Notes

- Cell attribute rendering shared by both Swift renderers (dim, inverse,
  hidden, strikethrough, underline styles, cursor shapes, dangerous-row tint)
  is listed once in RustBackend (RBK-033 to RBK-037). The Metal path converts
  cells in `RustTermBridge.convertCell` (dim at 60 %, hidden as fg = bg, tint
  blended into the background, underline variant in flag bits 8-10) and draws
  decorations in the fragment shader with the underline Y taken from
  `CTFontGetUnderlinePosition`.
- PRF-002: GPUI always renders on the GPU and has no CPU path, so the setting
  has nothing to switch. Chau7 Next keeps the switch (saved, with an
  explanation in Settings > Rendering); off turns ligatures off, since only
  Swift's Metal renderer has ligature code. The user may mark it `dropped`.
  Checked in gpui-pre 0.3.8 (2026-10-10): on macOS the renderer is Metal only
  (`gpui-pre-apple/src/metal_renderer.rs` picks a `metal::Device`, no
  feature or option selects anything else, and gpui-pre-macos does not use
  wgpu). On Linux and Windows `gpui-pre-wgpu/src/wgpu_context.rs`
  (`select_adapter_and_device`, `sort_adapters`) ranks software adapters
  (`DeviceType::Cpu`, e.g. llvmpipe or WARP) last and uses one only when no
  GPU adapter can configure the surface; `force_fallback_adapter` is
  hard-coded `false` and `ZED_DEVICE_ID` cannot pick an adapter whose device
  id is 0, so there is no switch to request CPU rendering either.
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
- PRF-002: ported as the closest equivalent (see the row); the user may still mark it `dropped`.
