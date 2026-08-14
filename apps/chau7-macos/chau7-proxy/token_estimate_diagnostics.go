package main

import (
	"sync"
	"time"
)

const tokenEstimateReportInterval = 5 * time.Minute

type tokenEstimateWindow struct {
	startedAt time.Time
	total     int
	estimated int
}

type TokenEstimateSnapshot struct {
	Total     int
	Estimated int
}

func (s TokenEstimateSnapshot) EstimatedPercent() float64 {
	if s.Total == 0 {
		return 0
	}
	return float64(s.Estimated) * 100 / float64(s.Total)
}

// TokenEstimateDiagnostics turns a per-request failure warning into one
// immediate signal followed by bounded five-minute summaries per endpoint.
type TokenEstimateDiagnostics struct {
	mu      sync.Mutex
	windows map[string]tokenEstimateWindow
}

func (d *TokenEstimateDiagnostics) Observe(key string, estimated bool, now time.Time) (TokenEstimateSnapshot, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()

	if d.windows == nil {
		d.windows = make(map[string]tokenEstimateWindow)
	}
	window, exists := d.windows[key]
	if !exists {
		window.startedAt = now
	}
	window.total++
	if estimated {
		window.estimated++
	}

	shouldReport := (!exists && estimated) || now.Sub(window.startedAt) >= tokenEstimateReportInterval
	if shouldReport {
		snapshot := TokenEstimateSnapshot{Total: window.total, Estimated: window.estimated}
		d.windows[key] = tokenEstimateWindow{startedAt: now}
		return snapshot, true
	}
	d.windows[key] = window
	return TokenEstimateSnapshot{}, false
}
