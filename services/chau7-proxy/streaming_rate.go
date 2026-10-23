package main

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	streamTokenCharsPerToken = 4
	streamRateWindow         = 3 * time.Second
	streamRateEmitInterval   = 900 * time.Millisecond
	maxPendingSSELineBytes   = 1 << 20
)

type streamRateSample struct {
	at        time.Time
	textRunes int
}

// streamingRateObserver converts provider SSE text deltas into a short-window
// estimate. It only emits counters; incomplete SSE framing is held in a bounded
// transient buffer until the next line arrives.
type streamingRateObserver struct {
	provider Provider
	tabID    string
	model    string
	notifier *IPCNotifier

	pending         []byte
	textRunes       int
	samples         []streamRateSample
	lastEmittedAt   time.Time
	lastEmittedToks int
}

func newStreamingRateObserver(
	provider Provider,
	tabID string,
	model string,
	notifier *IPCNotifier,
) io.Writer {
	return &streamingRateObserver{
		provider: provider,
		tabID:    tabID,
		model:    model,
		notifier: notifier,
	}
}

func (o *streamingRateObserver) Write(chunk []byte) (int, error) {
	length := len(chunk)
	o.pending = append(o.pending, chunk...)
	for {
		newline := bytes.IndexByte(o.pending, '\n')
		if newline < 0 {
			break
		}
		line := strings.TrimSpace(string(o.pending[:newline]))
		o.pending = o.pending[newline+1:]
		o.consumeSSELine(line)
	}
	if len(o.pending) > maxPendingSSELineBytes {
		o.pending = nil
	}
	return length, nil
}

func (o *streamingRateObserver) consumeSSELine(line string) {
	if !strings.HasPrefix(line, "data:") {
		return
	}
	data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
	if data == "" || data == "[DONE]" {
		return
	}
	text := streamingTextDelta(o.provider, []byte(data))
	if text == "" {
		return
	}

	now := time.Now()
	if len(o.samples) == 0 {
		o.samples = append(o.samples, streamRateSample{at: now, textRunes: 0})
	}
	o.textRunes += utf8.RuneCountInString(text)
	o.samples = append(o.samples, streamRateSample{at: now, textRunes: o.textRunes})
	o.pruneSamples(now)

	totalOutputTokens := o.textRunes / streamTokenCharsPerToken
	if totalOutputTokens <= o.lastEmittedToks || now.Sub(o.lastEmittedAt) < streamRateEmitInterval {
		return
	}
	rate, windowMs, windowTokens := o.shortWindowRate(now)
	if rate <= 0 || windowMs <= 0 {
		return
	}
	if err := o.notifier.NotifyGenerationProgress(
		o.tabID,
		o.provider,
		o.model,
		windowTokens,
		rate,
		windowMs,
		now,
	); err == nil {
		o.lastEmittedAt = now
		o.lastEmittedToks = totalOutputTokens
	}
}

func (o *streamingRateObserver) pruneSamples(now time.Time) {
	cutoff := now.Add(-streamRateWindow)
	removeCount := 0
	for removeCount+1 < len(o.samples) && o.samples[removeCount+1].at.Before(cutoff) {
		removeCount++
	}
	if removeCount > 0 {
		o.samples = append([]streamRateSample(nil), o.samples[removeCount:]...)
	}
}

func (o *streamingRateObserver) shortWindowRate(now time.Time) (float64, int64, int) {
	if len(o.samples) < 2 {
		return 0, 0, 0
	}
	cutoff := now.Add(-streamRateWindow)
	baseline := o.samples[0]
	for _, sample := range o.samples {
		if sample.at.After(cutoff) {
			break
		}
		baseline = sample
	}
	window := now.Sub(baseline.at)
	if window < 250*time.Millisecond {
		baseline = o.samples[0]
		window = now.Sub(baseline.at)
	}
	if window <= 0 {
		return 0, 0, 0
	}
	newRunes := o.textRunes - baseline.textRunes
	windowTokens := newRunes / streamTokenCharsPerToken
	if windowTokens < 1 && newRunes > 0 {
		windowTokens = 1
	}
	return float64(newRunes) / streamTokenCharsPerToken / window.Seconds(), window.Milliseconds(), windowTokens
}

func streamingTextDelta(provider Provider, data []byte) string {
	switch provider {
	case ProviderAnthropic:
		var event struct {
			Type  string `json:"type"`
			Delta struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"delta"`
		}
		if json.Unmarshal(data, &event) != nil || event.Type != "content_block_delta" || event.Delta.Type != "text_delta" {
			return ""
		}
		return event.Delta.Text

	case ProviderOpenAI:
		var event struct {
			Type    string          `json:"type"`
			Delta   json.RawMessage `json:"delta"`
			Choices []struct {
				Delta struct {
					Content json.RawMessage `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if json.Unmarshal(data, &event) != nil {
			return ""
		}
		if event.Type == "response.output_text.delta" {
			var delta string
			if json.Unmarshal(event.Delta, &delta) == nil {
				return delta
			}
			return ""
		}
		var result strings.Builder
		for _, choice := range event.Choices {
			var content string
			if json.Unmarshal(choice.Delta.Content, &content) == nil {
				result.WriteString(content)
				continue
			}
			var parts []struct {
				Text string `json:"text"`
			}
			if json.Unmarshal(choice.Delta.Content, &parts) == nil {
				for _, part := range parts {
					result.WriteString(part.Text)
				}
			}
		}
		return result.String()

	case ProviderGemini:
		var event struct {
			Candidates []struct {
				Content struct {
					Parts []struct {
						Text string `json:"text"`
					} `json:"parts"`
				} `json:"content"`
			} `json:"candidates"`
		}
		if json.Unmarshal(data, &event) != nil {
			return ""
		}
		var result strings.Builder
		for _, candidate := range event.Candidates {
			for _, part := range candidate.Content.Parts {
				result.WriteString(part.Text)
			}
		}
		return result.String()
	}
	return ""
}
