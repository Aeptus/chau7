# Rendering

Swift: `apps/chau7-macos/Sources/Chau7/Rendering/` (4 files, 775 lines)
Swift tests: `Rendering/CommandBlockOverlayTests.swift`
Wave: 1
Depends on: RustBackend

Overlays drawn on top of the terminal grid: inline images (iTerm2 image
protocol) with their context menu, search match highlights, the cursor line
highlight and the command block gutter.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| RND-001 | Inline images from the iTerm2 protocol (`ESC ] 1337 ; File=... : base64 BEL`, `inline=1`) are shown at the cursor; `width`/`height` in cells, px, % or auto, `preserveAspectRatio`, capped at 800x600 pt; setting `feature.inlineImages` (default on) | `Rendering/InlineImageSupport.swift` (`InlineImageHandler`), `RustBackend/RustTerminalView.swift` (`extractInlineImages`, `renderInlineImages`) |  | `chau7_next/src/terminal/images.rs`, `chau7_next_core/src/inline_image.rs`, `chau7_terminal` (`take_pending_images`) | done | NSImage |
| RND-002 | Inline images stay anchored to their row: they scroll with the output, hide when off screen, rescale when the font changes, and are removed by Clear Scrollback | `RustBackend/RustTerminalView.swift` (`updateInlineImagePositions`, `rescaleInlineImages`, `clearScrollbackBuffer`), `Rendering/InlineImageSupport.swift` (`InlineImageView`) |  | `chau7_next/src/terminal/images.rs` (`ImageLayer::place`, `track_history`), `chau7_next/src/terminal/view.rs` (`clear_scrollback`) | done |  |
| RND-003 | Right-click an inline image: Copy Image, Save Image... (PNG), Open in Preview | `Rendering/InlineImageSupport.swift` (`InlineImageView`) |  | `chau7_next/src/terminal/view.rs` (`show_image_menu`, `on_image_menu`) | done | NSSavePanel, NSWorkspace |
| RND-004 | `imgcat` helper script that can be installed to `~/bin` | `Rendering/InlineImageSupport.swift` (`ImgcatScript`) | | | n/a | |
| RND-005 | Search matches highlighted in the viewport (yellow), current match in orange, at most 300 per screen, positions follow scrolling and new output | `Rendering/TerminalHighlightView.swift` |  | `chau7_next/src/terminal/paint.rs` (`prepaint`), `chau7_next/src/workspace/find.rs` (`apply_highlights`) | done |  |
| RND-006 | Cursor line highlight: current row, optional rows above and below, optional previously entered input lines, stronger when focused, adapts to light/dark | `Rendering/TerminalCursorLineView.swift`, `RustBackend/RustTerminalView.swift` (`updateCursorLineHighlight`) | | | n/a | |
| RND-007 | Command block gutter: colored left mark per command (blue running, green success, red failure, gray unknown), hover tooltip with command, directory, exit code, duration and line count, click to collapse and scroll to the block | `Rendering/CommandBlockOverlayView.swift` | `CommandBlockOverlayTests` | | n/a | |

## Notes

- RND-001/002: in Swift the image is parsed out of the raw output copy
  (`extractInlineImages`) and drawn as an `NSImageView` in an overlay; the
  emulator's own interceptor strips the sequence from the grid. Chau7 Next
  takes the decoded payloads from `chau7_terminal` (`take_pending_images`,
  anchored where the cursor was when the image arrived in the stream) and
  paints them with the grid (`terminal/images.rs`, `paint.rs`). Like Swift,
  the image is drawn over the following lines (no rows are reserved). Swift
  keeps images at a screen row; Chau7 Next anchors them to their line, so
  they also move with new output.
- RND-005: Next computes highlights only when the query changes, on Find
  Next/Previous and on tab switch. Scrolling with the wheel or new output
  leaves them at stale rows. Colors also differ slightly (HSLA yellow/orange).
- n/a rows are not reachable in the Swift app today:
  RND-004 `ImgcatScript.install` has no caller; RND-006 is attached in
  `TerminalViewRepresentable` but `updateNSView` always calls
  `setCursorLineHighlightEnabled(false)`; RND-007 `CommandBlockOverlayView`
  is never instantiated (its tests cover `CommandBlockManager` logic in the
  Terminal module). Port them only if the Swift side wires them up.
- Sixel and Kitty images are not drawn by the Swift app either (see
  RustBackend RBK-056), so they are not parity items.
