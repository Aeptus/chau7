package main

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// InjectionPosition defines where content is injected relative to the user message.
type InjectionPosition string

const (
	PositionPrepend InjectionPosition = "prepend" // Before the user message (default)
	PositionAppend  InjectionPosition = "append"  // After the user message
	PositionSystem  InjectionPosition = "system"  // Into the system prompt / instructions
)

type InjectionTrigger string

const (
	TriggerEveryPrompt        InjectionTrigger = "every_prompt"
	TriggerFirstSessionPrompt InjectionTrigger = "first_session_prompt"
	TriggerAfterCompact       InjectionTrigger = "after_compact"
	TriggerAfterClear         InjectionTrigger = "after_clear"
)

type InjectionSessionEvent string

const (
	SessionEventAfterCompact InjectionSessionEvent = "after_compact"
	SessionEventAfterClear   InjectionSessionEvent = "after_clear"
)

var defaultInjectionTriggers = []InjectionTrigger{TriggerEveryPrompt}

// InjectionRule defines a per-project content injection rule.
type InjectionRule struct {
	Repository string             `json:"repository"`         // Repository name (e.g. "my-api") or absolute path
	Content    string             `json:"content"`            // Content to inject
	Position   InjectionPosition  `json:"position,omitempty"` // Where to inject (default: prepend)
	Triggers   []InjectionTrigger `json:"triggers,omitempty"` // When to inject (default: every_prompt)
}

// InjectionConfig is the top-level structure of prompt-rules.json.
type InjectionConfig struct {
	Rules []InjectionRule `json:"rules"`
}

// repoRuleEntry caches a per-repo injection rule (or nil for "no file").
type repoRuleEntry struct {
	rule     *InjectionRule
	loadedAt time.Time
}

type injectionSessionState struct {
	firstPromptSeen map[string]struct{}
	afterCompact    bool
	afterClear      bool
	lastSeen        time.Time
}

type injectionSessionSnapshot struct {
	isFirstPrompt bool
	afterCompact  bool
	afterClear    bool
}

// Injector manages content injection rules from two sources:
//  1. Global rules file (~/.chau7/prompt-rules.json) — configurable, shared across repos
//  2. Per-repo rules ({project}/.chau7/injection.json) — highest priority, repo-local
//
// Both sources are cached in memory and refreshed periodically.
type Injector struct {
	mu              sync.RWMutex
	rules           []InjectionRule
	repoCache       map[string]repoRuleEntry
	sessionStates   map[string]injectionSessionState
	configPath      string
	lastLoad        time.Time
	cacheTTL        time.Duration
	sessionStateTTL time.Duration
}

// NewInjector creates an Injector that loads rules from configPath.
// If configPath is empty it defaults to ~/.chau7/prompt-rules.json.
func NewInjector(configPath string) *Injector {
	if configPath == "" {
		home, _ := os.UserHomeDir()
		configPath = filepath.Join(home, ".chau7", "prompt-rules.json")
	}
	inj := &Injector{
		configPath:      configPath,
		repoCache:       make(map[string]repoRuleEntry),
		sessionStates:   make(map[string]injectionSessionState),
		cacheTTL:        30 * time.Second,
		sessionStateTTL: 24 * time.Hour,
	}
	inj.loadRules()
	return inj
}

// loadRules reads and parses the rules file. Errors are logged, not fatal —
// the proxy keeps working, just without injection.
func (inj *Injector) loadRules() {
	data, err := os.ReadFile(inj.configPath)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("[WARN] inject: failed to read rules: %v", err)
		}
		inj.mu.Lock()
		inj.lastLoad = time.Now()
		inj.mu.Unlock()
		return
	}

	var config InjectionConfig
	if err := json.Unmarshal(data, &config); err != nil {
		log.Printf("[WARN] inject: failed to parse rules: %v", err)
		inj.mu.Lock()
		inj.lastLoad = time.Now()
		inj.mu.Unlock()
		return
	}

	for i := range config.Rules {
		config.Rules[i] = normalizeInjectionRule(config.Rules[i])
		if config.Rules[i].Repository == "" {
			log.Printf("[WARN] inject: rule %d has empty repository, skipping", i)
		}
	}

	inj.mu.Lock()
	inj.rules = config.Rules
	inj.lastLoad = time.Now()
	inj.mu.Unlock()

	log.Printf("[INFO] inject: loaded %d rule(s) from %s", len(config.Rules), inj.configPath)
}

