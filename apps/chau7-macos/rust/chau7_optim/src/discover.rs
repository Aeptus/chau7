use anyhow::{Context, Result};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

/// Commands that CTO already wraps (must match ctoRewriteMap + execOnlyCommands).
const SUPPORTED_COMMANDS: &[&str] = &[
    "cat",
    "head",
    "tail",
    "ls",
    "find",
    "tree",
    "grep",
    "rg",
    "git",
    "diff",
    "cargo",
    "curl",
    "docker",
    "kubectl",
    "gh",
    "pnpm",
    "wget",
    "npm",
    "npx",
    "vitest",
    "prisma",
    "tsc",
    "next",
    "eslint",
    "prettier",
    "ruff",
    "pytest",
    "pip",
    "go",
    "golangci-lint",
    "wc",
    "playwright",
    "swift",
    "python",
    "python3",
];

/// Commands to ignore (not meaningful for optimization).
const IGNORED_COMMANDS: &[&str] = &[
    "cd",
    "echo",
    "printf",
    "true",
    "false",
    "exit",
    "return",
    "set",
    "unset",
    "export",
    "source",
    ".",
    "alias",
    "which",
    "type",
    "test",
    "[",
    "[[",
    "if",
    "then",
    "else",
    "fi",
    "for",
    "while",
    "do",
    "done",
    "case",
    "esac",
    "read",
    "sleep",
    "wait",
    "kill",
    "trap",
    "shift",
    "eval",
    "exec",
    "mkdir",
    "rmdir",
    "touch",
    "chmod",
    "chown",
    "chgrp",
    "ln",
    "mv",
    "cp",
    "rm",
    "pushd",
    "popd",
    "dirs",
    "ulimit",
    "umask",
    "hash",
    "pwd",
    "break",
    "continue",
    "command",
    "builtin",
    "declare",
    "local",
    "let",
    // Already CTO (when invoked as chau7-optim)
    "chau7-optim",
];

/// Commands to ignore when they appear as a prefix (e.g., `env FOO=bar cmd`).
const WRAPPER_PREFIXES: &[&str] = &[
    "env",
    "sudo",
    "time",
    "nice",
    "nohup",
    "caffeinate",
    "timeout",
];

struct UnhandledBucket {
    count: usize,
    examples: Vec<String>,
    total_output_bytes: usize,
}

/// Extract the base command from a shell command string.
fn extract_base_command(cmd: &str) -> Option<&str> {
    let trimmed = cmd.trim();
    if trimmed.is_empty() {
        return None;
    }

    // Skip comments
    if trimmed.starts_with('#') {
        return None;
    }

    // Skip separators (---, ===, etc.)
    if trimmed.chars().all(|c| c == '-' || c == '=' || c == '_') && trimmed.len() >= 3 {
        return None;
    }

    // Skip line continuations
    if trimmed == "\\" || trimmed.starts_with("\\\n") {
        return None;
    }

    // Skip redirections captured as standalone fragments (e.g., "2>/dev/null")
    if trimmed.starts_with("2>") || trimmed.starts_with("1>") || trimmed.starts_with(">&") {
        return None;
    }

    // Skip variable assignments at the start (FOO=bar cmd ...)
    let mut parts = trimmed.split_whitespace();
    loop {
        let word = parts.next()?;

        // Variable assignment: KEY=VALUE
        if word.contains('=') && !word.starts_with('-') && !word.starts_with('/') {
            continue;
        }
        // Wrapper prefixes like env, sudo
        if WRAPPER_PREFIXES.contains(&word) {
            continue;
        }

        // Skip shell variable expansions ("$OPTIM", "${OPTIM}")
        if word.starts_with('$') || word.starts_with('"') && word.contains('$') {
            // Treat $VAR or "$VAR" as ignored — we can't classify dynamic commands
            return None;
        }

        // This is the actual command
        // Strip leading parens from subshell syntax: (test ...) → test
        let word = word.trim_start_matches('(');
        // Strip path prefix (/usr/bin/foo -> foo)
        let base = word.rsplit('/').next().unwrap_or(word);

        // Skip if the "command" is just a number, punctuation, or empty
        if base.is_empty()
            || base.chars().all(|c| c.is_ascii_digit())
            || base == "null"
            || base == "dev"
        {
            return None;
        }

        return Some(base);
    }
}

