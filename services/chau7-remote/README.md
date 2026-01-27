# Chau7 Remote Agent

`chau7-remote` connects the macOS app to the relay and forwards encrypted frames.

## Build

```bash
go build ./cmd/chau7-remote
```

## Run

```bash
CHAU7_REMOTE_SOCKET="$HOME/Library/Application Support/Chau7/remote.sock" \
CHAU7_RELAY_URL="wss://relay.example.com/connect" \
CHAU7_MAC_NAME="$(scutil --get ComputerName)" \
./chau7-remote
```