// getRules returns the current rules, reloading the file if the cache has expired.
func (inj *Injector) getRules() []InjectionRule {
	inj.mu.RLock()
	stale := time.Since(inj.lastLoad) > inj.cacheTTL
	inj.mu.RUnlock()

	if stale {
		inj.loadRules()
	}

	inj.mu.RLock()
	defer inj.mu.RUnlock()
	rules := make([]InjectionRule, len(inj.rules))
	copy(rules, inj.rules)
	return rules
}

// MatchProject returns the first rule whose pattern matches the project path,
// or nil if none match. Rules are evaluated in order — first match wins.
func (inj *Injector) MatchProject(project string) *InjectionRule {
	if project == "" {
		return nil
	}
	for _, rule := range inj.getRules() {
		if matchRepository(rule.Repository, project) {
			return &rule
		}
	}
	return nil
}

func (inj *Injector) RecordSessionEvent(event InjectionSessionEvent, headers *CorrelationHeaders) bool {
	key := correlationSessionKey(headers)
	if key == "" {
		return false
	}

	now := time.Now()
	inj.mu.Lock()
	defer inj.mu.Unlock()

	inj.pruneExpiredSessionStatesLocked(now)
	state := inj.sessionStates[key]
	switch event {
	case SessionEventAfterCompact:
		state.afterCompact = true
	case SessionEventAfterClear:
		state.afterClear = true
	default:
		return false
	}
	state.lastSeen = now
	inj.sessionStates[key] = state
	return true
}

func (inj *Injector) snapshotForRule(headers *CorrelationHeaders, ruleKey string) injectionSessionSnapshot {
	key := correlationSessionKey(headers)
	if key == "" || strings.TrimSpace(ruleKey) == "" {
		return injectionSessionSnapshot{}
	}

	now := time.Now()
	inj.mu.Lock()
	defer inj.mu.Unlock()

	inj.pruneExpiredSessionStatesLocked(now)
	state := inj.sessionStates[key]
	snapshot := injectionSessionSnapshot{
		isFirstPrompt: !state.hasSeenFirstPrompt(ruleKey),
		afterCompact:  state.afterCompact,
		afterClear:    state.afterClear,
	}
	state.lastSeen = now
	inj.sessionStates[key] = state
	return snapshot
}

func (inj *Injector) commitRuleInjection(
	headers *CorrelationHeaders,
	ruleKey string,
	rule *InjectionRule,
	snapshot injectionSessionSnapshot,
) {
	key := correlationSessionKey(headers)
	if key == "" || strings.TrimSpace(ruleKey) == "" || rule == nil {
		return
	}

	now := time.Now()
	inj.mu.Lock()
	defer inj.mu.Unlock()

	inj.pruneExpiredSessionStatesLocked(now)
	state := inj.sessionStates[key]
	triggers := normalizeInjectionTriggers(rule.Triggers)

	if snapshot.isFirstPrompt && hasInjectionTrigger(triggers, TriggerFirstSessionPrompt) {
		if state.firstPromptSeen == nil {
			state.firstPromptSeen = make(map[string]struct{})
		}
		state.firstPromptSeen[ruleKey] = struct{}{}
	}
	if snapshot.afterCompact && hasInjectionTrigger(triggers, TriggerAfterCompact) {
		state.afterCompact = false
	}
	if snapshot.afterClear && hasInjectionTrigger(triggers, TriggerAfterClear) {
		state.afterClear = false
	}
	state.lastSeen = now
	inj.sessionStates[key] = state
}

func (inj *Injector) pruneExpiredSessionStatesLocked(now time.Time) {
	for key, state := range inj.sessionStates {
		if now.Sub(state.lastSeen) > inj.sessionStateTTL {
			delete(inj.sessionStates, key)
		}
	}
}

func correlationSessionKey(headers *CorrelationHeaders) string {
	if headers == nil {
		return ""
	}
	if value := normalizeCorrelationValue(headers.SessionID, "unknown"); value != "" {
		return "session:" + value
	}
	if value := normalizeCorrelationValue(headers.TabID, "default"); value != "" {
		return "tab:" + value
	}
	return ""
}

func normalizeCorrelationValue(value, placeholder string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || trimmed == placeholder {
		return ""
	}
	return trimmed
}

