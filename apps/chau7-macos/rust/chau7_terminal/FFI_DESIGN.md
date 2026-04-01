# Chau7 Terminal FFI Design

This document describes the Foreign Function Interface (FFI) design for the `chau7_terminal` Rust crate, which provides terminal emulation capabilities to the Chau7 macOS application via Swift.

## Overview

The FFI layer exposes a C-compatible interface that Swift can call using `@convention(c)` function pointers loaded at runtime via `dlopen`/`dlsym`. This approach provides:

- **Runtime flexibility**: The Rust library can be updated independently
- **Build isolation**: Swift and Rust compilation are decoupled
- **Graceful degradation**: The app can fall back to safe no-op behavior or alternate rendering paths if the Rust library is unavailable

## Memory Ownership Rules

### Principle: "Who allocates, who frees"

The FFI follows a strict ownership model where the allocator is responsible for providing a corresponding deallocation function.

### Opaque Handles

```
Chau7Terminal* terminal = chau7_terminal_create(80, 24, 10000);
// ... use terminal ...
chau7_terminal_destroy(terminal);  // REQUIRED - Rust allocated, Rust frees
```

**Rules:**
- `chau7_terminal_create()` allocates and returns ownership to the caller
- The caller MUST call `chau7_terminal_destroy()` exactly once
- After `destroy()`, the handle is invalid and must not be used

### Strings

```c
char* text = chau7_terminal_selection_text(terminal);
if (text) {
    // Use text...
    chau7_terminal_free_string(text);  // REQUIRED
}
```

**Rules:**
- Functions returning `char*` transfer ownership to the caller
- The caller MUST call `chau7_terminal_free_string()` for non-NULL strings
- NULL returns indicate no data (no action needed)

### Grid Snapshots

```c
GridSnapshot* grid = chau7_terminal_get_grid(terminal);
if (grid) {
    // Access grid->cells[row * grid->cols + col]...
    chau7_terminal_free_grid(grid);  // REQUIRED
}
```

**Rules:**
- `GridSnapshot` contains a dynamically allocated cell array
- The snapshot is independent of the terminal after creation
- Must be freed with `chau7_terminal_free_grid()`
- Snapshots remain valid even after `chau7_terminal_destroy()`

### Input Data (Caller-Owned)

```c
uint8_t buffer[1024];
ssize_t len = read(pty_fd, buffer, sizeof(buffer));
chau7_terminal_send_bytes(terminal, buffer, len);  // Rust does NOT take ownership
// buffer can be reused or freed immediately
```

**Rules:**
- `send_bytes` and `send_text` borrow data temporarily
- Rust copies what it needs during the call
- Caller retains ownership and can reuse/free immediately after

## Thread Safety Guarantees

### Per-Instance Thread Safety: NONE

A single `Chau7Terminal` instance is **NOT thread-safe**. The caller must ensure:

- Only one thread accesses a terminal at a time
- External synchronization (mutex/lock) if sharing across threads

### Cross-Instance Safety: FULL

Different terminal instances are completely independent:

```c
// Thread A                          // Thread B
Chau7Terminal* t1 = create(...);     Chau7Terminal* t2 = create(...);
send_bytes(t1, data1, len1);         send_bytes(t2, data2, len2);
// Safe: different instances
```

### Snapshot Independence

Grid snapshots are independent of their source terminal:

```c
// Thread A (UI)                     // Thread B (PTY reader)
GridSnapshot* snap = get_grid(t);    send_bytes(t, data, len);  // NOT SAFE!

// Correct approach:
lock(terminal_mutex);
GridSnapshot* snap = get_grid(t);
unlock(terminal_mutex);
// Now safe to use snap while Thread B continues
render(snap);                        // Safe: snapshot is independent
free_grid(snap);
```

### Recommended Pattern for Swift

```swift
class TerminalWrapper {
    private let queue = DispatchQueue(label: "terminal", qos: .userInteractive)
    private var terminal: OpaquePointer?

    func sendBytes(_ data: Data) {
        queue.async {
            data.withUnsafeBytes { buffer in
                chau7_terminal_send_bytes(self.terminal, buffer.baseAddress, buffer.count)
            }
        }
    }

    func getSnapshot() async -> GridSnapshot? {
        return await withCheckedContinuation { continuation in
            queue.async {
                let snap = chau7_terminal_get_grid(self.terminal)
                continuation.resume(returning: snap?.pointee)
            }
        }
    }
}
```

## Error Handling Conventions

### No Exceptions, No Panics

The FFI layer catches all Rust panics and converts them to safe returns:

- Pointer-returning functions return `NULL` on error
- Numeric functions return 0 or a sentinel value
- Boolean functions return `false` on error

