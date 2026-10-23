package main

import (
	"strings"
	"sync"
)

type AttributionSnapshot struct {
	Total        uint64
	Attributed   uint64
	Unattributed uint64
}

func (s AttributionSnapshot) Ratio() float64 {
	if s.Total == 0 {
		return 0
	}
	return float64(s.Attributed) / float64(s.Total)
}

// AttributionDiagnostics tracks calls recorded during this proxy process.
// Historical rows are deliberately excluded because their repository cannot
// be inferred safely after the fact.
type AttributionDiagnostics struct {
	mu           sync.Mutex
	total        uint64
	attributed   uint64
	unattributed uint64
}

func (d *AttributionDiagnostics) Record(projectPath string) (AttributionSnapshot, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()

	d.total++
	isUnattributed := strings.TrimSpace(projectPath) == ""
	isFirstUnattributed := isUnattributed && d.unattributed == 0
	if isUnattributed {
		d.unattributed++
	} else {
		d.attributed++
	}

	snapshot := AttributionSnapshot{
		Total:        d.total,
		Attributed:   d.attributed,
		Unattributed: d.unattributed,
	}
	shouldReport := snapshot.Total == 1 || isFirstUnattributed || snapshot.Total%100 == 0
	return snapshot, shouldReport
}
