package main

import (
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

// InjectionRule defines a per-project content injection rule.
type InjectionRule struct {
	Repository string            `json:"repository"`         // Repository name (e.g. "my-api") or absolute path
	Content    string            `json:"content"`            // Content to inject
	Position   InjectionPosition `json:"position,omitempty"` // Where to inject (default: prepend)
}

// InjectionConfig is the top-level structure of prompt-rules.json.
type InjectionConfig struct {
	Rules []InjectionRule `json:"rules"`
}

// Injector manages content injection rules loaded from a JSON config file.
// Rules are cached in memory and refreshed periodically to pick up edits
// without requiring a proxy restart.
type Injector struct {
	mu         sync.RWMutex
	rules      []InjectionRule
	configPath string
	lastLoad   time.Time
	cacheTTL   time.Duration
}

// NewInjector creates an Injector that loads rules from configPath.
// If configPath is empty it defaults to ~/.chau7/prompt-rules.json.
func NewInjector(configPath string) *Injector {
	if configPath == "" {
		home, _ := os.UserHomeDir()
		configPath = filepath.Join(home, ".chau7", "prompt-rules.json")
	}
	inj := &Injector{
		configPath: configPath,
		cacheTTL:   30 * time.Second,
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
		if config.Rules[i].Position == "" {
			config.Rules[i].Position = PositionPrepend
		}
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

// InjectContent mutates a request body according to the first matching rule
// for the given project. Returns the original body unchanged if no rule matches
// or if mutation fails.
func (inj *Injector) InjectContent(provider Provider, body []byte, project string) []byte {
	rule := inj.MatchProject(project)
	if rule == nil {
		return body
	}

	log.Printf("[INFO] inject: matched %q → %s for project %s",
		rule.Repository, rule.Position, project)

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
	return result
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

