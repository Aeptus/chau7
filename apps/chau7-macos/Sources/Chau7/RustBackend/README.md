# RustBackend

Alternative terminal backend using a Rust-based terminal emulator via FFI.

## Files

| File | Purpose |
|------|---------|
| `RustAnsiParser.swift` | Swift-side ANSI parser bridging Rust FFI structs for color and attribute segments |
| `RustDimPatcher.swift` | Dynamic library loader that patches dim attribute rendering in Rust output |
| `RustTerminalView.swift` | NSView-based terminal view powered by the Rust chau7_terminal FFI backend |
| `SixelKittyBridge.swift` | Enables Sixel and Kitty image protocols in SwiftTerm's TerminalOptions |

## Key Types

- `RustTerminalView` — NSView implementing the terminal display using the Rust FFI backend
- `RustDimPatcher` — singleton dynamically loading the dim-patching dylib at runtime
- `SixelKittyBridge` — singleton managing Sixel/Kitty graphics protocol settings

## Dependencies

- **Uses:** Terminal/Views (TerminalViewProtocol), Performance (RustTermBridge), Settings, Logging
- **Used by:** Terminal/Views (TerminalViewRepresentable), Performance (RustMetalDisplayCoordinator), Overlay
