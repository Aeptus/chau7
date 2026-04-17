package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeRulesFile(t *testing.T, dir string, rules []InjectionRule) string {
	t.Helper()
	path := filepath.Join(dir, "prompt-rules.json")
	data, err := json.Marshal(InjectionConfig{Rules: rules})
	if err != nil {
		t.Fatalf("marshal rules: %v", err)
	}
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatalf("write rules file: %v", err)
	}
	return path
}

// ---------------------------------------------------------------------------
// matchRepository
// ---------------------------------------------------------------------------

func TestMatchPath_Exact(t *testing.T) {
	if !matchRepository("/Users/me/repo", "/Users/me/repo") {
		t.Error("exact match should succeed")
	}
	if matchRepository("/Users/me/repo", "/Users/me/other") {
		t.Error("different path should not match")
	}
}

func TestMatchPath_PrefixWildcard(t *testing.T) {
	if !matchRepository("/Users/me/org/*", "/Users/me/org/repo-a") {
		t.Error("prefix wildcard should match child")
	}
	if matchRepository("/Users/me/org/*", "/Users/me/org") {
		t.Error("prefix wildcard should not match the prefix itself (no trailing /)")
	}
	if matchRepository("/Users/me/org/*", "/Users/me/other/repo") {
		t.Error("prefix wildcard should not match unrelated paths")
	}
}

func TestMatchRepository_Name(t *testing.T) {
	// Simple repo name matches last path component
	if !matchRepository("my-api", "/Users/me/code/my-api") {
		t.Error("repo name should match last path component")
	}
	if matchRepository("my-api", "/Users/me/code/other-repo") {
		t.Error("repo name should not match different repo")
	}
}

func TestMatchRepository_NameGlob(t *testing.T) {
	if !matchRepository("chau7-*", "/Users/me/code/chau7-proxy") {
		t.Error("repo name glob should match")
	}
	if !matchRepository("chau7-*", "/home/bob/chau7-relay") {
		t.Error("repo name glob should match on any machine")
	}
	if matchRepository("chau7-*", "/Users/me/code/unrelated") {
		t.Error("repo name glob should not match unrelated repo")
	}
}

func TestMatchRepository_EmptyPattern(t *testing.T) {
	if matchRepository("", "/Users/me/repo") {
		t.Error("empty pattern should never match")
	}
}

// ---------------------------------------------------------------------------
// Injector rule loading and matching
// ---------------------------------------------------------------------------

func TestInjector_MatchProject(t *testing.T) {
	dir := t.TempDir()
	path := writeRulesFile(t, dir, []InjectionRule{
		{Repository: "/repos/alpha", Content: "alpha rules", Position: PositionPrepend},
		{Repository: "/repos/beta/*", Content: "beta rules", Position: PositionAppend},
	})

	inj := NewInjector(path)

	rule := inj.MatchProject("/repos/alpha")
	if rule == nil || rule.Content != "alpha rules" {
		t.Fatalf("expected alpha rule, got %v", rule)
	}

	rule = inj.MatchProject("/repos/beta/sub")
	if rule == nil || rule.Content != "beta rules" {
		t.Fatalf("expected beta rule, got %v", rule)
	}

	rule = inj.MatchProject("/repos/gamma")
	if rule != nil {
		t.Fatalf("expected no match, got %v", rule)
	}
}

func TestInjector_DefaultPosition(t *testing.T) {
	dir := t.TempDir()
	path := writeRulesFile(t, dir, []InjectionRule{
		{Repository: "/repo", Content: "hello"},
	})

	inj := NewInjector(path)
	rule := inj.MatchProject("/repo")
	if rule == nil {
		t.Fatal("expected match")
	}
	if rule.Position != PositionPrepend {
		t.Errorf("default position should be prepend, got %s", rule.Position)
	}
}

func TestInjector_MissingFile(t *testing.T) {
	inj := NewInjector("/nonexistent/path/rules.json")
	rule := inj.MatchProject("/anything")
	if rule != nil {
		t.Fatal("expected nil when rules file missing")
	}
}

// ---------------------------------------------------------------------------
// Anthropic Messages API injection
// ---------------------------------------------------------------------------

