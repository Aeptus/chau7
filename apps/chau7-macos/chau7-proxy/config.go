package main

import (
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// Config holds the proxy server configuration loaded from environment variables.
// This design allows the same binary to be used by different host applications
// (Chau7, VS Code extension, CLI) by just setting the appropriate env vars.
type Config struct {
	// Port is the HTTP port to listen on (default: 18080)
	Port int

	// TLSPort is the HTTPS/WSS port for WebSocket-capable clients (default: Port+1).
	// A self-signed certificate is auto-generated on first start.
	TLSPort int

	// TLSCertPath and TLSKeyPath are paths to the self-signed cert and key.
	// If empty, defaults to <data_dir>/proxy-cert.pem and proxy-key.pem.
	TLSCertPath string
	TLSKeyPath  string

	// DBPath is the path to the SQLite database file
	DBPath string

	// IPCSocketPath is the path to the Unix socket for notifying the host app
	// If empty, IPC notifications are disabled
	IPCSocketPath string

	// LogPrompts controls whether to log prompt/response previews
	LogPrompts bool

	// LogLevel controls verbosity: "debug", "info", "warn", "error"
	LogLevel string

	// IdleTimeout is the duration of inactivity before suggesting a new task (default: 30 minutes)
	IdleTimeout time.Duration

	// CandidateGracePeriod is how long to wait before auto-confirming a task candidate (default: 5 seconds)
	CandidateGracePeriod time.Duration

	// v1.2 Features

	// AethymeURL is the base URL for the Aethyme API (optional)
	AethymeURL string

	// AethymeAPIKey is the API key for Aethyme authentication (optional)
	AethymeAPIKey string

	// MockupURL is the base URL for the Mockup SaaS analytics (optional)
	MockupURL string

	// MockupAPIKey is the API key for Mockup authentication (optional)
	MockupAPIKey string

	// EnableBaseline enables baseline estimation for token savings calculation
	EnableBaseline bool
}

// LoadConfig loads configuration from environment variables.
// Environment variables used:
//   - CHAU7_PROXY_PORT: HTTP port (default: 18080)
//   - CHAU7_DB_PATH: SQLite database path (required)
//   - CHAU7_IPC_SOCKET: Unix socket path for IPC (optional)
//   - CHAU7_LOG_PROMPTS: "1" to enable prompt logging (default: "0")
//   - CHAU7_LOG_LEVEL: Log level (default: "info")
//   - CHAU7_IDLE_TIMEOUT: Idle gap for new task in minutes (default: 30)
//   - CHAU7_CANDIDATE_GRACE_PERIOD: Seconds before candidate auto-confirms (default: 5)
//   - CHAU7_AETHYME_URL: Aethyme API base URL (optional, v1.2)
//   - CHAU7_AETHYME_API_KEY: Aethyme API key (optional, v1.2)
//   - CHAU7_MOCKUP_URL: Mockup SaaS base URL (optional, v1.2)
//   - CHAU7_MOCKUP_API_KEY: Mockup API key (optional, v1.2)
//   - CHAU7_ENABLE_BASELINE: "1" to enable baseline estimation (default: "1", v1.2)
//   - CHAU7_TLS_PORT: HTTPS/WSS port (default: CHAU7_PROXY_PORT+1)
//   - CHAU7_TLS_CERT: Path to TLS certificate PEM (default: <db_dir>/proxy-cert.pem)
//   - CHAU7_TLS_KEY: Path to TLS private key PEM (default: <db_dir>/proxy-key.pem)
func LoadConfig() *Config {
	cfg := &Config{
		Port:                 18080,
		LogLevel:             "info",
		LogPrompts:           false,
		DBPath:               os.Getenv("CHAU7_DB_PATH"),
		IPCSocketPath:        os.Getenv("CHAU7_IPC_SOCKET"),
		IdleTimeout:          30 * time.Minute,
		CandidateGracePeriod: 5 * time.Second,
		// v1.2 defaults
		AethymeURL:     os.Getenv("CHAU7_AETHYME_URL"),
		AethymeAPIKey:  os.Getenv("CHAU7_AETHYME_API_KEY"),
		MockupURL:      os.Getenv("CHAU7_MOCKUP_URL"),
		MockupAPIKey:   os.Getenv("CHAU7_MOCKUP_API_KEY"),
		EnableBaseline: true, // Enabled by default
	}

	if portStr := os.Getenv("CHAU7_PROXY_PORT"); portStr != "" {
		if port, err := strconv.Atoi(portStr); err == nil && port > 0 && port < 65536 {
			cfg.Port = port
		}
	}

	// TLS port defaults to HTTP port + 1
	cfg.TLSPort = cfg.Port + 1
	if tlsPortStr := os.Getenv("CHAU7_TLS_PORT"); tlsPortStr != "" {
		if port, err := strconv.Atoi(tlsPortStr); err == nil && port > 0 && port < 65536 {
			cfg.TLSPort = port
		}
	}

	// TLS cert/key paths default to alongside the database
	if certPath := os.Getenv("CHAU7_TLS_CERT"); certPath != "" {
		cfg.TLSCertPath = certPath
	} else if cfg.DBPath != "" {
		cfg.TLSCertPath = filepath.Join(filepath.Dir(cfg.DBPath), "proxy-cert.pem")
	}
	if keyPath := os.Getenv("CHAU7_TLS_KEY"); keyPath != "" {
		cfg.TLSKeyPath = keyPath
	} else if cfg.DBPath != "" {
		cfg.TLSKeyPath = filepath.Join(filepath.Dir(cfg.DBPath), "proxy-key.pem")
	}

	if os.Getenv("CHAU7_LOG_PROMPTS") == "1" {
		cfg.LogPrompts = true
	}

	if level := os.Getenv("CHAU7_LOG_LEVEL"); level != "" {
		cfg.LogLevel = level
	}

	if idleStr := os.Getenv("CHAU7_IDLE_TIMEOUT"); idleStr != "" {
		if minutes, err := strconv.Atoi(idleStr); err == nil && minutes > 0 {
			cfg.IdleTimeout = time.Duration(minutes) * time.Minute
		}
	}

	if graceStr := os.Getenv("CHAU7_CANDIDATE_GRACE_PERIOD"); graceStr != "" {
		if seconds, err := strconv.Atoi(graceStr); err == nil && seconds > 0 {
			cfg.CandidateGracePeriod = time.Duration(seconds) * time.Second
		}
	}

	// v1.2: baseline can be explicitly disabled
	if os.Getenv("CHAU7_ENABLE_BASELINE") == "0" {
		cfg.EnableBaseline = false
	}

	return cfg
}

// Validate checks if the configuration is valid
func (c *Config) Validate() error {
	if c.DBPath == "" {
		return ErrMissingDBPath
	}
	return nil
}

// Custom errors for configuration validation
var (
	ErrMissingDBPath = &ConfigError{Field: "CHAU7_DB_PATH", Message: "database path is required"}
)

type ConfigError struct {
	Field   string
	Message string
}

func (e *ConfigError) Error() string {
	return e.Field + ": " + e.Message
}
