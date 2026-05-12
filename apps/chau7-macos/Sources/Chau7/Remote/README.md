# Remote

Remote terminal control and viewing via IPC.

## Files

| File | Purpose |
|------|---------|
| `RemoteControlManager.swift` | Manages the remote control agent subprocess and IPC connection |
| `RemoteIPCServer.swift` | Unix socket server for receiving remote terminal frames |
| `RemoteViewerMode.swift` | Read-only remote viewing with owner approval and viewer management |
| `RemoteViewerStatusView.swift` | SwiftUI status view showing connected viewers with approve/deny controls |

## Key Types

- `RemoteControlManager` — singleton managing the remote agent process and bidirectional IPC
- `RemoteViewerMode` — ObservableObject for view-only remote sharing with permission model

## Notes

- The macOS Pairing settings panel renders the current pairing JSON payload inline and keeps the raw payload copyable for the iOS companion app.
- Stopping the remote agent clears pairing/session UI state so Settings does not show stale payloads.
- Pairing regeneration is lifecycle-aware: it restarts a running agent, starts a stopped agent when Remote Control is enabled, and stays stopped when the feature itself is disabled.

## Dependencies

- **Uses:** Logging, Settings, Overlay
- **Used by:** Overlay, Settings/Views

## Related Docs

- `../../../services/chau7-remote/docs/PROTOCOL.md`
- `../../../apps/chau7-ios/docs/REMOTE-UX.md`
