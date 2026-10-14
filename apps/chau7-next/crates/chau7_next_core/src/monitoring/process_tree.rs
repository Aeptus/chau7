//! `ProcessTreeProviderResolver.swift`: nearest live AI executable, never
//! arbitrary terminal output or a prompt string containing a tool's name.
use crate::{
    ai::tool_registry::COMMAND_NAME_MAP,
    command_detection::{detect_app, normalize_token, tokenize},
};
use std::collections::{HashMap, HashSet, VecDeque};
#[derive(Debug, Clone)]
pub struct ProcessRow {
    pub pid: u32,
    pub parent_pid: u32,
    pub command: String,
    pub argv: Vec<String>,
}
#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub rows: HashMap<u32, ProcessRow>,
    children: HashMap<u32, Vec<u32>>,
}
/// Process names whose argv is collected by the native process monitor.
pub const INTERPRETERS: &[&str] = &[
    "node", "python", "python3", "ruby", "npx", "bun", "bunx", "pnpm",
];
/// Runtimes whose argv path may identify an AI CLI script. Package-manager
/// argv is still inspected above for explicit launcher commands, but arbitrary
/// paths passed to install/run operations must not be treated as running tools.
const SCRIPT_RUNTIME_PATHS: &[&str] = &["node", "python", "python3", "ruby"];
const SKIPPED: &[&str] = &[
    "zsh",
    "bash",
    "fish",
    "sh",
    "dash",
    "ksh",
    "tmux",
    "tmux-server",
    "screen",
    "ssh",
    "sudo",
    "su",
    "login",
    "env",
    "node",
    "python",
    "python3",
    "ruby",
    "npx",
    "bun",
    "bunx",
    "pnpm",
    "ps",
];
impl Snapshot {
    pub fn from_rows(rows: impl IntoIterator<Item = ProcessRow>) -> Self {
        let mut result = Self::default();
        for row in rows {
            if row.pid > 0 {
                result.rows.insert(row.pid, row);
            }
        }
        for row in result.rows.values() {
            result
                .children
                .entry(row.parent_pid)
                .or_default()
                .push(row.pid);
        }
        for children in result.children.values_mut() {
            children.sort_unstable();
        }
        result
    }
    /// Shared bounded-ps fallback input, headers and malformed rows ignored.
    pub fn parse(text: &str) -> Self {
        Self::from_rows(text.lines().filter_map(|line| {
            let line = line.trim();
            let (pid, rest) = line.split_once(char::is_whitespace)?;
            let (parent, rest) = rest.trim_start().split_once(char::is_whitespace)?;
            let argv = tokenize(rest.trim());
            Some(ProcessRow {
                pid: pid.parse().ok()?,
                parent_pid: parent.parse().ok()?,
                command: argv.first()?.clone(),
                argv,
            })
        }))
    }
    pub fn resolve(&self, shell_pid: u32) -> Option<&'static str> {
        if shell_pid == 0 {
            return None;
        }
        let mut queue: VecDeque<_> = self
            .children
            .get(&shell_pid)
            .into_iter()
            .flatten()
            .copied()
            .collect();
        let mut visited = HashSet::from([shell_pid]);
        while let Some(pid) = queue.pop_front() {
            if !visited.insert(pid) {
                continue;
            }
            if let Some(row) = self.rows.get(&pid)
                && let Some(provider) = match_process(&row.command, &row.argv)
            {
                return Some(provider);
            }
            queue.extend(self.children.get(&pid).into_iter().flatten().copied());
        }
        None
    }

    /// Cached self-protection context is built off the UI thread from this
    /// same native snapshot. Cycles cannot add duplicate or unrelated names.
    pub fn descendant_names(&self, shell_pid: u32) -> Vec<String> {
        let mut queue: VecDeque<_> = self
            .children
            .get(&shell_pid)
            .into_iter()
            .flatten()
            .copied()
            .collect();
        let mut visited = HashSet::from([shell_pid]);
        let mut names = HashSet::new();
        while let Some(pid) = queue.pop_front() {
            if !visited.insert(pid) {
                continue;
            }
            if let Some(row) = self.rows.get(&pid) {
                let name = row
                    .command
                    .rsplit(['/', '\\'])
                    .next()
                    .unwrap_or(&row.command)
                    .trim();
                if !name.is_empty() {
                    names.insert(name.to_string());
                }
            }
            queue.extend(self.children.get(&pid).into_iter().flatten().copied());
        }
        let mut names: Vec<_> = names.into_iter().collect();
        names.sort();
        names
    }
}
fn process_token(token: &str) -> String {
    normalize_token(token.rsplit(['/', '\\']).next().unwrap_or(token))
}

