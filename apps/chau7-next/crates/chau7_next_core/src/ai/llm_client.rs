//! Request and response formats of `AI/LLMClient.swift`, without the HTTP
//! transport (the app sends the request).
//!
//! - OpenAI and Custom: chat completions (`model`, system and user
//!   `messages`, `max_tokens`), `Authorization: Bearer <key>` when a key is set.
//! - Anthropic: Messages API (`system`, user `messages`, `max_tokens`),
//!   `x-api-key` and `anthropic-version: 2023-06-01`.
//! - Ollama: `/api/chat` with `stream: false`, no key.
//!
//! Token usage: OpenAI `usage.total_tokens`, Anthropic input plus output
//! tokens, Ollama `eval_count`. Requests time out after 30 s.

use serde_json::{Value, json};

use crate::llm_provider::{LLMProviderConfig, LLMProviderType, LLMRequest, LLMResponse};

/// `urlRequest.timeoutInterval`.
pub const TIMEOUT_SECS: u64 = 30;

/// `LLMClientError`, with Swift's `errorDescription` as `Display`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LLMClientError {
    InvalidConfig,
    InvalidEndpoint(String),
    InvalidResponse,
    HttpError(u16, String),
    ParseFailed,
    /// The transport failed (no connection, timeout). Swift shows URLSession's
    /// own message here.
    Transport(String),
}

