# Chau7 Remote Control (macOS + iOS)

## Overview
Remote view and input for Chau7 terminal sessions from an iPhone. Works over the
internet without accounts using a relay that only forwards encrypted frames.

## Goals
- Live streaming terminal output.
- Simple input from iOS (text field + Send button).
- Hold-to-send default; setting to switch to tap-to-send.
- Send appends newline by default (toggleable).
- Accountless pairing via copy/paste payload (QR optional later).
- E2E encryption; relay cannot read data.
- Multiple Macs supported in iOS app.

## Non-Goals (v1)
- Full TUI control (arrow/ctrl/esc toolbar).
- File transfer or clipboard sync.
- Multi-user collaboration.

## Architecture
```
iOS App <-> Relay (CF Worker + Durable Object) <-> chau7-remote (Go) <-> Chau7 (Swift) <-> PTY
```

- macOS app owns PTY and UI.
- `chau7-remote` handles relay connection and E2E crypto.
- Relay only forwards encrypted frames.

## Pairing (Accountless)
Mac generates:
- `device_id` (UUID).
- `mac_pub` (X25519 public key).
- `pairing_code` (6 digits, TTL 10 minutes).

Pairing payload (copy/paste; QR optional later):
- `relay_url`
- `device_id`
- `mac_pub` (base64)
- `pairing_code`
- `expires_at` (ISO8601)

Flow:
1) Mac connects to relay and waits for pair requests.
2) iOS pastes pairing payload, connects to relay.
3) iOS sends `PAIR_REQUEST` to Mac (forwarded by relay).
4) Mac validates `pairing_code`, stores iOS public key, replies `PAIR_ACCEPT`.
5) Both sides persist keys locally (Keychain).

No on-Mac approval required.

## Session Establishment
Both sides connect to relay:
`wss://relay.example.com/connect/{device_id}?role=mac|ios`

Each side sends `HELLO` (cleartext). They compute:
- `shared_secret = X25519(own_priv, peer_pub)`
- `session_key = HKDF(shared_secret, salt=nonce_mac || nonce_ios)`
- `nonce_prefix = HKDF(shared_secret, info="nonce")` (4 bytes)

After `HELLO`, all frames are encrypted.

## Encryption
- Algorithm: ChaCha20-Poly1305
- Nonce: `nonce_prefix (4 bytes) + seq (8 bytes LE)`
- AAD: header bytes (version/type/flags/tab_id/seq/payload_len)

## Frame Format (Binary)
All frames (cleartext or encrypted) use the same header.

Header (LE):
- `version` (u8)
- `type` (u8)
- `flags` (u8)
- `reserved` (u8)
- `tab_id` (u32)  // 0 = active tab
- `seq` (u64)     // per-sender incrementing counter
- `payload_len` (u32)
- `payload` (bytes)

Flags:
- bit0: encrypted payload (1 = encrypted)
- bit1: reserved

## Message Types
Type codes (u8):
- `0x01 HELLO` (cleartext, JSON)
- `0x02 PAIR_REQUEST` (cleartext, JSON)
- `0x03 PAIR_ACCEPT` (cleartext, JSON)
- `0x04 PAIR_REJECT` (cleartext, JSON)
- `0x05 SESSION_READY` (encrypted, JSON)
- `0x10 TAB_LIST` (encrypted, JSON)
- `0x11 TAB_SWITCH` (encrypted, JSON)
- `0x20 OUTPUT` (encrypted, bytes)
- `0x21 INPUT` (encrypted, bytes)
- `0x22 SNAPSHOT` (encrypted, bytes)
- `0x30 PING` (encrypted, JSON)
- `0x31 PONG` (encrypted, JSON)
- `0x7F ERROR` (encrypted, JSON)
- `0x40 PAIRING_INFO` (local IPC, JSON)
- `0x41 SESSION_STATUS` (local IPC, JSON)
- `0x42 REMOTE_TELEMETRY` (encrypted over relay, local IPC after relay client decrypts)

JSON payloads are UTF-8.

### HELLO (JSON)
```
{
  "device_id": "uuid",
  "role": "mac|ios",
  "nonce": "base64-16bytes",
  "pub_key_fp": "base64-8bytes",
  "app_version": "x.y.z"
}
```

### PAIR_REQUEST (JSON)
```
{
  "device_id": "uuid",
  "pairing_code": "123456",
  "ios_pub": "base64",
  "ios_name": "iPhone"
}
```

