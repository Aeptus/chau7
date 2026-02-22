# Performance

GPU-accelerated Metal rendering pipeline, lock-free buffers, SIMD parsing, and low-latency input.

## Files

| File | Purpose |
|------|---------|
| `FeatureProfiler.swift` | Records per-feature timing metrics with os.signpost integration |
| `IOSurfaceRenderer.swift` | Direct GPU-to-display rendering via IOSurface bypassing the compositor |
| `LockFreeRingBuffer.swift` | SPSC lock-free ring buffer using Swift Atomics for PTY data transfer |
| `LowLatencyInput.swift` | IOKit HID-based keyboard input handler bypassing the NSEvent queue |
| `MetalTerminalRenderer.swift` | GPU-accelerated terminal renderer with dynamic glyph atlas and instanced drawing |
| `OptimalMetalView.swift` | MTKView subclass configured for minimal display latency (VSync, frame pacing) |
| `PerformanceIntegration.swift` | Unified API connecting all low-latency components with terminal infrastructure |
| `PredictiveRenderer.swift` | Pre-caches likely terminal output to reduce perceived latency |
| `RustMetalDisplayCoordinator.swift` | Metal rendering coordinator for the Rust terminal backend |
| `RustTermBridge.swift` | Converts Rust FFI GridSnapshot cell data into TerminalCell structs for Metal |
| `SIMDTerminalParser.swift` | SIMD-accelerated byte scanner for escape sequences (16-32 bytes at a time) |
| `ThreadPriority.swift` | Mach thread policy configuration for real-time render and input threads |
| `TripleBuffering.swift` | Triple-buffered terminal state with dirty region tracking and atomic swaps |

## Key Types

- `MetalTerminalRenderer` — core GPU renderer with glyph atlas, cursor, and decoration drawing
- `TripleBufferedTerminal` — lock-free triple buffer managing terminal cell state for GPU upload
- `RustMetalDisplayCoordinator` — orchestrator connecting Rust bridge, buffers, and Metal view
- `LockFreeRingBuffer<T>` — high-throughput SPSC ring buffer with atomic read/write positions

## Dependencies

- **Uses:** RustBackend, Logging
- **Used by:** Terminal/Views (TerminalViewRepresentable), Overlay, Debug
