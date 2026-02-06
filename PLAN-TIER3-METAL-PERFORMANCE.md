# Tier 3: Metal GPU Renderer, Triple Buffering, and Full Performance Stack

## Architecture Plan

**Date:** 2026-02-06
**Status:** PLAN ONLY -- no code changes
**Scope:** Integration of all 11 performance files in `Sources/Chau7/Performance/` with the existing SwiftTerm-based rendering pipeline

---

## 1. Component Readiness Assessment

### 1.1 SIMDTerminalParser.swift -- 90% Complete

**What exists:**
- Full SIMD16-based byte scanner for ESC, LF, CR, TAB, BEL
- Pure-ASCII fast-path check (`isPrintableASCII`)
- CSI and OSC sequence boundary detection
- Full escape sequence parser returning typed `EscapeSequence` structs
- Convenience extensions for `[UInt8]` and `Data` input

**What is missing:**
- Already partially wired: `Chau7TerminalView.dataReceived` calls `SIMDTerminalParser.scan()` at line 1488 and uses the result to skip dim patching on the pure-ASCII fast path (line 1573)
- Not yet used for actual terminal state mutation (the scan result is informational only; SwiftTerm's own parser still does all real work)
- The `parseEscapeSequences` method is never called from production code
- No integration with `LockFreeByteBuffer.peekContiguous()` for zero-copy scanning

**Verdict:** Functionally complete as a scanner. The Tier 3 role is limited: it provides pre-classification hints but does NOT replace SwiftTerm's parser.

---

### 1.2 LockFreeRingBuffer.swift -- 85% Complete

**What exists:**
- Generic `LockFreeRingBuffer<T>` with SPSC atomics (using swift-atomics `ManagedAtomic`)
- Power-of-2 capacity with bitmask modulo
- Batch read/write APIs
- Statistics tracking (writes, reads, drops)
- Specialized `LockFreeByteBuffer` with page-aligned allocation, `memcpy`-based bulk transfers, and `peekContiguous()` for zero-copy SIMD access

**What is missing:**
- No backpressure signaling (caller must poll `isFull`)
- No integration with PTY read loop -- currently `PerformanceTerminal.processPTYData` writes to the ring buffer but nothing reads from it (the data also flows through the normal SwiftTerm `feed(byteArray:)` path)
- `peekContiguous()` return could span a wrap boundary; the caller must handle the two-chunk case
- No memory ordering tests or validation beyond the atomic orderings chosen

**Verdict:** Implementation is solid. Main gap is that it is unused -- the PTY data currently flows directly from `LocalProcess` to `dataReceived` without touching the ring buffer.

---

### 1.3 PerformanceIntegration.swift -- 55% Complete

**What exists:**
- `PerformanceTerminal` class that instantiates and coordinates all subsystems
- `Configuration` struct with toggles for Metal, low-latency input, predictive rendering, triple buffering, SIMD parsing
- Lifecycle management (`start`/`stop`/`resize`)
- PTY data processing pipeline with SIMD fast-path and standard-path branches
- `syncFromTerminal(_:)` bridge that copies SwiftTerm `Terminal` cell data into `TripleBufferedTerminal`
- `render(to:)` method that reads cells from triple buffer and submits to `MetalTerminalRenderer`
- `FeatureSettings` extension with `usePerformanceTerminal` and `performanceConfig`

**What is missing:**
- `fastPathProcessText` is a stub -- iterates bytes but does not update cursor position or cell content
- `processCSI`/`processOSC`/`processSimpleEscape` are all stubs (empty or `break`)
- `syncFromTerminal` color extraction is naive: hardcodes white foreground / black background instead of resolving `Attribute.Color` (ansi256, trueColor, default)
- Character extraction uses `charData.getCharacter().asciiValue` which returns nil for non-ASCII, losing all Unicode
- No mechanism to trigger `syncFromTerminal` on each frame -- it must be called manually
- No connection to `Chau7TerminalView` or `TerminalSessionModel`
- The `onFrame` / `onKeyInput` callbacks are defined but never wired
- `displayController` is declared but never instantiated

**Verdict:** This is the central orchestrator but is roughly half-built. The SwiftTerm bridge logic and the rendering pipeline both need substantial work.

---

### 1.4 MetalTerminalRenderer.swift -- 75% Complete

**What exists:**
- Full Metal pipeline setup: device, command queue, vertex/fragment shaders (embedded MSL source)
- Two-pass rendering: background quads first, then glyph quads with alpha blending
- Instanced rendering with `CellInstance` struct (position, texCoord, foreground, background, flags)
- Glyph atlas builder using CoreText: rasterizes ASCII 32-126 into a 1024x1024 RGBA texture
- Orthographic projection matrix
- `render(cells:rows:cols:to:viewportSize:)` public API

**What is missing:**
- Only ASCII glyphs (32-126) are in the atlas -- no Unicode/emoji support
- No dynamic glyph atlas expansion (cache miss = invisible character)
- Bold/italic/underline rendering is not implemented (flags field exists but shaders ignore it)
- No cursor rendering
- No selection highlight rendering
- No underline/strikethrough/overline decorations in the shader
- Duplicate `simd_float4x4` orthographic initializer (lines 13-25 and 541-557) -- will cause a compile error
- No support for wide characters (CJK double-width)
- No Retina/HiDPI scaling in glyph atlas rasterization
- Cell size is computed from font metrics but `setFont` is never called automatically

**Verdict:** Core GPU rendering works for basic ASCII. Needs significant extension for production use.

---

### 1.5 TripleBuffering.swift -- 85% Complete

**What exists:**
- `TripleBufferedTerminal` with three `TerminalBuffer` instances
- Atomic index management for update/render/display buffers
- Dirty row tracking with `IndexSet`
- `commitUpdate()` copies dirty rows from update to render buffer
- `presentFrame()` swaps render and display buffers
- `DirtyRegionTracker` for sub-row (chunk-level) dirty tracking
- Statistics (swap count, frame count)

**What is missing:**
- `DirtyRegionTracker` is defined but not used by `TripleBufferedTerminal` (it uses `IndexSet`-based row tracking instead)
- Buffer swap has a subtle issue: `commitUpdate()` copies dirty rows from update[current] to render[render], then swaps indices, but if the producer writes faster than the consumer reads, data in the "new update buffer" (formerly render) may be stale
- No resize support -- recreating the `TripleBufferedTerminal` on resize (as `PerformanceTerminal.resize` does) discards all buffer content
- Cells are `TerminalCell` which stores `UInt32` character + `SIMD4<Float>` colors -- this means a full color conversion from SwiftTerm's `Attribute.Color` enum must happen on every sync

**Verdict:** Structurally sound. The main work is in the sync layer that populates it from SwiftTerm.

---

### 1.6 LowLatencyInput.swift -- 70% Complete

**What exists:**
- `LowLatencyInputHandler` using IOKit HID Manager for direct keyboard access
- Modifier tracking (shift, control, option, command, capsLock)
- `KeyCodeMap` for HID usage-to-character conversion (letters, numbers, symbols, special keys)
- `HighResolutionTimer` with `mach_absolute_time`-based nanosecond precision
- Configurable callback queue

**What is missing:**
- **Requires Accessibility/Input Monitoring permission** -- no permission request flow
- Does not handle dead keys, compose sequences, or IME input
- No integration with SwiftTerm's `NSTextInputClient` protocol (which handles marked text, IME, etc.)
- Missing arrow keys, function keys, and numpad in `KeyCodeMap`
- No way to coexist with SwiftTerm's own keyboard handling -- risk of double-processing events
- The `eventCount` property is not atomic despite being accessed from the HID callback queue

**Verdict:** This is the highest-risk component. IOKit HID keyboard monitoring requires system permissions and conflicts with SwiftTerm's NSEvent-based input. Should be deferred to last phase or made opt-in only for advanced users.

---

### 1.7 PredictiveRenderer.swift -- 60% Complete

**What exists:**
- `PredictiveRenderer` with command completion and shell history pattern matching
- `LocalEchoPredictor` for immediate keystroke echo
- LRU cache with eviction
- Background shell history loading (reads `~/.zsh_history` and `~/.bash_history`)
- Statistics tracking

**What is missing:**
- `CachedRender.renderedData` is `Data` but there is no actual rendering implementation -- the `prerender` method takes a renderer closure but nothing provides one
- `LocalEchoPredictor` is not connected to the existing local echo system in `Chau7TerminalView` (which already has `pendingLocalEcho` / `pendingLocalEchoOffset`)
- Command completions are hardcoded, not learned from actual shell completions
- No integration with the Metal renderer for pre-rendered glyph data
- Thread safety: `recentInput` array is mutated without synchronization

**Verdict:** The prediction logic is interesting but not critical for the initial Metal integration. The existing local echo in `Chau7TerminalView` already provides the most impactful latency reduction.

---

### 1.8 ThreadPriority.swift -- 90% Complete

**What exists:**
- `ThreadPriority` enum with `setRealTimePriority()`, `setRealTimeConstraint()`, `resetToDefault()`
- Mach thread policy configuration (extended policy, precedence, time constraint)
- `TerminalQoS` enum mapping render/PTY/parsing to DispatchQoS
- `makeQueue(for:label:)` factory
- `RenderThread` class with dedicated Thread + real-time priority + FPS measurement
- `PTYThreadManager` with separate read/write queues

**What is missing:**
- `RenderThread.renderLoop` uses `Thread.sleep` for frame pacing which is imprecise (jitter up to 1ms)
- No CVDisplayLink integration in `RenderThread` (display link is in `OptimalMetalView` and `IOSurfaceRenderer` separately)
- `preferPerformanceCores()` is best-effort only (macOS does not expose CPU affinity)
- No energy impact monitoring or adaptive throttling

**Verdict:** Production-ready for thread priority configuration. The `RenderThread` sleep-based pacing should be replaced with CVDisplayLink.

---

### 1.9 IOSurfaceRenderer.swift -- 65% Complete

**What exists:**
- `IOSurfaceRenderer` with IOSurface creation, Metal texture binding, CPU and GPU render paths
- Double-buffering support with front/back surface swap
- `LowLatencyDisplayController` with CVDisplayLink integration
- Display refresh rate detection
- Surface resize support

**What is missing:**
- `storageMode: .managed` on the Metal texture may not work with IOSurface on Apple Silicon (should be `.shared`)
- `LowLatencyDisplayController.displayCallback` dispatches to main queue, negating the latency benefit of CVDisplayLink
- No fence/semaphore synchronization between GPU rendering and surface presentation
- Cache mode property key may not be valid for all IOSurface versions
- The `attachToLayer` method sets `layer.contents` directly but this conflicts with CAMetalLayer-based rendering
- No Retina scaling support in surface dimensions

**Verdict:** Advanced optimization path. Should only be attempted after Metal + CAMetalLayer is stable. The CVDisplayLink-on-main-thread dispatch pattern defeats the purpose.

---

### 1.10 OptimalMetalView.swift -- 80% Complete

**What exists:**
- `OptimalMetalView` (MTKView subclass) with comprehensive low-latency CAMetalLayer configuration
- Three timing modes: vsync, immediate, adaptive
- Three frame pacing strategies: system, displayLink, targetFramerate
- CVDisplayLink integration for manual frame pacing
- Frame statistics (total frames, dropped frames, frame time)
- `NSView.configureMetalLayer` extension for converting any view to Metal
- Retina scaling support

**What is missing:**
- `optimalFrameRate` tries to access `screen.maximumFramesPerSecond` as an optional property, but this is not actually optional on NSScreen -- will need a guard
- No integration with `MetalTerminalRenderer` for actual drawing
- No keyboard/mouse event forwarding (since it replaces the SwiftTerm NSView)
- No accessibility support
- No scroll bar support
- The CVDisplayLink callback dispatches to main queue async, which adds ~1 frame of latency

**Verdict:** Good foundation for the Metal view container. The critical gap is that it cannot handle input or accessibility -- it needs to either wrap or coexist with SwiftTerm's TerminalView.

---

### 1.11 FeatureProfiler.swift -- 95% Complete

**What exists:**
- `FeatureProfiler` singleton with per-second bucketed metrics
- os_signpost integration for Instruments profiling
- `begin`/`end` token-based measurement API
- 10-second and 60-second rolling window aggregation
- Already used in production: `Chau7TerminalView.dataReceived` wraps render calls with profiler tokens

**What is missing:**
- No Metal-specific metrics (GPU frame time, draw call count, texture upload size)
- No automated alerting for performance regressions
- Bucket pruning uses linear scan

**Verdict:** Production-ready. Just needs new `FeatureMetric` cases for Metal rendering metrics.

---

## 2. Dependency Graph

```
                    FeatureProfiler (standalone, already in use)
                           |
                    FeatureSettings (standalone, already in use)
                           |
                    ThreadPriority
                     /          \
                    /            \
        PTYThreadManager    RenderThread
              |                  |
    LockFreeRingBuffer           |
              |                  |
    SIMDTerminalParser           |
              \                  |
               \                 |
         PerformanceTerminal  <--+-- (central coordinator)
              /    |    \
             /     |     \
    TripleBuffering |   PredictiveRenderer
                   |
          MetalTerminalRenderer
                   |
            OptimalMetalView
                   |
          IOSurfaceRenderer (optional, advanced)
                   |
        LowLatencyInput (optional, requires permissions)
```

**Integration Order (bottom-up):**

1. **FeatureProfiler** -- already integrated
2. **ThreadPriority** -- standalone, no dependencies
3. **SIMDTerminalParser** -- already partially integrated
4. **LockFreeRingBuffer** -- standalone, depends on swift-atomics (already in Package.swift)
5. **TripleBuffering** -- depends on `TerminalCell` from MetalTerminalRenderer
6. **MetalTerminalRenderer** -- depends on Metal framework (already linked)
7. **OptimalMetalView** -- depends on MetalTerminalRenderer
8. **PerformanceTerminal** -- depends on all above
9. **PredictiveRenderer** -- optional, can be deferred
10. **IOSurfaceRenderer** -- optional advanced path
11. **LowLatencyInput** -- optional, requires system permissions

---

## 3. Integration Architecture

### 3.1 Current Rendering Pipeline

```
PTY Process
    |
    v
LocalProcess (SwiftTerm) -- reads from file descriptor on background thread
    |
    v
LocalProcessTerminalView.dataReceived(slice:)
    |
    v
Chau7TerminalView.dataReceived(slice:)  [OVERRIDE]
    |-- SIMD pre-scan for fast-path detection
    |-- Local echo suppression
    |-- Dim sequence patching (Rust or Swift fallback)
    |
    v
super.dataReceived(slice:)  -->  feed(byteArray:)  -->  terminal.feed(buffer:)
    |
    v
Terminal.feed() -- SwiftTerm's escape sequence parser + terminal state machine
    |-- Updates Buffer.lines (array of BufferLine, each containing [CharData])
    |-- Calls TerminalDelegate methods (scrolled, bufferActivated, etc.)
    |
    v
queuePendingDisplay()  -- 16.67ms throttle (60fps)
    |
    v
updateDisplay()  -->  setNeedsDisplay(dirtyRect)
    |
    v
NSView.draw(dirtyRect:)
    |
    v
drawTerminalContents(dirtyRect:context:bufferOffset:)
    |-- Iterates rows in dirty rect
    |-- For each row: iterates CharData cells
    |-- Resolves Attribute.Color -> NSColor
    |-- Draws background rect with CGContext.fill
    |-- Draws text with CTLine/CTFontDrawGlyphs
    |
    v
Compositor (WindowServer) --> Display
```

### 3.2 Proposed Metal Pipeline (Coexistence Model)

The key architectural decision is **coexistence, not replacement**. SwiftTerm's `Terminal` remains the single source of truth for terminal state. The Metal renderer acts as an alternative display backend that reads from the same `Terminal` object.

```
PTY Process
    |
    v
LocalProcess (SwiftTerm) -- unchanged
    |
    v
Chau7TerminalView.dataReceived(slice:)  -- unchanged
    |
    v
terminal.feed(buffer:)  -- SwiftTerm parser, unchanged
    |
    v
queuePendingDisplay()  -- still throttles at 60fps
    |
    v
  [BRANCH POINT: Feature Flag]
    |
    |--- [Metal OFF] ---> NSView.draw() (existing path, unchanged)
    |
    |--- [Metal ON]  ---> SwiftTermBridge.syncToTripleBuffer()
                              |
                              v
                     TripleBufferedTerminal.updateBuffer
                         (populated from Terminal.getLine/getCharData)
                              |
                              v
                     TripleBufferedTerminal.commitUpdate()
                              |
                              v
                     OptimalMetalView.setNeedsDisplay()
                              |
                              v
                     MetalTerminalRenderer.render(cells:to:)
                              |
                              v
                     CAMetalLayer.nextDrawable() --> GPU --> Display
```

### 3.3 View Hierarchy (Metal Mode)

```
TerminalContainerView (NSView)
    |
    +-- Chau7TerminalView (hidden, still processes input + terminal state)
    |       |-- TerminalCursorLineView
    |       |-- TerminalHighlightView
    |
    +-- OptimalMetalView (visible, renders from triple buffer)
            |-- Cursor overlay (rendered in Metal)
            |-- Selection overlay (rendered in Metal)
```

The `Chau7TerminalView` remains in the view hierarchy but is hidden when Metal rendering is active. It continues to:
- Receive keyboard input via NSTextInputClient
- Process PTY data through `dataReceived`
- Manage the SwiftTerm `Terminal` instance
- Handle mouse events for selection
- Provide accessibility

The `OptimalMetalView` only handles display. Input events are forwarded from it to the hidden `Chau7TerminalView`.

---

## 4. SwiftTerm Bridge Design

### 4.1 The Core Problem

SwiftTerm's `Terminal` stores cell data as `BufferLine` arrays of `CharData`:

```swift
// SwiftTerm's data model
struct CharData {
    var attribute: Attribute  // fg/bg color + style flags
    var code: Int32           // Unicode codepoint (or lookup key)
    var width: Int8           // Display width (1 or 2 for CJK)
}

struct Attribute {
    var fg: Color    // .ansi256(code:) | .trueColor(r:g:b:) | .defaultColor
    var bg: Color    // same
    var style: CharacterStyle  // bold, italic, underline, etc.
}
```

The Metal renderer needs `TerminalCell`:

```swift
struct TerminalCell {
    var character: UInt32          // Unicode codepoint
    var foregroundColor: SIMD4<Float>  // RGBA float
    var backgroundColor: SIMD4<Float>  // RGBA float
    var flags: UInt32              // Style flags bitmask
}
```

### 4.2 Bridge Implementation: `SwiftTermBridge`

A new class `SwiftTermBridge` will handle the conversion:

```
SwiftTermBridge
    |-- Input: Terminal (SwiftTerm)
    |-- Input: Color palette (from Chau7TerminalView color scheme)
    |-- Output: TripleBufferedTerminal (update buffer)
    |
    |-- syncVisibleRows()  -- called on each display update
    |       |-- Reads terminal.rows x terminal.cols cells
    |       |-- Converts Attribute.Color -> SIMD4<Float> using cached palette
    |       |-- Writes to TripleBufferedTerminal.updateBuffer
    |       |-- Marks dirty rows
    |       |-- Calls commitUpdate()
    |
    |-- Color resolution cache
    |       |-- ansi256 palette: [UInt8: SIMD4<Float>] (256 entries, precomputed)
    |       |-- trueColor cache: LRU cache for recently seen RGB values
    |       |-- Default fg/bg from current color scheme
```

### 4.3 Critical API Surface on Terminal

The bridge needs these SwiftTerm APIs (all public):

| API | Purpose |
|-----|---------|
| `terminal.rows`, `terminal.cols` | Dimensions |
| `terminal.getLine(row:) -> BufferLine?` | Access row data |
| `line[col] -> CharData` | Access cell at column |
| `charData.getCharacter() -> Character` | Get displayed character |
| `charData.attribute.fg`, `.bg` | Get colors |
| `charData.attribute.style` | Get style flags |
| `charData.width` | Get display width |
| `terminal.buffer.x`, `.y` | Cursor position |
| `terminal.displayBuffer.yDisp` | Scroll offset |

**Thread safety concern:** `terminal.getLine(row:)` asserts it is called on the terminal's queue. The bridge must dispatch onto the correct queue or use SwiftTerm's existing synchronization. Since `drawTerminalContents` already reads the terminal from the main thread during `draw()`, and `queuePendingDisplay` dispatches to main, the bridge can safely sync on main thread.

### 4.4 Performance Optimization: Dirty Row Detection

Rather than syncing all rows every frame, detect which rows changed:

1. **SwiftTerm already tracks dirty lines** via `setNeedsDisplay(dirtyRect)` in `updateDisplay()`. We can intercept the dirty rect to know which rows changed.
2. **Alternative:** Compare a generation counter on each `BufferLine` (if exposed) or hash the row content.
3. **Fallback:** Full sync is acceptable at 60fps for typical terminal sizes (80x24 = 1920 cells, ~92KB of `TerminalCell` data per frame).

---

## 5. Phased Rollout

### Phase 3a: Metal Renderer Foundation (Est. 3-5 days)

**Goal:** Get Metal rendering working side-by-side with the existing CoreGraphics path, behind a feature flag.

**Deliverables:**

1. **Fix MetalTerminalRenderer compile errors**
   - Remove duplicate `simd_float4x4` orthographic initializer
   - Ensure shader source compiles with current Metal SDK

2. **Implement SwiftTermBridge**
   - New file: `SwiftTermBridge.swift`
   - Color resolution from `Attribute.Color` to `SIMD4<Float>`
   - Full Unicode character extraction (not just ASCII value)
   - Dirty row tracking

3. **Wire OptimalMetalView into TerminalContainerView**
   - Add Metal view as sibling to Chau7TerminalView
   - Forward keyboard/mouse events from Metal view to terminal view
   - Toggle visibility based on feature flag

4. **Implement basic TripleBuffering sync loop**
   - On each `queuePendingDisplay`, sync terminal state to triple buffer
   - Render from triple buffer to Metal drawable

5. **Add feature flag: `useMetalRenderer`**
   - Default: `false`
   - Persisted in UserDefaults
   - Accessible from Settings UI

**Success criteria:** Terminal displays correctly via Metal for ASCII content. Colors match the existing renderer. Toggle works without restart.

---

### Phase 3b: Feature Parity and Stability (Est. 5-8 days)

**Goal:** Achieve visual parity with the CoreGraphics renderer and handle all edge cases.

**Deliverables:**

1. **Extend glyph atlas for Unicode**
   - Dynamic atlas expansion: render glyphs on-demand when cache misses
   - Support for double-width (CJK) characters
   - Emoji rendering (likely via CoreText rasterization to texture)
   - Bold/italic glyph variants in atlas

2. **Cursor rendering in Metal**
   - Block, underline, and bar cursor styles
   - Cursor blink animation
   - Match existing `CaretView` behavior

3. **Selection rendering in Metal**
   - Highlight selected region with semi-transparent overlay
   - Support for rectangular selection

4. **Text decorations in Metal shader**
   - Underline, double-underline, strikethrough, overline
   - Dim (reduced alpha) rendering
   - Inverse video

5. **Retina/HiDPI support**
   - Scale glyph atlas by `backingScaleFactor`
   - Set `contentsScale` on CAMetalLayer

6. **Scrollback rendering**
   - Support scroll position offset when rendering
   - Coordinate with SwiftTerm's scroll state

7. **HighlightView integration**
   - Dangerous command highlights must render in Metal mode
   - Either render highlights in Metal or overlay the existing HighlightView

8. **Wire FeatureProfiler for Metal metrics**
   - Add `FeatureMetric.metalRender` case
   - Track GPU frame time, glyph cache misses, buffer sync time

**Success criteria:** Metal renderer is visually indistinguishable from CoreGraphics renderer. All test scenarios pass (Unicode, colors, decorations, cursor, selection, scrollback).

---

### Phase 3c: Performance Optimization and Advanced Features (Est. 5-7 days)

**Goal:** Realize the latency and throughput benefits of the full performance stack.

**Deliverables:**

1. **CVDisplayLink-based frame pacing**
   - Replace sleep-based `RenderThread` with CVDisplayLink from `OptimalMetalView`
   - Render on display link callback, not main thread
   - Requires rendering triple buffer read on the display link thread

2. **Real-time thread priority for render**
   - Apply `ThreadPriority.setRealTimePriority()` on the render thread
   - Measure impact on frame time consistency

3. **Dirty region optimization**
   - Use `DirtyRegionTracker` for sub-row GPU uploads
   - Only update changed portions of the instance buffer

4. **LockFreeRingBuffer for PTY data**
   - Route PTY data through `LockFreeByteBuffer` for zero-copy access
   - Use `peekContiguous()` with `SIMDTerminalParser` for zero-copy scanning
   - This requires modifying `LocalProcess` or adding a tap in `dataReceived`

5. **IOSurface rendering path (experimental)**
   - Add `IOSurfaceRenderer` as alternative to CAMetalLayer
   - Measure latency improvement vs. compositor overhead
   - Gate behind advanced/experimental flag

6. **PredictiveRenderer integration (optional)**
   - Pre-render common command completions
   - Display predicted text with reduced opacity
   - Reconcile when actual output arrives

7. **LowLatencyInput (optional, experimental)**
   - Only enable when user grants Input Monitoring permission
   - Must coexist with NSTextInputClient (disable HID for IME-active sessions)
   - Gate behind experimental flag with clear warning

**Success criteria:** Measurable latency reduction (target: < 5ms input-to-photon for keystrokes). No dropped frames at 120Hz. No regressions in throughput for bulk output (e.g., `cat` of large files).

---

## 6. Risk Assessment

### 6.1 High Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **SwiftTerm thread safety** | Terminal state accessed from render thread causes crashes | Always sync on main thread; use triple buffering to decouple read/write |
| **Glyph atlas overflow** | Unicode-heavy content causes atlas to run out of space | Implement multi-page atlas with LRU eviction; fallback to CoreText for rare glyphs |
| **Input event conflicts** | Metal view intercepts events meant for SwiftTerm | Keep Chau7TerminalView as first responder; Metal view is display-only |
| **Color accuracy** | Metal renderer colors don't match CoreGraphics | Use identical color space (sRGB); validate against screenshot comparison |
| **Memory pressure** | Triple buffer + glyph atlas + Metal resources increase memory by ~50-100MB | Lazy allocation; release Metal resources when Metal mode is disabled |

### 6.2 Medium Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Performance regression for small updates** | Metal overhead exceeds CoreGraphics for single-character updates | Skip Metal render when only 1-2 cells changed; use dirty tracking |
| **Retina scaling artifacts** | Glyphs appear blurry or misaligned on Retina displays | Test on 2x and 3x displays; use integer scaling for glyph atlas |
| **Scrollback memory** | Triple buffer stores full terminal state including scrollback | Only buffer visible rows + small margin; scrollback uses SwiftTerm's buffer |
| **macOS version compatibility** | Metal API differences across macOS versions | Test on macOS 13+ (minimum supported); use availability checks |
| **CVDisplayLink deprecation** | Apple may deprecate CVDisplayLink in future macOS | CADisplayLink (macOS 14+) as alternative; keep fallback timer |

### 6.3 Low Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **IOKit HID permissions** | User denies Input Monitoring | Graceful fallback to NSEvent; clear UI explaining the permission |
| **Metal device unavailable** | VM or very old Mac has no Metal | Feature flag prevents activation; runtime check in init |
| **swift-atomics version** | Atomics API changes | Already pinned to `from: "1.2.0"` in Package.swift |

---

## 7. Settings / Feature Flags

### 7.1 User-Facing Settings

| Setting | Type | Default | Location |
|---------|------|---------|----------|
| `useMetalRenderer` | Bool | `false` | Settings > Performance |
| `metalFramePacing` | Enum | `.vsync` | Settings > Performance > Advanced |
| `metalTargetFPS` | Int | `0` (= display refresh) | Settings > Performance > Advanced |

### 7.2 Internal / Debug Feature Flags

| Flag | Type | Default | Purpose |
|------|------|---------|---------|
| `useTripleBuffering` | Bool | `true` (when Metal on) | Can disable for A/B testing |
| `useRealtimeThreadPriority` | Bool | `false` | Experimental, may affect system responsiveness |
| `useIOSurfaceRenderer` | Bool | `false` | Experimental low-latency path |
| `useLowLatencyInput` | Bool | `false` | Requires Input Monitoring permission |
| `usePredictiveRenderer` | Bool | `false` | Experimental |
| `metalDebugOverlay` | Bool | `false` | Shows FPS, frame time, glyph cache stats |
| `forceFullRefresh` | Bool | `false` | Debug: disable dirty tracking |

### 7.3 FeatureSettings Integration

Add to `FeatureSettings.swift`:

```swift
// Performance > Metal Renderer
@Published var useMetalRenderer: Bool {
    didSet { UserDefaults.standard.set(useMetalRenderer, forKey: Keys.useMetalRenderer) }
}

// Performance > Advanced
@Published var metalFramePacing: String {  // "vsync" | "immediate" | "adaptive"
    didSet { UserDefaults.standard.set(metalFramePacing, forKey: Keys.metalFramePacing) }
}
```

### 7.4 Runtime Toggle Behavior

When `useMetalRenderer` is toggled:
- **ON:** Create `OptimalMetalView`, `MetalTerminalRenderer`, `TripleBufferedTerminal`. Hide Chau7TerminalView. Start sync loop.
- **OFF:** Destroy Metal resources. Unhide Chau7TerminalView. Resume CoreGraphics rendering.
- No terminal restart required. The SwiftTerm `Terminal` is unaffected.

---

## 8. Estimated Effort

| Phase | Scope | Estimate | Dependencies |
|-------|-------|----------|--------------|
| **3a** | Metal foundation + bridge + feature flag | 3-5 days | None (can start immediately) |
| **3b** | Feature parity (Unicode, cursor, selection, decorations) | 5-8 days | Phase 3a complete |
| **3c** | Performance optimization (CVDisplayLink, RT threads, dirty tracking) | 5-7 days | Phase 3b complete |
| **3c-opt** | Optional: IOSurface, predictive renderer, low-latency input | 3-5 days | Phase 3c complete |
| **Total** | Full Tier 3 | **16-25 days** | |

### Critical Path

```
Phase 3a (3-5d) --> Phase 3b (5-8d) --> Phase 3c (5-7d)
                                          |
                                          +--> Phase 3c-opt (3-5d, parallel/optional)
```

### Recommended Staffing

- 1 engineer full-time
- Phase 3a can be validated with basic ASCII terminals
- Phase 3b should include side-by-side visual comparison testing
- Phase 3c requires performance benchmarking infrastructure

---

## Appendix A: File Reference

| File | Path | Lines |
|------|------|-------|
| SIMDTerminalParser | `Sources/Chau7/Performance/SIMDTerminalParser.swift` | 337 |
| LockFreeRingBuffer | `Sources/Chau7/Performance/LockFreeRingBuffer.swift` | 351 |
| PerformanceIntegration | `Sources/Chau7/Performance/PerformanceIntegration.swift` | 465 |
| MetalTerminalRenderer | `Sources/Chau7/Performance/MetalTerminalRenderer.swift` | 557 |
| TripleBuffering | `Sources/Chau7/Performance/TripleBuffering.swift` | 339 |
| LowLatencyInput | `Sources/Chau7/Performance/LowLatencyInput.swift` | 285 |
| PredictiveRenderer | `Sources/Chau7/Performance/PredictiveRenderer.swift` | 462 |
| ThreadPriority | `Sources/Chau7/Performance/ThreadPriority.swift` | 316 |
| IOSurfaceRenderer | `Sources/Chau7/Performance/IOSurfaceRenderer.swift` | 384 |
| OptimalMetalView | `Sources/Chau7/Performance/OptimalMetalView.swift` | 344 |
| FeatureProfiler | `Sources/Chau7/Performance/FeatureProfiler.swift` | 193 |
| Chau7TerminalView | `Sources/Chau7/Chau7TerminalView.swift` | ~1600 |
| TerminalViewRepresentable | `Sources/Chau7/TerminalViewRepresentable.swift` | 253 |
| TerminalSessionModel | `Sources/Chau7/TerminalSessionModel.swift` | ~500 |

## Appendix B: SwiftTerm Rendering Path Detail

SwiftTerm's `drawTerminalContents` (in `AppleTerminalView.swift:866`) iterates visible rows and for each row:

1. Reads `displayBuffer.lines[row]` to get the `BufferLine`
2. For each cell in the line, reads `CharData`
3. Resolves `Attribute.Color` to platform color (NSColor/UIColor) using cached color tables
4. Fills background rectangles with `CGContext.fill`
5. Creates `CTLine` from attributed strings and draws with `CTLineDraw`
6. Handles decorations (underline, strikethrough) as separate `CGContext.stroke` calls
7. Handles double-width lines and Kitty graphics

The Metal bridge must replicate steps 1-3 to extract cell data. Steps 4-7 are replaced by the GPU pipeline.
