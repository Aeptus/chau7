package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// ModelPricing contains the pricing information for a model
type ModelPricing struct {
	InputPerMillion           float64 // USD per 1M input tokens
	OutputPerMillion          float64 // USD per 1M output tokens
	CacheCreationPerMillion   float64 // USD per 1M cache write tokens (0 = use 1.25x input)
	CacheReadPerMillion       float64 // USD per 1M cache read tokens (0 = use 0.1x input)
	ReasoningOutputPerMillion float64 // USD per 1M reasoning output tokens (0 = use output rate)
}

// CalculateCost computes the cost in USD for a given number of tokens
func (p ModelPricing) CalculateCost(inputTokens, outputTokens int) float64 {
	inputCost := (float64(inputTokens) / 1_000_000.0) * p.InputPerMillion
	outputCost := (float64(outputTokens) / 1_000_000.0) * p.OutputPerMillion
	return inputCost + outputCost
}

// CalculateFullCost computes cost including cache and reasoning tokens.
//
// IMPORTANT: OpenAI's completion_tokens already includes reasoning tokens as a
// subset. To avoid double-billing, we subtract reasoning from output before
// computing output cost, then bill reasoning separately (at the same rate for
// most models, but this allows future differentiation).
func (p ModelPricing) CalculateFullCost(input, output, cacheCreation, cacheRead, reasoning int) float64 {
	cost := (float64(input) / 1e6) * p.InputPerMillion

	// Subtract reasoning from output to avoid double-counting when the provider
	// includes reasoning in completion_tokens (OpenAI). For providers that don't
	// report reasoning (reasoning=0), this is a no-op.
	nonReasoningOutput := output - reasoning
	if nonReasoningOutput < 0 {
		nonReasoningOutput = 0
	}
	cost += (float64(nonReasoningOutput) / 1e6) * p.OutputPerMillion

	// Cache creation: 1.25x input rate for Anthropic (default), or explicit rate
	if cacheCreation > 0 {
		rate := p.CacheCreationPerMillion
		if rate == 0 {
			rate = p.InputPerMillion * 1.25
		}
		cost += (float64(cacheCreation) / 1e6) * rate
	}

	// Cache read: 0.1x input rate for Anthropic, 0.5x for OpenAI (default to 0.1x)
	if cacheRead > 0 {
		rate := p.CacheReadPerMillion
		if rate == 0 {
			rate = p.InputPerMillion * 0.1
		}
		cost += (float64(cacheRead) / 1e6) * rate
	}

	// Reasoning tokens billed at output rate unless explicitly set
	if reasoning > 0 {
		rate := p.ReasoningOutputPerMillion
		if rate == 0 {
			rate = p.OutputPerMillion
		}
		cost += (float64(reasoning) / 1e6) * rate
	}

	return cost
}