// matchRepository checks whether the project path matches a rule's repository
// pattern. Matching strategy depends on the pattern format:
//
//   - Repository name (no leading /): "my-api" matches any project whose last
//     path component is "my-api". This is portable across machines. Glob
//     patterns work here too: "chau7-*" matches "chau7-proxy", "chau7-relay", etc.
//
//   - Absolute path (leading /): "/Users/me/repo" is an exact or prefix match
//     against the full project path. Suffix "/*" enables prefix wildcard:
//     "/Users/me/org/*" matches any repo under that directory.
func matchRepository(pattern, project string) bool {
	if pattern == "" {
		return false
	}

	// Wildcard: matches every project.
	if pattern == "*" {
		return true
	}

	// Absolute path: match against the full project path.
	if strings.HasPrefix(pattern, "/") {
		if pattern == project {
			return true
		}
		if strings.HasSuffix(pattern, "/*") {
			prefix := strings.TrimSuffix(pattern, "/*")
			if strings.HasPrefix(project, prefix+"/") {
				return true
			}
		}
		matched, _ := filepath.Match(pattern, project)
		return matched
	}

	// Repository name: match against the last component of the project path,
	// mirroring RepositoryModel.repoName in the Swift app.
	repoName := filepath.Base(project)
	if pattern == repoName {
		return true
	}
	matched, _ := filepath.Match(pattern, repoName)
	return matched
}

// loadRepoRule checks for a per-repo injection file at {project}/.chau7/injection.json.
// Results (including misses) are cached with the same TTL as global rules.
func (inj *Injector) loadRepoRule(project string) *InjectionRule {
	inj.mu.RLock()
	if entry, ok := inj.repoCache[project]; ok && time.Since(entry.loadedAt) < inj.cacheTTL {
		inj.mu.RUnlock()
		return entry.rule
	}
	inj.mu.RUnlock()

	path := filepath.Join(project, ".chau7", "injection.json")
	data, err := os.ReadFile(path)
	if err != nil {
		inj.mu.Lock()
		inj.repoCache[project] = repoRuleEntry{rule: nil, loadedAt: time.Now()}
		inj.mu.Unlock()
		return nil
	}

	var rule InjectionRule
	if err := json.Unmarshal(data, &rule); err != nil {
		log.Printf("[WARN] inject: failed to parse %s: %v", path, err)
		inj.mu.Lock()
		inj.repoCache[project] = repoRuleEntry{rule: nil, loadedAt: time.Now()}
		inj.mu.Unlock()
		return nil
	}

	if rule.Position == "" {
		rule.Position = PositionPrepend
	}
	rule = normalizeInjectionRule(rule)

	log.Printf("[INFO] inject: loaded repo-local rule from %s", path)
	inj.mu.Lock()
	inj.repoCache[project] = repoRuleEntry{rule: &rule, loadedAt: time.Now()}
	inj.mu.Unlock()
	return &rule
}

// InjectContent mutates a request body according to the best matching rule
// for the given project. Priority:
//  1. Per-repo file: {project}/.chau7/injection.json (highest)
//  2. Global rules matching by repo name or path
//  3. Global wildcard rule (repository: "*")
//
// Returns the original body unchanged if no rule matches or if mutation fails.
func (inj *Injector) InjectContent(provider Provider, body []byte, project string, headers *CorrelationHeaders) []byte {
	// Priority 1: repo-local injection file
	rule := inj.loadRepoRule(project)

	// Priority 2+3: global rules (specific matches before * wildcard,
	// since rules are evaluated in order — first match wins)
	if rule == nil {
		rule = inj.MatchProject(project)
	}

	if rule == nil {
		return body
	}

	ruleKey := injectionRuleStateKey(rule, project)
	sessionSnapshot := inj.snapshotForRule(headers, ruleKey)
	if !shouldInjectForRule(rule, sessionSnapshot) {
		return body
	}

	source := rule.Repository
	if source == "" {
		source = "repo-local"
	}
	log.Printf("[INFO] inject: matched %q → %s for project %s (triggers=%v)",
		source, rule.Position, project, normalizeInjectionTriggers(rule.Triggers))

	var result []byte
	switch rule.Position {
	case PositionPrepend:
		result = injectUserMessage(provider, body, rule.Content, true)
	case PositionAppend:
		result = injectUserMessage(provider, body, rule.Content, false)
	case PositionSystem:
		result = injectSystem(provider, body, rule.Content)
	default:
		return body
	}

	if bytes.Equal(result, body) {
		return body
	}
	inj.commitRuleInjection(headers, ruleKey, rule, sessionSnapshot)
	return result
}

func normalizeInjectionRule(rule InjectionRule) InjectionRule {
	if rule.Position == "" {
		rule.Position = PositionPrepend
	}
	rule.Triggers = normalizeInjectionTriggers(rule.Triggers)
	return rule
}

