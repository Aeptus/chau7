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

## Dependencies

- **Uses:** Logging, Settings, Overlay
- **Used by:** Overlay, Settings/Views

## Related Docs

- `../../../services/chau7-remote/docs/PROTOCOL.md`
- `../../../apps/chau7-ios/docs/REMOTE-UX.md`
