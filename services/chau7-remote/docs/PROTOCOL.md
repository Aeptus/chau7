# Chau7 Remote Protocol

This document defines the remote-control transport shared by:

- the macOS app
- the `chau7-remote` Go agent
- the Cloudflare relay
- the iOS companion app

## Overview

Remote view and input for Chau7 terminal sessions from an iPhone. Works over the
internet without accounts using a relay that only forwards encrypted frames.

## Architecture

```text
iOS App <-> Relay (CF Worker + Durable Object) <-> chau7-remote (Go) <-> Chau7 (Swift) <-> PTY
```

- macOS owns PTY and UI state.
- `chau7-remote` handles relay connection and E2E crypto.
- the relay only forwards encrypted frames.

## Pairing

Mac generates:

- `device_id` (UUID)
- `mac_pub` (X25519 public key)
- `pairing_code` (6 digits, TTL 10 minutes)

Pairing payload:

- `relay_url`
- `device_id`
- `mac_pub` (base64)
- `pairing_code`
- `expires_at` (ISO8601)
- `relay_secret` (optional) — shared HMAC secret the iOS device uses to
  authenticate to the relay. Present only when relay auth is configured.

Flow:

1. Mac connects to relay and waits for pair requests.
2. iOS pastes pairing payload and connects to relay.
3. iOS sends `PAIR_REQUEST` to the Mac through the relay.
4. Mac validates `pairing_code`, stores the iOS public key, and replies `PAIR_ACCEPT`.
5. Both sides persist keys locally.

## Session Establishment

Both sides connect to relay:

`wss://relay.chau7.sh/connect/{device_id}?role=mac|ios`

### Relay authentication

When a `relay_secret` is configured, every relay request carries a scoped,
single-use HMAC-SHA256 token in the `Authorization: Bearer` header (never the
query string):

```
wire:    v2.{ts}.{nonce}.{scope}.{base64url_sig}
signed:  v2:{device_id}:{role}:{scope}:{ts}:{nonce}
```

- `role` is `mac` or `ios`; `scope` is `connect`, `push`, or `pending`.
- `ts` is unix seconds; tokens are valid for 120s (+30s future skew).
- `nonce` is 16 random bytes (base64url) and is single-use — the relay rejects
  reuse, defeating replay/connection-takeover.
- The signature uses HMAC-SHA256 over the signed message with `relay_secret`.

Each side then sends `HELLO` (cleartext). They compute:

- `shared_secret = X25519(own_priv, peer_pub)`
- `session_key = HKDF(shared_secret, salt=nonce_mac || nonce_ios)`
- `nonce_prefix = HKDF(shared_secret, info="nonce")` (4 bytes)

After `HELLO`, all frames are encrypted.

## Encryption

- Algorithm: ChaCha20-Poly1305
- Nonce: `nonce_prefix (4 bytes) + seq (8 bytes LE)`
- AAD: header bytes (`version/type/flags/tab_id/seq/payload_len`)

## Frame Format

All frames, cleartext or encrypted, use the same binary header.

Header (little-endian):

- `version` (`u8`)
- `type` (`u8`)
- `flags` (`u8`)
- `reserved` (`u8`)
- `tab_id` (`u32`) where `0` means active tab
- `seq` (`u64`) per-sender incrementing counter
- `payload_len` (`u32`)
- `payload` (`bytes`)

Flags:

- bit 0: encrypted payload
- bit 1: reserved

## Message Types

Type codes (`u8`). The Swift enum `RemoteFrameType`
(`apps/chau7-macos/Sources/Chau7Core/RemoteFrame.swift`) and the Go table in
`internal/protocol/frame.go` must both match this list:

