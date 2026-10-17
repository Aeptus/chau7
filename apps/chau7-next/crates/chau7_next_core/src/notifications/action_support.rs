//! The pure parts of `Notifications/NotificationActionExecutor.swift`:
//! template interpolation, the event as JSON and environment variables, the
//! lines written by "Write to file" and "Log time", the command lines of the
//! Docker, docker-compose, kubectl and git actions, Slack and Discord
//! payloads, browser bundle ids, the execution report and the timers of the
//! time tracking actions.

use std::collections::HashMap;
use std::time::Instant;

use serde_json::{Map, Value, json};

use super::actions::NotificationActionType;
use crate::ai::event::AiEvent;

/// Swift `UUID.uuidString`.
fn uuid_string(event: &AiEvent) -> String {
    event.id.hyphenated().to_string().to_uppercase()
}

/// `ActionContext.interpolate`: an empty or missing template gives the
/// message; `${message}`, `${type}`, `${tool}`, `${source}`, `${timestamp}`
/// and `${id}` are replaced.
pub fn interpolate(template: Option<&str>, event: &AiEvent) -> String {
    let Some(template) = template.filter(|t| !t.is_empty()) else {
        return event.message.clone();
    };
    template
        .replace("${message}", &event.message)
        .replace("${type}", &event.event_type)
        .replace("${tool}", &event.tool)
        .replace("${source}", event.source.raw_value())
        .replace("${timestamp}", &event.ts)
        .replace("${id}", &uuid_string(event))
}

/// `ActionContext.eventJSON`.
pub fn event_json(event: &AiEvent) -> Value {
    json!({
        "id": uuid_string(event),
        "source": event.source.raw_value(),
        "type": event.event_type,
        "tool": event.tool,
        "message": event.message,
        "timestamp": event.ts,
    })
}

/// `ActionContext.environmentVariables` (for "Run script").
pub fn environment_variables(event: &AiEvent) -> Vec<(&'static str, String)> {
    vec![
        ("CHAU7_EVENT_ID", uuid_string(event)),
        ("CHAU7_SOURCE", event.source.raw_value().to_string()),
        ("CHAU7_TYPE", event.event_type.clone()),
        ("CHAU7_TOOL", event.tool.clone()),
        ("CHAU7_MESSAGE", event.message.clone()),
        ("CHAU7_TIMESTAMP", event.ts.clone()),
    ]
}

/// `RuntimeIsolation.expandTilde(in:)`.
pub fn expand_tilde(path: &str, home: &str) -> String {
    if path == "~" {
        return home.to_string();
    }
    match path.strip_prefix("~/") {
        Some(rest) => format!("{}/{rest}", home.trim_end_matches('/')),
        None => path.to_string(),
    }
}

