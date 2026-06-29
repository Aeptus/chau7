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
	"strconv"
	"syscall"
	"time"

	"github.com/chau7/chau7-remote/internal/agent"
)

// watchParentProcess exits the agent when the parent Chau7 app dies. An
// orphaned agent reconnects to the relaunched app's single-client IPC socket
// and ping-pongs with the fresh agent over the one client slot, plus presents
// a duplicate identity to the relay. Reparenting to PID 1 is the orphan
// signal; CHAU7_PARENT_PID guards against intermediate reparenting.
func watchParentProcess() {
	expected := os.Getppid()
	if env := os.Getenv("CHAU7_PARENT_PID"); env != "" {
		if pid, err := strconv.Atoi(env); err == nil && pid > 1 {
			expected = pid
		}
	}
	for {
		time.Sleep(2 * time.Second)
		ppid := os.Getppid()
		if ppid == 1 || (expected > 1 && ppid != expected) {
			log.Printf("parent process gone (ppid=%d, expected=%d) — exiting", ppid, expected)
			os.Exit(0)
		}
	}
}

func main() {
	go watchParentProcess()

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
