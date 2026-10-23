package main

import (
	"testing"
	"time"
)

func TestTokenEstimateDiagnosticsReportsImmediatelyThenAggregates(t *testing.T) {
	var diagnostics TokenEstimateDiagnostics
	now := time.Unix(1_000, 0)

	first, report := diagnostics.Observe("anthropic /v1/messages", true, now)
	if !report || first.Total != 1 || first.Estimated != 1 {
		t.Fatalf("first estimate = %+v, report=%v", first, report)
	}
	if _, report := diagnostics.Observe("anthropic /v1/messages", true, now.Add(time.Minute)); report {
		t.Fatal("repeated estimate should be aggregated")
	}
	if _, report := diagnostics.Observe("anthropic /v1/messages", false, now.Add(2*time.Minute)); report {
		t.Fatal("successful extraction should not force an early report")
	}

	summary, report := diagnostics.Observe("anthropic /v1/messages", true, now.Add(5*time.Minute))
	if !report || summary.Total != 3 || summary.Estimated != 2 {
		t.Fatalf("summary = %+v, report=%v", summary, report)
	}
	if got := summary.EstimatedPercent(); got < 66 || got > 67 {
		t.Fatalf("estimated percentage = %f", got)
	}
}

func TestTokenEstimateDiagnosticsIsolatesEndpoints(t *testing.T) {
	var diagnostics TokenEstimateDiagnostics
	now := time.Unix(1_000, 0)
	if _, report := diagnostics.Observe("anthropic /v1/messages", true, now); !report {
		t.Fatal("first Anthropic estimate should report")
	}
	if _, report := diagnostics.Observe("openai /v1/responses", true, now); !report {
		t.Fatal("first OpenAI estimate should report independently")
	}
}
