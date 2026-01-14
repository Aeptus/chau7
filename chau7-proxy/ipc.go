package main

import (
	"encoding/json"
	"net"
	"sync"
	"time"
)

// IPCNotifier handles notifications to the host application via Unix socket
type IPCNotifier struct {
	socketPath string
	conn       net.Conn
	mu         sync.Mutex
	retryDelay time.Duration
}

// NewIPCNotifier creates a new IPC notifier
// If socketPath is empty, notifications are disabled (no-op)
func NewIPCNotifier(socketPath string) *IPCNotifier {
	return &IPCNotifier{
		socketPath: socketPath,
		retryDelay: 5 * time.Second,
	}
}

// NotifyAPICall sends an API call completion notification to the host app
func (n *IPCNotifier) NotifyAPICall(record *APICallRecord) error {
	if n.socketPath == "" {
		return nil // IPC disabled
	}

	msg := IPCMessage{
		Type: "api_call",
		Data: IPCAPICallData{
			SessionID:    record.SessionID,
			Provider:     string(record.Provider),
			Model:        record.Model,
			Endpoint:     record.Endpoint,
			InputTokens:  record.InputTokens,
			OutputTokens: record.OutputTokens,
			LatencyMs:    record.LatencyMs,
			StatusCode:   record.StatusCode,
			CostUSD:      record.CostUSD,
			Timestamp:    record.Timestamp.UTC().Format(time.RFC3339),
			ErrorMessage: record.ErrorMessage,
		},
	}

	return n.send(&msg)
}

// send sends a message to the host application
func (n *IPCNotifier) send(msg *IPCMessage) error {
	n.mu.Lock()
	defer n.mu.Unlock()

	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}

	// Try to connect if not connected
	if n.conn == nil {
		conn, err := net.DialTimeout("unix", n.socketPath, 2*time.Second)
		if err != nil {
			return err
		}
		n.conn = conn
	}

	// Set write deadline
	n.conn.SetWriteDeadline(time.Now().Add(2 * time.Second))

	// Send the message
	_, err = n.conn.Write(append(data, '\n'))
	if err != nil {
		// Connection might be broken, close and retry next time
		n.conn.Close()
		n.conn = nil
		return err
	}

	return nil
}

// Close closes the IPC connection
func (n *IPCNotifier) Close() error {
	n.mu.Lock()
	defer n.mu.Unlock()

	if n.conn != nil {
		err := n.conn.Close()
		n.conn = nil
		return err
	}
	return nil
}

// IPCMessage is the message format sent to the host application
type IPCMessage struct {
	Type string         `json:"type"`
	Data IPCAPICallData `json:"data"`
}

// IPCAPICallData contains the data for an API call notification
type IPCAPICallData struct {
	SessionID    string  `json:"session_id"`
	Provider     string  `json:"provider"`
	Model        string  `json:"model"`
	Endpoint     string  `json:"endpoint"`
	InputTokens  int     `json:"input_tokens"`
	OutputTokens int     `json:"output_tokens"`
	LatencyMs    int64   `json:"latency_ms"`
	StatusCode   int     `json:"status_code"`
	CostUSD      float64 `json:"cost_usd"`
	Timestamp    string  `json:"timestamp"`
	ErrorMessage string  `json:"error_message,omitempty"`
}