### NULL Safety

All functions accept NULL handles gracefully:

```c
chau7_terminal_send_bytes(NULL, data, len);  // No-op, no crash
chau7_terminal_destroy(NULL);                 // No-op, no crash
chau7_terminal_free_string(NULL);             // No-op, no crash
```

### Validation

Input validation is performed internally:

- Invalid UTF-8 in `send_text` produces replacement characters
- Out-of-bounds coordinates are clamped
- Zero-size allocations return NULL

## Example Usage from Swift

### Loading the Library

```swift
import Darwin

class RustTerminal {
    // Function type aliases
    private typealias CreateFn = @convention(c) (UInt16, UInt16, UInt32) -> OpaquePointer?
    private typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
    private typealias SendBytesFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Void
    private typealias GetGridFn = @convention(c) (OpaquePointer?) -> UnsafePointer<GridSnapshot>?
    private typealias FreeGridFn = @convention(c) (UnsafePointer<GridSnapshot>?) -> Void
    private typealias PollFn = @convention(c) (OpaquePointer?) -> PollResult
    private typealias FreeStringFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private var handle: UnsafeMutableRawPointer?
    private var terminal: OpaquePointer?

    private var createFn: CreateFn?
    private var destroyFn: DestroyFn?
    private var sendBytesFn: SendBytesFn?
    private var getGridFn: GetGridFn?
    private var freeGridFn: FreeGridFn?
    private var pollFn: PollFn?
    private var freeStringFn: FreeStringFn?

    init?(cols: UInt16, rows: UInt16, scrollback: UInt32) {
        // Find and load the library
        guard let libPath = Bundle.main.path(forResource: "libchau7_terminal", ofType: "dylib"),
              let handle = dlopen(libPath, RTLD_NOW) else {
            return nil
        }
        self.handle = handle

        // Load function pointers
        guard let createSym = dlsym(handle, "chau7_terminal_create"),
              let destroySym = dlsym(handle, "chau7_terminal_destroy"),
              let sendBytesSym = dlsym(handle, "chau7_terminal_send_bytes"),
              let getGridSym = dlsym(handle, "chau7_terminal_get_grid"),
              let freeGridSym = dlsym(handle, "chau7_terminal_free_grid"),
              let pollSym = dlsym(handle, "chau7_terminal_poll"),
              let freeStringSym = dlsym(handle, "chau7_terminal_free_string") else {
            dlclose(handle)
            return nil
        }

        createFn = unsafeBitCast(createSym, to: CreateFn.self)
        destroyFn = unsafeBitCast(destroySym, to: DestroyFn.self)
        sendBytesFn = unsafeBitCast(sendBytesSym, to: SendBytesFn.self)
        getGridFn = unsafeBitCast(getGridSym, to: GetGridFn.self)
        freeGridFn = unsafeBitCast(freeGridSym, to: FreeGridFn.self)
        pollFn = unsafeBitCast(pollSym, to: PollFn.self)
        freeStringFn = unsafeBitCast(freeStringSym, to: FreeStringFn.self)

        // Create terminal instance
        terminal = createFn?(cols, rows, scrollback)
        if terminal == nil {
            dlclose(handle)
            return nil
        }
    }

    deinit {
        if let terminal = terminal {
            destroyFn?(terminal)
        }
        if let handle = handle {
            dlclose(handle)
        }
    }

    func processOutput(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            sendBytesFn?(terminal, ptr, buffer.count)
        }
    }

    func poll() -> PollResult? {
        return pollFn?(terminal)
    }

    func withGridSnapshot<T>(_ body: (UnsafePointer<GridSnapshot>) -> T) -> T? {
        guard let grid = getGridFn?(terminal) else { return nil }
        defer { freeGridFn?(grid) }
        return body(grid)
    }
}
```

### Efficient Rendering Loop

