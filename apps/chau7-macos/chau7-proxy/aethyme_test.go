package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestNewAethymeClient_NilOnEmptyURL(t *testing.T) {
	client, err := NewAethymeClient("", "api-key")
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if client != nil {
		t.Error("Expected nil client for empty URL")
	}
}

func TestAethymeClient_GetContextPack(t *testing.T) {
	// Create a test server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/context-packs/pack_123" {
			t.Errorf("Unexpected path: %s", r.URL.Path)
		}

		if r.Header.Get("Accept") != "application/json" {
			t.Errorf("Missing Accept header")
		}

		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Errorf("Missing or incorrect Authorization header")
		}

		pack := ContextPack{
			ID:           "pack_123",
			RepoID:       "repo_456",
			Name:         "Test Context Pack",
			Version:      "1.0.0",
			TokenCount:   5000,
			TokensSaved:  2000,
			OriginalSize: 7000,
			CreatedAt:    time.Now(),
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(pack)
	}))
	defer server.Close()

	client, err := NewAethymeClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}

	pack, err := client.GetContextPack("pack_123")
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if pack.ID != "pack_123" {
		t.Errorf("Pack ID = %q, want pack_123", pack.ID)
	}

	if pack.TokensSaved != 2000 {
		t.Errorf("TokensSaved = %d, want 2000", pack.TokensSaved)
	}
}

func TestAethymeClient_GetContextPack_NotFound(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	client, err := NewAethymeClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}

	pack, err := client.GetContextPack("nonexistent")
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if pack != nil {
		t.Error("Expected nil pack for not found")
	}
}

func TestAethymeClient_Caching(t *testing.T) {
	callCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		pack := ContextPack{
			ID:          "pack_123",
			TokensSaved: 1000,
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(pack)
	}))
	defer server.Close()

	client, err := NewAethymeClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}

	// First call
	_, err = client.GetContextPack("pack_123")
	if err != nil {
		t.Fatalf("First call error: %v", err)
	}

	// Second call (should be cached)
	_, err = client.GetContextPack("pack_123")
	if err != nil {
		t.Fatalf("Second call error: %v", err)
	}

	if callCount != 1 {
		t.Errorf("Expected 1 API call (cached), got %d", callCount)
	}
}

func TestAethymeClient_GetRepoScorecard(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/repos/repo_123/scorecard" {
			t.Errorf("Unexpected path: %s", r.URL.Path)
		}

		scorecard := RepoScorecard{
			RepoID:           "repo_123",
			OverallScore:     85.5,
			TestCoverage:     78.0,
			DocCoverage:      90.0,
			CodeQuality:      88.0,
			ContextPackCount: 5,
			LastAnalyzed:     time.Now(),
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(scorecard)
	}))
	defer server.Close()

	client, err := NewAethymeClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}

	scorecard, err := client.GetRepoScorecard("repo_123")
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if scorecard.OverallScore != 85.5 {
		t.Errorf("OverallScore = %f, want 85.5", scorecard.OverallScore)
	}
}

func TestAethymeClient_ClearCache(t *testing.T) {
	callCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		pack := ContextPack{ID: "pack_123"}
		json.NewEncoder(w).Encode(pack)
	}))
	defer server.Close()

	client, err := NewAethymeClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}

	// First call
	client.GetContextPack("pack_123")

	// Clear cache
	client.ClearCache()

	// Second call (should hit API again)
	client.GetContextPack("pack_123")

	if callCount != 2 {
		t.Errorf("Expected 2 API calls after cache clear, got %d", callCount)
	}
}

func TestAethymeClient_Health(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	client, err := NewAethymeClient(server.URL, "test-key")
	if err != nil {
		t.Fatalf("Unexpected client init error: %v", err)
	}

	err = client.Health()
	if err != nil {
		t.Errorf("Health check failed: %v", err)
	}
}

func TestAethymeClient_NilClientMethods(t *testing.T) {
	var client *AethymeClient

	// All methods should handle nil gracefully
	pack, err := client.GetContextPack("test")
	if err != nil || pack != nil {
		t.Error("GetContextPack on nil client should return nil, nil")
	}

	skill, err := client.GetSkillPack("test")
	if err != nil || skill != nil {
		t.Error("GetSkillPack on nil client should return nil, nil")
	}

	score, err := client.GetRepoScorecard("test")
	if err != nil || score != nil {
		t.Error("GetRepoScorecard on nil client should return nil, nil")
	}

	err = client.Health()
	if err != nil {
		t.Error("Health on nil client should return nil")
	}
}

func TestNewAethymeClient_InvalidBaseURL(t *testing.T) {
	client, err := NewAethymeClient("http://example.com", "api-key")
	if err == nil {
		t.Fatal("Expected error for non-loopback http URL")
	}
	if client != nil {
		t.Fatal("Expected nil client for invalid URL")
	}
}

func TestNewAethymeClient_AllowsHTTPSPathPrefix(t *testing.T) {
	client, err := NewAethymeClient("https://api.example.com/aethyme/", "api-key")
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if client == nil {
		t.Fatal("Expected client")
	}
	if client.baseURL != "https://api.example.com/aethyme" {
		t.Fatalf("Got baseURL %q", client.baseURL)
	}
}
