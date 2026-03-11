# AI

LLM-powered error explanation and AI agent detection for terminal sessions.

> **Design principle — backend-agnostic AI support.** Chau7 strives to treat every AI coding tool identically. Logo/brand metadata is driven by `AIToolRegistry` (in Chau7Core) — the single source of truth for tool identity. LLM error explanation works with any configured provider. No subsystem should hardcode behavior for a specific AI tool.

## Files

| File | Purpose |
|------|---------|
| `AIAgentLogo.swift` | Renders AI CLI agent logos and brand colors, driven by `AIToolRegistry` definitions |
| `AITerminalLogSession.swift` | Records PTY output to a log file for AI tool sessions |
| `ErrorExplainer.swift` | Sends terminal error output to an LLM provider and returns structured explanations |
| `ErrorExplanationView.swift` | SwiftUI view displaying LLM-generated error explanations with suggested fixes |
| `LLMClient.swift` | HTTP client for LLM providers (OpenAI, Anthropic, Ollama, Custom) |

## Key Types

- `AIAgent` — enum of recognized AI CLI tools with logo and brand color metadata
- `ErrorExplainer` — ObservableObject service that queries LLMs to explain terminal errors
- `LLMClient` — generic HTTP client handling provider-specific request/response formats

## Dependencies

- **Uses:** Logging, Settings (via `FeatureSettings`), Chau7Core (AIToolRegistry)
- **Used by:** Overlay, Terminal, Settings/Views
