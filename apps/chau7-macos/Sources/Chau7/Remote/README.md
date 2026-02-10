# Remote

Remote terminal control and viewing via IPC, plus tmux control mode integration.

## Files

| File | Purpose |
|------|---------|
| `RemoteControlManager.swift` | Manages the remote control agent subprocess and IPC connection |
| `RemoteIPCServer.swift` | Unix socket server for receiving remote terminal frames |
| `RemoteViewerMode.swift` | Read-only remote viewing with owner approval and viewer management |
| `RemoteViewerStatusView.swift` | SwiftUI status view showing connected viewers with approve/deny controls |
| `TmuxControlMode.swift` | Manages tmux -CC control mode, mapping tmux windows/panes to Chau7 tabs |

## Key Types

- `RemoteControlManager` — singleton managing the remote agent process and bidirectional IPC
- `RemoteViewerMode` — ObservableObject for view-only remote sharing with permission model
- `TmuxControlMode` — ObservableObject parsing tmux control mode output into window/pane state

## Dependencies

- **Uses:** Logging, Settings, Overlay
- **Used by:** Overlay, Settings/Views
