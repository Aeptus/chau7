//! LLM providers for "bring your own AI" (`AI/LLMClient.swift`,
//! `LLMSettingsView.swift`): API keys in the Keychain and the HTTP call.
//!
//! Keys are stored per provider with `platform::secrets` (service
//! `com.chau7.next.llm.<provider>.apikey`, account `apikey`), never in the
//! settings file. Swift uses `com.chau7.llm.<provider>.apikey`; the two
//! apps keep separate items (DUAL-SHIP.md).
//!
//! The request is sent with `curl` (present on macOS, Linux and Windows 10
//! and later): the request is given on curl's standard input as a config
//! file, so the API key never shows in the process list. 30 s timeout.

use std::io::Write;
use std::process::{Command, Stdio};

use chau7_next_core::ai::llm_client::{
    HttpRequest, LLMClientError, TIMEOUT_SECS, build_request, parse_response,
};
use chau7_next_core::llm_provider::{LLMProviderConfig, LLMProviderType, LLMRequest, LLMResponse};

use crate::platform::secrets;

/// Keychain account of the API keys.
const ACCOUNT: &str = "apikey";

/// Short Keychain service of a provider's key (`keychainService`).
fn service(provider: LLMProviderType) -> String {
    format!("llm.{}.apikey", provider.raw_value())
}

/// The saved API key of a provider ("" when none).
pub fn api_key(provider: LLMProviderType) -> String {
    match secrets::current().get(&service(provider), ACCOUNT) {
        Ok(key) => key.unwrap_or_default(),
        Err(err) => {
            log::warn!("LLM key for {}: {err}", provider.display_name());
            String::new()
        }
    }
}

/// Saves (or, when empty, removes) a provider's API key.
pub fn save_api_key(provider: LLMProviderType, key: &str) -> Result<(), String> {
    let store = secrets::current();
    let result = if key.is_empty() {
        store.delete(&service(provider), ACCOUNT)
    } else {
        store.set(&service(provider), ACCOUNT, key)
    };
    result.map_err(|e| e.to_string())
}

/// A string for a curl config file: quoted, with `\` and `"` escaped.
fn curl_quote(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// The curl config for a request (read from stdin with `-K -`).
fn curl_config(request: &HttpRequest) -> String {
    let mut config = String::new();
    config.push_str(&format!("url = {}\n", curl_quote(&request.url)));
    config.push_str("request = \"POST\"\n");
    for (name, value) in &request.headers {
        config.push_str(&format!(
            "header = {}\n",
            curl_quote(&format!("{name}: {value}"))
        ));
    }
    config.push_str(&format!("data-binary = {}\n", curl_quote(&request.body)));
    config.push_str("write-out = \"\\n%{http_code}\"\n");
    config
}

/// Splits curl's output into (body, HTTP status).
fn split_status(output: &[u8]) -> Option<(&[u8], u16)> {
    let cut = output.iter().rposition(|b| *b == b'\n')?;
    let status = std::str::from_utf8(&output[cut + 1..])
        .ok()?
        .trim()
        .parse()
        .ok()?;
    Some((&output[..cut], status))
}

/// Sends a request (`LLMClient.send`). Blocking: call it off the main thread.
pub fn send(
    request: &LLMRequest,
    config: &LLMProviderConfig,
) -> Result<LLMResponse, LLMClientError> {
    let http = build_request(request, config)?;
    log::info!(
        "LLMClient: sending request to {} ({})",
        config.provider.display_name(),
        config.model
    );
    let mut child = Command::new("curl")
        .args(["-sS", "--max-time", &TIMEOUT_SECS.to_string(), "-K", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| LLMClientError::Transport(format!("Could not run curl: {e}")))?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(curl_config(&http).as_bytes());
    }
    let output = child
        .wait_with_output()
        .map_err(|e| LLMClientError::Transport(e.to_string()))?;
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(LLMClientError::Transport(if message.is_empty() {
            "The request failed".to_string()
        } else {
            message
        }));
    }
    let (body, status) = split_status(&output.stdout).ok_or(LLMClientError::InvalidResponse)?;
    let result = parse_response(status, body, config);
    if let Ok(response) = &result {
        log::info!(
            "LLMClient: response from {} ({} tokens)",
            config.provider.display_name(),
            response.tokens_used.unwrap_or(0)
        );
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_escapes_quotes_and_backslashes() {
        let request = HttpRequest {
            url: "https://x.test/v1".into(),
            headers: vec![("Authorization".into(), "Bearer k\"1".into())],
            body: r#"{"a":"line\nnext \"q\""}"#.into(),
        };
        let config = curl_config(&request);
        assert!(config.contains("url = \"https://x.test/v1\"\n"));
        assert!(config.contains("header = \"Authorization: Bearer k\\\"1\"\n"));
        assert!(config.contains(r#"data-binary = "{\"a\":\"line\\nnext \\\"q\\\"\"}""#));
        assert!(config.ends_with("write-out = \"\\n%{http_code}\"\n"));
    }

    #[test]
    fn status_is_the_last_line() {
        assert_eq!(
            split_status(b"{\"ok\":1}\n200"),
            Some((&b"{\"ok\":1}"[..], 200))
        );
        assert_eq!(split_status(b"no status"), None);
    }

    #[test]
    fn services_are_per_provider() {
        assert_eq!(service(LLMProviderType::Anthropic), "llm.anthropic.apikey");
        assert_eq!(
            secrets::service_name(&service(LLMProviderType::Openai)),
            "com.chau7.next.llm.openai.apikey"
        );
    }
}
