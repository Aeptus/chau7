# chau7_terminal

Rust terminal emulator shared by the Chau7 macOS app (`apps/chau7-next`, linked as an rlib) and the iOS remote app (`apps/chau7-ios`, linked as a static library through the C header). Built on [alacritty_terminal](https://crates.io/crates/alacritty_terminal) for VT parsing and [portable-pty](https://crates.io/crates/portable-pty) for PTY management.

## What It Does

Exposes a Rust API for Chau7 and a C-compatible FFI interface for the iOS app. The boundary is documented in detail in [FFI_DESIGN.md](FFI_DESIGN.md).

## Source Files

| File | Lines | Purpose |
|------|-------|---------|
| `lib.rs` | 15 | Crate root, module declarations |
| `terminal.rs` | ~2900 | Core terminal state machine (grid, cursor, scrollback, resize) |
| `ffi.rs` | ~1600 | C-compatible FFI exports consumed by the iOS app |
| `graphics.rs` | ~1900 | Sixel, iTerm2 inline images, Kitty graphics protocol |
| `color.rs` | ~300 | ANSI/256/RGB color resolution and palette |
| `metrics.rs` | ~300 | Render timing, frame latency, performance counters |
| `pool.rs` | ~100 | Object pool for reducing allocation pressure in hot paths |
| `pty.rs` | ~100 | PTY spawn and lifecycle management |
| `types.rs` | ~300 | Shared types (CellData, RenderSnapshot, etc.) |

## Building

From the Rust workspace root (`crates/`):

```bash
# Debug build (all workspace crates)
cargo build

# Release build
cargo build --release

# Build only this crate
cargo build -p chau7_terminal

# Run tests
cargo test -p chau7_terminal

# Format + lint
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
```

Chau7 (`apps/chau7-next`) depends on this crate by path and sets `CHAU7_TERMINAL_SKIP_CBINDGEN` so its builds never rewrite `include/chau7_terminal.h`. The iOS build script (`apps/chau7-ios/Scripts/build-rust-terminal-ios.sh`) builds `libchau7_terminal.a` for each iOS target and regenerates the header.

## Dependencies

| Crate | Purpose |
|-------|---------|
| `alacritty_terminal` | VT100/VT220/xterm terminal emulation |
| `portable-pty` | Cross-platform PTY creation |
| `parking_lot` | Faster mutex for FFI thread safety |
| `crossbeam-channel` | Lock-free channels for render pipeline |
| `memchr` | Fast byte scanning for escape sequence parsing |
| `base64` | Inline image data decoding |
| `cbindgen` (build) | Auto-generates C header from Rust FFI exports |

## Integration with Swift (iOS)

The iOS app links the static library and calls the FFI functions declared in `include/chau7_terminal.h`. Memory ownership follows a strict "who allocates, who frees" rule. See [FFI_DESIGN.md](FFI_DESIGN.md) for the full contract including memory rules, thread safety guarantees, and code examples.
