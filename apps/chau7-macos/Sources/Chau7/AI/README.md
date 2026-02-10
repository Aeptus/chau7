# AI

LLM-powered error explanation and AI agent detection for terminal sessions.

## Files

| File | Purpose |
|------|---------|
| `AIAgentLogo.swift` | Defines known AI CLI agents (Claude, Gemini, etc.) with brand colors and logos |
| `AITerminalLogSession.swift` | Records PTY output to a log file for AI tool sessions |
| `ErrorExplainer.swift` | Sends terminal error output to an LLM provider and returns structured explanations |
| `ErrorExplanationView.swift` | SwiftUI view displaying LLM-generated error explanations with suggested fixes |
| `LLMClient.swift` | HTTP client for LLM providers (OpenAI, Anthropic, Ollama, Custom) |

## Key Types

- `AIAgent` — enum of recognized AI CLI tools with logo and brand color metadata
- `ErrorExplainer` — ObservableObject service that queries LLMs to explain terminal errors
- `LLMClient` — generic HTTP client handling provider-specific request/response formats

## Dependencies

- **Uses:** Logging, Settings (via `FeatureSettings`)
- **Used by:** Overlay, Terminal, Settings/Views
