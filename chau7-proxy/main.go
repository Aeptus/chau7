package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	// Load configuration from environment
	config := LoadConfig()

	// Validate configuration
	if err := config.Validate(); err != nil {
		log.Fatalf("Configuration error: %v", err)
	}

	// Initialize database
	db, err := NewDatabase(config.DBPath)
	if err != nil {
		log.Fatalf("Failed to initialize database: %v", err)
	}
	defer db.Close()

	// Initialize IPC notifier
	ipc := NewIPCNotifier(config.IPCSocketPath)
	defer ipc.Close()

	// Create proxy handler
	proxy := NewProxyHandler(config, db, ipc)

	// Create HTTP server mux
	mux := http.NewServeMux()

	// Health check endpoint
	mux.HandleFunc("/health", handleHealth(db))

	// Stats endpoint
	mux.HandleFunc("/stats", handleStats(db))

	// All other requests go to the proxy
	mux.Handle("/", proxy)

	// Create server
	server := &http.Server{
		Addr:         fmt.Sprintf("127.0.0.1:%d", config.Port),
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 5 * time.Minute, // Long timeout for streaming
		IdleTimeout:  120 * time.Second,
	}

	// Start server in goroutine
	go func() {
		log.Printf("[INFO] chau7-proxy starting on %s", server.Addr)
		log.Printf("[INFO] Database: %s", config.DBPath)
		if config.IPCSocketPath != "" {
			log.Printf("[INFO] IPC socket: %s", config.IPCSocketPath)
		}

		if err := server.ListenAndServe(); err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	// Wait for shutdown signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("[INFO] Shutting down...")

	// Graceful shutdown with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Printf("[WARN] Shutdown error: %v", err)
	}

	log.Println("[INFO] Server stopped")
}

// handleHealth returns a health check handler
func handleHealth(db *Database) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte(`{"status":"unhealthy","error":"database unavailable"}`))
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok"}`))
	}
}

// handleStats returns a stats handler
func handleStats(db *Database) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		stats, err := db.GetDailyStats()
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte(`{"error":"failed to get stats"}`))
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"calls_today":%d,"input_tokens_today":%d,"output_tokens_today":%d,"cost_today":%.4f,"avg_latency_ms":%.1f}`,
			stats.CallCount,
			stats.TotalInputTokens,
			stats.TotalOutputTokens,
			stats.TotalCost,
			stats.AvgLatencyMs,
		)
	}
}
