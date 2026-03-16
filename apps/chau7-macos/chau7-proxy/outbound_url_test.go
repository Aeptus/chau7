package main

import (
	"net"
	"testing"
)

func TestNormalizeServiceBaseURL(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{name: "empty", input: "", want: ""},
		{name: "https host", input: "https://api.example.com", want: "https://api.example.com"},
		{name: "https trims trailing slash", input: "https://api.example.com/", want: "https://api.example.com"},
		{name: "https path prefix", input: "https://api.example.com/aethyme/", want: "https://api.example.com/aethyme"},
		{name: "loopback http", input: "http://127.0.0.1:8080", want: "http://127.0.0.1:8080"},
		{name: "localhost http", input: "http://localhost:3000", want: "http://localhost:3000"},
		{name: "public https ip", input: "https://8.8.8.8", want: "https://8.8.8.8"},
		{name: "reject relative", input: "/api/v1", wantErr: true},
		{name: "reject non-loopback http", input: "http://example.com", wantErr: true},
		{name: "reject non-loopback ip", input: "https://10.0.0.5", wantErr: true},
		{name: "reject query", input: "https://api.example.com?x=1", wantErr: true},
		{name: "reject userinfo", input: "https://user:pass@example.com", wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := normalizeServiceBaseURL(tc.input)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("Expected error, got none with %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("Unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("Got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestBuildServiceURL(t *testing.T) {
	tests := []struct {
		name     string
		baseURL  string
		endpoint string
		want     string
	}{
		{name: "root base", baseURL: "https://api.example.com", endpoint: "/health", want: "https://api.example.com/health"},
		{name: "prefixed base", baseURL: "https://api.example.com/base", endpoint: "/api/v1/events", want: "https://api.example.com/base/api/v1/events"},
		{name: "empty endpoint", baseURL: "https://api.example.com/base", endpoint: "", want: "https://api.example.com/base"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := buildServiceURL(tc.baseURL, tc.endpoint)
			if got != tc.want {
				t.Fatalf("Got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestValidateResolvedHost(t *testing.T) {
	tests := []struct {
		name    string
		host    string
		addrs   []net.IPAddr
		wantErr bool
	}{
		{name: "public hostname to public ip", host: "api.example.com", addrs: []net.IPAddr{{IP: net.ParseIP("8.8.8.8")}}},
		{name: "reject hostname to private ip", host: "api.example.com", addrs: []net.IPAddr{{IP: net.ParseIP("10.0.0.5")}}, wantErr: true},
		{name: "reject hostname to loopback", host: "api.example.com", addrs: []net.IPAddr{{IP: net.ParseIP("127.0.0.1")}}, wantErr: true},
		{name: "allow localhost to loopback", host: "localhost", addrs: []net.IPAddr{{IP: net.ParseIP("127.0.0.1")}}},
		{name: "reject localhost to public ip", host: "localhost", addrs: []net.IPAddr{{IP: net.ParseIP("8.8.8.8")}}, wantErr: true},
		{name: "reject empty resolution", host: "api.example.com", wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := validateResolvedHost(tc.host, tc.addrs)
			if tc.wantErr && err == nil {
				t.Fatal("Expected error, got nil")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("Unexpected error: %v", err)
			}
		})
	}
}
