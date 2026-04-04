# chau7_terminal

Rust terminal emulator providing FFI bindings to the Chau7 macOS app. Built on [alacritty_terminal](https://crates.io/crates/alacritty_terminal) for VT parsing and [portable-pty](https://crates.io/crates/portable-pty) for PTY management.

## What It Does

Exposes a C-compatible FFI interface that Swift loads at runtime via `dlopen`/`dlsym`. The boundary is documented in detail in [FFI_DESIGN.md](FFI_DESIGN.md).

## Source Files

| File | Lines | Purpose |
|------|-------|---------|
| `lib.rs` | 15 | Crate root, module declarations |
| `terminal.rs` | ~2900 | Core terminal state machine (grid, cursor, scrollback, resize) |
| `ffi.rs` | ~1600 | C-compatible FFI exports consumed by Swift |
| `graphics.rs` | ~1900 | Sixel, iTerm2 inline images, Kitty graphics protocol |
| `color.rs` | ~300 | ANSI/256/RGB color resolution and palette |
| `metrics.rs` | ~300 | Render timing, frame latency, performance counters |
| `pool.rs` | ~100 | Object pool for reducing allocation pressure in hot paths |
| `pty.rs` | ~100 | PTY spawn and lifecycle management |
| `types.rs` | ~300 | Shared types (CellData, RenderSnapshot, etc.) |

## Building

From the Rust workspace root (`apps/chau7-macos/rust/`):

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

The build produces `libchau7_terminal.dylib` in `target/{debug,release}/`. The macOS app build scripts (`Scripts/build-app.sh`, `Scripts/build-rust.sh`) handle copying the dylib into the app bundle.

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

## Integration with Swift

Swift loads the dylib at runtime and calls FFI functions via `@convention(c)` pointers. Memory ownership follows a strict "who allocates, who frees" rule. See [FFI_DESIGN.md](FFI_DESIGN.md) for the full contract including memory rules, thread safety guarantees, and code examples.

The pre-built dylib ships in `Libraries/` for convenience. Contributors only need the Rust toolchain if modifying terminal emulation code.
