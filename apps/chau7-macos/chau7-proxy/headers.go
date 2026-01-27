package main

import (
	"net/http"
)

// CorrelationHeaders contains all X-Chau7-* headers from incoming requests
// These headers enable task lifecycle tracking and multi-tenant correlation
type CorrelationHeaders struct {
	// Required headers
	SessionID string // X-Chau7-Session: Session/conversation ID
	TabID     string // X-Chau7-Tab: Tab/terminal identifier
	Project   string // X-Chau7-Project: Git root or project path

	// Optional task headers
	TaskID           string // X-Chau7-Task: Existing task ID (if known)
	TaskName         string // X-Chau7-Task-Name: Override auto-derived name
	NewTask          bool   // X-Chau7-New-Task: Force new task immediately
	DismissCandidate string // X-Chau7-Dismiss-Candidate: Dismiss pending candidate by ID

	// Multi-tenant headers (future use)
	TenantID string // X-Chau7-Tenant: Tenant ID for multi-tenant
	OrgID    string // X-Chau7-Org: Organization ID
	UserID   string // X-Chau7-User: User ID (hashed)
}

// Header constants
const (
	HeaderSession          = "X-Chau7-Session"
	HeaderTab              = "X-Chau7-Tab"
	HeaderProject          = "X-Chau7-Project"
	HeaderTask             = "X-Chau7-Task"
	HeaderTaskName         = "X-Chau7-Task-Name"
	HeaderNewTask          = "X-Chau7-New-Task"
	HeaderDismissCandidate = "X-Chau7-Dismiss-Candidate"
	HeaderTenant           = "X-Chau7-Tenant"
	HeaderOrg              = "X-Chau7-Org"
	HeaderUser             = "X-Chau7-User"
)

// ExtractCorrelationHeaders parses X-Chau7-* headers from an HTTP request
func ExtractCorrelationHeaders(r *http.Request) *CorrelationHeaders {
	h := &CorrelationHeaders{
		SessionID:        r.Header.Get(HeaderSession),
		TabID:            r.Header.Get(HeaderTab),
		Project:          r.Header.Get(HeaderProject),
		TaskID:           r.Header.Get(HeaderTask),
		TaskName:         r.Header.Get(HeaderTaskName),
		DismissCandidate: r.Header.Get(HeaderDismissCandidate),
		TenantID:         r.Header.Get(HeaderTenant),
		OrgID:            r.Header.Get(HeaderOrg),
		UserID:           r.Header.Get(HeaderUser),
	}

	// Parse boolean header
	newTaskValue := r.Header.Get(HeaderNewTask)
	h.NewTask = newTaskValue == "true" || newTaskValue == "1"

	// Apply defaults for required headers
	if h.SessionID == "" {
		h.SessionID = "unknown"
	}
	if h.TabID == "" {
		h.TabID = "default"
	}

	return h
}

// StripCorrelationHeaders removes X-Chau7-* headers before forwarding to upstream
// These headers are internal to Chau7 and should not be sent to providers
func StripCorrelationHeaders(header http.Header) {
	header.Del(HeaderSession)
	header.Del(HeaderTab)
	header.Del(HeaderProject)
	header.Del(HeaderTask)
	header.Del(HeaderTaskName)
	header.Del(HeaderNewTask)
	header.Del(HeaderDismissCandidate)
	header.Del(HeaderTenant)
	header.Del(HeaderOrg)
	header.Del(HeaderUser)
}

// IsCorrelationHeader returns true if the header name is a Chau7 correlation header
func IsCorrelationHeader(name string) bool {
	switch name {
	case HeaderSession, HeaderTab, HeaderProject, HeaderTask,
		HeaderTaskName, HeaderNewTask, HeaderDismissCandidate,
		HeaderTenant, HeaderOrg, HeaderUser:
		return true
	}
	return false
}
