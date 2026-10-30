package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"testing"
	"time"
)

// This opt-in executable fixture uses the real forwarding, SSE, task and SQLite
// paths. Only its transport is redirected to an owned loopback fake provider;
// production origin selection is unchanged. Ordinary tests never launch it.
func TestProxyPerformanceFixture(t *testing.T) {
	if os.Getenv("CHAU7_PERF_FIXTURE") != "1" {
		t.Skip("opt-in standalone performance fixture")
	}
	upstream, err := url.Parse(os.Getenv("CHAU7_PERF_UPSTREAM"))
	if err != nil || upstream.Scheme != "http" || upstream.Hostname() != "127.0.0.1" || upstream.Port() == "" {
		t.Fatal("fixture requires an owned loopback upstream")
	}
	db, err := NewDatabase(os.Getenv("CHAU7_DB_PATH"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = db.Close() }()
	ipc := NewIPCNotifier("")
	ipc.SetDatabase(db)
	defer func() { _ = ipc.Close() }()
	tasks := NewTaskManager(db, ipc, 5*time.Second, 30*time.Minute)
	// Keep this fixture source buildable against the frozen pre-change proxy.
	if closer, ok := any(tasks).(interface{ Close() }); ok {
		defer closer.Close()
	}
	proxy := NewProxyHandler(&Config{}, db, ipc, tasks, nil, nil, nil)
	transport := newUpstreamHTTPClient().Transport.(*http.Transport)
	defer transport.CloseIdleConnections()
	proxy.client.Transport = perfLoopbackTransport{upstream, transport}
	mux := http.NewServeMux()
	mux.HandleFunc("/stats", handleStats(db))
	mux.Handle("/", proxy)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := newProxyHTTPServer(listener.Addr().String(), mux)
	stopped := make(chan os.Signal, 1)
	signal.Notify(stopped, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(stopped)
	errors := make(chan error, 1)
	go func() { errors <- server.Serve(listener) }()
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{
		"perflab_proxy": listener.Addr().String(), "pid": os.Getpid(),
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-stopped:
	case err := <-errors:
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
}

type perfLoopbackTransport struct {
	upstream *url.URL
	base     *http.Transport
}

func (transport perfLoopbackTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	cloned := request.Clone(request.Context())
	target := *request.URL
	target.Scheme = transport.upstream.Scheme
	target.Host = transport.upstream.Host
	cloned.URL = &target
	cloned.Host = target.Host
	return transport.base.RoundTrip(cloned)
}
