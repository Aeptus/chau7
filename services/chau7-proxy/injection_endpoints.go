package main

import (
	"encoding/json"
	"net/http"
)

type InjectionEndpoints struct {
	injector *Injector
}

type SessionEventRequest struct {
	Event     string `json:"event"`
	SessionID string `json:"session_id"`
	TabID     string `json:"tab_id"`
}

func NewInjectionEndpoints(injector *Injector) *InjectionEndpoints {
	return &InjectionEndpoints{injector: injector}
}

func (ie *InjectionEndpoints) HandleSessionEvent(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, "method not allowed", "method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	if ie.injector == nil {
		writeError(w, "injector unavailable", "injector_unavailable", http.StatusServiceUnavailable)
		return
	}

	var req SessionEventRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", "invalid_body", http.StatusBadRequest)
		return
	}

	headers := &CorrelationHeaders{
		SessionID: req.SessionID,
		TabID:     req.TabID,
	}

	if correlationSessionKey(headers) == "" {
		writeError(w, "session_id or tab_id is required", "missing_session_identity", http.StatusBadRequest)
		return
	}

	event := InjectionSessionEvent(req.Event)
	switch event {
	case SessionEventAfterCompact, SessionEventAfterClear:
	default:
		writeError(w, "unsupported session event", "unsupported_event", http.StatusBadRequest)
		return
	}

	if !ie.injector.RecordSessionEvent(event, headers) {
		writeError(w, "failed to record session event", "record_failed", http.StatusBadRequest)
		return
	}

	writeJSON(w, map[string]bool{"success": true})
}