/// Split compound commands (&&, ||, ;, |) into individual commands.
fn split_commands(cmd: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut depth = 0u32; // track $() and () nesting
    let mut start = 0;
    let bytes = cmd.as_bytes();
    let mut i = 0;

    while i < bytes.len() {
        match bytes[i] {
            b'(' => depth += 1,
            b')' => depth = depth.saturating_sub(1),
            b'\'' => {
                // Skip single-quoted strings
                i += 1;
                while i < bytes.len() && bytes[i] != b'\'' {
                    i += 1;
                }
            }
            b'"' => {
                // Skip double-quoted strings
                i += 1;
                while i < bytes.len() && bytes[i] != b'"' {
                    if bytes[i] == b'\\' {
                        i += 1; // skip escaped char
                    }
                    i += 1;
                }
            }
            b'&' if depth == 0 && i + 1 < bytes.len() && bytes[i + 1] == b'&' => {
                parts.push(&cmd[start..i]);
                i += 2;
                start = i;
                continue;
            }
            b'|' if depth == 0 => {
                if i + 1 < bytes.len() && bytes[i + 1] == b'|' {
                    // ||
                    parts.push(&cmd[start..i]);
                    i += 2;
                    start = i;
                    continue;
                } else {
                    // pipe
                    parts.push(&cmd[start..i]);
                    i += 1;
                    start = i;
                    continue;
                }
            }
            b';' if depth == 0 => {
                parts.push(&cmd[start..i]);
                i += 1;
                start = i;
                continue;
            }
            _ => {}
        }
        i += 1;
    }

    if start < cmd.len() {
        parts.push(&cmd[start..]);
    }

    parts
}

/// Check if a command is already handled by CTO.
fn is_supported(base_cmd: &str) -> bool {
    SUPPORTED_COMMANDS.contains(&base_cmd)
}

/// Check if a command should be ignored.
fn is_ignored(base_cmd: &str) -> bool {
    IGNORED_COMMANDS.contains(&base_cmd)
}

/// Discover session files under ~/.claude/projects/.
fn discover_sessions(project_filter: Option<&str>, since_days: u64) -> Result<Vec<PathBuf>> {
    let home = dirs::home_dir().context("could not determine home directory")?;
    let projects_dir = home.join(".claude").join("projects");

    if !projects_dir.exists() {
        anyhow::bail!(
            "Claude Code projects directory not found: {}",
            projects_dir.display()
        );
    }

    let cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(since_days * 86400))
        .unwrap_or(SystemTime::UNIX_EPOCH);

    let mut sessions = Vec::new();

    for entry in fs::read_dir(&projects_dir)?.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        // Apply project filter
        if let Some(filter) = project_filter {
            let dir_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if !dir_name.contains(filter) {
                continue;
            }
        }

        // Walk for .jsonl files (non-recursive into subagents for speed)
        for sub_entry in fs::read_dir(&path).into_iter().flatten().flatten() {
            let file_path = sub_entry.path();
            if file_path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            if let Ok(meta) = fs::metadata(&file_path) {
                if let Ok(mtime) = meta.modified() {
                    if mtime < cutoff {
                        continue;
                    }
                }
            }
            sessions.push(file_path);
        }
    }

    Ok(sessions)
}

