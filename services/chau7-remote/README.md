# Chau7 Remote Agent

Go process that bridges the macOS app to the Cloudflare relay. Runs as a
local daemon, communicates with the app over a Unix socket, and maintains
an encrypted WebSocket connection to the relay.

## What It Does

- Listens on a Unix socket for IPC messages from the macOS app
- Performs X25519 key exchange and establishes ChaCha20-Poly1305 encrypted sessions
- Relays encrypted frames between the app and the Cloudflare relay via WebSocket
- Manages persistent pairing state (survives restarts)
- Registers iOS devices for APNs push notifications

## Source Files

| Path | Purpose |
|------|---------|
| `cmd/chau7-remote/main.go` | Entry point — env var parsing, signal handling, agent lifecycle |
| `internal/agent/agent.go` | Core agent — socket listener, WebSocket relay, encryption, pairing |
| `internal/agent/state.go` | Persistent pairing state (JSON file) |
| `internal/agent/agent_test.go` | Agent tests |
| `internal/protocol/` | Frame format definitions and message type constants |
| `docs/PROTOCOL.md` | Full protocol specification (frame format, encryption, nonce construction) |

## Build

```bash
go build ./cmd/chau7-remote
```

## Run

```bash
CHAU7_REMOTE_SOCKET="$HOME/Library/Application Support/Chau7/remote.sock" \
CHAU7_RELAY_URL="wss://relay.chau7.sh/connect" \
CHAU7_MAC_NAME="$(scutil --get ComputerName)" \
CHAU7_REMOTE_STATE="$HOME/Library/Application Support/Chau7/remote-state.json" \
./chau7-remote
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `CHAU7_REMOTE_SOCKET` | Unix socket path for IPC with the macOS app |
| `CHAU7_RELAY_URL` | WebSocket URL of the Cloudflare relay |
| `CHAU7_MAC_NAME` | Display name for this Mac (sent during pairing) |
| `CHAU7_REMOTE_STATE` | Path for persistent pairing state JSON |

## Identity storage and recovery

The agent wraps its private identity key before writing state. A wrapped-key
load failure stops startup with an actionable error; it does not clear the keys
or generate a replacement identity. If the machine identity service is
unavailable, retry after it recovers. If the wrapped key is damaged or belongs to
another Mac, preserve the file and restore a valid backup for the original Mac.
Do not delete state as an automatic recovery step: losing it breaks existing
pairings. An intentional identity reset requires pairing the devices again.

Saving also fails when the machine identity cannot be read, leaving the previous
file unchanged rather than falling back to plaintext. Legacy plaintext state is
still readable and is wrapped on its next successful save. State files use mode
0600 and are replaced atomically. The wrapping key is derived from the Mac's
hardware UUID; this is not a claim of protection against an attacker with access
to that identifier and the state file.

## Protocol

See [`docs/PROTOCOL.md`](docs/PROTOCOL.md) for the frame format, encryption, nonce
construction, and message type definitions.