### PAIR_ACCEPT (JSON)
```
{
  "device_id": "uuid",
  "mac_pub": "base64",
  "mac_name": "MacBook Pro"
}
```

### PAIR_REJECT (JSON)
```
{ "reason": "expired_code|invalid_code|internal_error" }
```

### SESSION_READY (JSON)
```
{ "session_id": "base64-8bytes" }
```

### TAB_LIST (JSON)
```
{
  "tabs": [
    { "tab_id": 1, "title": "Shell", "is_active": true },
    { "tab_id": 2, "title": "Claude", "is_active": false }
  ]
}
```

Tab IDs are session-scoped `u32` assigned by macOS.

### TAB_SWITCH (JSON)
```
{ "tab_id": 2 }
```

### OUTPUT (bytes)
Raw PTY bytes as-is.

### INPUT (bytes)
UTF-8 bytes. iOS app appends `\n` by default before sending.

### SNAPSHOT (bytes)
Raw PTY bytes for last N KB. Sent by macOS on iOS connect.

### PING/PONG (JSON)
```
{ "ts": "ISO8601" }
```

### ERROR (JSON)
```
{ "code": "unauthorized|bad_frame|internal_error", "message": "..." }
```

### PAIRING_INFO (JSON, local IPC)
```
{
  "relay_url": "wss://relay.example.com/connect",
  "device_id": "uuid",
  "mac_pub": "base64",
  "pairing_code": "123456",
  "expires_at": "ISO8601"
}
```

### SESSION_STATUS (JSON, local IPC)
```
{ "status": "connecting|ready|disconnected" }
```

### REMOTE_TELEMETRY (JSON)
Structured client telemetry emitted by the iOS app and persisted by macOS for
device-scoped debugging.

```
{
  "id": "uuid",
  "source": "ios",
  "device_id": "uuid",
  "device_name": "Christophe's iPhone",
  "app_version": "1.1.0",
  "session_id": "base64-8bytes",
  "event_type": "connect_requested",
  "status": "connecting",
  "tab_id": 2,
  "tab_title": "Shell",
  "message": "optional detail",
  "metadata": { "relay_host": "wss://..." },
  "timestamp": 794770102.125
}
```

`timestamp` uses Swift `Date` JSON encoding and is currently sent as a numeric
Foundation reference timestamp.

## Local IPC (Swift <-> Go)
Unix socket: `~/Library/Application Support/Chau7/remote.sock`

Use the same frame format, length-prefixed:
- `u32 frame_len` + `frame`

Encryption not needed for local IPC.

## Input Policy
- Hold-to-send default.
- Setting to disable hold (Send = tap).
- "Append newline on send" default (toggleable).
- No auto-send on Return key.

## iOS Permissions
- Camera access not used in v1; pairing is copy/paste to avoid camera permissions.

## Relay (Cloudflare) Details
Default: Cloudflare Worker + Durable Object.

WebSocket endpoint:
- `GET /connect/{device_id}?role=mac|ios`

Behavior:
- One active connection per role. New connection replaces old.
- DO forwards frames between mac and ios.
- No payload inspection; E2E encryption preserved.
- No message buffering (v1).

## Cloudflare Build Requirements (push to main)
Add a `services/chau7-relay/` directory with:
- `wrangler.toml`
- `package.json`
- `tsconfig.json`
- `src/worker.ts`
- `src/session.ts`

Example `wrangler.toml`:
```
name = "chau7-relay"
main = "src/worker.ts"
compatibility_date = "2024-10-01"
durable_objects.bindings = [
  { name = "SESSION", class_name = "SessionDO" }
]
migrations = [
  { tag = "v1", new_classes = ["SessionDO"] }
]
```

Cloudflare build config:
- Root directory: `services/chau7-relay`
- Build command: `npm install && npm run build`
- Deploy command: `npm run deploy`

## Rate Limits and Backpressure
- Batch output every 50-200ms.
- Cap output frame size (64 KB).
- Drop oldest output if iOS is lagging.
- Input rate limit: 10 KB/sec per device (configurable).

## Risks and Mitigations
- NAT/CGNAT: relay required for internet access.
- Relay compromise: E2E prevents content exposure.
- Device loss: revoke paired device from macOS UI.

## Milestones
1) Frame format + crypto helpers in `Chau7Core`.
2) `chau7-remote` Go client + Unix socket.
3) macOS RemoteControlManager integration.
4) iOS app (pairing, output stream, send).
5) CF relay implementation + CI deploy on push to main.