// PricingTable contains pricing for known models (as of January 2025)
// Prices are in USD per 1 million tokens
// This should be periodically updated or loaded from a config file
var PricingTable = map[string]ModelPricing{
	// Anthropic models
	"claude-opus-4-6":            {InputPerMillion: 15.00, OutputPerMillion: 75.00},
	"claude-sonnet-4-6":          {InputPerMillion: 3.00, OutputPerMillion: 15.00},
	"claude-haiku-4-5":           {InputPerMillion: 0.80, OutputPerMillion: 4.00},
	"claude-opus-4":              {InputPerMillion: 15.00, OutputPerMillion: 75.00},
	"claude-opus-4-20250514":     {InputPerMillion: 15.00, OutputPerMillion: 75.00},
	"claude-sonnet-4":            {InputPerMillion: 3.00, OutputPerMillion: 15.00},
	"claude-sonnet-4-20250514":   {InputPerMillion: 3.00, OutputPerMillion: 15.00},
	"claude-3-5-sonnet":          {InputPerMillion: 3.00, OutputPerMillion: 15.00},
	"claude-3-5-sonnet-20241022": {InputPerMillion: 3.00, OutputPerMillion: 15.00},
	"claude-3-5-haiku":           {InputPerMillion: 0.80, OutputPerMillion: 4.00},
	"claude-3-5-haiku-20241022":  {InputPerMillion: 0.80, OutputPerMillion: 4.00},
	"claude-3-opus":              {InputPerMillion: 15.00, OutputPerMillion: 75.00},
	"claude-3-opus-20240229":     {InputPerMillion: 15.00, OutputPerMillion: 75.00},
	"claude-3-sonnet":            {InputPerMillion: 3.00, OutputPerMillion: 15.00},
	"claude-3-sonnet-20240229":   {InputPerMillion: 3.00, OutputPerMillion: 15.00},
	"claude-3-haiku":             {InputPerMillion: 0.25, OutputPerMillion: 1.25},
	"claude-3-haiku-20240307":    {InputPerMillion: 0.25, OutputPerMillion: 1.25},

	// OpenAI models — CacheReadPerMillion = 0.5x input (OpenAI's cached pricing)
	"gpt-4o":                 {InputPerMillion: 2.50, OutputPerMillion: 10.00, CacheReadPerMillion: 1.25},
	"gpt-4o-2024-11-20":      {InputPerMillion: 2.50, OutputPerMillion: 10.00, CacheReadPerMillion: 1.25},
	"gpt-4o-mini":            {InputPerMillion: 0.15, OutputPerMillion: 0.60, CacheReadPerMillion: 0.075},
	"gpt-4o-mini-2024-07-18": {InputPerMillion: 0.15, OutputPerMillion: 0.60, CacheReadPerMillion: 0.075},
	"gpt-4-turbo":            {InputPerMillion: 10.00, OutputPerMillion: 30.00},
	"gpt-4-turbo-preview":    {InputPerMillion: 10.00, OutputPerMillion: 30.00},
	"gpt-4":                  {InputPerMillion: 30.00, OutputPerMillion: 60.00},
	"gpt-3.5-turbo":          {InputPerMillion: 0.50, OutputPerMillion: 1.50},
	"o1":                     {InputPerMillion: 15.00, OutputPerMillion: 60.00, CacheReadPerMillion: 7.50},
	"o1-2024-12-17":          {InputPerMillion: 15.00, OutputPerMillion: 60.00, CacheReadPerMillion: 7.50},
	"o1-mini":                {InputPerMillion: 3.00, OutputPerMillion: 12.00, CacheReadPerMillion: 1.50},
	"o1-preview":             {InputPerMillion: 15.00, OutputPerMillion: 60.00, CacheReadPerMillion: 7.50},
	"o3-mini":                {InputPerMillion: 1.10, OutputPerMillion: 4.40, CacheReadPerMillion: 0.55},

	// Google Gemini models (many are free tier)
	"gemini-2.0-flash":        {InputPerMillion: 0.00, OutputPerMillion: 0.00}, // Free
	"gemini-2.0-flash-exp":    {InputPerMillion: 0.00, OutputPerMillion: 0.00}, // Free
	"gemini-1.5-pro":          {InputPerMillion: 1.25, OutputPerMillion: 5.00},
	"gemini-1.5-pro-latest":   {InputPerMillion: 1.25, OutputPerMillion: 5.00},
	"gemini-1.5-flash":        {InputPerMillion: 0.075, OutputPerMillion: 0.30},
	"gemini-1.5-flash-latest": {InputPerMillion: 0.075, OutputPerMillion: 0.30},
	"gemini-pro":              {InputPerMillion: 0.50, OutputPerMillion: 1.50},
}

// CustomPricingOverrides loaded from ~/.chau7/pricing.json at startup.
// Keys are model names, values are {input_per_million, output_per_million}.
var CustomPricingOverrides map[string]ModelPricing

// LoadCustomPricing reads user-defined pricing overrides from ~/.chau7/pricing.json.
// The file is optional — if missing or malformed, no overrides are applied.
func LoadCustomPricing() {
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	path := filepath.Join(home, ".chau7", "pricing.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var overrides map[string]ModelPricing
	if err := json.Unmarshal(data, &overrides); err != nil {
		return
	}
	CustomPricingOverrides = overrides
}

// GetPricing returns the pricing for a model, with fallback to estimated pricing.
// Custom overrides from ~/.chau7/pricing.json take precedence over the built-in table.
func GetPricing(provider Provider, model string) ModelPricing {
	// Try custom overrides first
	if CustomPricingOverrides != nil {
		if pricing, ok := CustomPricingOverrides[model]; ok {
			return pricing
		}
	}
	// Try exact match first
	if pricing, ok := PricingTable[model]; ok {
		return pricing
	}

	// Try prefix matching for versioned models
	for knownModel, pricing := range PricingTable {
		if strings.HasPrefix(model, knownModel) {
			return pricing
		}
	}

	// Fallback to provider defaults (conservative estimates)
	switch provider {
	case ProviderAnthropic:
		return ModelPricing{InputPerMillion: 3.00, OutputPerMillion: 15.00} // Sonnet pricing
	case ProviderOpenAI:
		return ModelPricing{InputPerMillion: 2.50, OutputPerMillion: 10.00} // GPT-4o pricing
	case ProviderGemini:
		return ModelPricing{InputPerMillion: 0.00, OutputPerMillion: 0.00} // Free tier
	default:
		return ModelPricing{InputPerMillion: 3.00, OutputPerMillion: 15.00}
	}
}

// CalculateCostForCall computes the cost for a specific API call (legacy — input + output only)
func CalculateCostForCall(provider Provider, model string, inputTokens, outputTokens int) float64 {
	pricing := GetPricing(provider, model)
	return pricing.CalculateCost(inputTokens, outputTokens)
}

// CalculateFullCostForCall computes the cost including cache and reasoning tokens
func CalculateFullCostForCall(provider Provider, model string, meta ResponseMetadata) float64 {
	pricing := GetPricing(provider, model)
	return pricing.CalculateFullCost(
		meta.InputTokens,
		meta.OutputTokens,
		meta.CacheCreationInputTokens,
		meta.CacheReadInputTokens,
		meta.ReasoningOutputTokens,
	)
}