func TestInject_Anthropic_PrependUserMessage(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model":      "claude-sonnet-4-20250514",
		"max_tokens": 1024,
		"messages": []map[string]string{
			{"role": "user", "content": "Fix the bug"},
		},
	})

	result := injectUserMessage(ProviderAnthropic, body, "Context: use Go conventions", true)

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	msgs := parsed["messages"].([]interface{})
	msg := msgs[0].(map[string]interface{})
	content := msg["content"].(string)

	if content != "Context: use Go conventions\n\nFix the bug" {
		t.Errorf("unexpected content: %q", content)
	}
}

func TestInject_Anthropic_AppendUserMessage(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model": "claude-sonnet-4-20250514",
		"messages": []map[string]string{
			{"role": "user", "content": "Fix the bug"},
		},
	})

	result := injectUserMessage(ProviderAnthropic, body, "Remember: write tests", false)

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	msgs := parsed["messages"].([]interface{})
	msg := msgs[0].(map[string]interface{})
	content := msg["content"].(string)

	if content != "Fix the bug\n\nRemember: write tests" {
		t.Errorf("unexpected content: %q", content)
	}
}

func TestInject_Anthropic_ContentBlockArray(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model": "claude-sonnet-4-20250514",
		"messages": []map[string]interface{}{
			{
				"role": "user",
				"content": []map[string]string{
					{"type": "text", "text": "Describe this image"},
					{"type": "image", "source": "base64data"},
				},
			},
		},
	})

	result := injectUserMessage(ProviderAnthropic, body, "Be concise", true)

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	msgs := parsed["messages"].([]interface{})
	msg := msgs[0].(map[string]interface{})
	blocks := msg["content"].([]interface{})

	if len(blocks) != 3 {
		t.Fatalf("expected 3 content blocks, got %d", len(blocks))
	}

	first := blocks[0].(map[string]interface{})
	if first["text"] != "Be concise" {
		t.Errorf("first block should be injected text, got %v", first)
	}
}

func TestInject_Anthropic_MultipleMessages_LastUser(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model": "claude-sonnet-4-20250514",
		"messages": []map[string]string{
			{"role": "user", "content": "First question"},
			{"role": "assistant", "content": "First answer"},
			{"role": "user", "content": "Follow-up"},
		},
	})

	result := injectUserMessage(ProviderAnthropic, body, "PREFIX", true)

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	msgs := parsed["messages"].([]interface{})

	// First user message should be untouched
	first := msgs[0].(map[string]interface{})
	if first["content"] != "First question" {
		t.Errorf("first user message should be unchanged, got %q", first["content"])
	}

	// Last user message should be modified
	last := msgs[2].(map[string]interface{})
	if last["content"] != "PREFIX\n\nFollow-up" {
		t.Errorf("last user message should be prefixed, got %q", last["content"])
	}
}

// ---------------------------------------------------------------------------
// Anthropic system injection
// ---------------------------------------------------------------------------

func TestInject_Anthropic_System_String(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model":  "claude-sonnet-4-20250514",
		"system": "You are helpful",
		"messages": []map[string]string{
			{"role": "user", "content": "Hi"},
		},
	})

	result := injectSystem(ProviderAnthropic, body, "Extra rules")

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	sys := parsed["system"].(string)
	if sys != "Extra rules\n\nYou are helpful" {
		t.Errorf("unexpected system: %q", sys)
	}
}

func TestInject_Anthropic_System_NoExisting(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model": "claude-sonnet-4-20250514",
		"messages": []map[string]string{
			{"role": "user", "content": "Hi"},
		},
	})

	result := injectSystem(ProviderAnthropic, body, "New system")

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	sys := parsed["system"].(string)
	if sys != "New system" {
		t.Errorf("unexpected system: %q", sys)
	}
}

// ---------------------------------------------------------------------------
// OpenAI Responses API injection (Codex CLI)
// ---------------------------------------------------------------------------

func TestInject_ResponsesAPI_StringInput_Prepend(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model": "gpt-4o",
		"input": "Fix the tests",
	})

	result := injectUserMessage(ProviderOpenAI, body, "Context: Node.js project", true)

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	input := parsed["input"].(string)
	if input != "Context: Node.js project\n\nFix the tests" {
		t.Errorf("unexpected input: %q", input)
	}
}

func TestInject_ResponsesAPI_StringInput_Append(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model": "gpt-4o",
		"input": "Fix the tests",
	})

	result := injectUserMessage(ProviderOpenAI, body, "Be thorough", false)

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	input := parsed["input"].(string)
	if input != "Fix the tests\n\nBe thorough" {
		t.Errorf("unexpected input: %q", input)
	}
}

