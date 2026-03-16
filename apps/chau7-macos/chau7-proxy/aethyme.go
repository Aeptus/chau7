package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

// ContextPack represents metadata about an Aethyme context pack
type ContextPack struct {
	ID           string    `json:"id"`
	RepoID       string    `json:"repo_id"`
	Name         string    `json:"name"`
	Version      string    `json:"version"`
	TokenCount   int       `json:"token_count"`   // Compressed token count
	TokensSaved  int       `json:"tokens_saved"`  // Tokens saved by compression
	OriginalSize int       `json:"original_size"` // Original token count
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// SkillPack represents metadata about an Aethyme skill pack
type SkillPack struct {
	ID          string   `json:"id"`
	RepoID      string   `json:"repo_id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Skills      []string `json:"skills"`
	Version     string   `json:"version"`
}

// RepoScorecard contains quality metrics for a repository
type RepoScorecard struct {
	RepoID           string    `json:"repo_id"`
	OverallScore     float64   `json:"overall_score"` // 0-100
	TestCoverage     float64   `json:"test_coverage"`
	DocCoverage      float64   `json:"doc_coverage"`
	CodeQuality      float64   `json:"code_quality"`
	ContextPackCount int       `json:"context_pack_count"`
	LastAnalyzed     time.Time `json:"last_analyzed"`
}

// AethymeClient provides access to the Aethyme API
type AethymeClient struct {
	baseURL    string
	apiKey     string
	httpClient *http.Client
	cache      *aethymeCache
}

// aethymeCache provides local caching for Aethyme responses
type aethymeCache struct {
	mu            sync.RWMutex
	contextPacks  map[string]*cachedItem[*ContextPack]
	skillPacks    map[string]*cachedItem[*SkillPack]
	scorecards    map[string]*cachedItem[*RepoScorecard]
	cacheDuration time.Duration
}

type cachedItem[T any] struct {
	value     T
	expiresAt time.Time
}

// NewAethymeClient creates a new Aethyme API client
func NewAethymeClient(baseURL, apiKey string) (*AethymeClient, error) {
	if baseURL == "" {
		return nil, nil // Aethyme is optional
	}

	normalizedBaseURL, err := normalizeServiceBaseURL(baseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid Aethyme base URL: %w", err)
	}

	return &AethymeClient{
		baseURL:    normalizedBaseURL,
		apiKey:     apiKey,
		httpClient: newRestrictedHTTPClient(10 * time.Second),
		cache: &aethymeCache{
			contextPacks:  make(map[string]*cachedItem[*ContextPack]),
			skillPacks:    make(map[string]*cachedItem[*SkillPack]),
			scorecards:    make(map[string]*cachedItem[*RepoScorecard]),
			cacheDuration: 5 * time.Minute,
		},
	}, nil
}

// GetContextPack retrieves context pack metadata by ID
func (c *AethymeClient) GetContextPack(packID string) (*ContextPack, error) {
	if c == nil || packID == "" {
		return nil, nil
	}

	// Check cache first
	c.cache.mu.RLock()
	if cached, ok := c.cache.contextPacks[packID]; ok && time.Now().Before(cached.expiresAt) {
		c.cache.mu.RUnlock()
		return cached.value, nil
	}
	c.cache.mu.RUnlock()

	// Fetch from API
	url := buildServiceURL(c.baseURL, fmt.Sprintf("/api/v1/context-packs/%s", packID))
	resp, err := c.doRequest("GET", url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("aethyme: unexpected status %d", resp.StatusCode)
	}

	var pack ContextPack
	if err := json.NewDecoder(resp.Body).Decode(&pack); err != nil {
		return nil, fmt.Errorf("aethyme: failed to decode response: %w", err)
	}

	// Cache the result
	c.cache.mu.Lock()
	c.cache.contextPacks[packID] = &cachedItem[*ContextPack]{
		value:     &pack,
		expiresAt: time.Now().Add(c.cache.cacheDuration),
	}
	c.cache.mu.Unlock()

	return &pack, nil
}

// GetSkillPack retrieves skill pack metadata by ID
func (c *AethymeClient) GetSkillPack(packID string) (*SkillPack, error) {
	if c == nil || packID == "" {
		return nil, nil
	}

	// Check cache first
	c.cache.mu.RLock()
	if cached, ok := c.cache.skillPacks[packID]; ok && time.Now().Before(cached.expiresAt) {
		c.cache.mu.RUnlock()
		return cached.value, nil
	}
	c.cache.mu.RUnlock()

	// Fetch from API
	url := buildServiceURL(c.baseURL, fmt.Sprintf("/api/v1/skill-packs/%s", packID))
	resp, err := c.doRequest("GET", url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("aethyme: unexpected status %d", resp.StatusCode)
	}

	var pack SkillPack
	if err := json.NewDecoder(resp.Body).Decode(&pack); err != nil {
		return nil, fmt.Errorf("aethyme: failed to decode response: %w", err)
	}

	// Cache the result
	c.cache.mu.Lock()
	c.cache.skillPacks[packID] = &cachedItem[*SkillPack]{
		value:     &pack,
		expiresAt: time.Now().Add(c.cache.cacheDuration),
	}
	c.cache.mu.Unlock()

	return &pack, nil
}

// GetRepoScorecard retrieves the scorecard for a repository
func (c *AethymeClient) GetRepoScorecard(repoID string) (*RepoScorecard, error) {
	if c == nil || repoID == "" {
		return nil, nil
	}

	// Check cache first
	c.cache.mu.RLock()
	if cached, ok := c.cache.scorecards[repoID]; ok && time.Now().Before(cached.expiresAt) {
		c.cache.mu.RUnlock()
		return cached.value, nil
	}
	c.cache.mu.RUnlock()

	// Fetch from API
	url := buildServiceURL(c.baseURL, fmt.Sprintf("/api/v1/repos/%s/scorecard", repoID))
	resp, err := c.doRequest("GET", url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("aethyme: unexpected status %d", resp.StatusCode)
	}

	var scorecard RepoScorecard
	if err := json.NewDecoder(resp.Body).Decode(&scorecard); err != nil {
		return nil, fmt.Errorf("aethyme: failed to decode response: %w", err)
	}

	// Cache the result
	c.cache.mu.Lock()
	c.cache.scorecards[repoID] = &cachedItem[*RepoScorecard]{
		value:     &scorecard,
		expiresAt: time.Now().Add(c.cache.cacheDuration),
	}
	c.cache.mu.Unlock()

	return &scorecard, nil
}

// ListContextPacks lists context packs for a repository
func (c *AethymeClient) ListContextPacks(repoID string) ([]*ContextPack, error) {
	if c == nil || repoID == "" {
		return nil, nil
	}

	url := buildServiceURL(c.baseURL, fmt.Sprintf("/api/v1/repos/%s/context-packs", repoID))
	resp, err := c.doRequest("GET", url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("aethyme: unexpected status %d", resp.StatusCode)
	}

	var packs []*ContextPack
	if err := json.NewDecoder(resp.Body).Decode(&packs); err != nil {
		return nil, fmt.Errorf("aethyme: failed to decode response: %w", err)
	}

	return packs, nil
}

// doRequest performs an HTTP request with authentication
func (c *AethymeClient) doRequest(method, url string) (*http.Response, error) {
	req, err := http.NewRequest(method, url, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Accept", "application/json")
	if c.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.apiKey)
	}

	return c.httpClient.Do(req)
}

// Health checks if the Aethyme service is available
func (c *AethymeClient) Health() error {
	if c == nil {
		return nil // Aethyme is optional
	}

	url := buildServiceURL(c.baseURL, "/health")
	resp, err := c.httpClient.Get(url)
	if err != nil {
		return fmt.Errorf("aethyme: health check failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("aethyme: health check returned %d: %s", resp.StatusCode, string(body))
	}

	return nil
}

// ClearCache clears the local cache
func (c *AethymeClient) ClearCache() {
	if c == nil {
		return
	}

	c.cache.mu.Lock()
	defer c.cache.mu.Unlock()

	c.cache.contextPacks = make(map[string]*cachedItem[*ContextPack])
	c.cache.skillPacks = make(map[string]*cachedItem[*SkillPack])
	c.cache.scorecards = make(map[string]*cachedItem[*RepoScorecard])
}
