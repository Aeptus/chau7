package main

import "testing"

func TestProxyBuildInfoAlwaysHasExplicitIdentityFields(t *testing.T) {
	info := currentProxyBuildInfo()
	if info.Version == "" || info.BuildSHA == "" || info.BuildTimestamp == "" {
		t.Fatalf("incomplete proxy build info: %+v", info)
	}
}
