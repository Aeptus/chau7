package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// correlationContract mirrors Contracts/proxy-correlation.json. The Swift side
// (ShellLaunchConfiguratorContractTests) reads the same file, so the encoding
// cannot drift on one side while both suites stay green.
type correlationContract struct {
	Prefix           string `json:"prefix"`
	Encoding         string `json:"encoding"`
	HealthCapability string `json:"healthCapability"`
	Cases            []struct {
		Name          string `json:"name"`
		ProjectPath   string `json:"projectPath"`
		Token         string `json:"token"`
		RequestPath   string `json:"requestPath"`
		ForwardedPath string `json:"forwardedPath"`
	} `json:"cases"`
}

func loadCorrelationContract(t *testing.T) correlationContract {
	t.Helper()

	path := filepath.Join("..", "Contracts", "proxy-correlation.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read correlation contract at %s: %v", path, err)
	}

	var contract correlationContract
	if err := json.Unmarshal(raw, &contract); err != nil {
		t.Fatalf("decode correlation contract: %v", err)
	}
	if len(contract.Cases) == 0 {
		t.Fatal("correlation contract declares no cases")
	}
	return contract
}

// TestCorrelationContractPrefixMatchesImplementation pins the constant to the
// shared file. Changing one without the other is the exact skew this contract
// exists to prevent.
func TestCorrelationContractPrefixMatchesImplementation(t *testing.T) {
	contract := loadCorrelationContract(t)

	if contract.Prefix != projectCorrelationPathPrefix {
		t.Errorf("contract prefix %q != implementation %q", contract.Prefix, projectCorrelationPathPrefix)
	}
	if contract.HealthCapability != CapabilityProjectPathCorrelation {
		t.Errorf(
			"contract capability %q != implementation %q",
			contract.HealthCapability,
			CapabilityProjectPathCorrelation,
		)
	}
}

// TestCorrelationContractCapabilityIsAdvertised guards the startup skew check:
// the app refuses a proxy that does not list this capability, so dropping it
// from proxyCapabilities would silently disable the detection.
func TestCorrelationContractCapabilityIsAdvertised(t *testing.T) {
	contract := loadCorrelationContract(t)

	if !slices.Contains(proxyCapabilities, contract.HealthCapability) {
		t.Errorf(
			"capability %q missing from advertised %v; the app's startup check would reject this build",
			contract.HealthCapability,
			proxyCapabilities,
		)
	}
}

// TestCorrelationContractCasesStripToForwardedPath runs every shared case
// through the real handler entry point.
func TestCorrelationContractCasesStripToForwardedPath(t *testing.T) {
	contract := loadCorrelationContract(t)

	for _, testCase := range contract.Cases {
		t.Run(testCase.Name, func(t *testing.T) {
			if got := contract.Prefix + testCase.Token; got != pathPrefixOf(testCase.RequestPath, testCase.ForwardedPath) {
				t.Fatalf("contract case is self-inconsistent: %q does not prefix %q", got, testCase.RequestPath)
			}

			req, err := http.NewRequest(http.MethodPost, "https://127.0.0.1:18081"+testCase.RequestPath, nil)
			if err != nil {
				t.Fatalf("build request: %v", err)
			}

			if err := applyPathCorrelation(req); err != nil {
				t.Fatalf("apply correlation path: %v", err)
			}

			if req.URL.Path != testCase.ForwardedPath {
				t.Errorf("forwarded path = %q, want %q", req.URL.Path, testCase.ForwardedPath)
			}
			if got := req.Header.Get(HeaderProject); got != testCase.ProjectPath {
				t.Errorf("%s = %q, want %q", HeaderProject, got, testCase.ProjectPath)
			}
		})
	}
}

// pathPrefixOf returns the portion of requestPath preceding forwardedPath, so
// a malformed contract case fails loudly instead of vacuously passing.
func pathPrefixOf(requestPath, forwardedPath string) string {
	if len(requestPath) < len(forwardedPath) {
		return requestPath
	}
	return requestPath[:len(requestPath)-len(forwardedPath)]
}
