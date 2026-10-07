package main

import (
	"bytes"
	"log"
	"strings"
	"testing"
)

func TestDiagnosticLogEscapesUntrustedControls(t *testing.T) {
	for _, message := range []string{"model\nFAKE ENTRY", "endpoint\rFAKE ENTRY", "\x1b[2J", "\x00", "unicode\u2028separator\u2029", string([]byte{0xff})} {
		got := diagnosticLogLine(message)
		if strings.ContainsAny(got, "\n\r\x1b\x00\u2028\u2029") {
			t.Fatalf("control character remained in %q", got)
		}
	}
	if got := diagnosticLogLine("provider model: 42 requests"); got != "provider model: 42 requests" {
		t.Fatal(got)
	}
	var buffer bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&buffer)
	defer log.SetOutput(previous)
	diagnosticLogf("provider=%s error=%s", "model\nFAKE", "failed\rSPOOF")
	if strings.Count(buffer.String(), "\n") != 1 || !strings.Contains(buffer.String(), `model\nFAKE`) || !strings.Contains(buffer.String(), `failed\rSPOOF`) {
		t.Fatalf("unsafe log record: %q", buffer.String())
	}
}