```swift
class TerminalView: NSView {
    private var rustTerminal: RustTerminal?
    private var displayLink: CVDisplayLink?

    func render() {
        guard let terminal = rustTerminal else { return }

        // Check what changed
        guard let result = terminal.poll() else { return }

        if result.grid_changed {
            terminal.withGridSnapshot { grid in
                let cols = Int(grid.pointee.cols)
                let rows = Int(grid.pointee.rows)
                let cells = grid.pointee.cells

                for row in 0..<rows {
                    for col in 0..<cols {
                        let cell = cells![row * cols + col]
                        drawCell(cell, at: (col, row))
                    }
                }
            }
        }

        if result.cursor_changed {
            // Update cursor rendering
        }

        if result.title_changed, let newTitle = result.new_title {
            let title = String(cString: newTitle)
            window?.title = title
            terminal.freeString(newTitle)  // Don't forget!
        }

        if result.bell {
            NSSound.beep()
        }
    }

    private func drawCell(_ cell: CellData, at position: (Int, Int)) {
        let fg = NSColor(
            red: CGFloat(cell.fg_r) / 255.0,
            green: CGFloat(cell.fg_g) / 255.0,
            blue: CGFloat(cell.fg_b) / 255.0,
            alpha: 1.0
        )

        let bg = NSColor(
            red: CGFloat(cell.bg_r) / 255.0,
            green: CGFloat(cell.bg_g) / 255.0,
            blue: CGFloat(cell.bg_b) / 255.0,
            alpha: 1.0
        )

        var traits: NSFontDescriptor.SymbolicTraits = []
        if cell.flags & UInt8(CELL_FLAG_BOLD) != 0 { traits.insert(.bold) }
        if cell.flags & UInt8(CELL_FLAG_ITALIC) != 0 { traits.insert(.italic) }

        // Draw character with attributes...
    }
}
```

## Performance Considerations

### Grid Snapshot API

The `get_grid()` function creates a complete copy of the terminal grid. This design decision prioritizes:

1. **Thread safety**: Snapshots can be used on render threads without locks
2. **Consistency**: Snapshot represents a single point in time
3. **Simplicity**: No complex invalidation logic needed

**Costs:**
- Memory: `(rows + scrollback) * cols * sizeof(CellData)` per snapshot
- CPU: O(rows * cols) copy operation

**Mitigations:**

1. **Poll before snapshot**: Only call `get_grid()` when `poll()` indicates changes

```swift
let result = terminal.poll()
if result.grid_changed {
    let grid = terminal.getGrid()  // Only when needed
}
```

2. **Limit scrollback**: For memory-constrained scenarios, reduce scrollback size

```c
// 1000 lines instead of 10000
Chau7Terminal* t = chau7_terminal_create(80, 24, 1000);
```

3. **Dirty region tracking** (future enhancement): Track which rows changed for partial updates

### Batch Input Processing

For high-throughput scenarios, batch PTY reads:

```swift
// Inefficient: many small calls
while let byte = readByte() {
    terminal.sendBytes(Data([byte]))  // Overhead per call
}

// Efficient: batch reads
var buffer = Data(count: 16384)
while let count = readInto(&buffer) {
    terminal.sendBytes(buffer.prefix(count))  // Single call
}
```

### Memory Layout

`CellData` is designed for cache-friendly access:

```
Offset  Size  Field
0       4     character (uint32_t)
4       1     fg_r
5       1     fg_g
6       1     fg_b
7       1     bg_r
8       1     bg_g
9       1     bg_b
10      1     flags
11      1     (padding)
Total: 12 bytes per cell (aligned to 4 bytes)
```

For an 80x24 terminal with 10,000 scrollback lines:
- Visible grid: 80 * 24 * 12 = 23,040 bytes (~22 KB)
- Full snapshot: 80 * 10,024 * 12 = 9,623,040 bytes (~9.2 MB)

### Color Resolution

Colors are pre-resolved to RGB in the grid snapshot to:
- Avoid repeated color scheme lookups during rendering
- Simplify the rendering code (direct RGB values)
- Enable color scheme changes without regenerating render state

## API Reference Summary

| Function | Allocates | Returns | Free With |
|----------|-----------|---------|-----------|
| `create` | Terminal | `Chau7Terminal*` | `destroy` |
| `destroy` | - | void | - |
| `send_bytes` | - | void | - |
| `send_text` | - | void | - |
| `resize` | - | void | - |
| `get_grid` | Snapshot | `GridSnapshot*` | `free_grid` |
| `free_grid` | - | void | - |
| `scroll_position` | - | `uint32_t` | - |
| `scroll_to` | - | void | - |
| `scroll_lines` | - | void | - |
| `scrollback_lines` | - | `uint32_t` | - |
| `selection_text` | String | `char*` | `free_string` |
| `selection_clear` | - | void | - |
| `selection_update` | - | void | - |
| `free_string` | - | void | - |
| `cursor_position` | - | `CursorPosition` | - |
| `poll` | String (maybe) | `PollResult` | `free_string` for `new_title` |
| `set_colors` | - | void | - |
| `set_default_colors` | - | void | - |

## Version History

- **v1.0** (2024): Initial FFI design
  - Core terminal lifecycle
  - Grid snapshot API
  - Basic scrolling and selection

## Future Considerations

1. **Incremental updates**: Return only changed rows instead of full grid
2. **GPU buffer sharing**: Direct Metal/Vulkan buffer access
3. **Async input**: Non-blocking input processing with completion callbacks
4. **Sixel/image support**: Extension API for inline graphics