- `0x01 HELLO` (cleartext, JSON)
- `0x02 PAIR_REQUEST` (cleartext, JSON)
- `0x03 PAIR_ACCEPT` (cleartext, JSON)
- `0x04 PAIR_REJECT` (cleartext, JSON)
- `0x05 SESSION_READY` (encrypted, JSON)
- `0x10 TAB_LIST` (encrypted, JSON)
- `0x11 TAB_SWITCH` (encrypted, JSON)
- `0x12 ACTIVITY_STATE` (encrypted, JSON)
- `0x13 ACTIVITY_CLEARED` (encrypted, JSON)
- `0x14 CACHED_TAB_LIST` (encrypted, JSON — same payload as TAB_LIST, replayed by the agent from cache on connect)
- `0x15 INTERACTIVE_PROMPT_LIST` (encrypted, JSON)
- `0x20 OUTPUT` (encrypted, bytes)
- `0x21 INPUT` (encrypted, bytes)
- `0x22 SNAPSHOT` (encrypted, bytes)
- `0x23 TERMINAL_GRID_SNAPSHOT` (encrypted, bytes)
- `0x30 PING` (encrypted, JSON)
- `0x31 PONG` (encrypted, JSON)
- `0x40 PAIRING_INFO` (local IPC, JSON)
- `0x41 SESSION_STATUS` (local IPC, JSON)
- `0x42 REMOTE_TELEMETRY` (encrypted over relay, local IPC after relay client decrypts)
- `0x43 CLIENT_STATE` (encrypted, JSON)
- `0x50 APPROVAL_REQUEST` (encrypted, JSON)
- `0x51 APPROVAL_RESPONSE` (encrypted, JSON)
- `0x52 NOTIFICATION_EVENT` (encrypted, JSON)
- `0x7F ERROR` (encrypted, JSON)

JSON payloads are UTF-8.

Golden fixtures for every JSON payload live in `docs/fixtures/` and are
round-trip-tested from both Swift
(`apps/chau7-macos/Tests/Chau7Tests/Remote/RemoteWirePayloadFixtureTests.swift`)
and Go (`internal/agent/fixtures_test.go`). Change a payload by updating the
fixture and both implementations together; this document is the normative
description.

Unless a field is documented as an ISO 8601 string, Swift `Date` values are
encoded with the default `Codable` strategy: a JSON **number** of seconds
since 2001-01-01T00:00:00Z (`timeIntervalSinceReferenceDate`).

### HELLO

```json
{
  "device_id": "uuid",
  "role": "mac|ios",
  "nonce": "base64-16bytes",
  "pub_key_fp": "base64-8bytes",
  "app_version": "x.y.z"
}
```

### PAIR_REQUEST

```json
{
  "device_id": "uuid",
  "pairing_code": "123456",
  "ios_pub": "base64",
  "ios_name": "iPhone"
}
```

### PAIR_ACCEPT

```json
{
  "device_id": "uuid",
  "mac_pub": "base64",
  "mac_name": "MacBook Pro"
}
```

### PAIR_REJECT

```json
{ "reason": "expired_code|invalid_code|internal_error" }
```

### SESSION_READY

```json
{ "session_id": "base64-8bytes" }
```

### TAB_LIST

```json
{
  "tabs": [
    { "tab_id": 1, "title": "Shell", "is_active": true, "is_mcp_controlled": false },
    {
      "tab_id": 2,
      "title": "Claude",
      "project_name": "chau7-macos",
      "branch_name": "main",
      "ai_provider": "Claude",
      "is_active": false,
      "is_mcp_controlled": false
    }
  ]
}
```

Tab IDs are session-scoped `u32` values assigned by macOS. `project_name`,
`branch_name`, and `ai_provider` are optional and omitted when unknown. The
tab list aggregates controllable tabs across **all** open macOS windows, so a
client sees every session regardless of which window owns it.

### TAB_SWITCH

```json
{ "tab_id": 2 }
```

### ACTIVITY_STATE

This is the distilled remote AI task state selected by macOS for iOS Live
Activity rendering. Canonical Swift shape: `RemoteActivityState`
(`apps/chau7-macos/Sources/Chau7Core/RemoteActivityState.swift`).

