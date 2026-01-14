# chau7-proxy

A lightweight, cross-platform API proxy for capturing LLM API call metadata. Designed to work with Chau7 terminal and VS Code extensions.

## Features

- **Pass-through proxy**: Forwards all requests unchanged, including authentication headers
- **Multi-provider support**: Anthropic, OpenAI, and Google Gemini
- **Automatic detection**: Identifies provider from request path and headers
- **Metadata extraction**: Captures model, tokens, latency, and cost
- **Streaming support**: Handles SSE streaming responses
- **SQLite storage**: Persistent analytics with no external dependencies
- **IPC notifications**: Real-time updates to host application via Unix socket
- **No CGO required**: Pure Go SQLite implementation for easy cross-compilation

## Supported Providers

| Provider | Endpoints | Detection |
|----------|-----------|-----------|
| Anthropic | `/v1/messages`, `/v1/complete` | Path + `anthropic-version` header |
| OpenAI | `/v1/chat/completions`, `/v1/completions`, `/v1/responses` | Path pattern |
| Gemini | `/v1*/models/*:generateContent` | Path + `x-goog-api-key` header |

## Building

```bash
# Build for current platform
./build.sh

# Build for all platforms (macOS, Linux, Windows)
./build.sh all

# Run tests
./build.sh test
```

### Requirements

- Go 1.21 or later
- No CGO required (uses pure Go SQLite)

### Build Outputs

```
build/
├── darwin/
│   ├── chau7-proxy           # Universal Binary (arm64 + amd64)
│   ├── chau7-proxy-darwin-arm64
│   └── chau7-proxy-darwin-amd64
├── linux/
│   ├── chau7-proxy-linux-amd64
│   └── chau7-proxy-linux-arm64
└── windows/
    └── chau7-proxy-windows-amd64.exe
```

## Usage

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CHAU7_PROXY_PORT` | HTTP port to listen on | `18080` |
| `CHAU7_DB_PATH` | Path to SQLite database | **Required** |
| `CHAU7_IPC_SOCKET` | Unix socket for IPC notifications | (disabled) |
| `CHAU7_LOG_LEVEL` | Log level: debug, info, warn, error | `info` |
| `CHAU7_LOG_PROMPTS` | Log prompt previews: 0 or 1 | `0` |

### Running Standalone

```bash
export CHAU7_DB_PATH="$HOME/.chau7/analytics.db"
./chau7-proxy
```

### Integration with Chau7

When enabled in Chau7 settings, the proxy starts automatically. CLI tools are configured via environment variables:

```bash
# Set by Chau7 when spawning terminals
ANTHROPIC_BASE_URL=http://127.0.0.1:18080
OPENAI_BASE_URL=http://127.0.0.1:18080/v1
GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:18080
```

## API Endpoints

### Health Check

```
GET /health
```

Returns:
```json
{"status": "ok"}
```

### Daily Statistics

```
GET /stats
```

Returns:
```json
{
  "calls_today": 42,
  "input_tokens_today": 5000,
  "output_tokens_today": 10000,
  "cost_today": 0.1234,
  "avg_latency_ms": 250.5
}
```

## IPC Protocol

When `CHAU7_IPC_SOCKET` is set, the proxy sends newline-delimited JSON messages for each completed API call:

```json
{
  "type": "api_call",
  "data": {
    "session_id": "abc123",
    "provider": "anthropic",
    "model": "claude-3-5-sonnet",
    "endpoint": "/v1/messages",
    "input_tokens": 100,
    "output_tokens": 500,
    "latency_ms": 1234,
    "status_code": 200,
    "cost_usd": 0.0045,
    "timestamp": "2025-01-14T12:00:00Z",
    "error_message": ""
  }
}
```

## Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────┐
│   CLI Tool      │────▶│  chau7-proxy │────▶│  Provider API   │
│  (Claude Code)  │◀────│              │◀────│  (Anthropic)    │
└─────────────────┘     └──────────────┘     └─────────────────┘
                              │
                              │ IPC
                              ▼
                        ┌──────────────┐
                        │    Chau7     │
                        │ (Host App)   │
                        └──────────────┘
```

## Testing

```bash
# Run all tests
./build.sh test

# Run with coverage
./build.sh coverage

# Run specific test
go test -v -run TestDetectProvider ./...
```

## License

Part of the Chau7 project.