pub fn match_process(command: &str, argv: &[String]) -> Option<&'static str> {
    let base = process_token(command);
    if !SKIPPED.contains(&base.as_str())
        && let Some(provider) = COMMAND_NAME_MAP.get(base.as_str())
    {
        return Some(*provider);
    }
    // Current Swift also resolves launch wrappers/package commands before
    // looking for interpreter script paths. Registry owns the display strings.
    if let Some(detected) = detect_app(&argv.join(" "))
        && let Some(provider) = COMMAND_NAME_MAP
            .values()
            .copied()
            .find(|name| *name == detected)
    {
        return Some(provider);
    }
    // Wrapper argv has already been checked by detect_app. Restrict basename
    // matching of later path arguments to script runtimes, so commands such as
    // `pnpm install /tmp/opencode` or `npx unrelated /tmp/opencode` stay negative.
    if !SCRIPT_RUNTIME_PATHS.contains(&base.as_str()) {
        return None;
    }
    for (index, token) in argv.iter().enumerate() {
        let normalized = process_token(token);
        if index == 0 {
            if !SKIPPED.contains(&normalized.as_str())
                && let Some(provider) = COMMAND_NAME_MAP.get(normalized.as_str())
            {
                return Some(*provider);
            }
            continue;
        }
        if token.starts_with('-')
            || !(token.contains('/')
                || token.contains('\\')
                || token.starts_with('.')
                || token.starts_with('~')
                || token.contains("node_modules")
                || token.contains(".bin"))
        {
            continue;
        }
        if let Some(provider) = COMMAND_NAME_MAP.get(normalized.as_str()) {
            return Some(*provider);
        }
    }
    None
}
#[cfg(test)]
mod tests {
    use super::*;
    fn row(pid: u32, parent_pid: u32, command: &str, argv: &[&str]) -> ProcessRow {
        ProcessRow {
            pid,
            parent_pid,
            command: command.into(),
            argv: argv.iter().map(|s| s.to_string()).collect(),
        }
    }
    #[test]
    fn observed_descendant_names_exclude_other_shells_and_terminate_cycles() {
        let snapshot = Snapshot::from_rows([
            row(1, 3, "zsh", &[]),
            row(2, 1, "/owned/chau7-next-helper", &[]),
            row(3, 2, "C:\\owned\\mcp-bridge", &[]),
            row(5, 9, "unrelated", &[]),
        ]);
        assert_eq!(
            snapshot.descendant_names(1),
            ["chau7-next-helper", "mcp-bridge"]
        );
        assert!(snapshot.descendant_names(0).is_empty());
    }
    #[test]
    fn nearest_agent_wins_over_child_tools_and_cycles_terminate() {
        let s = Snapshot::from_rows([
            row(2, 1, "bash", &[]),
            row(3, 2, "codex", &[]),
            row(4, 3, "claude", &[]),
        ]);
        assert_eq!(s.resolve(1), Some("Codex"));
        assert_eq!(s.resolve(3), Some("Claude"));
        assert_eq!(s.resolve(0), None);
        let s = Snapshot::from_rows([row(2, 1, "bash", &[]), row(1, 2, "zsh", &[])]);
        assert_eq!(s.resolve(1), None);
    }
    #[test]
    fn interpreter_scripts_match_but_literal_payload_does_not() {
        assert_eq!(
            match_process(
                "node",
                &["node".into(), "/opt/node_modules/.bin/claude.js".into()]
            ),
            Some("Claude")
        );
        assert_eq!(
            match_process("python3", &["python3".into(), "C:\\tools\\codex.py".into()]),
            Some("Codex")
        );
        assert_eq!(
            match_process(
                "node",
                &[
                    "node".into(),
                    "server.js".into(),
                    "--message".into(),
                    "claude".into()
                ]
            ),
            None
        );
        assert_eq!(
            match_process("echo", &["echo".into(), "codex".into()]),
            None
        );
        assert_eq!(match_process("claude-helper", &[]), None);
    }
    #[test]
    fn opencode_process_tree_resolves_binary_and_supported_package_runners() {
        assert!(INTERPRETERS.contains(&"bun"));
        assert!(INTERPRETERS.contains(&"bunx"));
        assert!(INTERPRETERS.contains(&"pnpm"));

        for (command, args) in [
            ("opencode", vec!["opencode", "--session", "ses_123"]),
            ("npx", vec!["npx", "opencode-ai"]),
            ("bunx", vec!["bunx", "opencode-ai"]),
            ("bun", vec!["bun", "x", "opencode-ai"]),
            ("pnpm", vec!["pnpm", "dlx", "opencode-ai"]),
        ] {
            let args: Vec<_> = args.into_iter().map(str::to_string).collect();
            let snapshot = Snapshot::from_rows([
                row(2, 1, "zsh", &[]),
                ProcessRow {
                    pid: 3,
                    parent_pid: 2,
                    command: command.to_string(),
                    argv: args,
                },
            ]);
            assert_eq!(snapshot.resolve(1), Some("OpenCode"), "{command}");
        }
    }

