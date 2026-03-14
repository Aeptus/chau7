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
