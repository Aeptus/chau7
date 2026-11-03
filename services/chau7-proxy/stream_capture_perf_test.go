package main

import (
	"bytes"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Exercise the production handler, metadata and live-rate path without retaining
// a second downstream body in the benchmark client. Payload construction and DB
// setup are outside the timed interval; each response is accounted in SQLite.
func BenchmarkProxyStreaming(b *testing.B) {
	originalLog := log.Writer()
	log.SetOutput(io.Discard)
	b.Cleanup(func() { log.SetOutput(originalLog) })
	for _, count := range []int{16, 1024} {
		b.Run(strconv.Itoa(count)+"-deltas", func(b *testing.B) {
			line := `data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"` + strings.Repeat("x", 1024) + "\"}}\n\n"
			payload := []byte("data: {\"message\":{\"model\":\"claude-perflab\",\"usage\":{\"input_tokens\":32}}}\n\n" + strings.Repeat(line, count) + "data: {\"usage\":{\"output_tokens\":32}}\n\n")
			db, err := NewDatabase(filepath.Join(b.TempDir(), "proxy.db"))
			if err != nil {
				b.Fatal(err)
			}
			b.Cleanup(func() { _ = db.Close() })
			ipc := NewIPCNotifier("")
			b.Cleanup(func() { _ = ipc.Close() })
			tasks := NewTaskManager(db, ipc, time.Hour, time.Hour)
			b.Cleanup(tasks.Close)
			proxy := NewProxyHandler(&Config{}, db, ipc, tasks, nil, nil, nil)
			proxy.client.Transport = roundTripFunc(func(_ *http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"text/event-stream"}}, Body: io.NopCloser(bytes.NewReader(payload))}, nil
			})
			b.ReportAllocs()
			b.SetBytes(int64(len(payload)))
			b.ResetTimer()
			for b.Loop() {
				request := httptest.NewRequest(http.MethodPost, "/v1/messages", strings.NewReader(`{"model":"claude-perflab","stream":true}`))
				request.Header.Set("X-Chau7-Tab", "perflab")
				request.Header.Set("X-Chau7-Session", "perflab")
				out := &discardStreamResponse{header: make(http.Header)}
				proxy.ServeHTTP(out, request)
				if out.status != 200 || out.bytes != len(payload) {
					b.Fatalf("incomplete stream: status=%d bytes=%d", out.status, out.bytes)
				}
			}
		})
	}
}

type discardStreamResponse struct {
	header        http.Header
	status, bytes int
}

func (w *discardStreamResponse) Header() http.Header         { return w.header }
func (w *discardStreamResponse) WriteHeader(status int)      { w.status = status }
func (w *discardStreamResponse) Write(p []byte) (int, error) { w.bytes += len(p); return len(p), nil }
func (*discardStreamResponse) Flush()                        {}