```json
{
  "activity_id": "tab-2-session-abc123",
  "tab_id": 2,
  "tab_title": "Claude",
  "tool_name": "Claude",
  "project_name": "chau7-macos",
  "session_id": "abc123",
  "status": "running|approval_required|waiting_input|completed|failed|idle",
  "headline": "Claude is active",
  "detail": "swift test",
  "logo_asset_name": "claude-logo",
  "tab_color_name": "purple",
  "is_selected_tab": true,
  "started_at": 804600000,
  "updated_at": 804600042.5,
  "approval": {
    "request_id": "uuid",
    "command": "swift test",
    "flagged_command": "swift test"
  }
}
```

`started_at`/`updated_at` are Swift `Date` numbers (seconds since 2001-01-01).
`project_name`, `session_id`, `detail`, `logo_asset_name`, `tab_color_name`,
`started_at`, and `approval` are optional and omitted when absent.

Rules:

- macOS computes this from session state (`effectiveStatus` + approval contexts) and exports only the single highest-priority activity
- Priority order: `approval_required` > `waiting_input` > `failed` > `running` > `completed` > `idle`
- `completed` and `failed` are transient end states
- iOS must treat this payload as authoritative

### ACTIVITY_CLEARED

```json
{ "reason": "idle|disconnect|selection_changed|activity_ended" }
```

### CACHED_TAB_LIST

Same payload as TAB_LIST. The agent replays its last cached tab list to a
freshly connected client before live frames resume, so the UI is populated
immediately.

### INTERACTIVE_PROMPT_LIST

The full current set of interactive prompts (list replace, not delta).
Canonical Swift shape: `RemoteInteractivePromptListPayload`
(`apps/chau7-macos/Sources/Chau7Core/RemoteInteractivePrompt.swift`).

```json
{
  "prompts": [
    {
      "id": "prompt-1",
      "tab_id": 3,
      "tab_title": "migrate",
      "tool_name": "Claude Code",
      "project_name": "Mockup",
      "branch_name": "main",
      "current_directory": "/Users/dev/Mockup",
      "prompt": "Overwrite existing file?",
      "detail": "optional detail line",
      "options": [
        { "id": "yes", "label": "Yes", "response": "y" },
        { "id": "no", "label": "No", "response": "n", "is_destructive": true }
      ],
      "detected_at": 804600000
    }
  ]
}
```

`is_destructive` is present iff `true` (Go `omitempty`; Swift mirrors this).
`detected_at` is a Swift `Date` number.

### CLIENT_STATE

Sent by iOS whenever its delivery-relevant state changes. The agent uses it
to gate push notifications (`shouldNotifyClientViaPush`). Canonical Swift
shape: `RemoteClientStatePayload`
(`apps/chau7-macos/Sources/Chau7Core/Remote/RemoteWirePayloads.swift`).

```json
{
  "app_state": "foreground|background",
  "stream_mode": "full|approvals_only",
  "push_token": "hex",
  "push_topic": "bundle-id",
  "push_environment": "development|production",
  "notifications_authorized": true
}
```

### APPROVAL_REQUEST

Sent by macOS when a command or protected action needs remote approval.
Canonical Swift shape: `ApprovalRequestPayload` (Chau7Core).

```json
{
  "request_id": "uuid",
  "command": "rm -rf build",
  "flagged_command": "rm -rf build",
  "timestamp": "ISO8601",
  "tab_title": "build",
  "tool_name": "Claude Code",
  "project_name": "Mockup",
  "branch_name": "main",
  "current_directory": "/Users/dev/Mockup",
  "recent_command": "swift build",
  "context_note": "optional",
  "session_id": "sess-abc"
}
```

All fields after `timestamp` are optional. Decoders must tolerate a missing
`timestamp` (older agent re-encodes omitted it) and fall back to receipt time.
`push_title` / `push_subtitle` / `push_body` carry pre-formatted push text
composed on the Mac by the shared notification formatter; the agent and iOS
prefer them and fall back to local formatting when absent.

