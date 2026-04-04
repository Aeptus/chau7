# iOS App Architecture

Chau7 Remote is the iOS companion app for controlling macOS Chau7 sessions.
It connects to a paired Mac over an encrypted WebSocket relay.

## Targets

| Target | Purpose |
|--------|---------|
| `Chau7RemoteApp` | Main app — 17 Swift files, ~4,200 lines |
| `Chau7RemoteWidget` | ActivityKit Live Activities for Dynamic Island and Lock Screen |

## Architecture Layers

```
┌─ UI Layer ──────────────────────────────────────────┐
│  TerminalView    ApprovalsView    SettingsView       │
│  PairingSheetView    RemoteTerminalRendererView      │
├─ State ─────────────────────────────────────────────┤
│  RemoteClient (@Observable singleton)                │
│  RemoteTerminalRendererStore    AppSettings          │
├─ Network ───────────────────────────────────────────┤
│  URLSessionWebSocketTask → Cloudflare relay          │
│  RemoteCrypto (ChaChaPoly over Curve25519)           │
│  RemoteReconnectBackoff (exponential, 5 attempts)    │
├─ Persistence ───────────────────────────────────────┤
│  KeychainStore (private key, pairing, trusted ID)    │
│  @AppStorage (UI preferences)                        │
├─ System Integration ────────────────────────────────┤
│  APNs (push for offline approvals)                   │
│  ActivityKit (Live Activities / Dynamic Island)       │
│  URL scheme (chau7remote://)                         │
└─────────────────────────────────────────────────────┘
```

## Core Components

### RemoteClient

The central singleton (~1,500 lines). Manages:

- **WebSocket lifecycle**: connect, handshake, receive loop, reconnect
- **Cryptography**: X25519 key exchange → HKDF → ChaChaPoly session
- **Tab state**: remote tab list, active tab, output buffering
- **Approvals**: pending requests, response queue, in-flight tracking
- **Interactive prompts**: Claude/Codex option selection
- **Live Activities**: state updates to `RemoteLiveActivityManager`
- **Background handling**: scene phase transitions, background tasks, stream mode switching

### Connection Lifecycle

```
Disconnected → Connecting → Handshake → Encrypted → Active
                   ↓                        ↓
               Timeout/Error          Background Suspended
                   ↓                        ↓
            Reconnect (backoff)       Foreground Resume
```

1. User pastes pairing JSON (relay URL, device ID, Mac public key, pairing code)
2. Connect WebSocket to `relay/{deviceID}?role=ios`
3. Exchange Hello payloads (nonces) → derive shared secret
4. Send PairRequest → receive PairAccept → session ready
5. Trusted pairings skip steps 3-4 on reconnect

### Terminal Rendering

Two paths, toggled by Settings:

| Path | Default | Implementation |
|------|---------|----------------|
| Text | Yes | `UITextView` with optional ANSI stripping |
| Grid | No | Rust terminal emulator via `Chau7Core` FFI → custom `UIView.draw()` |

The grid renderer (`RemoteTerminalRendererStore` → `RemoteRustTerminalPlayback` →
`RemoteTerminalCanvasView`) replays incoming bytes through the Rust terminal
emulator and renders cell-by-cell with color, formatting, and cursor.

### Approval Flow

1. Mac sends `ApprovalRequestPayload` over relay
2. `RemoteClient` appends to `pendingApprovals`
3. Local notification posted (or suppressed if push woke the app)
4. User taps Allow/Deny in `ApprovalsView` or notification action
5. `RemoteClient` sends encrypted `ApprovalResponsePayload`
6. Request moves to `approvalHistory`

### Live Activities

`RemoteLiveActivityManager` creates and updates `Activity<Chau7RemoteActivityAttributes>`
instances. The Dynamic Island shows the active tool, project name, and
approve/deny buttons. Activities auto-dismiss after completion (8s) or failure (20s).

### Deep Links

URL scheme `chau7remote://` with actions: `open`, `switch`, `approve`, `deny`.
Parsed by `RemoteActivityURLAction` and routed through `RemoteClient.handle(url:)`.

## Dependencies

| Framework | Purpose |
|-----------|---------|
| `Chau7Core` | Shared protocol types, Rust FFI terminal bindings |
| `CryptoKit` | Curve25519, ChaChaPoly, SHA256, HKDF |
| `Security` | Keychain storage |
| `ActivityKit` | Live Activities and Dynamic Island |
| `UserNotifications` | APNs push and local notifications |
| `CoreText` | Font metrics for grid renderer |

## Persistence

| Store | Data |
|-------|------|
| Keychain (`com.chau7.remote`) | iOS private key, Mac public key, pairing payload, trusted identity |
| `@AppStorage` | hold_to_send, append_newline, render_ansi, experimental_terminal_renderer |
