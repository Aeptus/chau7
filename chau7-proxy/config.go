package main

import (
	"os"
	"strconv"
	"time"
)

// Config holds the proxy server configuration loaded from environment variables.
// This design allows the same binary to be used by different host applications
// (Chau7, VS Code extension, CLI) by just setting the appropriate env vars.
type Config struct {
	// Port is the HTTP port to listen on (default: 18080)
	Port int

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
func LoadConfig() *Config {
	cfg := &Config{
		Port:                 18080,
		LogLevel:             "info",
		LogPrompts:           false,
		DBPath:               os.Getenv("CHAU7_DB_PATH"),
		IPCSocketPath:        os.Getenv("CHAU7_IPC_SOCKET"),
		IdleTimeout:          30 * time.Minute,
		CandidateGracePeriod: 5 * time.Second,
	}

	if portStr := os.Getenv("CHAU7_PROXY_PORT"); portStr != "" {
		if port, err := strconv.Atoi(portStr); err == nil && port > 0 && port < 65536 {
			cfg.Port = port
		}
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
