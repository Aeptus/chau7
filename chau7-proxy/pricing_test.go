package main

import (
	"math"
	"testing"
)

func TestModelPricing_CalculateCost(t *testing.T) {
	tests := []struct {
		name         string
		pricing      ModelPricing
		inputTokens  int
		outputTokens int
		expectCost   float64
	}{
		{
			name:         "Claude Sonnet typical request",
			pricing:      ModelPricing{InputPerMillion: 3.00, OutputPerMillion: 15.00},
			inputTokens:  1000,
			outputTokens: 500,
			expectCost:   0.0105, // (1000/1M * 3) + (500/1M * 15)
		},
		{
			name:         "GPT-4o typical request",
			pricing:      ModelPricing{InputPerMillion: 2.50, OutputPerMillion: 10.00},
			inputTokens:  500,
			outputTokens: 200,
			expectCost:   0.00325, // (500/1M * 2.5) + (200/1M * 10)
		},
		{
			name:         "Zero tokens",
			pricing:      ModelPricing{InputPerMillion: 3.00, OutputPerMillion: 15.00},
			inputTokens:  0,
			outputTokens: 0,
			expectCost:   0.0,
		},
		{
			name:         "Free tier (Gemini)",
			pricing:      ModelPricing{InputPerMillion: 0.00, OutputPerMillion: 0.00},
			inputTokens:  10000,
			outputTokens: 5000,
			expectCost:   0.0,
		},
		{
			name:         "Large request (1M tokens)",
			pricing:      ModelPricing{InputPerMillion: 15.00, OutputPerMillion: 75.00},
			inputTokens:  500000,
			outputTokens: 500000,
			expectCost:   45.0, // (0.5M * 15) + (0.5M * 75)
		},
		{
			name:         "Only input tokens",
			pricing:      ModelPricing{InputPerMillion: 3.00, OutputPerMillion: 15.00},
			inputTokens:  1000000,
			outputTokens: 0,
			expectCost:   3.0,
		},
		{
			name:         "Only output tokens",
			pricing:      ModelPricing{InputPerMillion: 3.00, OutputPerMillion: 15.00},
			inputTokens:  0,
			outputTokens: 1000000,
			expectCost:   15.0,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cost := tc.pricing.CalculateCost(tc.inputTokens, tc.outputTokens)
			if math.Abs(cost-tc.expectCost) > 0.0001 {
				t.Errorf("Expected cost %.6f, got %.6f", tc.expectCost, cost)
			}
		})
	}
}

func TestGetPricing_ExactMatch(t *testing.T) {
	tests := []struct {
		model       string
		expectInput float64
	}{
		{"claude-opus-4", 15.00},
		{"claude-sonnet-4", 3.00},
		{"claude-3-5-haiku", 0.80},
		{"gpt-4o", 2.50},
		{"gpt-4o-mini", 0.15},
		{"o1", 15.00},
		{"gemini-1.5-pro", 1.25},
		{"gemini-2.0-flash", 0.00},
	}

	for _, tc := range tests {
		t.Run(tc.model, func(t *testing.T) {
			pricing := GetPricing(ProviderAnthropic, tc.model)
			if pricing.InputPerMillion != tc.expectInput {
				t.Errorf("Model %s: expected input pricing %.2f, got %.2f",
					tc.model, tc.expectInput, pricing.InputPerMillion)
			}
		})
	}
}

func TestGetPricing_PrefixMatch(t *testing.T) {
	// Versioned models should match base model
	tests := []struct {
		model       string
		expectInput float64
	}{
		{"claude-3-5-sonnet-20241022", 3.00},
		{"claude-3-opus-20240229", 15.00},
		{"gpt-4o-2024-11-20", 2.50},
		{"gemini-1.5-pro-latest", 1.25},
	}

	for _, tc := range tests {
		t.Run(tc.model, func(t *testing.T) {
			pricing := GetPricing(ProviderAnthropic, tc.model)
			if pricing.InputPerMillion != tc.expectInput {
				t.Errorf("Model %s: expected input pricing %.2f, got %.2f",
					tc.model, tc.expectInput, pricing.InputPerMillion)
			}
		})
	}
}

