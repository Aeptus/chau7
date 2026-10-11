//! Port of `apps/chau7-macos/Sources/Chau7Core/CommandDetection.swift`.
//!
//! Contains both halves of the Swift file:
//! - [`CommandDetection`]-style free functions: AI CLI and dev server
//!   detection from command lines and terminal output, shell-like
//!   tokenization, and a best-effort "is this command executable" check.
//! - [`event_parsing`]: parsing of Claude Code hook event JSON payloads.
//!
//! The AI tool table [`AI_TOOLS`] mirrors `AIToolRegistry.allTools`
//! (`AIToolRegistry.swift`); the registry queries live in `ai::tool_registry`.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::LazyLock;

// MARK: - AI tool table (from AIToolRegistry.allTools)

/// Detection metadata for one AI coding tool, mirroring the subset of
/// `AIToolDefinition` used by command and output detection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AiToolEntry {
    /// Canonical display name, e.g. "Claude".
    pub display_name: &'static str,
    /// CLI command names (lowercased) that map to this tool.
    pub command_names: &'static [&'static str],
    /// Terminal output patterns (already lowercased).
    pub output_patterns: &'static [&'static str],
    /// How to build a resume command, `None` for tools without resume support.
    pub resume_format: Option<ResumeFormat>,
    /// Provider key for session resume and persistence (for example "claude").
    pub resume_provider_key: Option<&'static str>,
    /// Bundled logo asset name without extension (for example "claude-logo").
    pub logo_asset_name: Option<&'static str>,
    /// Tab color name for auto-theming.
    pub tab_color_name: Option<&'static str>,
    /// `AIEventSource` raw value for tools that emit history or notification events.
    pub event_source_raw_value: Option<&'static str>,
}

/// How to construct a resume command for a tool
/// (`AIToolDefinition.ResumeFormat`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResumeFormat {
    /// `claude --resume <sessionId>`
    DashFlag {
        command: &'static str,
        flag: &'static str,
    },
    /// `codex resume <sessionId>`
    Subcommand {
        command: &'static str,
        subcommand: &'static str,
    },
}

impl ResumeFormat {
    /// Builds the shell command that resumes `session_id`.
    pub fn build_command(&self, session_id: &str) -> String {
        match self {
            ResumeFormat::DashFlag { command, flag } => format!("{command} {flag} {session_id}"),
            ResumeFormat::Subcommand {
                command,
                subcommand,
            } => format!("{command} {subcommand} {session_id}"),
        }
    }
}

