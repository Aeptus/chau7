package main

import "testing"

func TestAttributionDiagnosticsReportsNewCallRatio(t *testing.T) {
	var diagnostics AttributionDiagnostics

	first, shouldReport := diagnostics.Record("/repo/one")
	if !shouldReport || first.Total != 1 || first.Attributed != 1 || first.Ratio() != 1 {
		t.Fatalf("unexpected first snapshot: %+v report=%v", first, shouldReport)
	}

	second, shouldReport := diagnostics.Record("")
	if !shouldReport {
		t.Fatal("first unattributed call must be reported immediately")
	}
	if second.Total != 2 || second.Attributed != 1 || second.Unattributed != 1 || second.Ratio() != 0.5 {
		t.Fatalf("unexpected mixed snapshot: %+v", second)
	}

	third, shouldReport := diagnostics.Record("/repo/two")
	if shouldReport {
		t.Fatal("routine calls should wait for the periodic report boundary")
	}
	if third.Total != 3 || third.Attributed != 2 || third.Unattributed != 1 {
		t.Fatalf("unexpected third snapshot: %+v", third)
	}
}