func normalizeInjectionTriggers(triggers []InjectionTrigger) []InjectionTrigger {
	if len(triggers) == 0 {
		return append([]InjectionTrigger(nil), defaultInjectionTriggers...)
	}
	seen := make(map[InjectionTrigger]struct{}, len(triggers))
	normalized := make([]InjectionTrigger, 0, len(triggers))
	for _, trigger := range triggers {
		if trigger == "" {
			continue
		}
		if _, ok := seen[trigger]; ok {
			continue
		}
		seen[trigger] = struct{}{}
		normalized = append(normalized, trigger)
	}
	if len(normalized) == 0 {
		return append([]InjectionTrigger(nil), defaultInjectionTriggers...)
	}
	return normalized
}

func shouldInjectForRule(rule *InjectionRule, snapshot injectionSessionSnapshot) bool {
	for _, trigger := range normalizeInjectionTriggers(rule.Triggers) {
		switch trigger {
		case TriggerEveryPrompt:
			return true
		case TriggerFirstSessionPrompt:
			if snapshot.isFirstPrompt {
				return true
			}
		case TriggerAfterCompact:
			if snapshot.afterCompact {
				return true
			}
		case TriggerAfterClear:
			if snapshot.afterClear {
				return true
			}
		}
	}
	return false
}

func (state injectionSessionState) hasSeenFirstPrompt(ruleKey string) bool {
	if len(state.firstPromptSeen) == 0 {
		return false
	}
	_, ok := state.firstPromptSeen[ruleKey]
	return ok
}

func hasInjectionTrigger(triggers []InjectionTrigger, needle InjectionTrigger) bool {
	for _, trigger := range normalizeInjectionTriggers(triggers) {
		if trigger == needle {
			return true
		}
	}
	return false
}

func injectionRuleStateKey(rule *InjectionRule, project string) string {
	if rule == nil {
		return ""
	}
	normalized := normalizeInjectionRule(*rule)
	scope := strings.TrimSpace(normalized.Repository)
	if scope == "" {
		scope = "repo-local:" + project
	} else {
		scope = "rule:" + scope
	}

	var builder strings.Builder
	builder.WriteString(scope)
	builder.WriteString("|")
	builder.WriteString(string(normalized.Position))
	for _, trigger := range []InjectionTrigger{
		TriggerEveryPrompt,
		TriggerFirstSessionPrompt,
		TriggerAfterCompact,
		TriggerAfterClear,
	} {
		if hasInjectionTrigger(normalized.Triggers, trigger) {
			builder.WriteString("|")
			builder.WriteString(string(trigger))
		}
	}
	return builder.String()
}

// ---------------------------------------------------------------------------
// User-message injection (prepend / append)
// ---------------------------------------------------------------------------

// injectUserMessage prepends or appends content to the last user message in
// the request body. Handles three request formats:
//   - messages array (Anthropic Messages API, OpenAI Chat Completions)
//   - input field (OpenAI Responses API — string or array)
//   - contents array (Gemini)
func injectUserMessage(provider Provider, body []byte, content string, prepend bool) []byte {
	var payload map[string]interface{}
	if err := json.Unmarshal(body, &payload); err != nil {
		log.Printf("[WARN] inject: failed to parse body: %v", err)
		return body
	}

	modified := false

	// 1. messages array (Anthropic, OpenAI Chat Completions)
	if msgs, ok := payload["messages"].([]interface{}); ok && len(msgs) > 0 {
		modified = mutateLastUserMessage(msgs, content, prepend)
	}

	// 2. input field (OpenAI Responses API)
	if !modified {
		if input, exists := payload["input"]; exists {
			switch v := input.(type) {
			case string:
				if prepend {
					payload["input"] = content + "\n\n" + v
				} else {
					payload["input"] = v + "\n\n" + content
				}
				modified = true
			case []interface{}:
				modified = mutateLastUserMessage(v, content, prepend)
			}
		}
	}

	// 3. contents array (Gemini)
	if !modified {
		if contents, ok := payload["contents"].([]interface{}); ok && len(contents) > 0 {
			modified = mutateGeminiLastUser(contents, content, prepend)
		}
	}

	if !modified {
		// No user message found — return original body unmodified.
		// This is normal for non-chat requests (e.g. embeddings, token counts).
		return body
	}

	return mustMarshal(payload, body)
}

