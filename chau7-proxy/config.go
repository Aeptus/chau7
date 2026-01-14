package main

import (
	"os"
	"strconv"
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
}

// LoadConfig loads configuration from environment variables.
// Environment variables used:
//   - CHAU7_PROXY_PORT: HTTP port (default: 18080)
//   - CHAU7_DB_PATH: SQLite database path (required)
//   - CHAU7_IPC_SOCKET: Unix socket path for IPC (optional)
//   - CHAU7_LOG_PROMPTS: "1" to enable prompt logging (default: "0")
//   - CHAU7_LOG_LEVEL: Log level (default: "info")
func LoadConfig() *Config {
	cfg := &Config{
		Port:          18080,
		LogLevel:      "info",
		LogPrompts:    false,
		DBPath:        os.Getenv("CHAU7_DB_PATH"),
		IPCSocketPath: os.Getenv("CHAU7_IPC_SOCKET"),
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
