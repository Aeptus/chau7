package main

import (
	"sync"
	"time"
)

// BaselineVersion is the version of the baseline estimation algorithm
const BaselineVersion = "1.0.0"

// BaselineMethod represents the method used to estimate baseline tokens
type BaselineMethod string

const (
	BaselineMethodUnavailable    BaselineMethod = "unavailable"
	BaselineMethodCharEstimate   BaselineMethod = "character_estimate"
	BaselineMethodHistoricalAvg  BaselineMethod = "historical_avg"
	BaselineMethodContextPack    BaselineMethod = "context_pack"
	BaselineMethodModelDefault   BaselineMethod = "model_default"
)

// BaselineEstimate contains the estimated baseline token usage
type BaselineEstimate struct {
	InputTokens  int            `json:"input_tokens"`
	OutputTokens int            `json:"output_tokens"`
	TotalTokens  int            `json:"total_tokens"`
	Method       BaselineMethod `json:"method"`
	Version      string         `json:"version"`
	TokensSaved  int            `json:"tokens_saved"` // Can be negative
	Confidence   float64        `json:"confidence"`   // 0.0 - 1.0
}

// ModelOutputStats tracks historical output token statistics per model
type ModelOutputStats struct {
	Model          string
	TotalCalls     int
	TotalOutput    int64
	AvgOutput      float64
	LastUpdated    time.Time
}

// BaselineEstimator provides token baseline estimation for measuring savings
type BaselineEstimator struct {
	mu               sync.RWMutex
	modelStats       map[string]*ModelOutputStats // model -> stats
	aethymeClient    *AethymeClient
	db               *Database

	// Configuration
	charsPerToken    float64 // Average characters per token (heuristic)
	minSamples       int     // Minimum samples for historical average
}

// NewBaselineEstimator creates a new baseline estimator
func NewBaselineEstimator(db *Database, aethyme *AethymeClient) *BaselineEstimator {
	return &BaselineEstimator{
		modelStats:    make(map[string]*ModelOutputStats),
		aethymeClient: aethyme,
		db:            db,
		charsPerToken: 4.0, // ~4 characters per token is a reasonable heuristic
		minSamples:    10,  // Need at least 10 samples for historical average
	}
}

// EstimateBaseline calculates the baseline token estimate for a request
// This represents what the token usage would be WITHOUT context optimization
func (be *BaselineEstimator) EstimateBaseline(
	provider Provider,
	model string,
	promptContent string,
	actualInput int,
	actualOutput int,
	contextPackID string,
) *BaselineEstimate {
	// Try different estimation methods in priority order

	// 1. If we have a context pack, use its metadata for estimation
	if contextPackID != "" && be.aethymeClient != nil {
		if estimate := be.estimateFromContextPack(provider, model, promptContent, actualInput, actualOutput, contextPackID); estimate != nil {
			return estimate
		}
	}

	// 2. Try historical average for output tokens
	if estimate := be.estimateFromHistorical(provider, model, promptContent, actualInput, actualOutput); estimate != nil {
		return estimate
	}

	// 3. Fall back to character-based estimation
	return be.estimateFromCharacters(provider, model, promptContent, actualInput, actualOutput)
}

// estimateFromContextPack uses Aethyme context pack metadata for baseline
func (be *BaselineEstimator) estimateFromContextPack(
	provider Provider,
	model string,
	promptContent string,
	actualInput int,
	actualOutput int,
	contextPackID string,
) *BaselineEstimate {
	if be.aethymeClient == nil {
		return nil
	}

	pack, err := be.aethymeClient.GetContextPack(contextPackID)
	if err != nil || pack == nil {
		return nil
	}

	// Context pack tells us how many tokens were saved by compression
	// baseline = actual + saved
	baselineInput := actualInput + pack.TokensSaved
	baselineOutput := be.getHistoricalOutputAvg(model, actualOutput)

	estimate := &BaselineEstimate{
		InputTokens:  baselineInput,
		OutputTokens: baselineOutput,
		TotalTokens:  baselineInput + baselineOutput,
		Method:       BaselineMethodContextPack,
		Version:      BaselineVersion,
		Confidence:   0.9, // High confidence when we have context pack data
	}
	estimate.TokensSaved = estimate.TotalTokens - (actualInput + actualOutput)

	return estimate
}

// estimateFromHistorical uses historical averages for baseline estimation
func (be *BaselineEstimator) estimateFromHistorical(
	provider Provider,
	model string,
	promptContent string,
	actualInput int,
	actualOutput int,
) *BaselineEstimate {
	be.mu.RLock()
	stats, ok := be.modelStats[model]
	be.mu.RUnlock()

	if !ok || stats.TotalCalls < be.minSamples {
		return nil
	}

	// Use character-based estimate for input (no context pack info)
	baselineInput := be.estimateInputTokens(promptContent, actualInput)

	// Use historical average for output
	baselineOutput := int(stats.AvgOutput)
	if baselineOutput < actualOutput {
		baselineOutput = actualOutput // Can't save more than actual
	}

	estimate := &BaselineEstimate{
		InputTokens:  baselineInput,
		OutputTokens: baselineOutput,
		TotalTokens:  baselineInput + baselineOutput,
		Method:       BaselineMethodHistoricalAvg,
		Version:      BaselineVersion,
		Confidence:   0.7, // Good confidence with historical data
	}
	estimate.TokensSaved = estimate.TotalTokens - (actualInput + actualOutput)

	return estimate
}

