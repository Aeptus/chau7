# Tier 2: Rust Terminal Renderer Fixes + Settings Toggle

## Overview

The Rust terminal backend (`RustTerminalView`) is a hybrid architecture:
- **Rust crate** (`rust/chau7_terminal/src/lib.rs`): Uses `alacritty_terminal` for VTE parsing + state management, `portable-pty` for PTY, exposes grid snapshots via C FFI (`dlopen`/`dlsym`)
- **Swift renderer** (`RustTerminalView.swift`): Polls Rust at 60fps via CVDisplayLink, renders grid cells using CoreGraphics/CoreText, manages input/selection/scrolling

The main repo already has significant integration work done: `TerminalViewLike` protocol, `UnifiedTerminalContainerView`, `TerminalViewRepresentable` with backend switching, and `TerminalSessionModel` with `attachRustTerminal()`. The worktree (`nice-borg`) is behind -- it still uses SwiftTerm-only `TerminalViewRepresentable`.

---

## 1. Visual Bug Fixes

### 1.1 Shell Starts Below the Tab Bar (Layout/Inset Issue)

**Symptom**: The shell prompt appears pushed down, as if there is invisible padding at the top of the terminal view.

**Root Cause Analysis**:
The `RustTerminalView.layout()` method (line 1906-1935 in main repo) currently does:
```swift
override func layout() {
    super.layout()
    gridView?.frame = bounds
    overlayContainer?.frame = bounds
    // ... recalculate cols/rows ...
}
```
The comment says "Match SwiftTerm behavior: use bounds directly without toolbar inset calculation. The hosting view is already positioned at contentLayoutRect by OverlayBlurView." However, the actual hosting hierarchy differs between SwiftTerm and Rust paths.

