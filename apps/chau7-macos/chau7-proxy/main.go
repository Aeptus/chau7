package main

import (
	"context"
	"crypto/tls"
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
	ipc.SetDatabase(db) // Enable event storage
	defer ipc.Close()

	// v1.2: Initialize Aethyme client (optional)
	var aethymeClient *AethymeClient
	if config.AethymeURL != "" {
		client, err := NewAethymeClient(config.AethymeURL, config.AethymeAPIKey)
		if err != nil {
			log.Printf("[WARN] Aethyme integration disabled: %v", err)
		} else {
			aethymeClient = client
			log.Printf("[INFO] Aethyme integration enabled: %s", client.baseURL)
		}
	}

	// v1.2: Initialize Mockup client (optional)
	var mockupClient *MockupClient
	if config.MockupURL != "" {
		client, err := NewMockupClient(config.MockupURL, config.MockupAPIKey)
		if err != nil {
			log.Printf("[WARN] Mockup analytics disabled: %v", err)
		} else {
			mockupClient = client
			log.Printf("[INFO] Mockup analytics enabled: %s", client.baseURL)
			defer mockupClient.Close()
		}
	}

	// v1.2: Initialize baseline estimator
	var baselineEstimator *BaselineEstimator
	if config.EnableBaseline {
		baselineEstimator = NewBaselineEstimator(db, aethymeClient)
		if err := baselineEstimator.LoadHistoricalStats(); err != nil {
			log.Printf("[WARN] Failed to load historical stats: %v", err)
		}
		log.Printf("[INFO] Baseline estimation enabled")
	}

	// Initialize task manager
	taskManager := NewTaskManager(db, ipc, config.CandidateGracePeriod, config.IdleTimeout)

	// v1.2: Wire up mockup client for analytics forwarding
	if mockupClient != nil {
		taskManager.SetMockupClient(mockupClient)
	}

	// Create proxy handler
	proxy := NewProxyHandler(config, db, ipc, taskManager, baselineEstimator, mockupClient)

	// Create task endpoints handler
	taskEndpoints := NewTaskEndpoints(taskManager, db)

	// Create HTTP server mux
	mux := http.NewServeMux()

	// Health check endpoint
	mux.HandleFunc("/health", handleHealth(db))

	// Stats endpoint
	mux.HandleFunc("/stats", handleStats(db))

	// Task management endpoints
	mux.HandleFunc("/task/candidate", taskEndpoints.HandleGetCandidate)
	mux.HandleFunc("/task/start", taskEndpoints.HandleStartTask)
	mux.HandleFunc("/task/dismiss", taskEndpoints.HandleDismissCandidate)
	mux.HandleFunc("/task/assess", taskEndpoints.HandleAssessTask)
	mux.HandleFunc("/task/current", taskEndpoints.HandleGetCurrentTask)
	mux.HandleFunc("/task/name", taskEndpoints.HandleUpdateTaskName)

	// Events endpoint
	mux.HandleFunc("/events", taskEndpoints.HandleGetEvents)

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

	// Start HTTP server in goroutine
	go func() {
		log.Printf("[INFO] chau7-proxy HTTP starting on %s", server.Addr)
		log.Printf("[INFO] Database: %s", config.DBPath)
		if config.IPCSocketPath != "" {
			log.Printf("[INFO] IPC socket: %s", config.IPCSocketPath)
		}

		if err := server.ListenAndServe(); err != http.ErrServerClosed {
			log.Fatalf("HTTP server error: %v", err)
		}
	}()

	// Start TLS server for WSS-capable clients (e.g. subscription Codex)
	var tlsServer *http.Server
	if config.TLSCertPath != "" && config.TLSKeyPath != "" {
		if err := ensureSelfSignedCert(config.TLSCertPath, config.TLSKeyPath); err != nil {
			log.Printf("[WARN] Failed to generate TLS cert: %v (TLS listener disabled)", err)
		} else {
			tlsServer = &http.Server{
				Addr:         fmt.Sprintf("127.0.0.1:%d", config.TLSPort),
				Handler:      mux,
				ReadTimeout:  30 * time.Second,
				WriteTimeout: 5 * time.Minute,
				IdleTimeout:  120 * time.Second,
				// Disable HTTP/2 so that standard HTTP/1.1 WebSocket upgrade
				// works. HTTP/2 uses a different mechanism (RFC 8441 Extended
				// CONNECT) that our simple hijack-based tunneler doesn't support.
				TLSNextProto: make(map[string]func(*http.Server, *tls.Conn, http.Handler)),
			}

			go func() {
				log.Printf("[INFO] chau7-proxy TLS/WSS starting on %s", tlsServer.Addr)
				if err := tlsServer.ListenAndServeTLS(config.TLSCertPath, config.TLSKeyPath); err != http.ErrServerClosed {
					log.Printf("[WARN] TLS server error: %v", err)
				}
			}()
		}
	}

	// Wait for shutdown signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("[INFO] Shutting down...")

	// Graceful shutdown with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if tlsServer != nil {
		if err := tlsServer.Shutdown(ctx); err != nil {
			log.Printf("[WARN] TLS shutdown error: %v", err)
		}
	}

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