// mutateLastUserMessage finds the last message with role "user" and
// prepends/appends content to it. Works with both string and array content.
func mutateLastUserMessage(messages []interface{}, content string, prepend bool) bool {
	for i := len(messages) - 1; i >= 0; i-- {
		msg, ok := messages[i].(map[string]interface{})
		if !ok {
			continue
		}
		role, _ := msg["role"].(string)
		if role != "user" {
			continue
		}

		switch c := msg["content"].(type) {
		case string:
			if prepend {
				msg["content"] = content + "\n\n" + c
			} else {
				msg["content"] = c + "\n\n" + content
			}
			return true

		case []interface{}:
			textBlock := map[string]interface{}{
				"type": "text",
				"text": content,
			}
			if prepend {
				msg["content"] = append([]interface{}{textBlock}, c...)
			} else {
				msg["content"] = append(c, textBlock)
			}
			return true
		}
	}
	return false
}

// mutateGeminiLastUser handles Gemini's contents[].parts[] structure.
func mutateGeminiLastUser(contents []interface{}, content string, prepend bool) bool {
	for i := len(contents) - 1; i >= 0; i-- {
		turn, ok := contents[i].(map[string]interface{})
		if !ok {
			continue
		}
		role, _ := turn["role"].(string)
		if role != "user" && role != "" {
			continue
		}

		parts, ok := turn["parts"].([]interface{})
		if !ok {
			continue
		}

		textPart := map[string]interface{}{"text": content}
		if prepend {
			turn["parts"] = append([]interface{}{textPart}, parts...)
		} else {
			turn["parts"] = append(parts, textPart)
		}
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// System injection
// ---------------------------------------------------------------------------

// injectSystem prepends content to the system prompt / instructions field.
func injectSystem(provider Provider, body []byte, content string) []byte {
	var payload map[string]interface{}
	if err := json.Unmarshal(body, &payload); err != nil {
		log.Printf("[WARN] inject: failed to parse body for system injection: %v", err)
		return body
	}

	switch provider {
	case ProviderAnthropic:
		injectAnthropicSystem(payload, content)

	case ProviderOpenAI:
		// Responses API uses "instructions"; Chat Completions uses a system message.
		if _, hasInput := payload["input"]; hasInput {
			injectResponsesSystem(payload, content)
		} else {
			injectChatCompletionsSystem(payload, content)
		}

	case ProviderGemini:
		injectGeminiSystem(payload, content)

	default:
		return body
	}

	return mustMarshal(payload, body)
}

func injectAnthropicSystem(payload map[string]interface{}, content string) {
	switch existing := payload["system"].(type) {
	case string:
		payload["system"] = content + "\n\n" + existing
	case []interface{}:
		textBlock := map[string]interface{}{
			"type": "text",
			"text": content,
		}
		payload["system"] = append([]interface{}{textBlock}, existing...)
	default:
		payload["system"] = content
	}
}

func injectResponsesSystem(payload map[string]interface{}, content string) {
	if existing, ok := payload["instructions"].(string); ok && existing != "" {
		payload["instructions"] = content + "\n\n" + existing
	} else {
		payload["instructions"] = content
	}
}

func injectChatCompletionsSystem(payload map[string]interface{}, content string) {
	msgs, ok := payload["messages"].([]interface{})
	if !ok {
		return
	}

	// Modify existing system message if present
	if len(msgs) > 0 {
		first, ok := msgs[0].(map[string]interface{})
		if ok {
			role, _ := first["role"].(string)
			if role == "system" || role == "developer" {
				switch c := first["content"].(type) {
				case string:
					first["content"] = content + "\n\n" + c
				case []interface{}:
					textBlock := map[string]interface{}{
						"type": "text",
						"text": content,
					}
					first["content"] = append([]interface{}{textBlock}, c...)
				}
				return
			}
		}
	}

	// No system message found — insert one at position 0
	sysMsg := map[string]interface{}{
		"role":    "system",
		"content": content,
	}
	payload["messages"] = append([]interface{}{sysMsg}, msgs...)
}

func injectGeminiSystem(payload map[string]interface{}, content string) {
	existing, ok := payload["systemInstruction"].(map[string]interface{})
	if ok {
		parts, _ := existing["parts"].([]interface{})
		textPart := map[string]interface{}{"text": content}
		existing["parts"] = append([]interface{}{textPart}, parts...)
	} else {
		payload["systemInstruction"] = map[string]interface{}{
			"parts": []interface{}{
				map[string]interface{}{"text": content},
			},
		}
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func mustMarshal(payload map[string]interface{}, fallback []byte) []byte {
	result, err := json.Marshal(payload)
	if err != nil {
		log.Printf("[WARN] inject: failed to re-marshal body: %v", err)
		return fallback
	}
	return result
}
