package main

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"
	"unicode/utf8"
)

const projectCorrelationPathPrefix = "/_chau7/project/"

// CapabilityProjectPathCorrelation is advertised on /health so the app can
// tell whether the proxy it launched understands the correlation prefix its
// own shell wrapper emits. A bundled proxy older than the Swift binary
// forwards the prefix verbatim, and the only symptom is a 404 from the
// upstream provider — which points at the provider, not at the skew.
const CapabilityProjectPathCorrelation = "project-path-correlation"

// applyPathCorrelation materializes correlation carried by clients that do
// not support custom request headers (notably Codex). The internal prefix is
// removed before provider detection and upstream forwarding.
func applyPathCorrelation(r *http.Request) error {
	if !strings.HasPrefix(r.URL.Path, projectCorrelationPathPrefix) {
		return nil
	}

	remainder := strings.TrimPrefix(r.URL.Path, projectCorrelationPathPrefix)
	separator := strings.IndexByte(remainder, '/')
	if separator <= 0 {
		return fmt.Errorf("invalid Chau7 project correlation path")
	}

	projectBytes, err := base64.RawURLEncoding.DecodeString(remainder[:separator])
	if err != nil || len(projectBytes) == 0 || len(projectBytes) > 4096 ||
		!utf8.Valid(projectBytes) || strings.ContainsAny(string(projectBytes), "\x00\r\n") {
		return fmt.Errorf("invalid Chau7 project correlation token")
	}

	if r.Header.Get(HeaderProject) == "" {
		r.Header.Set(HeaderProject, string(projectBytes))
	}
	r.URL.Path = remainder[separator:]
	r.URL.RawPath = ""
	return nil
}