/// All known AI tools, in registry order (order matters for output detection).
pub const AI_TOOLS: &[AiToolEntry] = &[
    AiToolEntry {
        display_name: "Claude",
        command_names: &[
            "claude",
            "claude-code",
            "claude-cli",
            "claude-pty",
            "claude-wrapper",
        ],
        output_patterns: &[
            "╭─ claude",
            "╰─ claude",
            "powered by anthropic",
            "claude.ai/",
            "claude.ai",
            "claude code",
            "anthropic's claude",
        ],
        resume_format: Some(ResumeFormat::DashFlag {
            command: "claude",
            flag: "--resume",
        }),
        resume_provider_key: Some("claude"),
        logo_asset_name: Some("claude-logo"),
        tab_color_name: Some("purple"),
        event_source_raw_value: Some("claude_code"),
    },
    AiToolEntry {
        display_name: "Codex",
        command_names: &["codex", "codex-cli", "codex-pty", "codex-wrapper"],
        output_patterns: &[
            "╭─ codex",
            "╰─ codex",
            "openai codex",
            "codex cli",
            "codex.openai",
        ],
        resume_format: Some(ResumeFormat::Subcommand {
            command: "codex",
            subcommand: "resume",
        }),
        resume_provider_key: Some("codex"),
        logo_asset_name: Some("codex-logo"),
        tab_color_name: Some("green"),
        event_source_raw_value: Some("codex"),
    },
    AiToolEntry {
        display_name: "Gemini",
        command_names: &["gemini", "gemini-cli", "gemini-pty"],
        output_patterns: &[
            "google ai studio",
            "gemini pro",
            "gemini.google",
            "google gemini",
            "gemini cli",
        ],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: Some("gemini-logo"),
        tab_color_name: Some("blue"),
        event_source_raw_value: None,
    },
    AiToolEntry {
        display_name: "ChatGPT",
        command_names: &["chatgpt", "chatgpt-cli", "gpt", "gpt-cli", "openai"],
        output_patterns: &["chatgpt", "openai.com/", "openai.com"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: Some("chatgpt-logo"),
        tab_color_name: Some("green"),
        event_source_raw_value: None,
    },
    AiToolEntry {
        display_name: "Copilot",
        command_names: &["copilot", "copilot-cli", "github-copilot"],
        output_patterns: &["github copilot", "copilot cli", "gh copilot"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: Some("copilot-logo"),
        tab_color_name: Some("orange"),
        event_source_raw_value: Some("copilot"),
    },
    AiToolEntry {
        display_name: "Aider",
        command_names: &["aider", "aider-chat"],
        output_patterns: &["aider v", "aider is running", "aider.chat"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: Some("aider-logo"),
        tab_color_name: Some("pink"),
        event_source_raw_value: Some("aider"),
    },
    AiToolEntry {
        display_name: "Cursor",
        command_names: &["cursor"],
        output_patterns: &["cursor.sh", "cursor ide", "cursor cli", "cursor.com"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: Some("cursor-logo"),
        tab_color_name: Some("teal"),
        event_source_raw_value: Some("cursor"),
    },
    AiToolEntry {
        display_name: "Windsurf",
        command_names: &["windsurf", "windsurf-cli"],
        output_patterns: &["windsurf", "codeium", "windsurf.ai"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: None,
        tab_color_name: Some("teal"),
        event_source_raw_value: Some("windsurf"),
    },
    // Output patterns must be specific: bare "cline" matches common substrings
    // like "decline", "client", "incline" in any AI tool's output.
    AiToolEntry {
        display_name: "Cline",
        command_names: &["cline"],
        output_patterns: &["cline v", "cline cli", "cline.bot", "cline agent"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: None,
        tab_color_name: None,
        event_source_raw_value: Some("cline"),
    },
    AiToolEntry {
        display_name: "Cody",
        command_names: &["cody"],
        output_patterns: &["sourcegraph cody", "cody cli", "cody.dev"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: None,
        tab_color_name: None,
        event_source_raw_value: None,
    },
    AiToolEntry {
        display_name: "Amazon Q",
        command_names: &["amazon-q"],
        output_patterns: &["amazon q developer", "amazon q cli", "codewhisperer"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: None,
        tab_color_name: None,
        event_source_raw_value: None,
    },
    AiToolEntry {
        display_name: "Devin",
        command_names: &["devin"],
        output_patterns: &["devin cli", "devin.ai"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: None,
        tab_color_name: None,
        event_source_raw_value: None,
    },
    AiToolEntry {
        display_name: "Continue",
        command_names: &["continue"],
        output_patterns: &["continue.dev"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: None,
        tab_color_name: Some("yellow"),
        event_source_raw_value: Some("continue_ai"),
    },
    AiToolEntry {
        display_name: "Goose",
        command_names: &["goose"],
        output_patterns: &["goose v", "goose.ai", "block goose"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: None,
        tab_color_name: None,
        event_source_raw_value: None,
    },
    AiToolEntry {
        display_name: "Mentat",
        command_names: &["mentat"],
        output_patterns: &["mentat v", "mentat.ai"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: None,
        tab_color_name: None,
        event_source_raw_value: None,
    },
    AiToolEntry {
        display_name: "Amp",
        command_names: &["amp"],
        output_patterns: &["amp.dev", "amp cli"],
        resume_format: None,
        resume_provider_key: None,
        logo_asset_name: None,
        tab_color_name: None,
        event_source_raw_value: None,
    },
];

/// Command name to AI tool display name (`CommandDetection.appNameMap`).
pub static APP_NAME_MAP: LazyLock<HashMap<&'static str, &'static str>> = LazyLock::new(|| {
    let mut map = HashMap::new();
    for tool in AI_TOOLS {
        for cmd in tool.command_names {
            map.insert(*cmd, tool.display_name);
        }
    }
    map
});

/// Lowercased output patterns for AI tool detection, in registry order
/// (`CommandDetection.outputDetectionPatterns`).
pub static OUTPUT_DETECTION_PATTERNS: LazyLock<Vec<(&'static str, &'static str)>> =
    LazyLock::new(|| {
        AI_TOOLS
            .iter()
            .flat_map(|tool| {
                tool.output_patterns
                    .iter()
                    .map(move |p| (*p, tool.display_name))
            })
            .collect()
    });

/// Dev server command names and their display names (`devServerMap`).
pub const DEV_SERVER_COMMANDS: &[(&str, &str)] = &[
    // Vite
    ("vite", "Vite"),
    ("vite-node", "Vite"),
    // Next.js
    ("next", "Next.js"),
    ("next-dev", "Next.js"),
    // Nuxt
    ("nuxt", "Nuxt"),
    ("nuxi", "Nuxt"),
    // Webpack
    ("webpack", "Webpack"),
    ("webpack-dev-server", "Webpack"),
    ("webpack-cli", "Webpack"),
    // Parcel
    ("parcel", "Parcel"),
    // Turbo
    ("turbo", "Turbo"),
    ("turbopack", "Turbo"),
    // Remix
    ("remix", "Remix"),
    // Astro
    ("astro", "Astro"),
    // SvelteKit
    ("svelte-kit", "SvelteKit"),
    // Angular
    ("ng", "Angular"),
    // Vue CLI
    ("vue-cli-service", "Vue"),
    // Create React App
    ("react-scripts", "React"),
    // Gatsby
    ("gatsby", "Gatsby"),
    // Expo
    ("expo", "Expo"),
    // Electron
    ("electron", "Electron"),
    // Tauri
    ("tauri", "Tauri"),
    // Generic dev servers
    ("live-server", "Live Server"),
    ("http-server", "HTTP Server"),
    ("serve", "Serve"),
    ("nodemon", "Nodemon"),
    ("ts-node-dev", "TS Node Dev"),
    ("tsx", "TSX"),
];

/// Dev server command name map (`CommandDetection.devServerMap`).
pub static DEV_SERVER_MAP: LazyLock<HashMap<&'static str, &'static str>> =
    LazyLock::new(|| DEV_SERVER_COMMANDS.iter().copied().collect());

/// Common dev ports and their typical associations (`commonDevPorts`).
pub const COMMON_DEV_PORTS: &[(u16, &str)] = &[
    (3000, "Dev Server"), // Next.js, Create React App, many others
    (3001, "Dev Server"),
    (4000, "Dev Server"), // Phoenix, some Node apps
    (4200, "Angular"),    // Angular CLI default
    (5000, "Dev Server"), // Flask, many others
    (5173, "Vite"),       // Vite default
    (5174, "Vite"),
    (8000, "Dev Server"), // Django, many others
    (8080, "Dev Server"), // Common alternative
    (8081, "Dev Server"),
    (8888, "Dev Server"), // Jupyter, some servers
    (9000, "Dev Server"),
    (19000, "Expo"), // Expo default
    (19001, "Expo"),
    (19002, "Expo"),
];

/// Lowercased output patterns that indicate a dev server is running, checked
/// in order (`devServerOutputPatterns`).
pub const DEV_SERVER_OUTPUT_PATTERNS: &[(&str, &str)] = &[
    // Vite: the banner is "  VITE v6.x.x  ready in Nms"
    ("vite v", "Vite"),
    ("localhost:5173", "Vite"), // Vite default port
    ("localhost:5174", "Vite"), // Vite secondary port
    // Next.js
    ("ready started server on", "Next.js"),
    ("▲ next.js", "Next.js"),
    ("next.js", "Next.js"),
    // Nuxt
    ("nuxt", "Nuxt"),
    ("nitro", "Nuxt"),
    // Webpack
    ("webpack compiled", "Webpack"),
    ("｢wds｣", "Webpack"),
    ("｢wdm｣", "Webpack"),
    // Parcel
    ("server running at http://localhost:", "Parcel"),
    ("✨ built in", "Parcel"),
    // Angular
    ("angular live development server", "Angular"),
    // React (Create React App)
    ("compiled successfully!", "React"),
    ("starting the development server", "React"),
    // Remix
    ("remix app server", "Remix"),
    // Astro
    ("astro", "Astro"),
    ("🚀  astro", "Astro"),
    // SvelteKit
    ("sveltekit", "SvelteKit"),
    // Gatsby
    ("gatsby develop", "Gatsby"),
    // Expo
    ("starting metro bundler", "Expo"),
    ("metro waiting on", "Expo"),
    // Electron
    ("electron", "Electron"),
    // Nodemon
    ("[nodemon]", "Nodemon"),
    ("nodemon", "Nodemon"),
    // Generic patterns (lower priority, checked last)
    ("listening on port", "Dev Server"),
    ("server listening on", "Dev Server"),
    ("server running at", "Dev Server"),
    ("development server", "Dev Server"),
    ("dev server running", "Dev Server"),
    ("local:", "Dev Server"),
];

/// Shell wrapper commands that should be skipped (`wrapperCommands`).
pub const WRAPPER_COMMANDS: &[&str] = &["command", "builtin", "exec", "noglob", "time"];

/// Sudo options that take a value argument (`sudoOptionsWithValue`).
pub const SUDO_OPTIONS_WITH_VALUE: &[&str] = &["-u", "-g", "-h", "-p", "-a", "-c", "-t", "-r"];

static APP_NAME_KEYS: LazyLock<Vec<&'static str>> =
    LazyLock::new(|| APP_NAME_MAP.keys().copied().collect());

static DEV_SERVER_KEYS: LazyLock<HashSet<&'static str>> =
    LazyLock::new(|| DEV_SERVER_MAP.keys().copied().collect());

// MARK: - Public API

/// Shared tail of `detectApp` / `detectLaunchableApp` once the command token
/// is known.
fn detect_ai_app_from_tokens(tokens: &[String], token: &str) -> Option<String> {
    let normalized = normalize_token(token);

    // Direct match
    if let Some(name) = APP_NAME_MAP.get(normalized.as_str()) {
        return Some((*name).to_string());
    }

    // Special case: gh copilot
    if normalized == "gh" && find_subcommand(tokens, "gh", &["copilot"]).is_some() {
        return Some("Copilot".to_string());
    }

    // Special case: npx/bunx/pnpm with AI packages
    if (normalized == "npx" || normalized == "bunx" || normalized == "pnpm")
        && let Some(ai_app) = find_subcommand(tokens, &normalized, &APP_NAME_KEYS)
    {
        return APP_NAME_MAP.get(ai_app.as_str()).map(|s| (*s).to_string());
    }

    None
}

/// Detects an AI app name from a command line.
pub fn detect_app(command_line: &str) -> Option<String> {
    let tokens = tokenize(command_line);
    let token = extract_command_token(&tokens)?;
    detect_ai_app_from_tokens(&tokens, token)
}

/// Detects an AI app name from a command line only when the launcher command
/// appears executable from the provided shell context. This avoids transient
/// false positives when a user types a known AI CLI name that is not actually
/// installed.
pub fn detect_launchable_app(
    command_line: &str,
    current_directory: &str,
    search_path: Option<&str>,
) -> Option<String> {
    let tokens = tokenize(command_line);
    let token = extract_command_token(&tokens)?;
    if !command_appears_executable(token, current_directory, search_path) {
        return None;
    }
    detect_ai_app_from_tokens(&tokens, token)
}

/// Detects a dev server from a command line.
pub fn detect_dev_server(command_line: &str) -> Option<String> {
    let tokens = tokenize(command_line);
    let token = extract_command_token(&tokens)?;
    let normalized = normalize_token(token);

    // Direct match on dev server commands
    if let Some(name) = DEV_SERVER_MAP.get(normalized.as_str()) {
        return Some((*name).to_string());
    }

    // Package manager with dev/start scripts: npm run dev, pnpm dev, yarn dev, bun dev
    const PACKAGE_MANAGERS: &[&str] = &["npm", "pnpm", "yarn", "bun"];
    if PACKAGE_MANAGERS.contains(&normalized.as_str()) {
        const DEV_SCRIPTS: &[&str] = &["dev", "start", "serve", "develop", "watch"];
        // Check for "run dev", "run start", etc.
        if find_subcommand(&tokens, &normalized, &["run"]).is_some()
            && let Some(script) = find_subcommand(&tokens, "run", DEV_SCRIPTS)
        {
            return Some(script_to_server_name(&script).to_string());
        }
        // Direct: pnpm dev, yarn dev, bun dev
        if let Some(script) = find_subcommand(&tokens, &normalized, DEV_SCRIPTS) {
            return Some(script_to_server_name(&script).to_string());
        }
    }

    // npx/bunx with dev server packages
    if normalized == "npx" || normalized == "bunx" {
        let keys: Vec<&str> = DEV_SERVER_KEYS.iter().copied().collect();
        if let Some(dev_server) = find_subcommand(&tokens, &normalized, &keys) {
            return DEV_SERVER_MAP
                .get(dev_server.as_str())
                .map(|s| (*s).to_string());
        }
    }

    None
}

/// Detects a dev server from terminal output (case-insensitive). Patterns are
/// stored lowercased, so only the haystack is lowercased.
pub fn detect_dev_server_from_output(output: &str) -> Option<String> {
    let lowered = output.to_lowercase();
    DEV_SERVER_OUTPUT_PATTERNS
        .iter()
        .find(|(pattern, _)| lowered.contains(pattern))
        .map(|(_, name)| (*name).to_string())
}

/// URL prefixes from the Swift `devServerURLPatterns` regexes; each must be
/// followed by one or more digits.
const DEV_SERVER_URL_PREFIXES: &[&str] = &[
    "http://localhost:",
    "http://127.0.0.1:",
    "https://localhost:",
    "http://0.0.0.0:",
];

fn ascii_digit_run(s: &str) -> usize {
    s.bytes().take_while(u8::is_ascii_digit).count()
}

/// Extracts a URL from dev server output (e.g. "http://localhost:3000").
/// Patterns are tried in order; within one pattern the leftmost match wins.
pub fn extract_dev_server_url(output: &str) -> Option<String> {
    for prefix in DEV_SERVER_URL_PREFIXES {
        for (idx, _) in output.match_indices(prefix) {
            let after = idx + prefix.len();
            let digits = ascii_digit_run(&output[after..]);
            if digits > 0 {
                return Some(output[idx..after + digits].to_string());
            }
        }
    }
    None
}

/// Extracts a 4 or 5 digit port number that follows a `:` and is itself
/// followed by `/`, whitespace, or the end of the text
/// (Swift regex `:(\d{4,5})(?:/|\s|$)`).
pub fn extract_port(text: &str) -> Option<i64> {
    for (idx, _) in text.match_indices(':') {
        let rest = &text[idx + 1..];
        let digits = ascii_digit_run(rest);
        if !(4..=5).contains(&digits) {
            continue;
        }
        let terminated = match rest[digits..].chars().next() {
            None => true,
            Some(c) => c == '/' || c.is_whitespace(),
        };
        if terminated {
            return rest[..digits].parse().ok();
        }
    }
    None
}

/// Maps a script name to a dev server display name.
fn script_to_server_name(script: &str) -> &'static str {
    match script.to_lowercase().as_str() {
        "watch" => "Watch Mode",
        // "dev", "develop", "start", "serve" and anything else
        _ => "Dev Server",
    }
}

/// Extracts the command token from a raw command line.
pub fn command_token(command_line: &str) -> Option<String> {
    let tokens = tokenize(command_line);
    command_token_index(&tokens).map(|i| tokens[i].clone())
}

/// Returns the index of the command token inside tokenized input, skipping
/// environment assignments, `env`, `sudo`, shell wrappers and leading options.
pub fn command_token_index(tokens: &[String]) -> Option<usize> {
    let mut index = 0;
    while index < tokens.len() {
        let token = &tokens[index];
        if token.is_empty() {
            index += 1;
            continue;
        }

        if is_env_assignment(token) {
            index += 1;
            continue;
        }

        let lower = token.to_lowercase();
        if lower == "env" {
            index = consume_env(tokens, index + 1);
            continue;
        }

        if lower == "sudo" {
            index = consume_sudo(tokens, index + 1);
            continue;
        }

        if WRAPPER_COMMANDS.contains(&lower.as_str()) {
            // "command -v foo" and "command -V" are existence queries, not
            // execution. "command -p foo" DOES execute foo (using the default
            // PATH), so -p is treated as a normal wrapper flag and skipped.
            if lower == "command"
                && let Some(next) = tokens.get(index + 1)
                && next.to_lowercase() == "-v"
            {
                return None;
            }
            index += 1;
            continue;
        }

        if lower.starts_with('-') {
            index += 1;
            continue;
        }

        return Some(index);
    }
    None
}

/// Detects an AI app from terminal output (case-insensitive). Patterns are
/// stored lowercased, so only the haystack is lowercased.
pub fn detect_app_from_output(output: &str) -> Option<String> {
    let lowered = output.to_lowercase();
    OUTPUT_DETECTION_PATTERNS
        .iter()
        .find(|(pattern, _)| lowered.contains(pattern))
        .map(|(_, name)| (*name).to_string())
}

// MARK: - Tokenization

/// Tokenizes a command line respecting quotes and escapes. Stops at the first
/// unquoted `#`, `|`, `;` or `&`.
pub fn tokenize(line: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut in_single_quote = false;
    let mut in_double_quote = false;
    let mut is_escaped = false;

    fn flush(tokens: &mut Vec<String>, current: &mut String) {
        if !current.is_empty() {
            tokens.push(std::mem::take(current));
        }
    }

    for ch in line.chars() {
        if is_escaped {
            current.push(ch);
            is_escaped = false;
            continue;
        }

        if ch == '\\' && !in_single_quote {
            is_escaped = true;
            continue;
        }

        if ch == '\'' && !in_double_quote {
            in_single_quote = !in_single_quote;
            continue;
        }

        if ch == '"' && !in_single_quote {
            in_double_quote = !in_double_quote;
            continue;
        }

        if !in_single_quote && !in_double_quote {
            if matches!(ch, '#' | '|' | ';' | '&') {
                break;
            }
            if ch.is_whitespace() {
                flush(&mut tokens, &mut current);
                continue;
            }
        }

        current.push(ch);
    }

    flush(&mut tokens, &mut current);
    tokens
}

/// Normalizes a command token to a lookup key: trims whitespace, keeps the
/// last path component, drops its extension and lowercases it.
pub fn normalize_token(token: &str) -> String {
    let trimmed = token.trim();
    let component = paths::last_path_component(trimmed);
    paths::deleting_path_extension(&component).to_lowercase()
}

/// Checks if a token is an environment variable assignment (`NAME=value`).
pub fn is_env_assignment(token: &str) -> bool {
    let Some(eq) = token.find('=') else {
        return false;
    };
    let mut name = token[..eq].chars();
    match name.next() {
        Some(first) if first == '_' || first.is_alphabetic() => {}
        _ => return false,
    }
    name.all(|ch| ch == '_' || ch.is_alphabetic() || ch.is_numeric())
}

/// Best-effort check that a command token can be executed by the shell using
/// the provided current directory and PATH (`searchPath`, falling back to the
/// process `PATH` when `None` or empty).
pub fn command_appears_executable(
    token: &str,
    current_directory: &str,
    search_path: Option<&str>,
) -> bool {
    let trimmed = token.trim();
    if trimmed.is_empty() {
        return false;
    }

    if trimmed.contains('/') || trimmed.starts_with('~') {
        return match paths::resolve_command_path(trimmed, current_directory) {
            Some(resolved) => paths::is_executable_file(&resolved),
            None => false,
        };
    }

    paths::path_directories(search_path, current_directory)
        .iter()
        .any(|dir| paths::is_executable_file(&paths::append_component(dir, trimmed)))
}

// MARK: - Internal helpers

fn extract_command_token(tokens: &[String]) -> Option<&str> {
    command_token_index(tokens).map(|i| tokens[i].as_str())
}

fn consume_env(tokens: &[String], start: usize) -> usize {
    let mut index = start;
    while index < tokens.len() {
        let token = &tokens[index];
        if token == "--" {
            return index + 1;
        }
        if token.starts_with('-') || is_env_assignment(token) {
            index += 1;
            continue;
        }
        break;
    }
    index
}

fn consume_sudo(tokens: &[String], start: usize) -> usize {
    let mut index = start;
    while index < tokens.len() {
        let token = &tokens[index];
        if token == "--" {
            return index + 1;
        }
        if token.starts_with('-') {
            if SUDO_OPTIONS_WITH_VALUE.contains(&token.as_str()) && index + 1 < tokens.len() {
                index += 2;
                continue;
            }
            index += 1;
            continue;
        }
        break;
    }
    index
}

/// Finds the first token whose normalized form is `command`, then returns the
/// first following non-option token if its normalized form is in `targets`.
fn find_subcommand(tokens: &[String], command: &str, targets: &[&str]) -> Option<String> {
    let cmd_index = tokens.iter().position(|t| normalize_token(t) == command)?;
    for token in &tokens[cmd_index + 1..] {
        if token.starts_with('-') {
            continue;
        }
        let normalized = normalize_token(token);
        if targets.contains(&normalized.as_str()) {
            return Some(normalized);
        }
        break;
    }
    None
}

/// Path helpers mirroring the NSString / URL / RuntimeIsolation behavior the
/// Swift code relies on.
mod paths {
    use super::Path;

    /// `NSString.lastPathComponent`: trailing slashes ignored, "/" stays "/".
    pub(super) fn last_path_component(path: &str) -> String {
        if path.is_empty() {
            return String::new();
        }
        let stripped = path.trim_end_matches('/');
        if stripped.is_empty() {
            return "/".to_string();
        }
        match stripped.rfind('/') {
            Some(i) => stripped[i + 1..].to_string(),
            None => stripped.to_string(),
        }
    }

    /// `NSString.deletingPathExtension` applied to a single component: the
    /// extension is the text after the last `.`, which must not be the first
    /// character (hidden files keep their name) nor the last one.
    pub(super) fn deleting_path_extension(component: &str) -> String {
        match component.rfind('.') {
            Some(i) if i > 0 && i + 1 < component.len() => component[..i].to_string(),
            _ => component.to_string(),
        }
    }

    /// `RuntimeIsolation.homePath()`: `CHAU7_HOME_ROOT` override, else `HOME`.
    fn home_path() -> String {
        if let Ok(raw) = std::env::var("CHAU7_HOME_ROOT") {
            let trimmed = raw.trim();
            if !trimmed.is_empty() {
                return standardize_absolute(&absolutize(trimmed));
            }
        }
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".to_string());
        standardize_absolute(&absolutize(&home))
    }

    /// `RuntimeIsolation.expandTilde(in:)`: only a leading `~/` is expanded.
    pub(super) fn expand_tilde(path: &str) -> String {
        match path.strip_prefix('~') {
            Some(rest) if rest.starts_with('/') => format!("{}{}", home_path(), rest),
            _ => path.to_string(),
        }
    }

    /// `URL(fileURLWithPath:)` resolves relative paths against the process
    /// working directory.
    fn absolutize(path: &str) -> String {
        if path.starts_with('/') {
            return path.to_string();
        }
        let cwd = std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".to_string());
        append_component(&cwd, path)
    }

    /// `URL.standardized.path` for an absolute path: removes `.` and empty
    /// segments, resolves `..` lexically and drops the trailing slash.
    fn standardize_absolute(path: &str) -> String {
        let mut parts: Vec<&str> = Vec::new();
        for seg in path.split('/') {
            match seg {
                "" | "." => {}
                ".." => {
                    parts.pop();
                }
                other => parts.push(other),
            }
        }
        format!("/{}", parts.join("/"))
    }

    /// `URL.appendingPathComponent(...).path` (no standardization).
    pub(super) fn append_component(dir: &str, component: &str) -> String {
        if dir.ends_with('/') {
            format!("{dir}{component}")
        } else {
            format!("{dir}/{component}")
        }
    }

    fn standardized_directory_path(path: &str) -> String {
        let trimmed = path.trim();
        if trimmed.is_empty() {
            return String::new();
        }
        let expanded = expand_tilde(trimmed);
        standardize_absolute(&absolutize(&expanded))
    }

    pub(super) fn resolve_command_path(token: &str, current_directory: &str) -> Option<String> {
        let expanded = expand_tilde(token);
        if expanded.starts_with('/') {
            return Some(standardize_absolute(&expanded));
        }
        let base = standardized_directory_path(current_directory);
        if base.is_empty() {
            return None;
        }
        Some(standardize_absolute(&append_component(&base, &expanded)))
    }

    fn resolve_directory_path(path: &str, current_directory: &str) -> String {
        let expanded = expand_tilde(path);
        if expanded.starts_with('/') {
            return standardize_absolute(&expanded);
        }
        let base = standardized_directory_path(current_directory);
        if base.is_empty() {
            return String::new();
        }
        standardize_absolute(&append_component(&base, &expanded))
    }

    pub(super) fn path_directories(
        search_path: Option<&str>,
        current_directory: &str,
    ) -> Vec<String> {
        let raw_path = match search_path {
            Some(p) if !p.is_empty() => p.to_string(),
            _ => std::env::var("PATH").unwrap_or_default(),
        };
        let base = standardized_directory_path(current_directory);
        raw_path
            .split(':')
            .map(|entry| {
                let component = if entry.is_empty() { "." } else { entry };
                resolve_directory_path(component, &base)
            })
            .filter(|p| !p.is_empty())
            .collect()
    }

    /// Exists, is not a directory (symlinks followed) and has an execute bit.
    pub(super) fn is_executable_file(path: &str) -> bool {
        let Ok(meta) = std::fs::metadata(Path::new(path)) else {
            return false;
        };
        if meta.is_dir() {
            return false;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            meta.permissions().mode() & 0o111 != 0
        }
        #[cfg(not(unix))]
        {
            true
        }
    }
}

// MARK: - Event Parsing

/// Pure functions for parsing Claude Code hook events (Swift `EventParsing`).
pub mod event_parsing {
    use super::json;
    use super::paths;

    /// Event types from hooks.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum EventType {
        UserPrompt,
        ToolStart,
        ToolComplete,
        PermissionRequest,
        ResponseComplete,
        Notification,
        SessionEnd,
        Unknown,
    }

    impl EventType {
        /// All cases, in declaration order (Swift `CaseIterable`).
        pub const ALL: [EventType; 8] = [
            EventType::UserPrompt,
            EventType::ToolStart,
            EventType::ToolComplete,
            EventType::PermissionRequest,
            EventType::ResponseComplete,
            EventType::Notification,
            EventType::SessionEnd,
            EventType::Unknown,
        ];

        /// Swift `rawValue`.
        pub fn as_str(self) -> &'static str {
            match self {
                EventType::UserPrompt => "user_prompt",
                EventType::ToolStart => "tool_start",
                EventType::ToolComplete => "tool_complete",
                EventType::PermissionRequest => "permission_request",
                EventType::ResponseComplete => "response_complete",
                EventType::Notification => "notification",
                EventType::SessionEnd => "session_end",
                EventType::Unknown => "unknown",
            }
        }

        /// Swift `init?(rawValue:)`.
        pub fn from_raw_value(raw: &str) -> Option<EventType> {
            EventType::ALL.into_iter().find(|t| t.as_str() == raw)
        }

        /// Swift `init(from hookEvent:)`: maps a Claude Code hook name.
        pub fn from_hook(hook_event: &str) -> EventType {
            match hook_event {
                "UserPromptSubmit" => EventType::UserPrompt,
                "PreToolUse" => EventType::ToolStart,
                "PostToolUse" => EventType::ToolComplete,
                "PermissionRequest" => EventType::PermissionRequest,
                "Stop" => EventType::ResponseComplete,
                "SessionEnd" => EventType::SessionEnd,
                _ => EventType::Unknown,
            }
        }
    }

    /// Parsed event data.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct ParsedEvent {
        pub event_type: EventType,
        pub hook: String,
        pub tool_name: String,
        pub message: String,
        pub session_id: String,
        pub project_path: String,
    }

    /// Parses a JSON event payload from a hook. Returns `None` unless the
    /// payload is valid JSON whose top level is an object. Fields that are
    /// missing or not strings default to "" (and `type` to `Unknown`).
    pub fn parse_event(json_bytes: &[u8]) -> Option<ParsedEvent> {
        let obj = json::parse_top_level_object(json_bytes)?;
        let get = |key: &str| -> String {
            match obj.get(key) {
                Some(json::Scalar::String(s)) => s.clone(),
                _ => String::new(),
            }
        };
        let type_string = match obj.get("type") {
            Some(json::Scalar::String(s)) => s.as_str(),
            _ => "unknown",
        };
        let event_type = EventType::from_raw_value(type_string).unwrap_or(EventType::Unknown);
        Some(ParsedEvent {
            event_type,
            hook: get("hook"),
            tool_name: get("tool_name"),
            message: get("message"),
            session_id: get("session_id"),
            project_path: get("project_path"),
        })
    }

    /// `URL(fileURLWithPath:).lastPathComponent`; an empty path refers to the
    /// process working directory, like Foundation.
    fn url_last_path_component(path: &str) -> String {
        if path.is_empty() {
            let cwd = std::env::current_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| "/".to_string());
            return paths::last_path_component(&cwd);
        }
        paths::last_path_component(path)
    }

    /// Extracts the session ID (file name without extension) from a
    /// transcript path.
    pub fn extract_session_id(transcript_path: &str) -> String {
        paths::deleting_path_extension(&url_last_path_component(transcript_path))
    }

    /// Extracts the project name (last path component) from a project path.
    pub fn extract_project_name(project_path: &str) -> String {
        url_last_path_component(project_path)
    }
}

/// Minimal strict JSON reader, enough for `EventParsing`: it validates the
/// whole document and keeps only the scalar members of the top-level object.
/// Nested objects and arrays are parsed for validity and then discarded.
mod json {
    use std::collections::HashMap;

    /// A kept top-level member value. Nested containers become `Container`.
    #[derive(Debug, Clone, PartialEq)]
    pub(super) enum Scalar {
        String(String),
        Number(f64),
        Bool(bool),
        Null,
        Container,
    }

    const MAX_DEPTH: usize = 512;

    struct Parser<'a> {
        s: &'a [u8],
        pos: usize,
    }

    /// Returns the members of the top-level object, or `None` if the input
    /// is not valid UTF-8 JSON or the top level is not an object. Duplicate
    /// keys keep the last value.
    pub(super) fn parse_top_level_object(bytes: &[u8]) -> Option<HashMap<String, Scalar>> {
        let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
        std::str::from_utf8(bytes).ok()?;
        let mut p = Parser { s: bytes, pos: 0 };
        p.skip_ws();
        if p.peek()? != b'{' {
            // A valid top-level array would still fail the `as? [String: Any]` cast.
            return None;
        }
        let mut members = HashMap::new();
        p.parse_object(0, Some(&mut members))?;
        p.skip_ws();
        if p.pos != p.s.len() {
            return None;
        }
        Some(members)
    }

    impl Parser<'_> {
        fn peek(&self) -> Option<u8> {
            self.s.get(self.pos).copied()
        }

        fn bump(&mut self) -> Option<u8> {
            let b = self.peek()?;
            self.pos += 1;
            Some(b)
        }

        fn expect(&mut self, b: u8) -> Option<()> {
            (self.bump()? == b).then_some(())
        }

        fn skip_ws(&mut self) {
            while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
                self.pos += 1;
            }
        }

        fn parse_value(&mut self, depth: usize) -> Option<Scalar> {
            self.skip_ws();
            match self.peek()? {
                b'{' => {
                    self.parse_object(depth + 1, None)?;
                    Some(Scalar::Container)
                }
                b'[' => {
                    self.parse_array(depth + 1)?;
                    Some(Scalar::Container)
                }
                b'"' => self.parse_string().map(Scalar::String),
                b't' => self.literal(b"true").map(|_| Scalar::Bool(true)),
                b'f' => self.literal(b"false").map(|_| Scalar::Bool(false)),
                b'n' => self.literal(b"null").map(|_| Scalar::Null),
                b'-' | b'0'..=b'9' => self.parse_number().map(Scalar::Number),
                _ => None,
            }
        }

        fn literal(&mut self, lit: &[u8]) -> Option<()> {
            if self.s[self.pos..].starts_with(lit) {
                self.pos += lit.len();
                Some(())
            } else {
                None
            }
        }

        fn parse_object(
            &mut self,
            depth: usize,
            mut out: Option<&mut HashMap<String, Scalar>>,
        ) -> Option<()> {
            if depth > MAX_DEPTH {
                return None;
            }
            self.expect(b'{')?;
            self.skip_ws();
            if self.peek()? == b'}' {
                self.pos += 1;
                return Some(());
            }
            loop {
                self.skip_ws();
                let key = self.parse_string()?;
                self.skip_ws();
                self.expect(b':')?;
                let value = self.parse_value(depth)?;
                if let Some(map) = out.as_deref_mut() {
                    map.insert(key, value);
                }
                self.skip_ws();
                match self.bump()? {
                    b',' => continue,
                    b'}' => return Some(()),
                    _ => return None,
                }
            }
        }

        fn parse_array(&mut self, depth: usize) -> Option<()> {
            if depth > MAX_DEPTH {
                return None;
            }
            self.expect(b'[')?;
            self.skip_ws();
            if self.peek()? == b']' {
                self.pos += 1;
                return Some(());
            }
            loop {
                self.parse_value(depth)?;
                self.skip_ws();
                match self.bump()? {
                    b',' => continue,
                    b']' => return Some(()),
                    _ => return None,
                }
            }
        }

        fn parse_hex4(&mut self) -> Option<u32> {
            let hex = self.s.get(self.pos..self.pos + 4)?;
            let text = std::str::from_utf8(hex).ok()?;
            if !text.bytes().all(|b| b.is_ascii_hexdigit()) {
                return None;
            }
            self.pos += 4;
            u32::from_str_radix(text, 16).ok()
        }

        fn parse_string(&mut self) -> Option<String> {
            self.expect(b'"')?;
            let mut out = String::new();
            loop {
                let start = self.pos;
                while let Some(b) = self.peek() {
                    if b == b'"' || b == b'\\' || b < 0x20 {
                        break;
                    }
                    self.pos += 1;
                }
                // Input was validated as UTF-8 and we only split on ASCII bytes.
                out.push_str(std::str::from_utf8(&self.s[start..self.pos]).ok()?);
                match self.bump()? {
                    b'"' => return Some(out),
                    b'\\' => {}
                    _ => return None, // unescaped control character
                }
                match self.bump()? {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{08}'),
                    b'f' => out.push('\u{0C}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        let hi = self.parse_hex4()?;
                        let code = if (0xD800..0xDC00).contains(&hi) {
                            self.expect(b'\\')?;
                            self.expect(b'u')?;
                            let lo = self.parse_hex4()?;
                            if !(0xDC00..0xE000).contains(&lo) {
                                return None;
                            }
                            0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                        } else if (0xDC00..0xE000).contains(&hi) {
                            return None;
                        } else {
                            hi
                        };
                        out.push(char::from_u32(code)?);
                    }
                    _ => return None,
                }
            }
        }

        fn parse_number(&mut self) -> Option<f64> {
            let start = self.pos;
            if self.peek() == Some(b'-') {
                self.pos += 1;
            }
            match self.bump()? {
                b'0' => {}
                b'1'..=b'9' => {
                    while matches!(self.peek(), Some(b'0'..=b'9')) {
                        self.pos += 1;
                    }
                }
                _ => return None,
            }
            if self.peek() == Some(b'.') {
                self.pos += 1;
                if !self.bump()?.is_ascii_digit() {
                    return None;
                }
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.pos += 1;
                }
            }
            if matches!(self.peek(), Some(b'e' | b'E')) {
                self.pos += 1;
                if matches!(self.peek(), Some(b'+' | b'-')) {
                    self.pos += 1;
                }
                if !self.bump()?.is_ascii_digit() {
                    return None;
                }
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.pos += 1;
                }
            }
            std::str::from_utf8(&self.s[start..self.pos])
                .ok()?
                .parse()
                .ok()
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn reads_scalars_and_skips_containers() {
            let m = parse_top_level_object(
                br#"{"a":"x\n\u00e9\ud83d\ude00","b":-1.5e3,"c":true,"d":null,"e":{"f":[1,{"g":[]}]},"h":[]}"#,
            )
            .unwrap();
            assert_eq!(m["a"], Scalar::String("x\n\u{e9}\u{1F600}".into()));
            assert_eq!(m["b"], Scalar::Number(-1500.0));
            assert_eq!(m["c"], Scalar::Bool(true));
            assert_eq!(m["d"], Scalar::Null);
            assert_eq!(m["e"], Scalar::Container);
            assert_eq!(m["h"], Scalar::Container);
            assert!(!m.contains_key("f"));
        }

        #[test]
        fn rejects_invalid_documents() {
            for bad in [
                &b""[..],
                b"[]",
                b"\"s\"",
                b"{",
                b"{\"a\":}",
                b"{\"a\":1,}",
                b"{\"a\":01}",
                b"{\"a\":\"\x01\"}",
                b"{\"a\":\"\\ud800\"}",
                b"{} x",
                b"{\"a\":tru}",
                b"{\"a\":\xff}",
            ] {
                assert!(parse_top_level_object(bad).is_none(), "{bad:?}");
            }
        }

        #[test]
        fn accepts_bom_whitespace_and_empty_object() {
            assert!(
                parse_top_level_object(b"\xEF\xBB\xBF  {} \n")
                    .unwrap()
                    .is_empty()
            );
        }

        #[test]
        fn rejects_excessive_nesting() {
            let deep = format!("{{\"a\":{}{}}}", "[".repeat(1000), "]".repeat(1000));
            assert!(parse_top_level_object(deep.as_bytes()).is_none());
        }
    }
}

#[cfg(test)]
mod tests {
    //! Ported from `Tests/Chau7Tests/Terminal/CommandDetectionTests.swift`
    //! (`CommandDetectionTests` and `EventParsingTests`). All 66 Swift tests
    //! are ported; none skipped. `testAllEventTypes` (which only checks that
    //! every raw value is non-nil) becomes a raw value round-trip check.
    //! Extra tests cover functions the Swift suite does not exercise
    //! (dev server command detection, URL and port extraction).

    use super::event_parsing::{self, EventType};
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn d(s: &str) -> Option<String> {
        detect_app(s)
    }

    fn out(s: &str) -> Option<String> {
        detect_app_from_output(s)
    }

    fn some(s: &str) -> Option<String> {
        Some(s.to_string())
    }

    fn unique_temp_dir() -> PathBuf {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        std::env::temp_dir().join(format!(
            "chau7-cmd-detect-{}-{}-{}",
            std::process::id(),
            n,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ))
    }

    /// Creates a temp dir containing an executable script `name`, runs `body`
    /// with (dir, executable path), then removes the dir.
    #[cfg(unix)]
    fn with_executable(name: &str, body: impl FnOnce(&str, &str)) {
        let root = unique_temp_dir();
        std::fs::create_dir_all(&root).unwrap();
        let exe = root.join(name);
        std::fs::write(&exe, "#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            body(root.to_str().unwrap(), exe.to_str().unwrap())
        }));
        let _ = std::fs::remove_dir_all(&root);
        if let Err(e) = result {
            std::panic::resume_unwind(e);
        }
    }

    // MARK: - Basic Detection

    #[test]
    fn detect_claude() {
        assert_eq!(d("claude"), some("Claude"));
        assert_eq!(d("claude-code"), some("Claude"));
        assert_eq!(d("claude-cli"), some("Claude"));
    }

    #[test]
    fn detect_gemini() {
        assert_eq!(d("gemini"), some("Gemini"));
        assert_eq!(d("gemini-cli"), some("Gemini"));
    }

    #[test]
    fn detect_chatgpt() {
        assert_eq!(d("chatgpt"), some("ChatGPT"));
        assert_eq!(d("gpt"), some("ChatGPT"));
        assert_eq!(d("openai"), some("ChatGPT"));
    }

    #[test]
    fn detect_copilot() {
        assert_eq!(d("copilot"), some("Copilot"));
        assert_eq!(d("copilot-cli"), some("Copilot"));
    }

    #[test]
    fn detect_codex() {
        assert_eq!(d("codex"), some("Codex"));
        assert_eq!(d("codex-cli"), some("Codex"));
    }

    #[test]
    fn detect_aider() {
        assert_eq!(d("aider"), some("Aider"));
        assert_eq!(d("aider-chat"), some("Aider"));
    }

    #[test]
    fn detect_cursor() {
        assert_eq!(d("cursor"), some("Cursor"));
    }

    #[test]
    fn detect_cody() {
        assert_eq!(d("cody"), some("Cody"));
    }

    #[test]
    fn detect_amazon_q() {
        assert_eq!(d("amazon-q"), some("Amazon Q"));
        // "q" alone is too generic (commonly aliased to exit/quit)
        assert_eq!(d("q"), None);
    }

    #[test]
    fn detect_goose() {
        assert_eq!(d("goose"), some("Goose"));
    }

    #[test]
    fn detect_amp() {
        assert_eq!(d("amp"), some("Amp"));
    }

    #[test]
    fn unknown_command() {
        assert_eq!(d("vim"), None);
        assert_eq!(d("ls -la"), None);
        assert_eq!(d("git status"), None);
    }

    // MARK: - Path Handling

    #[test]
    fn detect_with_absolute_path() {
        assert_eq!(d("/usr/local/bin/claude"), some("Claude"));
        assert_eq!(d("/opt/homebrew/bin/gemini-cli"), some("Gemini"));
    }

    #[test]
    fn detect_with_relative_path() {
        assert_eq!(d("./claude"), some("Claude"));
        assert_eq!(d("../bin/chatgpt"), some("ChatGPT"));
    }

    // MARK: - Sudo Handling

    #[test]
    fn detect_with_sudo() {
        assert_eq!(d("sudo claude"), some("Claude"));
        assert_eq!(d("sudo -u root claude"), some("Claude"));
        assert_eq!(d("sudo -E claude"), some("Claude"));
    }

    #[test]
    fn sudo_with_options() {
        assert_eq!(d("sudo -u admin -g wheel claude"), some("Claude"));
        assert_eq!(d("sudo -- claude"), some("Claude"));
    }

    // MARK: - Environment Variables

    #[test]
    fn detect_with_env_prefix() {
        assert_eq!(d("FOO=bar claude"), some("Claude"));
        assert_eq!(d("PATH=/usr/bin TERM=xterm claude"), some("Claude"));
        assert_eq!(d("env FOO=bar claude"), some("Claude"));
    }

    #[test]
    fn env_with_options() {
        assert_eq!(d("env -i claude"), some("Claude"));
        assert_eq!(d("env -- claude"), some("Claude"));
    }

    // MARK: - Shell Wrappers

    #[test]
    fn detect_with_command() {
        assert_eq!(d("command claude"), some("Claude"));
    }

    #[test]
    fn detect_with_exec() {
        assert_eq!(d("exec claude"), some("Claude"));
    }

    #[test]
    fn detect_with_time() {
        assert_eq!(d("time claude"), some("Claude"));
    }

    #[test]
    fn detect_with_noglob() {
        assert_eq!(d("noglob claude"), some("Claude"));
    }

    // MARK: - Complex Commands

    #[test]
    fn detect_with_multiple_wrappers() {
        assert_eq!(d("env FOO=bar sudo -u root command claude"), some("Claude"));
        assert_eq!(d("time sudo env PATH=/bin claude"), some("Claude"));
    }

    // MARK: - GitHub Copilot (gh copilot)

    #[test]
    fn detect_gh_copilot() {
        assert_eq!(d("gh copilot"), some("Copilot"));
        assert_eq!(d("gh copilot suggest"), some("Copilot"));
        assert_eq!(d("gh copilot explain"), some("Copilot"));
    }

    #[test]
    fn gh_other_subcommands() {
        assert_eq!(d("gh pr list"), None);
        assert_eq!(d("gh issue create"), None);
    }

    // MARK: - npx/bunx

    #[test]
    fn detect_npx_claude() {
        assert_eq!(d("npx claude"), some("Claude"));
        assert_eq!(d("npx -y claude"), some("Claude"));
    }

    #[test]
    fn detect_bunx_claude() {
        assert_eq!(d("bunx claude"), some("Claude"));
    }

    #[test]
    fn detect_pnpm_claude() {
        assert_eq!(d("pnpm claude"), some("Claude"));
    }

    // Unix paths, PATH syntax and execute bits.
    #[cfg(unix)]
    #[test]
    fn detect_launchable_app_requires_executable() {
        with_executable("gemini", |dir, _| {
            assert_eq!(
                detect_launchable_app("gemini", dir, Some(dir)),
                some("Gemini")
            );
        });
    }

    #[test]
    fn detect_launchable_app_rejects_missing_executable() {
        let dir = unique_temp_dir();
        let dir = dir.to_str().unwrap();
        assert_eq!(d("gemini"), some("Gemini"));
        assert_eq!(detect_launchable_app("gemini", dir, Some(dir)), None);
    }

    // Unix paths, PATH syntax and execute bits.
    #[cfg(unix)]
    #[test]
    fn detect_launchable_app_with_wrapper_command() {
        with_executable("gh", |dir, _| {
            assert_eq!(
                detect_launchable_app("gh copilot suggest", dir, Some(dir)),
                some("Copilot")
            );
        });
    }

    // MARK: - Output Detection

    #[test]
    fn detect_claude_from_output() {
        assert_eq!(out("╭─ Claude Code"), some("Claude"));
        assert_eq!(out("Powered by Anthropic"), some("Claude"));
        assert_eq!(out("Visit claude.ai for more"), some("Claude"));
    }

    #[test]
    fn detect_claude_from_output_case_insensitive() {
        assert_eq!(out("CLAUDE CODE v2.0"), some("Claude"));
        assert_eq!(out("powered by ANTHROPIC"), some("Claude"));
    }

    #[test]
    fn detect_gemini_from_output() {
        assert_eq!(out("Google AI Studio"), some("Gemini"));
        assert_eq!(out("Using Gemini Pro model"), some("Gemini"));
    }

    #[test]
    fn detect_chatgpt_from_output() {
        assert_eq!(out("ChatGPT CLI v1.0"), some("ChatGPT"));
        assert_eq!(out("Visit openai.com"), some("ChatGPT"));
        assert_eq!(out("CHATGPT is ready"), some("ChatGPT"));
    }

    #[test]
    fn detect_copilot_from_output() {
        assert_eq!(out("GitHub Copilot CLI"), some("Copilot"));
        assert_eq!(out("Copilot CLI ready"), some("Copilot"));
    }

    #[test]
    fn detect_codex_from_output() {
        assert_eq!(out("OpenAI Codex"), some("Codex"));
        assert_eq!(out("╭─ Codex"), some("Codex"));
    }

    #[test]
    fn detect_aider_from_output() {
        assert_eq!(out("Aider is running"), some("Aider"));
        assert_eq!(out("https://aider.chat"), some("Aider"));
    }

    #[test]
    fn detect_cursor_from_output() {
        assert_eq!(out("Cursor CLI ready"), some("Cursor"));
        assert_eq!(out("cursor.sh"), some("Cursor"));
    }

    #[test]
    fn detect_new_tools_from_output() {
        assert_eq!(out("Sourcegraph Cody ready"), some("Cody"));
        assert_eq!(out("Amazon Q Developer"), some("Amazon Q"));
        assert_eq!(out("goose v1.2.0"), some("Goose"));
        assert_eq!(out("Visit continue.dev"), some("Continue"));
    }

    #[test]
    fn no_detection_from_output() {
        assert_eq!(out("Hello, world!"), None);
        assert_eq!(out("$ ls -la"), None);
        // "cursor" alone must NOT match (too generic)
        assert_eq!(out("move cursor to line 10"), None);
    }

    // MARK: - Dev Server Output Detection

    #[test]
    fn detect_dev_server_from_output_case_insensitive() {
        let f = detect_dev_server_from_output;
        assert_eq!(f("VITE v6.0.0  ready"), some("Vite"));
        assert_eq!(f("Vite V6.0.0  ready"), some("Vite"));
        assert_eq!(f("Ready Started Server On 0.0.0.0:3000"), some("Next.js"));
        assert_eq!(f("WEBPACK COMPILED successfully"), some("Webpack"));
    }

    #[test]
    fn dev_server_angular_detection() {
        let f = detect_dev_server_from_output;
        assert_eq!(
            f("Angular Live Development Server is listening"),
            some("Angular")
        );
        // "compiled successfully!" is React (Create React App), not Angular
        assert_eq!(f("Compiled successfully!"), some("React"));
    }

    #[test]
    fn dev_server_no_false_positives() {
        assert_eq!(detect_dev_server_from_output("Hello, world!"), None);
        assert_eq!(detect_dev_server_from_output("git status"), None);
    }

    // MARK: - Tokenization

    #[test]
    fn basic_tokenization() {
        assert_eq!(tokenize("claude"), ["claude"]);
        assert_eq!(tokenize("claude --help"), ["claude", "--help"]);
        assert_eq!(tokenize("ls -la /tmp"), ["ls", "-la", "/tmp"]);
    }

    #[test]
    fn quoted_tokenization() {
        assert_eq!(tokenize("echo 'hello world'"), ["echo", "hello world"]);
        assert_eq!(tokenize("echo \"hello world\""), ["echo", "hello world"]);
    }

    #[test]
    fn escaped_tokenization() {
        assert_eq!(tokenize("echo hello\\ world"), ["echo", "hello world"]);
    }

    #[test]
    fn comment_handling() {
        assert_eq!(tokenize("claude # this is a comment"), ["claude"]);
    }

    #[test]
    fn pipe_handling() {
        assert_eq!(tokenize("claude | grep foo"), ["claude"]);
    }

    #[test]
    fn semicolon_handling() {
        assert_eq!(tokenize("claude; echo done"), ["claude"]);
    }

    #[test]
    fn ampersand_handling() {
        assert_eq!(tokenize("claude &"), ["claude"]);
        assert_eq!(tokenize("claude && echo done"), ["claude"]);
    }

    // MARK: - Token Normalization

    #[test]
    fn normalize_token_cases() {
        assert_eq!(normalize_token("claude"), "claude");
        assert_eq!(normalize_token("CLAUDE"), "claude");
        assert_eq!(normalize_token("/usr/bin/claude"), "claude");
        assert_eq!(normalize_token("./claude.sh"), "claude");
    }

    // MARK: - Environment Assignment Detection

    #[test]
    fn env_assignment_detection() {
        assert!(is_env_assignment("FOO=bar"));
        assert!(is_env_assignment("_VAR=value"));
        assert!(is_env_assignment("PATH=/usr/bin"));
        assert!(!is_env_assignment("claude"));
        assert!(!is_env_assignment("--option=value"));
        assert!(!is_env_assignment("123=invalid"));
    }

    // MARK: - Edge Cases

    #[test]
    fn empty_input() {
        assert_eq!(d(""), None);
        assert_eq!(d("   "), None);
    }

    #[test]
    fn only_env_vars() {
        assert_eq!(d("FOO=bar BAZ=qux"), None);
    }

    #[test]
    fn only_options() {
        assert_eq!(d("-v --help"), None);
    }

    #[test]
    fn case_sensitivity() {
        assert_eq!(d("CLAUDE"), some("Claude"));
        assert_eq!(d("Claude"), some("Claude"));
        assert_eq!(d("cLaUdE"), some("Claude"));
    }

    // MARK: - command -v (Existence Queries)

    #[test]
    fn command_dash_v_is_not_execution() {
        assert_eq!(d("command -v claude"), None);
        assert_eq!(d("command -v codex"), None);
        assert_eq!(d("command -v aider"), None);
    }

    #[test]
    fn command_dash_p_still_detects() {
        assert_eq!(d("command -p claude"), some("Claude"));
    }

    #[test]
    fn command_without_dash_v_still_detects() {
        assert_eq!(d("command claude"), some("Claude"));
        assert_eq!(d("command codex"), some("Codex"));
    }

    // MARK: - Event Parsing Tests

    #[test]
    fn event_type_from_hook() {
        assert_eq!(
            EventType::from_hook("UserPromptSubmit"),
            EventType::UserPrompt
        );
        assert_eq!(EventType::from_hook("PreToolUse"), EventType::ToolStart);
        assert_eq!(EventType::from_hook("PostToolUse"), EventType::ToolComplete);
        assert_eq!(
            EventType::from_hook("PermissionRequest"),
            EventType::PermissionRequest
        );
        assert_eq!(EventType::from_hook("Stop"), EventType::ResponseComplete);
        assert_eq!(EventType::from_hook("SessionEnd"), EventType::SessionEnd);
        assert_eq!(EventType::from_hook("UnknownHook"), EventType::Unknown);
    }

    #[test]
    fn parse_event_json() {
        let json = br#"{
            "type": "tool_start",
            "hook": "PreToolUse",
            "tool_name": "Read",
            "message": "Reading file.swift",
            "session_id": "abc123",
            "project_path": "~/test/project"
        }"#;
        let event = event_parsing::parse_event(json).unwrap();
        assert_eq!(event.event_type, EventType::ToolStart);
        assert_eq!(event.hook, "PreToolUse");
        assert_eq!(event.tool_name, "Read");
        assert_eq!(event.message, "Reading file.swift");
        assert_eq!(event.session_id, "abc123");
        assert_eq!(event.project_path, "~/test/project");
    }

    #[test]
    fn parse_invalid_json() {
        assert!(event_parsing::parse_event(b"not json").is_none());
    }

    #[test]
    fn extract_session_id() {
        assert_eq!(
            event_parsing::extract_session_id("~/.claude/sessions/abc123.jsonl"),
            "abc123"
        );
        assert_eq!(
            event_parsing::extract_session_id("/tmp/session-xyz.log"),
            "session-xyz"
        );
    }

    #[test]
    fn extract_project_name() {
        assert_eq!(
            event_parsing::extract_project_name("~/projects/my-app"),
            "my-app"
        );
        assert_eq!(
            event_parsing::extract_project_name("/home/user/code/"),
            "code"
        );
    }

    #[test]
    fn all_event_types() {
        for t in EventType::ALL {
            assert_eq!(EventType::from_raw_value(t.as_str()), Some(t));
        }
    }

    // MARK: - Rust-port extras

    #[test]
    fn parse_event_defaults_for_missing_or_non_string_fields() {
        let event =
            event_parsing::parse_event(br#"{"type": 3, "hook": null, "message": {"x": 1}}"#)
                .unwrap();
        assert_eq!(event.event_type, EventType::Unknown);
        assert_eq!(event.hook, "");
        assert_eq!(event.message, "");
        assert_eq!(event.tool_name, "");
        assert!(event_parsing::parse_event(b"[1, 2]").is_none());
        let event = event_parsing::parse_event(br#"{"type": "bogus"}"#).unwrap();
        assert_eq!(event.event_type, EventType::Unknown);
    }

    #[test]
    fn detect_dev_server_commands() {
        assert_eq!(detect_dev_server("vite"), some("Vite"));
        assert_eq!(detect_dev_server("npx next dev"), some("Next.js"));
        assert_eq!(detect_dev_server("npm run dev"), some("Dev Server"));
        assert_eq!(detect_dev_server("pnpm dev"), some("Dev Server"));
        assert_eq!(detect_dev_server("yarn watch"), some("Watch Mode"));
        assert_eq!(detect_dev_server("npm run build"), None);
        assert_eq!(detect_dev_server("npm install"), None);
        assert_eq!(detect_dev_server("ls"), None);
    }

    #[test]
    fn extract_dev_server_url_patterns() {
        assert_eq!(
            extract_dev_server_url("Local: http://localhost:5173/ ready"),
            some("http://localhost:5173")
        );
        assert_eq!(
            extract_dev_server_url("at http://127.0.0.1:8000"),
            some("http://127.0.0.1:8000")
        );
        // Pattern order beats position: localhost is tried before 0.0.0.0.
        assert_eq!(
            extract_dev_server_url("http://0.0.0.0:3000 and http://localhost:4000"),
            some("http://localhost:4000")
        );
        assert_eq!(extract_dev_server_url("http://localhost:abc"), None);
        assert_eq!(extract_dev_server_url("nothing here"), None);
    }

    #[test]
    fn extract_port_cases() {
        assert_eq!(extract_port("http://localhost:3000"), Some(3000));
        assert_eq!(extract_port("http://localhost:5173/"), Some(5173));
        assert_eq!(extract_port("port :19000 open"), Some(19000));
        assert_eq!(extract_port("time 12:30 then :8080\n"), Some(8080));
        assert_eq!(extract_port(":123456"), None);
        assert_eq!(extract_port(":80"), None);
        assert_eq!(extract_port(":8080x"), None);
    }

    #[test]
    fn command_token_and_index() {
        assert_eq!(
            command_token("FOO=1 sudo -u root claude --x"),
            some("claude")
        );
        assert_eq!(command_token("command -v claude"), None);
        let tokens = tokenize("env A=b exec vim file");
        assert_eq!(command_token_index(&tokens), Some(3));
    }

    // Unix paths, PATH syntax and execute bits.
    #[cfg(unix)]
    #[test]
    fn command_appears_executable_paths() {
        with_executable("tool", |dir, exe| {
            assert!(command_appears_executable(exe, "/", None));
            assert!(command_appears_executable(
                "./tool",
                dir,
                Some("/nonexistent")
            ));
            assert!(command_appears_executable("tool", "/", Some(dir)));
            // Empty PATH entry means the current directory.
            assert!(command_appears_executable(
                "tool",
                dir,
                Some("/nonexistent:")
            ));
            assert!(!command_appears_executable(
                "tool",
                "/",
                Some("/nonexistent")
            ));
            assert!(!command_appears_executable("  ", dir, Some(dir)));
            // A directory is not executable.
            assert!(!command_appears_executable(dir, "/", None));
        });
    }

    #[cfg(unix)]
    #[test]
    fn non_executable_file_is_rejected() {
        with_executable("plain", |dir, exe| {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(exe, std::fs::Permissions::from_mode(0o644)).unwrap();
            assert!(!command_appears_executable("plain", "/", Some(dir)));
        });
    }

    #[test]
    fn path_helpers_match_nsstring() {
        assert_eq!(paths::last_path_component("/usr/bin/"), "bin");
        assert_eq!(paths::last_path_component("/"), "/");
        assert_eq!(paths::last_path_component(""), "");
        assert_eq!(paths::deleting_path_extension(".bashrc"), ".bashrc");
        assert_eq!(paths::deleting_path_extension("a.tar.gz"), "a.tar");
        assert_eq!(normalize_token("node.js"), "node");
    }
}
