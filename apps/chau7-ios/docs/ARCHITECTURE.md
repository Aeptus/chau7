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

#### Remote tab stream ownership

The phone keeps one explicit high-rate terminal subscription. On the first
inventory it starts from the Mac-active tab, then its selection is independent:
changing tabs on either device no longer changes focus on the other. A reconnect
re-subscribes the phone's still-valid selection as soon as live inventory is
available. macOS promotes only that subscribed session from its adaptive
1–8 second background poll to the same blocking, event-driven PTY drain used by
a locally visible terminal. Its hidden Mac renderer stays disabled, so remote
bytes do not invalidate the tab list or surrounding Mac UI. The promotion is
released when iOS enters approvals-only background mode or disconnects. This
single-subscription model bounds Mac CPU, relay traffic, and iPhone battery use
while the per-tab replay cache keeps recently viewed content ready for fast
switching.

#### Streaming latency diagnostics

Each timed output frame carries its macOS capture and send timestamps. iOS then
keeps the encrypted frame sequence attached while recording receive, application,
terminal-engine mutation, render-state publication, SwiftUI/UIView update, and
Core Graphics draw completion. A one-shot display-link callback records the next
refresh opportunity after drawing.

`Remote streaming window` entries in the in-app diagnostics report five-second
maximums for every boundary, plus `presented_frames` and
`last_presented_frame` (`transport-generation:frame-sequence`). The macOS-to-iOS
and end-to-end values are explicitly labeled `estimated` because they compare
two devices' wall clocks. All iOS-only boundaries use the same device clock.
The same entry includes the active, subscribed, and last-output tab IDs plus an
explicit match flag, so a transport/render-selection mismatch is visible without
logging terminal content.

The final display-link value proves that the correlated frame was rasterized and
reached the next compositor refresh opportunity. Public iOS APIs do not expose a
physical-panel scanout acknowledgment, so it must not be described as guaranteed
pixel scanout time.

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

### Onboarding & Pairing

- `OnboardingView` runs once on first launch (gated by the `has_completed_onboarding`
  AppStorage flag) and routes the user into pairing.
- `PairingSheetView` accepts the pairing payload three ways: scanning the Mac's QR
  code via `QRScannerView` (AVFoundation), a one-tap "Paste & Pair" from the
  clipboard, or manual entry. `PairingPayloadValidator` reports specific errors
  (missing field, expired code, unreadable text).
- When unpaired, the Terminal tab shows a `ContentUnavailableView` with a pairing
  call-to-action instead of an empty black surface.

### Status Display

`RemoteClientDisplay.swift` maps the client's internal status strings
(`Encrypted`, `Session ready`, …) to user-facing labels and a coarse
`ConnectionPhase` used for status dot colors, so implementation states never reach
the UI.

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
| `@AppStorage` | hold_to_send, append_newline, render_ansi, experimental_terminal_renderer, show_keyboard_bar, terminal_font_size, has_completed_onboarding |
