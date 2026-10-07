package agent

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestRelayHTTPPostHonorsCancelledOwner(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1); w.WriteHeader(http.StatusOK) }))
	defer server.Close()
	a := &Agent{relayBaseURL: server.URL, state: &State{DeviceID: "test-device"}}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := a.relayHTTPPost(ctx, "/pending/test-device", "pending", map[string]any{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled request returned %v", err)
	}
	if requests.Load() != 0 {
		t.Fatal("cancelled owner still sent a relay request")
	}
}

func TestRelayHTTPPostCancelsInFlightRequestWithOwner(t *testing.T) {
	started := make(chan struct{})
	finished := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		close(started)
		<-r.Context().Done()
		close(finished)
	}))
	defer server.Close()
	a := &Agent{relayBaseURL: server.URL, state: &State{DeviceID: "test-device"}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- a.relayHTTPPost(ctx, "/pending/test-device", "pending", map[string]any{}) }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("relay request never started")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("owner cancellation returned %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("relay operation outlived its owner")
	}
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("relay handler did not observe disconnect")
	}
}