func TestInject_ResponsesAPI_ArrayInput(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model": "gpt-4o",
		"input": []map[string]string{
			{"role": "user", "content": "Fix it"},
		},
	})

	result := injectUserMessage(ProviderOpenAI, body, "PREFIX", true)

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	input := parsed["input"].([]interface{})
	msg := input[0].(map[string]interface{})
	if msg["content"] != "PREFIX\n\nFix it" {
		t.Errorf("unexpected content: %q", msg["content"])
	}
}

func TestInject_ResponsesAPI_System(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model":        "gpt-4o",
		"input":        "Fix the bug",
		"instructions": "You are a coder",
	})

	result := injectSystem(ProviderOpenAI, body, "Also lint")

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	instr := parsed["instructions"].(string)
	if instr != "Also lint\n\nYou are a coder" {
		t.Errorf("unexpected instructions: %q", instr)
	}
}

func TestInject_ResponsesAPI_System_NoExisting(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model": "gpt-4o",
		"input": "Fix the bug",
	})

	result := injectSystem(ProviderOpenAI, body, "New instructions")

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	instr := parsed["instructions"].(string)
	if instr != "New instructions" {
		t.Errorf("unexpected instructions: %q", instr)
	}
}

// ---------------------------------------------------------------------------
// OpenAI Chat Completions system injection
// ---------------------------------------------------------------------------

func TestInject_ChatCompletions_System_Existing(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model": "gpt-4o",
		"messages": []map[string]string{
			{"role": "system", "content": "You are helpful"},
			{"role": "user", "content": "Hi"},
		},
	})

	result := injectSystem(ProviderOpenAI, body, "Extra")

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	msgs := parsed["messages"].([]interface{})
	sys := msgs[0].(map[string]interface{})
	if sys["content"] != "Extra\n\nYou are helpful" {
		t.Errorf("unexpected system content: %q", sys["content"])
	}
}

func TestInject_ChatCompletions_System_None(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"model": "gpt-4o",
		"messages": []map[string]string{
			{"role": "user", "content": "Hi"},
		},
	})

	result := injectSystem(ProviderOpenAI, body, "New system")

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	msgs := parsed["messages"].([]interface{})
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages (system + user), got %d", len(msgs))
	}
	sys := msgs[0].(map[string]interface{})
	if sys["role"] != "system" || sys["content"] != "New system" {
		t.Errorf("unexpected system message: %v", sys)
	}
}

// ---------------------------------------------------------------------------
// Gemini injection
// ---------------------------------------------------------------------------

func TestInject_Gemini_PrependUserMessage(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"contents": []map[string]interface{}{
			{
				"role": "user",
				"parts": []map[string]string{
					{"text": "Hello"},
				},
			},
		},
	})

	result := injectUserMessage(ProviderGemini, body, "PREFIX", true)

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	contents := parsed["contents"].([]interface{})
	turn := contents[0].(map[string]interface{})
	parts := turn["parts"].([]interface{})

	if len(parts) != 2 {
		t.Fatalf("expected 2 parts, got %d", len(parts))
	}

	first := parts[0].(map[string]interface{})
	if first["text"] != "PREFIX" {
		t.Errorf("first part should be injected, got %v", first)
	}
}

func TestInject_Gemini_System(t *testing.T) {
	body := mustJSON(t, map[string]interface{}{
		"contents": []map[string]interface{}{
			{"role": "user", "parts": []map[string]string{{"text": "Hi"}}},
		},
	})

	result := injectSystem(ProviderGemini, body, "Be brief")

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	si := parsed["systemInstruction"].(map[string]interface{})
	parts := si["parts"].([]interface{})
	first := parts[0].(map[string]interface{})
	if first["text"] != "Be brief" {
		t.Errorf("unexpected systemInstruction: %v", first)
	}
}

// ---------------------------------------------------------------------------
// InjectContent end-to-end (with Injector)
// ---------------------------------------------------------------------------

