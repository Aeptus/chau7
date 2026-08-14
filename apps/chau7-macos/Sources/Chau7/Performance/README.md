# Performance

GPU-accelerated Metal rendering pipeline, memory-pressure handling, and
render/work profiling.

Note: earlier revisions of this README listed IOSurface/lock-free-input files
(`IOSurfaceRenderer`, `LockFreeRingBuffer`, `LowLatencyInput`,
`PerformanceIntegration`, `PredictiveRenderer`, `ThreadPriority`) that were
deliberately removed along with the CVDisplayLink frame-pacing machinery (see
`OptimalMetalView.swift` header). No IOSurface rendering exists in Chau7; keep
this table in sync with the directory so external memory tooling doesn't
attribute phantom subsystems.

## Files

| File | Purpose |
|------|---------|
| `FeatureProfiler.swift` | Records per-feature timing metrics with os.signpost integration |
| `MemoryPressureCoordinator.swift` | Broadcasts pressure levels to registered `MemoryReclaimable` caches |
| `MemoryPressureResponder.swift` | OS memory-pressure source + self-imposed footprint ceiling + scrollback budget hook |
| `MetalTerminalRenderer.swift` | GPU-accelerated terminal renderer with dynamic glyph atlas and instanced drawing |
| `OptimalMetalView.swift` | MTKView subclass configured for minimal display latency |
| `RenderPipelineProfiler.swift` | 30s aggregates of sync/commit/draw volume per view |
| `RustMetalDisplayCoordinator.swift` | Metal rendering coordinator for the Rust terminal backend (per window) |
| `RustTermBridge.swift` | Converts Rust FFI GridSnapshot cell data into TerminalCell structs for Metal |
| `SIMDTerminalParser.swift` | SIMD-accelerated byte scanner for escape sequences (16-32 bytes at a time) |
| `TerminalMemoryReclaimer.swift` | Critical-pressure reclamation of per-tab caches and invisible-window GPU resources |
| `TerminalWorkProfiler.swift` | Aggregated terminal backend work metrics (captures, replays, tab-switch paint) |
| `TripleBuffering.swift` | Triple-buffered terminal state with dirty row tracking and atomic swaps |
| `WakeupProfiler.swift` | Wakeup attribution instrumentation |

## Key Types

- `MetalTerminalRenderer` — core GPU renderer with glyph atlas, cursor, and decoration drawing
- `TripleBufferedTerminal` — lock-free triple buffer managing terminal cell state for GPU upload
- `RustMetalDisplayCoordinator` — orchestrator connecting Rust bridge, buffers, and Metal view

## Dependencies

- **Uses:** RustBackend, Logging
- **Used by:** Terminal/Views (TerminalViewRepresentable), Overlay, Debug