    #[test]
    fn process_path_fallback_is_limited_to_known_interpreters() {
        assert_eq!(
            match_process("cat", &["cat".into(), "/tmp/opencode".into()]),
            None
        );
        assert_eq!(
            match_process("vim", &["vim".into(), "/tmp/claude".into()]),
            None
        );
        for (command, args) in [
            ("pnpm", vec!["pnpm", "install", "/tmp/opencode"]),
            ("bun", vec!["bun", "install", "/tmp/opencode"]),
            ("npx", vec!["npx", "unrelated", "/tmp/opencode"]),
            ("bunx", vec!["bunx", "unrelated", "/tmp/opencode"]),
        ] {
            let args: Vec<_> = args.into_iter().map(str::to_string).collect();
            assert_eq!(match_process(command, &args), None, "{command}");
        }
        assert_eq!(
            match_process("node", &["node".into(), "/opt/tools/opencode".into()]),
            Some("OpenCode")
        );
    }

    #[test]
    fn fallback_parse_preserves_paths_and_deterministic_sibling_order() {
        let s = Snapshot::parse(
            "PID PPID ARGS\n 6 1 /usr/bin/node '/path with spaces/claude.js'\n 4 1 /opt/codex\nmalformed\n",
        );
        assert_eq!(s.resolve(1), Some("Codex"));
        assert_eq!(s.rows[&6].argv[1], "/path with spaces/claude.js");
    }
    #[test]
    fn duplicate_pid_uses_latest_parent_without_stale_adjacency() {
        let s = Snapshot::from_rows([row(2, 1, "claude", &[]), row(2, 9, "claude", &[])]);
        assert_eq!(s.resolve(1), None);
        assert_eq!(s.resolve(9), Some("Claude"));
    }
    #[test]
    fn launch_wrappers_and_package_executables_follow_current_registry() {
        for (command, args, expected) in [
            ("npx", vec!["npx", "claude"], "Claude"),
            ("env", vec!["env", "MODE=x", "codex"], "Codex"),
            ("gh", vec!["gh", "copilot", "suggest"], "Copilot"),
        ] {
            let args: Vec<_> = args.into_iter().map(str::to_string).collect();
            assert_eq!(match_process(command, &args), Some(expected));
        }
    }
}