impl std::fmt::Display for LLMClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidConfig => write!(f, "LLM provider is not configured correctly"),
            Self::InvalidEndpoint(url) => write!(f, "Invalid endpoint URL: {url}"),
            Self::InvalidResponse => write!(f, "Server returned an invalid response"),
            Self::HttpError(code, body) => {
                write!(
                    f,
                    "HTTP {code}: {}",
                    body.chars().take(100).collect::<String>()
                )
            }
            Self::ParseFailed => write!(f, "Failed to parse LLM response"),
            Self::Transport(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for LLMClientError {}

/// A ready-to-send POST request.
#[derive(Debug, Clone, PartialEq)]
pub struct HttpRequest {
    pub url: String,
    /// Header name and value pairs, in a fixed order.
    pub headers: Vec<(String, String)>,
    pub body: String,
}

/// Whether `endpoint` is a URL Swift's `URL(string:)` would take for a POST:
/// an http or https scheme and a host.
fn is_valid_endpoint(endpoint: &str) -> bool {
    let lower = endpoint.trim().to_lowercase();
    let rest = lower
        .strip_prefix("https://")
        .or_else(|| lower.strip_prefix("http://"));
    match rest {
        Some(rest) => {
            let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
            !host.is_empty() && !endpoint.contains(char::is_whitespace)
        }
        None => false,
    }
}

/// Builds the request for `config` (`buildRequest`), checking the config
/// and endpoint first like `send`.
pub fn build_request(
    request: &LLMRequest,
    config: &LLMProviderConfig,
) -> Result<HttpRequest, LLMClientError> {
    if !config.is_valid() {
        return Err(LLMClientError::InvalidConfig);
    }
    if !is_valid_endpoint(&config.endpoint) {
        return Err(LLMClientError::InvalidEndpoint(config.endpoint.clone()));
    }
    let content_type = ("Content-Type".to_string(), "application/json".to_string());
    let (body, headers) = match config.provider {
        LLMProviderType::Openai | LLMProviderType::Custom => {
            let body = json!({
                "model": config.model,
                "messages": [
                    {"role": "system", "content": request.system_prompt},
                    {"role": "user", "content": request.user_message},
                ],
                "max_tokens": request.max_tokens,
            });
            let mut headers = vec![content_type];
            if !config.api_key.is_empty() {
                headers.push((
                    "Authorization".to_string(),
                    format!("Bearer {}", config.api_key),
                ));
            }
            (body, headers)
        }
        LLMProviderType::Anthropic => {
            let body = json!({
                "model": config.model,
                "system": request.system_prompt,
                "messages": [
                    {"role": "user", "content": request.user_message},
                ],
                "max_tokens": request.max_tokens,
            });
            let headers = vec![
                content_type,
                ("x-api-key".to_string(), config.api_key.clone()),
                ("anthropic-version".to_string(), "2023-06-01".to_string()),
            ];
            (body, headers)
        }
        LLMProviderType::Ollama => {
            let body = json!({
                "model": config.model,
                "messages": [
                    {"role": "system", "content": request.system_prompt},
                    {"role": "user", "content": request.user_message},
                ],
                "stream": false,
            });
            (body, vec![content_type])
        }
    };
    Ok(HttpRequest {
        url: config.endpoint.clone(),
        headers,
        body: body.to_string(),
    })
}

/// Checks the status and parses the body (`send` after the transfer,
/// `parseResponse`).
pub fn parse_response(
    status: u16,
    body: &[u8],
    config: &LLMProviderConfig,
) -> Result<LLMResponse, LLMClientError> {
    if !(200..=299).contains(&status) {
        let text = String::from_utf8(body.to_vec()).unwrap_or_else(|_| "no body".to_string());
        log::error!(
            "LLMClient: HTTP {status}: {}",
            text.chars().take(200).collect::<String>()
        );
        return Err(LLMClientError::HttpError(status, text));
    }
    let json: Value = serde_json::from_slice(body).map_err(|_| LLMClientError::ParseFailed)?;
    let obj = json.as_object().ok_or(LLMClientError::ParseFailed)?;
    let int = |v: Option<&Value>| v.and_then(Value::as_i64);
    match config.provider {
        LLMProviderType::Openai | LLMProviderType::Custom => {
            let content = obj
                .get("choices")
                .and_then(Value::as_array)
                .and_then(|c| c.first())
                .and_then(|c| c.get("message"))
                .and_then(|m| m.get("content"))
                .and_then(Value::as_str)
                .ok_or(LLMClientError::ParseFailed)?;
            let tokens = int(obj.get("usage").and_then(|u| u.get("total_tokens")));
            Ok(LLMResponse::new(content, tokens, &config.model))
        }
        LLMProviderType::Anthropic => {
            let text = obj
                .get("content")
                .and_then(Value::as_array)
                .and_then(|c| c.first())
                .and_then(|c| c.get("text"))
                .and_then(Value::as_str)
                .ok_or(LLMClientError::ParseFailed)?;
            let usage = obj.get("usage");
            let input = int(usage.and_then(|u| u.get("input_tokens"))).unwrap_or(0);
            let output = int(usage.and_then(|u| u.get("output_tokens"))).unwrap_or(0);
            Ok(LLMResponse::new(text, Some(input + output), &config.model))
        }
        LLMProviderType::Ollama => {
            let content = obj
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(Value::as_str)
                .ok_or(LLMClientError::ParseFailed)?;
            let tokens = int(obj.get("eval_count"));
            Ok(LLMResponse::new(content, tokens, &config.model))
        }
    }
}

/// The "Test Connection" request (`testConnection`).
pub fn test_connection_request() -> LLMRequest {
    LLMRequest::new("Reply with OK.", "Test connection", 10)
}

/// "OK: <model>" or "Error: <message>" (`testResult`).
pub fn test_connection_result(result: &Result<LLMResponse, LLMClientError>) -> String {
    match result {
        Ok(response) => format!("OK: {}", response.model),
        Err(err) => format!("Error: {err}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(provider: LLMProviderType, key: &str) -> LLMProviderConfig {
        LLMProviderConfig::new(provider, key, None, None, 1024)
    }

    fn body(req: &HttpRequest) -> Value {
        serde_json::from_str(&req.body).unwrap()
    }

    #[test]
    fn openai_request() {
        let req = build_request(
            &LLMRequest::new("sys", "user", 50),
            &config(LLMProviderType::Openai, "k"),
        )
        .unwrap();
        assert!(req.url.contains("openai.com"));
        let b = body(&req);
        assert_eq!(b["model"], "gpt-4o");
        assert_eq!(b["messages"][0]["role"], "system");
        assert_eq!(b["messages"][1]["content"], "user");
        assert_eq!(b["max_tokens"], 50);
        assert!(
            req.headers
                .contains(&("Authorization".into(), "Bearer k".into()))
        );
    }

    #[test]
    fn anthropic_request() {
        let req = build_request(
            &LLMRequest::new("sys", "user", 20),
            &config(LLMProviderType::Anthropic, "ak"),
        )
        .unwrap();
        let b = body(&req);
        assert_eq!(b["system"], "sys");
        assert_eq!(b["messages"].as_array().unwrap().len(), 1);
        assert!(
            req.headers
                .contains(&("anthropic-version".into(), "2023-06-01".into()))
        );
        assert!(req.headers.contains(&("x-api-key".into(), "ak".into())));
    }

    #[test]
    fn ollama_request_does_not_stream() {
        let req = build_request(
            &LLMRequest::new("s", "u", 20),
            &config(LLMProviderType::Ollama, ""),
        )
        .unwrap();
        let b = body(&req);
        assert_eq!(b["stream"], false);
        assert!(b.get("max_tokens").is_none());
    }

    #[test]
    fn invalid_config_and_endpoint() {
        assert_eq!(
            build_request(
                &LLMRequest::new("s", "u", 5),
                &config(LLMProviderType::Openai, "")
            ),
            Err(LLMClientError::InvalidConfig)
        );
        let cfg = LLMProviderConfig::new(LLMProviderType::Ollama, "", Some("not a url"), None, 5);
        assert_eq!(
            build_request(&LLMRequest::new("s", "u", 5), &cfg),
            Err(LLMClientError::InvalidEndpoint("not a url".into()))
        );
    }

    #[test]
    fn parse_responses() {
        let openai = config(LLMProviderType::Openai, "k");
        let r = parse_response(
            200,
            br#"{"choices":[{"message":{"content":"hi"}}],"usage":{"total_tokens":12}}"#,
            &openai,
        )
        .unwrap();
        assert_eq!((r.content.as_str(), r.tokens_used), ("hi", Some(12)));

        let anthropic = config(LLMProviderType::Anthropic, "k");
        let r = parse_response(
            200,
            br#"{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":3,"output_tokens":4}}"#,
            &anthropic,
        )
        .unwrap();
        assert_eq!((r.content.as_str(), r.tokens_used), ("ok", Some(7)));

        let ollama = config(LLMProviderType::Ollama, "");
        let r = parse_response(
            200,
            br#"{"message":{"content":"yo"},"eval_count":9}"#,
            &ollama,
        )
        .unwrap();
        assert_eq!((r.content.as_str(), r.tokens_used), ("yo", Some(9)));
        assert_eq!(r.model, "llama3.2");
    }

    #[test]
    fn parse_errors() {
        let openai = config(LLMProviderType::Openai, "k");
        let err = parse_response(401, b"denied", &openai).unwrap_err();
        assert_eq!(err.to_string(), "HTTP 401: denied");
        assert_eq!(
            parse_response(200, b"{}", &openai),
            Err(LLMClientError::ParseFailed)
        );
        assert_eq!(
            parse_response(200, b"[1]", &openai),
            Err(LLMClientError::ParseFailed)
        );
    }

    #[test]
    fn test_connection_texts() {
        let ok = Ok(LLMResponse::new("OK", None, "gpt-4o"));
        assert_eq!(test_connection_result(&ok), "OK: gpt-4o");
        let err = Err(LLMClientError::InvalidConfig);
        assert_eq!(
            test_connection_result(&err),
            "Error: LLM provider is not configured correctly"
        );
        assert_eq!(test_connection_request().max_tokens, 10);
    }
}