In the SwiftTerm path, `Chau7TerminalView` (a subclass of SwiftTerm's `LocalProcessTerminalView`) handles its own internal layout within `TerminalContainerView`. The `TerminalContainerView.layout()` simply does `terminalView.frame = bounds`.

For the Rust path, `RustTerminalContainerView` does the same thing. The issue is likely that when the Rust terminal calculates its grid dimensions (`cols` and `rows`), it uses the full `bounds.height` which includes the space that should be reserved for the title bar area if the overlay positioning isn't correctly accounting for it.

**Specific Fix**:
1. In `RustTerminalView.layout()`, verify that `bounds` correctly represents the usable area (below the toolbar/tab bar). Add debug logging comparing `bounds`, `frame`, `window?.contentLayoutRect`, and the parent view's frame.
2. The `setupViews()` method initializes `cols`/`rows` from `bounds` before the view is added to the window hierarchy, when `bounds` may be `.zero` or incorrect. The fix is already partially in place (the `startTerminal()` method recalculates), but ensure the initial `setupViews()` doesn't set incorrect dimensions that cause a layout flicker.
3. Check if `UnifiedTerminalContainerView.layout()` correctly propagates bounds to the inner `RustTerminalContainerView`. The chain is: `UnifiedTerminalContainerView` -> `RustTerminalContainerView` -> `RustTerminalView` -> `RustGridView`. Each `layout()` must set `frame = bounds` consistently.

**Files to modify**:
- `RustTerminalView.swift` -- `layout()` method
- `TerminalViewRepresentable.swift` -- `RustTerminalContainerView.layout()`
- Potentially `Chau7OverlayView.swift` if the hosting view positioning differs

**Estimated effort**: 2-4 hours

### 1.2 Cursor Not on Same Grid as Prompt (Cell Dimensions Mismatch)

**Symptom**: The cursor block appears offset from where the text characters are, suggesting the cursor's cell dimensions don't match the grid's cell dimensions.

**Root Cause Analysis**:
The cell dimensions are calculated in `updateCellDimensions()` (line 1946-1960):
```swift
private func updateCellDimensions() {
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let size = ("W" as NSString).size(withAttributes: attrs)
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    cellWidth = max(1, floor(size.width * scale) / scale)
    cellHeight = max(1, floor((font.ascender - font.descender + font.leading) * scale) / scale)
    gridView?.cellSize = CGSize(width: cellWidth, height: cellHeight)
}
```

The `RustGridView.draw()` method (line 174-267) uses `cellSize` for character positioning:
```swift
let cellHeight = cellSize.height
let cellWidth = cellSize.width
let lineHeight = font.ascender - font.descender + font.leading
let baselineOffset = (cellHeight - lineHeight) / 2.0 + font.ascender
```

The cursor drawing in `drawCursor()` (line 269-311) also uses `cellSize`:
```swift
let x = CGFloat(cursor.col) * cellWidth
let y = bounds.height - CGFloat(cursor.row + 1) * cellHeight
```

The mismatch likely occurs because:
1. `updateCellDimensions()` is called during `setupViews()` before the view has a window, so `window?.backingScaleFactor` returns `nil` and falls back to `NSScreen.main?.backingScaleFactor`. If the terminal is later displayed on a different screen (or the scale changes), the cell dimensions won't match.
2. The `baselineOffset` calculation in `draw()` uses the font's metrics directly, while the cell height was calculated with rounding (`floor`). This can cause a fractional-pixel misalignment between character baselines and cursor position.
3. The cursor position comes from `rust.cursorPosition` which returns `(col: UInt16, row: UInt16)` -- these are 0-indexed grid coordinates from the Rust side. If the Rust grid dimensions don't match the Swift-calculated `cols`/`rows`, the cursor will be at the wrong position.

**Specific Fix**:
1. Ensure `updateCellDimensions()` is called again in `viewDidMoveToWindow()` when the actual `backingScaleFactor` is available.
2. Ensure the cursor drawing uses the exact same coordinate math as the cell drawing. Both should use `bounds.height - CGFloat(row + 1) * cellHeight` for the Y coordinate.
3. Verify that the `cols`/`rows` passed to `rust.resize()` match what `RustGridView.draw()` expects. Add an assertion that `Int(snapshot.cols) == self.cols` and `Int(snapshot.rows) == self.rows` in `syncGridToRenderer()`.
4. Investigate whether `"W"` is the right character for cell width measurement. SwiftTerm uses a different approach -- check what character/method it uses for consistency.

**Files to modify**:
- `RustTerminalView.swift` -- `updateCellDimensions()`, `viewDidMoveToWindow()`, `syncGridToRenderer()`
- `RustGridView` (nested in `RustTerminalView.swift`) -- `draw()`, `drawCursor()`

**Estimated effort**: 2-3 hours

### 1.3 Welcome Tip Box Not Displayed

**Symptom**: The power user tip box that appears on shell startup in the SwiftTerm path does not appear in the Rust terminal path.

**Root Cause Analysis**:
The `feed()` method in `RustTerminalView` is a no-op (line 4265-4272):
```swift
func feed(text: String) {
    Log.trace("RustTerminalView[\(viewId)]: feed(text:) - Ignored (native renderer does not support direct feed)")
}

func feed(byteArray: [UInt8]) {
    Log.trace("RustTerminalView[\(viewId)]: feed(byteArray:) - Ignored (native renderer does not support direct feed)")
}
```

However, the main repo's `TerminalViewRepresentable` already fixes this by using `injectOutput()` instead. In `makeRustTerminalView()` (line 333-345):
```swift
container.onFirstRustLayout = { rustView in
    let tip = PowerUserTips.randomFormattedTip()
    let headerBox = terminalHeaderBox(cols: rustView.renderCols, message: tip)
    rustView.startTerminal(initialOutput: headerBox)
    // ...
}
```

And `startTerminal(initialOutput:)` calls `injectOutput()` (line 1869-1871):
```swift
if let initialOutput, !initialOutput.isEmpty {
    injectOutput(initialOutput)
}
```

The `injectOutput()` method (line 3174-3185) properly injects via the Rust FFI:
```swift
func injectOutput(_ text: String) {
    rustTerminal.injectOutput(data)
    headlessTerminal?.terminal.feed(byteArray: Array(data))
    needsGridSync = true
}
```

**Specific Fix**:
The fix is already implemented in the main repo. When porting to `nice-borg`:
1. Use the `startTerminal(initialOutput:)` pattern from the main repo's `TerminalViewRepresentable`.
2. Ensure `injectOutput()` is called after the Rust terminal is created but before the first poll cycle renders, so the tip appears at the top of the terminal.
3. The `terminalHeaderBox()` function needs the `cols` value. In the Rust path, this is available via `rustView.renderCols` after `setupViews()` but before `startTerminal()`. The box width calculation also accounts for a `-18` margin adjustment in the main repo version (line 418) vs `-2` padding in the worktree version -- use the main repo version.

**Files to modify**:
- `TerminalViewRepresentable.swift` -- Add Rust terminal creation path
- `RustTerminalView.swift` -- Already has `injectOutput()`, just needs to be wired up

**Estimated effort**: 1-2 hours

---

## 2. Missing Features (RustTerminalView vs SwiftTerm)

### 2.1 Already Implemented (in main repo)

Based on code analysis, these features are already implemented in the main repo's `RustTerminalView`:

| Feature | Status | Notes |
|---------|--------|-------|
| Basic text rendering | Done | `RustGridView.draw()` with CoreGraphics/CoreText |
| Bold/italic/underline/strikethrough | Done | Cell flags `CellFlags.bold`, etc. |
| Dim/hidden/inverse attributes | Done | Color resolution + alpha |
| 256-color + true color | Done | Rust-side `color_to_rgb_with_theme()` + Swift `resolveColors()` |
| ANSI 16-color palette (theme-aware) | Done | `ThemeColors` struct, `setColors()` FFI |
| Cursor rendering (block/underline/bar) | Done | `drawCursor()` with style support |
| Cursor blinking | Done | `tickCursorBlink()` with phase tracking |
| Keyboard input (printable + special keys) | Done | `keyDown()`, `generateTerminalSequence()` |
| Arrow keys (normal + application cursor mode) | Done | DECCKM mode support via FFI |
| Function keys (F1-F12) | Done | `functionKeySequence()` |
| Ctrl+key combinations | Done | `controlCharacter()` mapping |
| Alt/Option as meta key | Done | ESC prefix for Alt+key |
| Scrollback buffer | Done | Rust-side scrollback, `scrollLines()`, `scrollTo()` |
| Scroll wheel | Done | `scrollWheel()` event handling |
| Text selection (click+drag) | Done | `startSelection()`, `updateSelection()` via FFI |
| Double-click word selection | Done | Selection type = Semantic |
| Triple-click line selection | Done | Selection type = Lines |
| Select All | Done | `selectAll()` FFI |
| Copy/Paste | Done | Clipboard integration + bracketed paste mode |
| Context menu | Done | Right-click menu with Copy/Paste/Select All/Clear |
| Mouse reporting to TUI apps | Done | `sendMousePress()`, `sendMouseRelease()`, SGR encoding |
| Mouse mode detection | Done | `getMouseMode()`, `isMouseReportingActive()` FFI |
| Bell event detection | Done | `checkBell()` FFI + audio/visual feedback |
| Color scheme application | Done | `applyColorScheme()` with theme sync to Rust |
| Font configuration | Done | Font family/size with `updateCellDimensions()` |
| Scrollback size configuration | Done | `setScrollbackSize()` FFI |
| OSC 7 (current directory) | Done | `parseOSC7()` parsing |
| OSC 0/1/2 (terminal title) | Done | `getPendingTitle()` FFI |
| Process exit detection | Done | `getPendingExitCode()`, `isPtyClosed()` FFI |
| Shell environment variables | Done | `createWithEnv()` FFI |
| Local echo (latency optimization) | Done | Overlay cells with prediction + suppression |
| Smart scroll | Done | Don't auto-scroll when user is reading history |
| Inline images (iTerm2 protocol) | Done | `extractInlineImages()`, `InlineImageView` |
| Snippet insertion with placeholders | Done | `insertSnippet()` |
| Command history navigation | Done | `installHistoryKeyMonitor()` |
| Path detection (clickable file paths) | Done | Path hover detection |
| Debug state inspection | Done | `debugState()` FFI |
| Performance metrics | Done | Adaptive polling, dirty row tracking |

### 2.2 Not Yet Implemented / Partial

| Feature | Status | Gap Description |
|---------|--------|-----------------|
| `feed()` method | Stub (no-op) | Cannot directly inject ANSI text into the display. Workaround: use `injectOutput()` which goes through the Rust VTE parser. The `feed()` stub exists for `TerminalViewLike` protocol conformance. This is acceptable since `injectOutput()` covers the use cases. |
| Find/Search highlighting | Partial | `headlessTerminal` mirrors Rust state for search, but the find bar integration with `TerminalHighlightView` needs verification that it reads from the correct buffer. |
| Shell integration | Not tested | Shell integration scripts (prompt detection, command tracking) rely on OSC sequences being parsed. The Rust backend handles OSC 7 and OSC 0/1/2, but shell integration may need additional OSC handlers. |
| Semantic selection (URLs) | Partial | Double-click word selection works via `SelectionType::Semantic`, but URL detection and clickable links (beyond file paths) may not match SwiftTerm behavior. |
| Sixel graphics | Not implemented | The Rust crate's `alacritty_terminal` does not support Sixel. SwiftTerm may or may not support this -- low priority. |
| Wide character (CJK) rendering | Untested | The Rust side marks wide characters with `WIDE_CHAR` flag, but the Swift renderer draws each cell independently with fixed `cellWidth`. Wide characters (2-column) would need to render at `2 * cellWidth`. |
| Accessibility (VoiceOver) | Not implemented | `RustGridView` returns `nil` from `hitTest()` and sets `acceptsFirstResponder = false`. No accessibility tree is exposed. |

---

## 3. Settings Toggle

### 3.1 Current State

**Main repo** (`./`):
- `FeatureSettings.swift` already has `isRustTerminalEnabled` property (line 1103):
  ```swift
  @Published var isRustTerminalEnabled: Bool {
      didSet { UserDefaults.standard.set(isRustTerminalEnabled, forKey: Keys.rustTerminalEnabled) }
  }
  ```
- Key: `"feature.rustTerminalEnabled"` (line 1510)
- Default value: `true` (line 1725) -- Rust is the default when available
- `TerminalViewRepresentable.makeNSView()` checks `settings.isRustTerminalEnabled` to choose backend

**Worktree** (`nice-borg`):
- `FeatureSettings.swift` does NOT have `isRustTerminalEnabled`
- `TerminalViewRepresentable` only creates `Chau7TerminalView` (SwiftTerm)
- No `UnifiedTerminalContainerView`, no `RustTerminalContainerView`

### 3.2 Implementation Plan

#### Step 1: Add the Setting to FeatureSettings.swift (worktree)

Add to `FeatureSettings.swift`:

```swift
// In Keys struct:
static let rustTerminalEnabled = "feature.rustTerminalEnabled"

// As a @Published property:
@Published var isRustTerminalEnabled: Bool {
    didSet { UserDefaults.standard.set(isRustTerminalEnabled, forKey: Keys.rustTerminalEnabled) }
}

// In init():
self.isRustTerminalEnabled = defaults.object(forKey: Keys.rustTerminalEnabled) as? Bool ?? false
// NOTE: Default to FALSE (SwiftTerm) in the worktree since Rust terminal is still WIP
```

#### Step 2: Add Toggle to TerminalSettingsView

Add a new section to `TerminalSettingsView.swift` after the "Bell" section:

```swift
Divider()
    .padding(.vertical, 8)

// Backend
SettingsSectionHeader("Terminal Backend", icon: "cpu")

SettingsToggle(
    label: "Use Rust Terminal (Experimental)",
    help: "Use the Rust-based terminal renderer instead of SwiftTerm. " +
          "This is experimental and may have rendering issues. " +
          "Changes take effect for new tabs only.",
    isOn: $settings.isRustTerminalEnabled
)

if !RustTerminalView.isAvailable {
    Text("Rust terminal library not found. The SwiftTerm backend will be used.")
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.leading, 20)
}
```

#### Step 3: Show a "Restart Required" Note

Since the backend choice is made at terminal creation time (in `makeNSView`), changing the toggle does not affect already-open tabs. Add a note:

```swift
if settings.isRustTerminalEnabled {
    Text("New tabs will use the Rust terminal backend. Existing tabs are not affected.")
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.leading, 20)
}
```

**Estimated effort**: 1-2 hours

---

## 4. Integration: Wiring the Toggle into TerminalViewRepresentable

### 4.1 Port from Main Repo

The main repo has the complete integration. The following changes need to be ported to the `nice-borg` worktree:

#### 4.1.1 TerminalViewRepresentable.swift (Major Changes)

Replace the current `TerminalViewRepresentable` with the main repo version that includes:

1. **`RustTerminalContainerView`** class (lines 33-56): Container for `RustTerminalView`, mirrors `TerminalContainerView` for SwiftTerm.

2. **`UnifiedTerminalContainerView`** class (lines 59-107): Wrapper that holds either SwiftTerm or Rust container. Has `usesRustBackend` flag, accessors for both view types, and `onFirstSwiftTermLayout` / `onFirstRustLayout` callbacks.

3. **`makeNSView()` return type change**: From `TerminalContainerView` to `UnifiedTerminalContainerView`.

4. **Backend selection logic** (lines 116-133):
   ```swift
   func makeNSView(context: Context) -> UnifiedTerminalContainerView {
       let useRust = RustTerminalView.isAvailable && settings.isRustTerminalEnabled
       if useRust {
           return makeRustTerminalView()
       } else {
           return makeSwiftTermView()
       }
   }
   ```

5. **`makeRustTerminalView()`** method (lines 237-347): Creates `RustTerminalView`, configures shell/environment before first layout, wires up all callbacks (onInput, onOutput, onBufferChanged, etc.), sets up cursor line view and highlight view, uses `onFirstRustLayout` to call `startTerminal(initialOutput:)`.

6. **`updateNSView()`** method (lines 349-405): Dispatches to `updateSwiftTermView()` or `updateRustTerminalView()` based on `container.usesRustBackend`.

#### 4.1.2 TerminalSessionModel.swift (Additions)

Add the following to `TerminalSessionModel`:

1. **Properties**:
   ```swift
   private weak var rustTerminalView: RustTerminalView?
   private var retainedRustTerminalView: RustTerminalView?

   var existingRustTerminalView: RustTerminalView? {
       retainedRustTerminalView
   }
   ```

2. **`attachRustTerminal(_:)`** method: Similar to `attachTerminal()` but for `RustTerminalView`. Wires up `onTitleChanged`, `onProcessTerminated`, `onDirectoryChanged`, starts dev server monitoring, and auto-focuses.

3. **`activeTerminalView`** computed property: Returns whichever view is attached (Rust or SwiftTerm), for backend-agnostic operations.

#### 4.1.3 TerminalViewProtocol.swift (New File)

Port the `TerminalViewLike` protocol and conformance extensions. This enables `TerminalSessionModel` to work with either backend through a single protocol.

#### 4.1.4 Supporting View Updates

Port changes to:
- `TerminalHighlightView.swift`: Add `rustTerminalView` setter and support for reading grid data from `RustTerminalView`.
- `TerminalCursorLineView.swift`: Add `update(with:)` overload for `RustTerminalView`.

### 4.2 Build Considerations

- The `RustTerminalView.swift` file imports `SwiftTerm` for `HeadlessTerminal`. Ensure the `SwiftTerm` package dependency is present in the worktree.
- The Rust dylib (`libchau7_terminal.dylib`) must be built and available in one of the candidate paths. For development, set `CHAU7_RUST_LIB_PATH` environment variable.
- The `RustTerminalView.swift` file is ~4500 lines. Consider whether it should be in the worktree as-is or needs modifications for the `nice-borg` branch.

**Estimated effort**: 4-6 hours

---

## 5. Testing Strategy

### 5.1 Unit-Level Verification

1. **FFI binding check**: Verify `RustTerminalFFI.isAvailable` returns `true` when the dylib is present, and `false` when it is not. Test both `CHAU7_RUST_LIB_PATH` and bundle resource paths.

2. **Grid snapshot integrity**: Verify that `getGrid()` returns valid data by checking:
   - `snapshot.cols` and `snapshot.rows` match what was passed to `resize()`
   - `snapshot.cells` is non-null and contains `cols * rows` cells
   - Cell characters are valid Unicode codepoints

3. **Cell dimension consistency**: Verify that `cellWidth * cols` approximately equals `bounds.width` and `cellHeight * rows` approximately equals `bounds.height` (within 1 cell of rounding).

### 5.2 Visual Regression Testing

1. **Layout correctness**: Open a new tab with Rust terminal enabled.
   - Prompt should appear at the top-left of the terminal area (below tab bar, no extra padding)
   - Run `printf 'X%.0s' {1..80}; echo` to fill a line -- all 80 X's should be visible
   - Cursor should be aligned with the last character position

2. **Cursor alignment**: Type a command like `echo hello`. The cursor should track with each character. Delete characters -- cursor should retreat correctly.

3. **Welcome tip box**: Open a new tab. The ASCII box with a power user tip should appear and then the shell prompt should appear below it.

4. **Color rendering**: Run `chau7-colortest` or similar ANSI color test. Verify 16 ANSI colors match the color scheme, 256-color rendering is correct, and true color gradients render properly.

5. **Scrollback**: Generate lots of output (`seq 1 1000`), then scroll up. Verify scroll position is correct, content is readable, and scrolling back to bottom works.

### 5.3 Interactive Testing

1. **vim/neovim**: Open vim, verify:
   - Arrow keys work (application cursor mode)
   - Ctrl+C interrupts correctly
   - Visual mode selection works
   - Paste in insert mode uses bracketed paste

2. **tmux**: Start tmux, verify:
   - Pane splitting works
   - Mouse mode (if enabled) reports clicks correctly
   - Scroll wheel scrolls within tmux panes

3. **htop/top**: Run htop, verify:
   - Full-screen TUI rendering is correct
   - Colors display properly
   - Mouse interaction works (if mouse reporting enabled)

4. **Tab switching**: Open multiple tabs, some with Rust backend and some with SwiftTerm (change setting between tab creation). Verify:
   - Both backends work simultaneously
   - Switching between tabs doesn't cause crashes
   - Each tab maintains its own shell session

### 5.4 Settings Toggle Testing

1. **Default OFF**: Fresh install should default to SwiftTerm (OFF in worktree).
2. **Toggle ON**: Enable the toggle, open a new tab. Verify the Rust terminal is used (check logs for "Using Rust terminal backend").
3. **Toggle OFF**: Disable the toggle, open another new tab. Verify SwiftTerm is used.
4. **Existing tabs unchanged**: Toggling the setting should not affect already-open tabs.
5. **Library unavailable**: Remove/rename the dylib, verify the toggle is ignored and SwiftTerm is used with an info message in the settings.

### 5.5 Performance Testing

1. **Throughput**: Run `cat /dev/urandom | base64 | head -c 10000000` and verify no UI freezes.
2. **Memory**: Monitor memory usage during heavy output -- the cell buffer pool should prevent unbounded growth.
3. **CPU idle**: With a terminal at prompt (no activity), CPU usage should be near-zero (adaptive polling should reduce poll frequency).

**Estimated effort for full testing**: 4-6 hours

---

## 6. Task Breakdown and Estimated Effort

| # | Task | Effort | Priority | Dependencies |
|---|------|--------|----------|-------------|
| 1 | Add `isRustTerminalEnabled` to `FeatureSettings.swift` (worktree) | 30 min | P0 | None |
| 2 | Add toggle UI to `TerminalSettingsView.swift` | 1 hr | P0 | Task 1 |
| 3 | Port `RustTerminalView.swift` to worktree | 1 hr | P0 | None (file copy + review) |
| 4 | Port `TerminalViewProtocol.swift` to worktree | 30 min | P0 | Task 3 |
| 5 | Port `RustTerminalContainerView` + `UnifiedTerminalContainerView` to `TerminalViewRepresentable.swift` | 2 hr | P0 | Tasks 3, 4 |
| 6 | Port `attachRustTerminal()` + related changes to `TerminalSessionModel.swift` | 1.5 hr | P0 | Tasks 3, 4 |
| 7 | Port `TerminalHighlightView` + `TerminalCursorLineView` Rust support | 1 hr | P0 | Task 3 |
| 8 | Fix layout/inset issue (Bug 1.1) | 3 hr | P1 | Tasks 3-7 |
| 9 | Fix cursor alignment (Bug 1.2) | 2.5 hr | P1 | Tasks 3-7 |
| 10 | Verify tip box display (Bug 1.3) | 1 hr | P1 | Tasks 3-7 |
| 11 | Build Rust crate and configure dylib path | 1 hr | P0 | None |
| 12 | Visual regression testing | 3 hr | P1 | All above |
| 13 | Interactive testing (vim, tmux, etc.) | 2 hr | P2 | All above |
| 14 | Performance testing | 1 hr | P2 | All above |

**Total estimated effort**: 20-22 hours (3-4 days of focused work)

### Recommended Order of Execution

**Phase 1 -- Port & Toggle (Day 1-2)**:
1. Task 11 (build Rust crate)
2. Task 3 (port RustTerminalView.swift)
3. Task 4 (port TerminalViewProtocol.swift)
4. Task 1 (add setting)
5. Task 6 (port TerminalSessionModel changes)
6. Task 7 (port highlight/cursor line support)
7. Task 5 (port TerminalViewRepresentable)
8. Task 2 (add settings UI)

**Phase 2 -- Bug Fixes (Day 2-3)**:
9. Task 8 (layout fix)
10. Task 9 (cursor fix)
11. Task 10 (tip box verification)

**Phase 3 -- Testing (Day 3-4)**:
12. Task 12 (visual testing)
13. Task 13 (interactive testing)
14. Task 14 (performance testing)

---

## 7. Key Files Reference

### Worktree (nice-borg) -- Files to Modify
- `/apps/chau7-macos/Sources/Chau7/FeatureSettings.swift` -- Add `isRustTerminalEnabled`
- `/apps/chau7-macos/Sources/Chau7/SettingsViews/TerminalSettingsView.swift` -- Add toggle UI
- `/apps/chau7-macos/Sources/Chau7/TerminalViewRepresentable.swift` -- Add Rust path
- `/apps/chau7-macos/Sources/Chau7/TerminalSessionModel.swift` -- Add `attachRustTerminal()`

### Worktree -- Files to Add (port from main repo)
- `/apps/chau7-macos/Sources/Chau7/RustTerminalView.swift` -- Full Rust terminal view
- `/apps/chau7-macos/Sources/Chau7/TerminalViewProtocol.swift` -- `TerminalViewLike` protocol

### Main Repo -- Reference Source
- `/Sources/Chau7/RustTerminalView.swift` -- ~4500 lines, complete implementation
- `/Sources/Chau7/TerminalViewRepresentable.swift` -- Unified container + backend selection
- `/Sources/Chau7/TerminalSessionModel.swift` -- `attachRustTerminal()` + rust view retention
- `/Sources/Chau7/TerminalViewProtocol.swift` -- Protocol + conformance extensions
- `/Sources/Chau7/FeatureSettings.swift` -- `isRustTerminalEnabled` property + key
- `/rust/chau7_terminal/src/lib.rs` -- Rust FFI crate (alacritty_terminal + portable-pty)

### Rust Crate
- `/rust/chau7_terminal/src/lib.rs` -- Single-file crate, ~1500 lines
- Build: `cargo build --release` in `/rust/chau7_terminal/`
- Output: `rust/target/release/libchau7_terminal.dylib`
