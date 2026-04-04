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
CHAU7_RELAY_URL="wss://relay.example.com/connect" \
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

## Protocol

See [`docs/PROTOCOL.md`](docs/PROTOCOL.md) for the frame format, encryption, nonce
construction, and message type definitions.
