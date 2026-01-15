package main

import (
	"testing"
)

func TestTokenEstimator_EstimateTokens(t *testing.T) {
	te := NewTokenEstimator()

	tests := []struct {
		name     string
		text     string
		expected int
	}{
		{"empty", "", 0},
		{"short", "hello", 1},                           // 5 chars / 4 = 1
		{"medium", "hello world", 2},                    // 11 chars / 4 = 2
		{"long", "This is a longer piece of text.", 8}, // 32 chars / 4 = 8
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := te.EstimateTokens(tt.text)
			if result != tt.expected {
				t.Errorf("EstimateTokens(%q) = %d, want %d", tt.text, result, tt.expected)
			}
		})
	}
}

func TestBaselineEstimator_EstimateBaseline(t *testing.T) {
	be := NewBaselineEstimator(nil, nil)

	tests := []struct {
		name         string
		provider     Provider
		model        string
		prompt       string
		actualInput  int
		actualOutput int
		expectMethod BaselineMethod
	}{
		{
			name:         "character estimate",
			provider:     ProviderAnthropic,
			model:        "claude-sonnet-4",
			prompt:       "Fix the login bug",
			actualInput:  100,
			actualOutput: 500,
			expectMethod: BaselineMethodCharEstimate,
		},
		{
			name:         "empty prompt",
			provider:     ProviderOpenAI,
			model:        "gpt-4o",
			prompt:       "",
			actualInput:  200,
			actualOutput: 300,
			expectMethod: BaselineMethodCharEstimate,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := be.EstimateBaseline(
				tt.provider,
				tt.model,
				tt.prompt,
				tt.actualInput,
				tt.actualOutput,
				"", // no context pack
			)

			if result == nil {
				t.Fatal("Expected non-nil baseline estimate")
			}

			if result.Method != tt.expectMethod {
				t.Errorf("Method = %q, want %q", result.Method, tt.expectMethod)
			}

			if result.Version != BaselineVersion {
				t.Errorf("Version = %q, want %q", result.Version, BaselineVersion)
			}

			if result.TotalTokens != result.InputTokens+result.OutputTokens {
				t.Errorf("TotalTokens = %d, want %d (Input + Output)",
					result.TotalTokens, result.InputTokens+result.OutputTokens)
			}
		})
	}
}

func TestBaselineEstimator_RecordCall(t *testing.T) {
	be := NewBaselineEstimator(nil, nil)

	// Record some calls
	be.RecordCall("claude-sonnet-4", 100)
	be.RecordCall("claude-sonnet-4", 200)
	be.RecordCall("claude-sonnet-4", 300)

	stats := be.GetStats()
	modelStats, ok := stats["claude-sonnet-4"]
	if !ok {
		t.Fatal("Expected stats for claude-sonnet-4")
	}

	if modelStats.TotalCalls != 3 {
		t.Errorf("TotalCalls = %d, want 3", modelStats.TotalCalls)
	}

	if modelStats.TotalOutput != 600 {
		t.Errorf("TotalOutput = %d, want 600", modelStats.TotalOutput)
	}

	expectedAvg := 200.0
	if modelStats.AvgOutput != expectedAvg {
		t.Errorf("AvgOutput = %f, want %f", modelStats.AvgOutput, expectedAvg)
	}
}

func TestBaselineEstimator_HistoricalAverage(t *testing.T) {
	be := NewBaselineEstimator(nil, nil)
	be.minSamples = 3 // Lower for testing

	// Record enough samples
	for i := 0; i < 5; i++ {
		be.RecordCall("claude-opus-4", 1000)
	}

	// Now historical average should be used
	result := be.EstimateBaseline(
		ProviderAnthropic,
		"claude-opus-4",
		"Fix the critical bug",
		200,
		500,
		"",
	)

	if result.Method != BaselineMethodHistoricalAvg {
		t.Errorf("Method = %q, want %q", result.Method, BaselineMethodHistoricalAvg)
	}

	// Output should be based on historical average (1000), not actual (500)
	if result.OutputTokens < 500 {
		t.Errorf("OutputTokens = %d, should be at least actual (500)", result.OutputTokens)
	}
}

func TestBaselineEstimator_TokensSaved(t *testing.T) {
	be := NewBaselineEstimator(nil, nil)

	tests := []struct {
		name           string
		prompt         string
		actualInput    int
		actualOutput   int
		expectPositive bool
	}{
		{
			name:           "savings when baseline higher",
			prompt:         "This is a long prompt with many words that would normally require more tokens",
			actualInput:    10,
			actualOutput:   50,
			expectPositive: true, // baseline > actual = positive savings
		},
		{
			name:           "no savings when actual higher",
			prompt:         "Short",
			actualInput:    100,
			actualOutput:   200,
			expectPositive: false, // baseline < actual = negative savings
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := be.EstimateBaseline(
				ProviderAnthropic,
				"claude-sonnet-4",
				tt.prompt,
				tt.actualInput,
				tt.actualOutput,
				"",
			)

			if tt.expectPositive && result.TokensSaved <= 0 {
				t.Errorf("Expected positive savings, got %d", result.TokensSaved)
			}

			// Verify formula: tokens_saved = baseline_total - actual_total
			expectedSaved := result.TotalTokens - (tt.actualInput + tt.actualOutput)
			if result.TokensSaved != expectedSaved {
				t.Errorf("TokensSaved = %d, want %d (baseline - actual)", result.TokensSaved, expectedSaved)
			}
		})
	}
}

func TestBaselineEstimator_ModelDefaults(t *testing.T) {
	be := NewBaselineEstimator(nil, nil)

	tests := []struct {
		model          string
		expectedMinOut int
	}{
		{"claude-opus-4", 2000},
		{"claude-sonnet-4", 1500},
		{"gpt-4o", 1500},
		{"gemini-pro", 1200},
		{"unknown-model", 1500}, // default
	}

	for _, tt := range tests {
		t.Run(tt.model, func(t *testing.T) {
			result := be.EstimateBaseline(
				ProviderAnthropic,
				tt.model,
				"test prompt",
				100,
				100, // low actual output
				"",
			)

			// Model default should be used since actual is low
			if result.OutputTokens < tt.expectedMinOut {
				t.Errorf("OutputTokens = %d, want at least %d for model %s",
					result.OutputTokens, tt.expectedMinOut, tt.model)
			}
		})
	}
}

func TestBaselineEstimator_Confidence(t *testing.T) {
	be := NewBaselineEstimator(nil, nil)

	// Character estimate should have lower confidence
	result := be.EstimateBaseline(
		ProviderAnthropic,
		"claude-sonnet-4",
		"test",
		100,
		100,
		"",
	)

	if result.Confidence != 0.5 {
		t.Errorf("Character estimate confidence = %f, want 0.5", result.Confidence)
	}

	// After enough samples, historical average should have higher confidence
	be.minSamples = 2
	be.RecordCall("claude-sonnet-4", 200)
	be.RecordCall("claude-sonnet-4", 200)
	be.RecordCall("claude-sonnet-4", 200)

	result = be.EstimateBaseline(
		ProviderAnthropic,
		"claude-sonnet-4",
		"test",
		100,
		100,
		"",
	)

	if result.Confidence != 0.7 {
		t.Errorf("Historical avg confidence = %f, want 0.7", result.Confidence)
	}
}