func TestInjectContent_EndToEnd(t *testing.T) {
	dir := t.TempDir()
	path := writeRulesFile(t, dir, []InjectionRule{
		{Repository: "/my/repo", Content: "INJECTED", Position: PositionPrepend},
	})

	inj := NewInjector(path)

	body := mustJSON(t, map[string]interface{}{
		"model": "claude-sonnet-4-20250514",
		"messages": []map[string]string{
			{"role": "user", "content": "Hello"},
		},
	})

	result := inj.InjectContent(ProviderAnthropic, body, "/my/repo")

	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)

	msgs := parsed["messages"].([]interface{})
	msg := msgs[0].(map[string]interface{})
	if msg["content"] != "INJECTED\n\nHello" {
		t.Errorf("unexpected content: %q", msg["content"])
	}
}

func TestInjectContent_NoMatch(t *testing.T) {
	dir := t.TempDir()
	path := writeRulesFile(t, dir, []InjectionRule{
		{Repository: "/my/repo", Content: "INJECTED"},
	})

	inj := NewInjector(path)

	body := mustJSON(t, map[string]interface{}{
		"model": "gpt-4o",
		"input": "Hello",
	})

	result := inj.InjectContent(ProviderOpenAI, body, "/other/repo")

	if string(result) != string(body) {
		t.Error("body should be unchanged when no rule matches")
	}
}

func TestInjectContent_RepoName(t *testing.T) {
	dir := t.TempDir()
	path := writeRulesFile(t, dir, []InjectionRule{
		{Repository: "my-api", Content: "INJECTED", Position: PositionPrepend},
	})

	inj := NewInjector(path)

	body := mustJSON(t, map[string]interface{}{
		"model": "gpt-4o",
		"input": "Hello",
	})

	// Should match by repo name regardless of base path
	result := inj.InjectContent(ProviderOpenAI, body, "/Users/alice/code/my-api")
	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)
	if parsed["input"] != "INJECTED\n\nHello" {
		t.Errorf("repo name match failed: %q", parsed["input"])
	}

	// Same repo name, different machine path
	result2 := inj.InjectContent(ProviderOpenAI, body, "/home/bob/projects/my-api")
	var parsed2 map[string]interface{}
	mustUnmarshal(t, result2, &parsed2)
	if parsed2["input"] != "INJECTED\n\nHello" {
		t.Errorf("portable repo name match failed: %q", parsed2["input"])
	}
}

func TestInjectContent_NoMessages(t *testing.T) {
	dir := t.TempDir()
	path := writeRulesFile(t, dir, []InjectionRule{
		{Repository: "my-api", Content: "INJECTED", Position: PositionPrepend},
	})

	inj := NewInjector(path)

	// Body with no messages/input/contents — e.g. an embeddings request.
	// Must pass through unmodified.
	body := mustJSON(t, map[string]interface{}{
		"model": "text-embedding-ada-002",
		"input": "Hello world",
	})

	// This should work (input is a string, so it gets injected)
	result := inj.InjectContent(ProviderOpenAI, body, "/x/my-api")
	var parsed map[string]interface{}
	mustUnmarshal(t, result, &parsed)
	if parsed["input"] != "INJECTED\n\nHello world" {
		t.Errorf("string input injection failed: %q", parsed["input"])
	}

	// Body with no recognizable message structure at all
	rawBody := []byte(`{"model":"gpt-4o","prompt":"legacy completion"}`)
	result2 := inj.InjectContent(ProviderOpenAI, rawBody, "/x/my-api")
	if string(result2) != string(rawBody) {
		t.Error("body should pass through unchanged when no applicable field found")
	}

	// Empty body should not panic
	result3 := inj.InjectContent(ProviderOpenAI, []byte{}, "/x/my-api")
	if len(result3) != 0 {
		t.Error("empty body should return empty")
	}
}

func TestInjectContent_EmptyProject(t *testing.T) {
	dir := t.TempDir()
	path := writeRulesFile(t, dir, []InjectionRule{
		{Repository: "/my/repo", Content: "INJECTED"},
	})

	inj := NewInjector(path)
	body := []byte(`{"model":"gpt-4o","input":"Hi"}`)

	result := inj.InjectContent(ProviderOpenAI, body, "")

	if string(result) != string(body) {
		t.Error("body should be unchanged when project is empty")
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func mustJSON(t *testing.T, v interface{}) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	return data
}

func mustUnmarshal(t *testing.T, data []byte, v interface{}) {
	t.Helper()
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatalf("json.Unmarshal: %v\nbody: %s", err, data)
	}
}
