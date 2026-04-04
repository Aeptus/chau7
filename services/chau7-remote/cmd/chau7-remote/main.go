// chau7-remote connects the macOS app to the Cloudflare relay via a local
// Unix socket. It handles X25519 key exchange, ChaCha20-Poly1305 encrypted
// frame relay, APNs push registration, and persistent pairing state.
//
// Environment variables:
//
//	CHAU7_REMOTE_SOCKET  — Unix socket path for IPC with the macOS app
//	CHAU7_RELAY_URL      — WebSocket URL of the Cloudflare relay
//	CHAU7_MAC_NAME       — Display name for this Mac (sent during pairing)
//	CHAU7_REMOTE_STATE   — Path for persistent pairing state JSON
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"chau7-remote/internal/agent"
)

func main() {
	socketPath := os.Getenv("CHAU7_REMOTE_SOCKET")
	relayURL := os.Getenv("CHAU7_RELAY_URL")
	macName := os.Getenv("CHAU7_MAC_NAME")
	statePath := os.Getenv("CHAU7_REMOTE_STATE")

	remoteAgent, err := agent.NewAgent(socketPath, relayURL, macName, statePath)
	if err != nil {
		log.Fatalf("remote agent init failed: %v", err)
	}

	// Ignore SIGPIPE so broken IPC/relay writes return errors instead of killing the process.
	signal.Ignore(syscall.SIGPIPE)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := remoteAgent.Run(ctx); err != nil {
		log.Fatalf("remote agent stopped: %v", err)
	}
}