### APPROVAL_RESPONSE

```json
{ "request_id": "uuid", "approved": true }
```

### NOTIFICATION_EVENT

A user-facing notification composed entirely on the Mac (semantic kind +
pre-formatted text). The agent relays it as a push when the client is
push-eligible; it dedups on `identity_key` (at most one push per key) and
never formats or decides. This is how non-approval kinds (task finished /
failed) reach the phone. Canonical Swift shape:
`RemoteNotificationEventPayload` (Chau7Core).

```json
{
  "kind": "task_finished",
  "identity_key": "session:sess-abc",
  "title": "Mockup — Claude Code: Finished",
  "subtitle": "build · Mockup (main)",
  "body": "All tests pass",
  "thread_id": "build"
}
```

`subtitle` and `thread_id` are optional.

### OUTPUT

Raw PTY bytes.

### INPUT

UTF-8 bytes. iOS app appends `\n` by default before sending.

### SNAPSHOT

Raw PTY bytes for the last N KB. Sent by macOS on iOS connect.

### TERMINAL_GRID_SNAPSHOT

Binary encoding of the current terminal grid (cells + attributes) for
faithful remote rendering. See `RemoteTerminalGridSnapshot` in Chau7Core for
the layout.

### PING / PONG

```json
{ "ts": "ISO8601" }
```

### ERROR

```json
{ "code": "unauthorized|bad_frame|internal_error", "message": "..." }
```

### PAIRING_INFO

Local IPC payload:

```json
{
  "relay_url": "wss://relay.chau7.sh/connect",
  "device_id": "uuid",
  "mac_pub": "base64",
  "pairing_code": "123456",
  "expires_at": "ISO8601",
  "relay_secret": "optional-shared-hmac-secret"
}
```

### SESSION_STATUS

Local IPC payload:

```json
{ "status": "connecting|ready|disconnected" }
```

### REMOTE_TELEMETRY

Structured iOS-side telemetry forwarded to macOS for device-scoped debugging.

```json
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

## REST channel (relay HTTP API)

Alongside the WebSocket, the relay exposes an HTTP API used for push
delivery and for state recovery when the WS is not (yet) connected. All
routes require a scoped single-use HMAC relay token unless the relay runs
with `RELAY_ALLOW_UNAUTHENTICATED`.

- `POST /push/register/:deviceId` (role=mac, scope=push) — register an iOS
  device's APNs token. Body: `{ "token", "topic", "environment" }`.
- `POST /push/notify/:deviceId` (role=mac, scope=push) — forward a push
  notification to the registered device. The relay builds the APNs payload
  (`time-sensitive` interruption level, thread grouping by tab title).
- `POST /pending/:deviceId` (role=mac, scope=pending) — replace the pending
  approvals/prompts snapshot. Body: the `pending_state.json` fixture shape:

  ```json
  {
    "approvals": [ { /* APPROVAL_REQUEST payload */ } ],
    "interactive_prompts": [ { /* INTERACTIVE_PROMPT_LIST entry */ } ]
  }
  ```

  The agent posts this on every pending-state change (`syncPendingState`).
- `GET /pending/:deviceId` (role=ios, scope=pending) — read the snapshot.
  The relay adds an `updated_at` ISO 8601 string stamped at write time.

**Consistency:** the REST snapshot and the WS delta stream are two
independent channels. Clients must merge (never wholesale-replace) so that a
stale snapshot cannot clobber approvals that arrived over the WS after the
snapshot was written. Additionally, the agent stamps each snapshot with
`session_epoch` (a random identifier minted per agent session generation,
regenerated on `resetSession`) and `state_version` (monotonic within an
epoch): within one epoch a client applies only strictly newer versions, and
a changed epoch resets its arbitration state. Snapshots from older agents
lack the fields and rely on the client's delta-journal merge alone.
