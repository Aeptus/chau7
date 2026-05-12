# Remote Tests

Tests for remote pairing payloads, remote terminal viewing, prompt delivery, and IPC-facing helpers.

## Files

| File | Tests |
|------|-------|
| `RemotePairingInfoTests.swift` | Pairing JSON serialization and regeneration-plan decisions used by the Settings pairing UI |
| `RemoteFrameTests.swift` | Remote frame encoding/decoding and round-trip serialization |
| `RemoteInteractivePromptTests.swift` | Interactive prompt payload handling and display-facing behavior |
| `RemoteOutputBufferingTests.swift` | Buffered remote output flush/coalescing rules |
| `RemoteTabRegistryTests.swift` | Tab ID mapping used by remote control routing |
| `RemoteViewerModeTests.swift` | Remote viewer mode state management and sharing |
| `RemoteTerminalGridSnapshotTests.swift` | Structured terminal grid snapshot payloads for remote rendering |

## Corresponding Source

- `Sources/Chau7/Remote/` — remote control manager, settings-facing models, and IPC transport
- `Sources/Chau7Core/RemoteFrame.swift` — shared frame encoding/decoding primitives
