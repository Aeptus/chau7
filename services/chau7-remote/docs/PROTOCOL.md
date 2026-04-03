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

Flow:

1. Mac connects to relay and waits for pair requests.
2. iOS pastes pairing payload and connects to relay.
3. iOS sends `PAIR_REQUEST` to the Mac through the relay.
4. Mac validates `pairing_code`, stores the iOS public key, and replies `PAIR_ACCEPT`.
5. Both sides persist keys locally.

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

Type codes (`u8`):

- `0x01 HELLO` (cleartext, JSON)
- `0x02 PAIR_REQUEST` (cleartext, JSON)
- `0x03 PAIR_ACCEPT` (cleartext, JSON)
- `0x04 PAIR_REJECT` (cleartext, JSON)
- `0x05 SESSION_READY` (encrypted, JSON)
- `0x10 TAB_LIST` (encrypted, JSON)
- `0x11 TAB_SWITCH` (encrypted, JSON)
- `0x12 ACTIVITY_STATE` (encrypted, JSON)
- `0x13 ACTIVITY_CLEARED` (encrypted, JSON)
- `0x20 OUTPUT` (encrypted, bytes)
- `0x21 INPUT` (encrypted, bytes)
- `0x22 SNAPSHOT` (encrypted, bytes)
- `0x30 PING` (encrypted, JSON)
- `0x31 PONG` (encrypted, JSON)
- `0x40 PAIRING_INFO` (local IPC, JSON)
- `0x41 SESSION_STATUS` (local IPC, JSON)
- `0x42 REMOTE_TELEMETRY` (encrypted over relay, local IPC after relay client decrypts)
- `0x7F ERROR` (encrypted, JSON)

JSON payloads are UTF-8.

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
    { "tab_id": 1, "title": "Shell", "is_active": true },
    { "tab_id": 2, "title": "Claude", "is_active": false }
  ]
}
```

Tab IDs are session-scoped `u32` values assigned by macOS.

### TAB_SWITCH

```json
{ "tab_id": 2 }
```

### ACTIVITY_STATE

This is the distilled remote AI task state selected by macOS for iOS Live Activity rendering.

```json
{
  "activity_id": "tab-2-session-abc123",
  "tab_id": 2,
  "tab_title": "Claude",
  "tool_name": "Claude",
  "project_name": "chau7-macos",
  "session_id": "abc123",
  "status": "running|waiting_input|completed|failed|idle",
  "headline": "Claude is editing files",
  "detail": "Needs approval to continue",
  "started_at": "ISO8601",
  "updated_at": "ISO8601",
  "priority": 100,
  "is_action_required": true,
  "approval": {
    "request_id": "uuid",
    "title": "Approve command",
    "message": "Run swift test?",
    "allow_label": "Approve",
    "deny_label": "Deny"
  }
}
```

Rules:

- macOS computes this from internal AI events and exports only the single highest-priority activity
- `waiting_input` wins over running work
- `completed` and `failed` are transient end states
- iOS must treat this payload as authoritative

### ACTIVITY_CLEARED

```json
{ "reason": "idle|disconnect|selection_changed|activity_ended" }
```

### OUTPUT

Raw PTY bytes.

### INPUT

UTF-8 bytes. iOS app appends `\n` by default before sending.

### SNAPSHOT

Raw PTY bytes for the last N KB. Sent by macOS on iOS connect.

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
  "relay_url": "wss://relay.example.com/connect",
  "device_id": "uuid",
  "mac_pub": "base64",
  "pairing_code": "123456",
  "expires_at": "ISO8601"
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