fn csv_field(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

/// The line "Write to file" appends (`format`: `json`, `csv`, else text).
pub fn write_to_file_line(format: &str, template: Option<&str>, event: &AiEvent) -> String {
    match format {
        "json" => event_json(event).to_string(),
        "csv" => [
            event.ts.as_str(),
            event.source.raw_value(),
            event.event_type.as_str(),
            event.tool.as_str(),
            event.message.as_str(),
        ]
        .iter()
        .map(|f| csv_field(f))
        .collect::<Vec<_>>()
        .join(","),
        _ => match template.filter(|t| !t.is_empty()) {
            Some(t) => interpolate(Some(t), event),
            None => format!("[{}] {}: {}", event.ts, event.event_type, event.message),
        },
    }
}

/// Header written once when "Log time" creates its CSV file.
pub const LOG_TIME_HEADER: &str = "timestamp,description\n";

/// One "Log time" CSV row (without the newline).
pub fn log_time_entry(event: &AiEvent, description: &str) -> String {
    format!("{},{}", event.ts, csv_field(description))
}

/// Foundation `String.capitalized` for the simple cases used here: each
/// space-separated word gets an upper-case first letter, the rest lower case.
pub fn capitalized(value: &str) -> String {
    value
        .split(' ')
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => first
                    .to_uppercase()
                    .chain(chars.flat_map(char::to_lowercase))
                    .collect(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Slack incoming webhook payload.
pub fn slack_payload(
    event: &AiEvent,
    username: Option<&str>,
    emoji: Option<&str>,
    channel: Option<&str>,
) -> Value {
    let mut payload = Map::new();
    payload.insert("username".into(), username.unwrap_or("Chau7").into());
    payload.insert("icon_emoji".into(), emoji.unwrap_or(":computer:").into());
    let text = format!("*{}*: {}", capitalized(&event.event_type), event.message);
    payload.insert("text".into(), interpolate(Some(&text), event).into());
    if let Some(channel) = channel.filter(|c| !c.is_empty()) {
        payload.insert("channel".into(), channel.into());
    }
    Value::Object(payload)
}

/// Discord webhook payload.
pub fn discord_payload(event: &AiEvent, username: Option<&str>, avatar: Option<&str>) -> Value {
    let mut payload = Map::new();
    payload.insert("username".into(), username.unwrap_or("Chau7").into());
    let text = format!("**{}**: {}", capitalized(&event.event_type), event.message);
    payload.insert("content".into(), interpolate(Some(&text), event).into());
    if let Some(avatar) = avatar.filter(|a| !a.is_empty()) {
        payload.insert("avatar_url".into(), avatar.into());
    }
    Value::Object(payload)
}

/// Webhook body: the custom payload when it is a JSON object, else the event.
pub fn webhook_payload(custom: Option<&str>, event: &AiEvent) -> Value {
    custom
        .filter(|c| !c.is_empty())
        .and_then(|c| serde_json::from_str::<Value>(c).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| event_json(event))
}

/// Custom webhook headers: a JSON object of strings, else none.
pub fn webhook_headers(raw: Option<&str>) -> Vec<(String, String)> {
    let Some(Value::Object(map)) = raw.and_then(|r| serde_json::from_str::<Value>(r).ok()) else {
        return Vec::new();
    };
    // Swift casts to `[String: String]`: any non-string value drops them all.
    let mut out = Vec::new();
    for (k, v) in map {
        match v {
            Value::String(s) => out.push((k, s)),
            _ => return Vec::new(),
        }
    }
    out
}

/// Arguments curl runs with; the request itself comes from
/// [`curl_config`] on stdin, so URLs (Slack and Discord webhook URLs carry a
/// secret) and headers never show in `ps`.
pub const CURL_STDIN_ARGS: [&str; 3] = ["-sS", "-K", "-"];

/// A curl config value in double quotes (`\`, `"`, newlines escaped).
pub fn curl_quote(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// curl config (read with `curl -K -`) for an HTTP request with a JSON body
/// (`None` for GET). Chau7 Next has no HTTP stack of its own; `curl` sends
/// the webhook, Slack and Discord requests like `URLSession` did. Prints only
/// the HTTP status.
pub fn curl_config(
    url: &str,
    method: &str,
    headers: &[(String, String)],
    body: Option<&str>,
) -> String {
    let mut config = String::new();
    config.push_str(&format!("url = {}\n", curl_quote(url)));
    config.push_str(&format!("request = {}\n", curl_quote(method)));
    config.push_str("output = \"/dev/null\"\n");
    config.push_str("write-out = \"%{http_code}\"\n");
    config.push_str("header = \"Content-Type: application/json\"\n");
    config.push_str("header = \"User-Agent: Chau7/1.0\"\n");
    for (k, v) in headers {
        config.push_str(&format!("header = {}\n", curl_quote(&format!("{k}: {v}"))));
    }
    if let Some(body) = body {
        config.push_str(&format!("data-binary = {}\n", curl_quote(body)));
    }
    config
}

/// A URL Foundation's `URL(string:)` would accept for the webhook actions:
/// a scheme followed by `:` and no spaces.
pub fn is_valid_url(url: &str) -> bool {
    let Some((scheme, rest)) = url.split_once(':') else {
        return false;
    };
    !scheme.is_empty()
        && scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
        && scheme
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic())
        && !rest.is_empty()
        && !url.contains(char::is_whitespace)
}

/// Docker steps for "Docker bump" (`operation`: restart, stop, start,
/// rebuild).
pub fn docker_bump_steps(operation: &str, container: &str) -> Result<Vec<Vec<String>>, String> {
    let c = container.to_string();
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    Ok(match operation {
        "restart" => vec![vec!["restart".into(), c]],
        "stop" => vec![vec!["stop".into(), c]],
        "start" => vec![vec!["start".into(), c]],
        "rebuild" => vec![
            vec!["stop".into(), c.clone()],
            vec!["rm".into(), c.clone()],
            [s(&["build", "-t"]), vec![c.clone(), ".".into()]].concat(),
            [s(&["run", "-d", "--name"]), vec![c.clone(), c]].concat(),
        ],
        other => return Err(format!("dockerBump unknown operation: {other}")),
    })
}

/// docker-compose arguments (`operation`: up, down, restart, build, pull).
pub fn docker_compose_arguments(
    compose_path: &str,
    operation: &str,
    services: &str,
) -> Result<Vec<String>, String> {
    let services: Vec<String> = if services.is_empty() {
        Vec::new()
    } else {
        services.split(',').map(|s| s.trim().to_string()).collect()
    };
    let mut args = vec!["-f".to_string(), compose_path.to_string()];
    match operation {
        "up" => args.extend(["up".into(), "-d".into()]),
        "down" | "restart" | "build" | "pull" => args.push(operation.into()),
        other => return Err(format!("dockerCompose unknown operation: {other}")),
    }
    args.extend(services);
    Ok(args)
}

/// kubectl arguments (`operation`: restart, scale, status).
pub fn kubectl_arguments(
    deployment: &str,
    namespace: &str,
    context: Option<&str>,
    operation: &str,
    replicas: Option<&str>,
) -> Result<Vec<String>, String> {
    let mut args = Vec::new();
    if let Some(ctx) = context.filter(|c| !c.is_empty()) {
        args.extend(["--context".to_string(), ctx.to_string()]);
    }
    args.extend(["-n".to_string(), namespace.to_string()]);
    let target = format!("deployment/{deployment}");
    match operation {
        "restart" => args.extend(["rollout".into(), "restart".into(), target]),
        "scale" => args.extend([
            "scale".into(),
            target,
            format!("--replicas={}", replicas.unwrap_or("1")),
        ]),
        "status" => args.extend(["rollout".into(), "status".into(), target]),
        other => return Err(format!("kubernetesRollout unknown operation: {other}")),
    }
    Ok(args)
}

/// Bundle id for the "Open URL" browser choice; `None` for the default
/// browser.
pub fn browser_bundle_id(browser: &str) -> Option<&str> {
    Some(match browser {
        "default" => return None,
        "safari" => "com.apple.Safari",
        "chrome" => "com.google.Chrome",
        "firefox" => "org.mozilla.firefox",
        "arc" => "company.thebrowser.Browser",
        other => other,
    })
}

/// `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`.
pub fn percent_encode_query_allowed(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        let allowed = b.is_ascii_alphanumeric()
            || matches!(
                b,
                b'!' | b'$'
                    | b'&'
                    | b'\''
                    | b'('
                    | b')'
                    | b'*'
                    | b'+'
                    | b','
                    | b'-'
                    | b'.'
                    | b'/'
                    | b':'
                    | b';'
                    | b'='
                    | b'?'
                    | b'@'
                    | b'_'
                    | b'~'
            );
        if allowed {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// What a batch of actions did (`NotificationActionExecutor.ExecutionReport`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExecutionReport {
    /// Raw values of the actions that ran.
    pub successful_actions: Vec<String>,
    pub notes: Vec<String>,
    pub did_dispatch_banner: bool,
    pub did_style_tab: bool,
}

impl ExecutionReport {
    pub fn success(action_type: NotificationActionType) -> Self {
        let mut r = Self::default();
        r.record_success(action_type);
        r
    }

    pub fn failure(note: impl Into<String>) -> Self {
        let mut r = Self::default();
        r.record_failure(note);
        r
    }

    pub fn record_success(&mut self, action_type: NotificationActionType) {
        self.successful_actions
            .push(action_type.raw_value().to_string());
        self.did_dispatch_banner |= action_type == NotificationActionType::ShowNotification;
        self.did_style_tab |= action_type == NotificationActionType::StyleTab;
    }

    pub fn record_failure(&mut self, note: impl Into<String>) {
        self.notes.push(note.into());
    }

    pub fn append(&mut self, other: ExecutionReport) {
        self.successful_actions.extend(other.successful_actions);
        self.notes.extend(other.notes);
        self.did_dispatch_banner |= other.did_dispatch_banner;
        self.did_style_tab |= other.did_style_tab;
    }
}

/// Running timers of the "Start timer" and "Stop timer" actions.
#[derive(Debug, Default)]
pub struct TimeTracker {
    /// Name to start, in start order (Swift picks an arbitrary one when no
    /// name is given; the oldest is used here).
    timers: Vec<(String, Instant)>,
}

impl TimeTracker {
    pub fn start(&mut self, name: &str, now: Instant) {
        self.timers.retain(|(n, _)| n != name);
        self.timers.push((name.to_string(), now));
    }

    /// Stops the named timer, or any when `name` is empty. Returns the name
    /// and elapsed seconds.
    pub fn stop(&mut self, name: Option<&str>, now: Instant) -> Option<(String, f64)> {
        let index = match name.filter(|n| !n.is_empty()) {
            Some(n) => self.timers.iter().position(|(t, _)| t == n)?,
            None => {
                if self.timers.is_empty() {
                    return None;
                }
                0
            }
        };
        let (name, start) = self.timers.remove(index);
        Some((name, now.saturating_duration_since(start).as_secs_f64()))
    }

    pub fn active(&self) -> HashMap<String, Instant> {
        self.timers.iter().cloned().collect()
    }
}

/// "Stopped 'x' after 1m 5s".
pub fn elapsed_label(seconds: f64) -> String {
    let total = seconds as i64;
    format!("{}m {}s", total / 60, total % 60)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::event::AiEventSource;
    use std::time::Duration;
    use uuid::Uuid;

    fn event() -> AiEvent {
        let mut e = AiEvent::new(
            AiEventSource::codex(),
            "waiting_input",
            "Codex",
            "Codex is \"waiting\"",
            "2026-04-01T20:00:00Z",
        );
        e.id = Uuid::parse_str("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee").unwrap();
        e
    }

    #[test]
    fn interpolation() {
        let e = event();
        assert_eq!(interpolate(None, &e), e.message);
        assert_eq!(interpolate(Some(""), &e), e.message);
        assert_eq!(
            interpolate(Some("${tool}/${type}/${source}/${timestamp}/${id}"), &e),
            "Codex/waiting_input/codex/2026-04-01T20:00:00Z/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        );
    }

    #[test]
    fn event_json_and_environment() {
        let e = event();
        let json = event_json(&e);
        assert_eq!(json["type"], "waiting_input");
        assert_eq!(json["timestamp"], "2026-04-01T20:00:00Z");
        let env = environment_variables(&e);
        assert_eq!(env.len(), 6);
        assert!(env.contains(&("CHAU7_TOOL", "Codex".to_string())));
    }

    #[test]
    fn file_lines() {
        let e = event();
        assert_eq!(
            write_to_file_line("csv", None, &e),
            r#""2026-04-01T20:00:00Z","codex","waiting_input","Codex","Codex is ""waiting""""#
        );
        assert_eq!(
            write_to_file_line("text", None, &e),
            "[2026-04-01T20:00:00Z] waiting_input: Codex is \"waiting\""
        );
        assert_eq!(write_to_file_line("text", Some("${tool}!"), &e), "Codex!");
        assert!(write_to_file_line("json", None, &e).starts_with('{'));
        assert_eq!(
            log_time_entry(&e, "a \"b\""),
            "2026-04-01T20:00:00Z,\"a \"\"b\"\"\""
        );
    }

    #[test]
    fn tilde_expansion() {
        assert_eq!(expand_tilde("~/x/y", "/Users/me"), "/Users/me/x/y");
        assert_eq!(expand_tilde("~", "/Users/me"), "/Users/me");
        assert_eq!(expand_tilde("/abs", "/Users/me"), "/abs");
    }

    #[test]
    fn payloads() {
        let e = event();
        let slack = slack_payload(&e, None, None, Some("#dev"));
        assert_eq!(slack["text"], "*Waiting_input*: Codex is \"waiting\"");
        assert_eq!(slack["username"], "Chau7");
        assert_eq!(slack["icon_emoji"], ":computer:");
        assert_eq!(slack["channel"], "#dev");
        assert!(
            slack_payload(&e, None, None, Some(""))
                .get("channel")
                .is_none()
        );
        let discord = discord_payload(&e, Some("Bot"), Some("https://a/b.png"));
        assert_eq!(
            discord["content"],
            "**Waiting_input**: Codex is \"waiting\""
        );
        assert_eq!(discord["avatar_url"], "https://a/b.png");
        assert_eq!(webhook_payload(Some(r#"{"a":1}"#), &e)["a"], 1);
        assert_eq!(webhook_payload(Some("[1]"), &e)["tool"], "Codex");
        assert_eq!(
            webhook_headers(Some(r#"{"X-A":"1"}"#)),
            vec![("X-A".to_string(), "1".to_string())]
        );
        assert!(webhook_headers(Some(r#"{"X-A":1}"#)).is_empty());
        assert!(webhook_headers(None).is_empty());
        assert_eq!(capitalized("hello wORLD"), "Hello World");
    }

    #[test]
    fn curl_and_urls() {
        let config = curl_config(
            "https://hooks.slack.com/services/SECRET",
            "POST",
            &[("Authorization".into(), "Bearer \"t\"\nx".into())],
            Some("{\"a\":\"b\\\\c\"}"),
        );
        assert!(config.contains("url = \"https://hooks.slack.com/services/SECRET\"\n"));
        assert!(config.contains("header = \"Authorization: Bearer \\\"t\\\"\\nx\"\n"));
        assert!(config.contains(r#"data-binary = "{\"a\":\"b\\\\c\"}""#));
        assert!(config.contains("request = \"POST\"\n"));
        // Nothing secret goes on the command line.
        assert_eq!(CURL_STDIN_ARGS, ["-sS", "-K", "-"]);
        assert!(!curl_config("u:x", "GET", &[], None).contains("data-binary"));
        assert!(is_valid_url("https://hooks.slack.com/x"));
        assert!(!is_valid_url("not a url"));
        assert!(!is_valid_url(""));
        assert_eq!(percent_encode_query_allowed("a b?c=é"), "a%20b?c=%C3%A9");
        assert_eq!(browser_bundle_id("default"), None);
        assert_eq!(browser_bundle_id("arc"), Some("company.thebrowser.Browser"));
        assert_eq!(browser_bundle_id("com.x"), Some("com.x"));
    }

    #[test]
    fn devops_commands() {
        assert_eq!(
            docker_bump_steps("restart", "web").unwrap(),
            [["restart", "web"]]
        );
        let rebuild = docker_bump_steps("rebuild", "web").unwrap();
        assert_eq!(rebuild.len(), 4);
        assert_eq!(rebuild[2], ["build", "-t", "web", "."]);
        assert_eq!(rebuild[3], ["run", "-d", "--name", "web", "web"]);
        assert!(docker_bump_steps("nope", "web").is_err());
        assert_eq!(
            docker_compose_arguments("/a.yml", "up", "web, db").unwrap(),
            ["-f", "/a.yml", "up", "-d", "web", "db"]
        );
        assert_eq!(
            docker_compose_arguments("/a.yml", "pull", "").unwrap(),
            ["-f", "/a.yml", "pull"]
        );
        assert!(docker_compose_arguments("/a.yml", "x", "").is_err());
        assert_eq!(
            kubectl_arguments("api", "prod", Some("ctx"), "scale", Some("3")).unwrap(),
            [
                "--context",
                "ctx",
                "-n",
                "prod",
                "scale",
                "deployment/api",
                "--replicas=3"
            ]
        );
        assert_eq!(
            kubectl_arguments("api", "default", None, "restart", None).unwrap(),
            ["-n", "default", "rollout", "restart", "deployment/api"]
        );
        assert!(kubectl_arguments("api", "default", None, "x", None).is_err());
    }

    #[test]
    fn report_and_timers() {
        let mut report = ExecutionReport::success(NotificationActionType::ShowNotification);
        report.append(ExecutionReport::success(NotificationActionType::StyleTab));
        report.append(ExecutionReport::failure("x"));
        assert_eq!(
            report.successful_actions,
            ["show_notification", "style_tab"]
        );
        assert!(report.did_dispatch_banner && report.did_style_tab);
        assert_eq!(report.notes, ["x"]);

        let mut t = TimeTracker::default();
        let t0 = Instant::now();
        assert_eq!(t.stop(None, t0), None);
        t.start("a", t0);
        t.start("b", t0);
        assert_eq!(t.active().len(), 2);
        let (name, secs) = t.stop(Some("b"), t0 + Duration::from_secs(65)).unwrap();
        assert_eq!(name, "b");
        assert_eq!(elapsed_label(secs), "1m 5s");
        assert_eq!(t.stop(Some("zz"), t0), None);
        assert_eq!(t.stop(None, t0).unwrap().0, "a");
    }
}