// estimateFromCharacters uses character count heuristic for baseline
func (be *BaselineEstimator) estimateFromCharacters(
	provider Provider,
	model string,
	promptContent string,
	actualInput int,
	actualOutput int,
) *BaselineEstimate {
	baselineInput := be.estimateInputTokens(promptContent, actualInput)
	baselineOutput := be.getModelDefaultOutput(model, actualOutput)

	estimate := &BaselineEstimate{
		InputTokens:  baselineInput,
		OutputTokens: baselineOutput,
		TotalTokens:  baselineInput + baselineOutput,
		Method:       BaselineMethodCharEstimate,
		Version:      BaselineVersion,
		Confidence:   0.5, // Lower confidence for heuristic estimation
	}
	estimate.TokensSaved = estimate.TotalTokens - (actualInput + actualOutput)

	return estimate
}

// estimateInputTokens estimates input token count from prompt content
func (be *BaselineEstimator) estimateInputTokens(promptContent string, actualInput int) int {
	if promptContent == "" {
		// No content available, use actual as baseline (no savings calculable)
		return actualInput
	}

	// Estimate tokens from character count
	estimated := int(float64(len(promptContent)) / be.charsPerToken)

	// If actual is significantly higher, use actual (context might have added tokens)
	if actualInput > estimated {
		return actualInput
	}

	return estimated
}

// getHistoricalOutputAvg returns historical average or actual if not enough samples
func (be *BaselineEstimator) getHistoricalOutputAvg(model string, actualOutput int) int {
	be.mu.RLock()
	stats, ok := be.modelStats[model]
	be.mu.RUnlock()

	if !ok || stats.TotalCalls < be.minSamples {
		return actualOutput
	}

	avg := int(stats.AvgOutput)
	if avg < actualOutput {
		return actualOutput
	}
	return avg
}

// getModelDefaultOutput returns a default output estimate based on model class
func (be *BaselineEstimator) getModelDefaultOutput(model string, actualOutput int) int {
	// Model-specific output averages (based on typical usage patterns)
	defaults := map[string]int{
		"claude-opus":   2000,
		"claude-sonnet": 1500,
		"claude-haiku":  1000,
		"gpt-4":         1500,
		"gpt-4o":        1500,
		"gpt-4o-mini":   1000,
		"gpt-3.5":       800,
		"gemini-pro":    1200,
		"gemini-flash":  1000,
		"o1":            3000,
		"o3":            2500,
	}

	// Try prefix matching
	for prefix, defaultOutput := range defaults {
		if len(model) >= len(prefix) && model[:len(prefix)] == prefix {
			if defaultOutput > actualOutput {
				return defaultOutput
			}
			return actualOutput
		}
	}

	// Generic default
	if actualOutput > 1500 {
		return actualOutput
	}
	return 1500
}

// RecordCall updates the historical statistics for a model
func (be *BaselineEstimator) RecordCall(model string, outputTokens int) {
	be.mu.Lock()
	defer be.mu.Unlock()

	stats, ok := be.modelStats[model]
	if !ok {
		stats = &ModelOutputStats{
			Model:       model,
			LastUpdated: time.Now(),
		}
		be.modelStats[model] = stats
	}

	// Update rolling average
	stats.TotalCalls++
	stats.TotalOutput += int64(outputTokens)
	stats.AvgOutput = float64(stats.TotalOutput) / float64(stats.TotalCalls)
	stats.LastUpdated = time.Now()
}

// LoadHistoricalStats loads historical statistics from the database
func (be *BaselineEstimator) LoadHistoricalStats() error {
	if be.db == nil {
		return nil
	}

	stats, err := be.db.GetModelOutputStats()
	if err != nil {
		return err
	}

	be.mu.Lock()
	defer be.mu.Unlock()

	for _, s := range stats {
		be.modelStats[s.Model] = s
	}

	return nil
}

// GetStats returns the current model statistics
func (be *BaselineEstimator) GetStats() map[string]*ModelOutputStats {
	be.mu.RLock()
	defer be.mu.RUnlock()

	// Return a copy
	result := make(map[string]*ModelOutputStats)
	for k, v := range be.modelStats {
		copy := *v
		result[k] = &copy
	}
	return result
}

// TokenEstimator provides simple token estimation utilities
type TokenEstimator struct {
	charsPerToken float64
}

// NewTokenEstimator creates a new token estimator
func NewTokenEstimator() *TokenEstimator {
	return &TokenEstimator{
		charsPerToken: 4.0,
	}
}

// EstimateTokens estimates the number of tokens in a text
func (te *TokenEstimator) EstimateTokens(text string) int {
	if text == "" {
		return 0
	}
	return int(float64(len(text)) / te.charsPerToken)
}

// EstimateFromBytes estimates tokens from byte length
func (te *TokenEstimator) EstimateFromBytes(byteLen int) int {
	return int(float64(byteLen) / te.charsPerToken)
}
