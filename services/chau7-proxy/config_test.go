package main

import "testing"

func TestNextInjectionOverrideConfigIsOptional(t *testing.T) {
	t.Setenv("CHAU7_INJECTION_REPO_OVERRIDES", "")
	if LoadConfig().InjectionRepoOverridesDir != "" {
		t.Fatal("default must preserve Swift")
	}
	t.Setenv("CHAU7_INJECTION_REPO_OVERRIDES", "/isolated-next-overlays")
	if LoadConfig().InjectionRepoOverridesDir != "/isolated-next-overlays" {
		t.Fatal("Next override directory missing")
	}
}