func TestGetPricing_FallbackToProvider(t *testing.T) {
	tests := []struct {
		provider    Provider
		model       string
		expectInput float64
		expectOutput float64
	}{
		{
			provider:    ProviderAnthropic,
			model:       "claude-unknown-model",
			expectInput: 3.00,  // Falls back to Sonnet pricing
			expectOutput: 15.00,
		},
		{
			provider:    ProviderOpenAI,
			model:       "gpt-5-future",
			expectInput: 2.50,  // Falls back to GPT-4o pricing
			expectOutput: 10.00,
		},
		{
			provider:    ProviderGemini,
			model:       "gemini-unknown",
			expectInput: 0.00,  // Falls back to free tier
			expectOutput: 0.00,
		},
		{
			provider:    Provider("unknown"),
			model:       "some-model",
			expectInput: 3.00,  // Default fallback
			expectOutput: 15.00,
		},
	}

	for _, tc := range tests {
		t.Run(string(tc.provider)+"/"+tc.model, func(t *testing.T) {
			pricing := GetPricing(tc.provider, tc.model)
			if pricing.InputPerMillion != tc.expectInput {
				t.Errorf("Expected input pricing %.2f, got %.2f",
					tc.expectInput, pricing.InputPerMillion)
			}
			if pricing.OutputPerMillion != tc.expectOutput {
				t.Errorf("Expected output pricing %.2f, got %.2f",
					tc.expectOutput, pricing.OutputPerMillion)
			}
		})
	}
}

func TestCalculateCostForCall(t *testing.T) {
	tests := []struct {
		name         string
		provider     Provider
		model        string
		inputTokens  int
		outputTokens int
		minCost      float64
		maxCost      float64
	}{
		{
			name:         "Claude Sonnet small request",
			provider:     ProviderAnthropic,
			model:        "claude-3-5-sonnet",
			inputTokens:  100,
			outputTokens: 50,
			minCost:      0.001,
			maxCost:      0.002,
		},
		{
			name:         "GPT-4o medium request",
			provider:     ProviderOpenAI,
			model:        "gpt-4o",
			inputTokens:  5000,
			outputTokens: 1000,
			minCost:      0.02,
			maxCost:      0.03,
		},
		{
			name:         "Free Gemini",
			provider:     ProviderGemini,
			model:        "gemini-2.0-flash",
			inputTokens:  10000,
			outputTokens: 5000,
			minCost:      0.0,
			maxCost:      0.0,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cost := CalculateCostForCall(tc.provider, tc.model, tc.inputTokens, tc.outputTokens)
			if cost < tc.minCost || cost > tc.maxCost {
				t.Errorf("Cost %.6f not in expected range [%.6f, %.6f]",
					cost, tc.minCost, tc.maxCost)
			}
		})
	}
}

func TestPricingTableCompleteness(t *testing.T) {
	// Ensure all providers have reasonable default pricing
	providers := []Provider{ProviderAnthropic, ProviderOpenAI, ProviderGemini}

	for _, p := range providers {
		t.Run(string(p)+"_default", func(t *testing.T) {
			pricing := GetPricing(p, "nonexistent-model-12345")
			// All providers should have some defined fallback
			if pricing.InputPerMillion < 0 || pricing.OutputPerMillion < 0 {
				t.Errorf("Provider %s has invalid default pricing", p)
			}
		})
	}
}

func TestPricingTableHasKnownModels(t *testing.T) {
	// Verify the pricing table includes critical models
	criticalModels := []string{
		"claude-opus-4",
		"claude-sonnet-4",
		"gpt-4o",
		"gpt-4o-mini",
		"gemini-1.5-pro",
	}

	for _, model := range criticalModels {
		t.Run(model, func(t *testing.T) {
			if _, ok := PricingTable[model]; !ok {
				t.Errorf("Critical model %q missing from pricing table", model)
			}
		})
	}
}