/// Extract Bash commands from a session JSONL file.
fn extract_bash_commands(path: &PathBuf) -> Vec<(String, Option<usize>)> {
    let file = match fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return vec![],
    };
    let reader = BufReader::new(file);

    let mut tool_uses: Vec<(String, String)> = Vec::new(); // (id, command)
    let mut tool_results: HashMap<String, usize> = HashMap::new(); // id -> output_len

    for line in reader.lines().map_while(Result::ok) {
        // Fast pre-filter
        if !line.contains("\"Bash\"") && !line.contains("\"tool_result\"") {
            continue;
        }

        let entry: serde_json::Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let entry_type = entry.get("type").and_then(|t| t.as_str()).unwrap_or("");

        match entry_type {
            "assistant" => {
                if let Some(content) = entry.pointer("/message/content").and_then(|c| c.as_array())
                {
                    for block in content {
                        if block.get("type").and_then(|t| t.as_str()) == Some("tool_use")
                            && block.get("name").and_then(|n| n.as_str()) == Some("Bash")
                        {
                            if let (Some(id), Some(cmd)) = (
                                block.get("id").and_then(|i| i.as_str()),
                                block.pointer("/input/command").and_then(|c| c.as_str()),
                            ) {
                                tool_uses.push((id.to_string(), cmd.to_string()));
                            }
                        }
                    }
                }
            }
            "user" => {
                if let Some(content) = entry.pointer("/message/content").and_then(|c| c.as_array())
                {
                    for block in content {
                        if block.get("type").and_then(|t| t.as_str()) == Some("tool_result") {
                            if let Some(id) = block.get("tool_use_id").and_then(|i| i.as_str()) {
                                let len = block
                                    .get("content")
                                    .and_then(|c| c.as_str())
                                    .map(|s| s.len())
                                    .unwrap_or(0);
                                tool_results.insert(id.to_string(), len);
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }

    tool_uses
        .into_iter()
        .map(|(id, cmd)| {
            let output_len = tool_results.get(&id).copied();
            (cmd, output_len)
        })
        .collect()
}

pub fn run(project: Option<&str>, since_days: u64, limit: usize, verbose: u8) -> Result<()> {
    let sessions = discover_sessions(project, since_days)?;

    if verbose > 0 {
        eprintln!("Scanning {} session files...", sessions.len());
    }

    let mut total_commands: usize = 0;
    let mut supported_count: usize = 0;
    let mut ignored_count: usize = 0;
    let mut unhandled: HashMap<String, UnhandledBucket> = HashMap::new();

    for session_path in &sessions {
        let commands = extract_bash_commands(session_path);

        for (full_cmd, output_len) in &commands {
            let parts = split_commands(full_cmd);

            for part in parts {
                let base = match extract_base_command(part) {
                    Some(b) => b,
                    None => continue,
                };

                total_commands += 1;

                if is_supported(base) {
                    supported_count += 1;
                } else if is_ignored(base) {
                    ignored_count += 1;
                } else {
                    let bucket =
                        unhandled
                            .entry(base.to_string())
                            .or_insert_with(|| UnhandledBucket {
                                count: 0,
                                examples: Vec::new(),
                                total_output_bytes: 0,
                            });
                    bucket.count += 1;
                    if bucket.examples.len() < 3 {
                        let example = part.trim().chars().take(80).collect::<String>();
                        if !bucket.examples.contains(&example) {
                            bucket.examples.push(example);
                        }
                    }
                    if let Some(len) = output_len {
                        bucket.total_output_bytes += len;
                    }
                }
            }
        }
    }

    // Sort by count descending
    let mut sorted: Vec<_> = unhandled.into_iter().collect();
    sorted.sort_by(|a, b| b.1.count.cmp(&a.1.count));

    // Print report
    println!("CTO Discover — Top Unhandled Commands");
    println!("{}", "=".repeat(60));
    println!(
        "Scanned: {} sessions (last {} days), {} Bash commands",
        sessions.len(),
        since_days,
        total_commands
    );
    println!(
        "Already optimized: {} ({}%)",
        supported_count,
        if total_commands > 0 {
            supported_count * 100 / total_commands
        } else {
            0
        }
    );
    println!("Shell builtins/ignored: {}", ignored_count);

    let unhandled_total: usize = sorted.iter().map(|(_, b)| b.count).sum();
    println!(
        "Unhandled: {} ({} unique commands)",
        unhandled_total,
        sorted.len()
    );
    println!();

    if sorted.is_empty() {
        println!("No unhandled commands found — CTO covers everything!");
        return Ok(());
    }

    println!(
        "{:<20} {:>6}  {:>10}  Examples",
        "Command", "Count", "Output"
    );
    println!("{}", "-".repeat(75));

    for (base, bucket) in sorted.iter().take(limit) {
        let output_str = if bucket.total_output_bytes > 0 {
            format_bytes(bucket.total_output_bytes)
        } else {
            "-".to_string()
        };

        let examples = bucket.examples.join(", ");
        let examples_truncated = if examples.len() > 35 {
            format!("{}...", &examples[..32])
        } else {
            examples
        };

        println!(
            "{:<20} {:>6}  {:>10}  {}",
            truncate(base, 19),
            bucket.count,
            output_str,
            examples_truncated,
        );
    }

    if sorted.len() > limit {
        println!("\n... +{} more commands", sorted.len() - limit);
    }

    // Show potential savings estimate
    let total_unhandled_bytes: usize = sorted.iter().map(|(_, b)| b.total_output_bytes).sum();
    if total_unhandled_bytes > 0 {
        let estimated_tokens = total_unhandled_bytes / 4;
        let potential_savings = estimated_tokens * 60 / 100; // assume ~60% savings
        println!(
            "\nEstimated potential savings: ~{} tokens/session (assuming 60% reduction)",
            format_number(potential_savings)
        );
    }

    Ok(())
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}…", &s[..max - 1])
    }
}

fn format_bytes(bytes: usize) -> String {
    if bytes >= 1_000_000 {
        format!("{:.1}MB", bytes as f64 / 1_000_000.0)
    } else if bytes >= 1_000 {
        format!("{:.1}KB", bytes as f64 / 1_000.0)
    } else {
        format!("{}B", bytes)
    }
}

fn format_number(n: usize) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        format!("{}", n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_base_command_simple() {
        assert_eq!(extract_base_command("git status"), Some("git"));
        assert_eq!(extract_base_command("ls -la"), Some("ls"));
        assert_eq!(extract_base_command("cargo test"), Some("cargo"));
    }

    #[test]
    fn test_extract_base_command_with_path() {
        assert_eq!(extract_base_command("/usr/bin/git status"), Some("git"));
        assert_eq!(extract_base_command("/bin/ls"), Some("ls"));
    }

    #[test]
    fn test_extract_base_command_with_env() {
        assert_eq!(
            extract_base_command("FOO=bar python3 test.py"),
            Some("python3")
        );
        assert_eq!(
            extract_base_command("NODE_ENV=test npm run build"),
            Some("npm")
        );
    }

    #[test]
    fn test_extract_base_command_with_sudo() {
        assert_eq!(extract_base_command("sudo apt install foo"), Some("apt"));
        assert_eq!(
            extract_base_command("env FOO=1 python3 test.py"),
            Some("python3")
        );
    }

    #[test]
    fn test_extract_base_command_empty() {
        assert_eq!(extract_base_command(""), None);
        assert_eq!(extract_base_command("   "), None);
    }

    #[test]
    fn test_split_commands_pipe() {
        let parts = split_commands("git status | grep modified");
        assert_eq!(parts.len(), 2);
        assert!(parts[0].trim().starts_with("git"));
        assert!(parts[1].trim().starts_with("grep"));
    }

    #[test]
    fn test_split_commands_and() {
        let parts = split_commands("cd /tmp && ls -la");
        assert_eq!(parts.len(), 2);
    }

    #[test]
    fn test_split_commands_semicolon() {
        let parts = split_commands("echo hello; echo world");
        assert_eq!(parts.len(), 2);
    }

    #[test]
    fn test_split_commands_quoted() {
        let parts = split_commands(r#"echo "hello && world""#);
        assert_eq!(parts.len(), 1); // && inside quotes shouldn't split
    }

    #[test]
    fn test_extract_false_positives_filtered() {
        // Separators
        assert_eq!(extract_base_command("---"), None);
        assert_eq!(extract_base_command("==="), None);
        // Subshell parens
        assert_eq!(
            extract_base_command("(test -f .env && echo yes)"),
            Some("test")
        );
        // pwd is ignored
        assert!(is_ignored("pwd"));
    }

    #[test]
    fn test_is_supported() {
        assert!(is_supported("git"));
        assert!(is_supported("cargo"));
        assert!(is_supported("ls"));
        assert!(is_supported("python3"));
        assert!(is_supported("python"));
        assert!(is_supported("swift"));
    }

    #[test]
    fn test_is_ignored() {
        assert!(is_ignored("cd"));
        assert!(is_ignored("echo"));
        assert!(is_ignored("mkdir"));
        assert!(!is_ignored("python3")); // python3 is supported, not ignored
        assert!(!is_ignored("swift"));
    }
}
