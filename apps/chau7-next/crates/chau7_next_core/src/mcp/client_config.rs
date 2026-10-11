//! Registers the MCP bridge in the configs of AI coding tools
//! (`MCPServerManager.registerMCPWithAllTools`).
//!
//! | Tool | File | Only when |
//! |---|---|---|
//! | Claude Code | `~/.claude.json` (`mcpServers`) | the file or `~/.claude/` exists |
//! | Codex | `~/.codex/config.toml` (`[mcp_servers.<name>]`) | the file exists |
//! | Cursor | `~/.cursor/mcp.json` (`mcpServers`) | `~/.cursor/` exists |
//! | Windsurf | `~/.codeium/windsurf/mcp_config.json` (`mcpServers`) | `~/.codeium/windsurf/` exists |
//!
//! Chau7 Next writes only its own entry ([`crate::data_root::MCP_SERVER_NAME`],
//! `chau7-next`) and never the Swift app's `chau7` entry. Everything else in
//! the files is kept: JSON values (and key order, since the app is built with
//! serde_json's `preserve_order`; Swift sorted every key), TOML line by line. A file is rewritten only when the entry changes, atomically
//! (temporary file in the same folder, then rename), with the original
//! permissions, and through symbolic links (dotfile managers). A JSON file
//! that exists but does not parse as an object is left alone.

use std::io::Write;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

/// What the configs launch: the bridge binary and its arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerEntry {
    pub command: String,
    pub args: Vec<String>,
}

impl ServerEntry {
    fn json(&self) -> Value {
        let mut map = Map::new();
        map.insert("command".into(), Value::String(self.command.clone()));
        map.insert(
            "args".into(),
            Value::Array(self.args.iter().cloned().map(Value::String).collect()),
        );
        Value::Object(map)
    }
}

/// Which tool a config belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Client {
    ClaudeCode,
    Codex,
    Cursor,
    Windsurf,
}

impl Client {
    pub const ALL: [Client; 4] = [
        Client::ClaudeCode,
        Client::Codex,
        Client::Cursor,
        Client::Windsurf,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Client::ClaudeCode => "Claude Code",
            Client::Codex => "Codex",
            Client::Cursor => "Cursor",
            Client::Windsurf => "Windsurf",
        }
    }

    /// The config file under `home`.
    pub fn config_path(self, home: &Path) -> PathBuf {
        match self {
            Client::ClaudeCode => home.join(".claude.json"),
            Client::Codex => home.join(".codex").join("config.toml"),
            Client::Cursor => home.join(".cursor").join("mcp.json"),
            Client::Windsurf => home
                .join(".codeium")
                .join("windsurf")
                .join("mcp_config.json"),
        }
    }

    /// Whether the tool looks installed (never litter `home` otherwise).
    pub fn is_installed(self, home: &Path) -> bool {
        match self {
            Client::ClaudeCode => self.config_path(home).exists() || home.join(".claude").exists(),
            Client::Codex => self.config_path(home).exists(),
            Client::Cursor => home.join(".cursor").exists(),
            Client::Windsurf => home.join(".codeium").join("windsurf").exists(),
        }
    }
}

/// Outcome of one registration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The tool is not installed: nothing written.
    NotInstalled,
    /// The entry was already up to date.
    Unchanged,
    Written,
    /// The file exists but is not a JSON object: left alone.
    SkippedInvalid,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MergeError {
    /// Existing content does not parse as a JSON object.
    NotAnObject,
    /// `mcpServers` exists but is not an object: left alone rather than
    /// replaced (it belongs to the user or another tool).
    ServersNotAnObject,
}

/// Set `mcpServers.<name>` in a JSON config. `existing` is the file content
/// (`None` when the file does not exist). Returns the new content, or
/// `Ok(None)` when the entry is already there with the same values.
pub fn merge_json(
    existing: Option<&str>,
    name: &str,
    entry: &ServerEntry,
) -> Result<Option<String>, MergeError> {
    let mut root = match existing {
        None => Map::new(),
        Some(text) => match serde_json::from_str::<Value>(text) {
            Ok(Value::Object(map)) => map,
            _ => return Err(MergeError::NotAnObject),
        },
    };
    let wanted = entry.json();
    let servers = root
        .entry("mcpServers")
        .or_insert_with(|| Value::Object(Map::new()));
    let Some(servers) = servers.as_object_mut() else {
        return Err(MergeError::ServersNotAnObject);
    };
    if existing.is_some() && servers.get(name) == Some(&wanted) {
        return Ok(None);
    }
    servers.insert(name.to_string(), wanted);
    serde_json::to_string_pretty(&Value::Object(root))
        .map(|mut text| {
            text.push('\n');
            Some(text)
        })
        .map_err(|_| MergeError::NotAnObject)
}

/// A TOML basic string.
fn toml_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn toml_array(items: &[String]) -> String {
    let inner: Vec<String> = items.iter().map(|s| toml_string(s)).collect();
    format!("[{}]", inner.join(", "))
}

/// Whether a trimmed line assigns `key` (`key = ...` or `key=...`).
fn assigns(trimmed: &str, key: &str) -> bool {
    trimmed.strip_prefix(key).is_some_and(|rest| {
        rest.starts_with(' ') || rest.starts_with('=') || rest.starts_with('\t')
    })
}

/// Set `[mcp_servers.<name>]` in a Codex `config.toml`
/// (`registerCodex`). When the table exists, its `command` and `args`
/// lines are replaced (or added at the end of the table); otherwise the
/// table is inserted before `[features]`, or appended. Other tables, the
/// Swift app's `[mcp_servers.chau7]` included, are not touched. Returns
/// `None` when nothing changes.
pub fn merge_codex_toml(content: &str, name: &str, entry: &ServerEntry) -> Option<String> {
    let header = format!("[mcp_servers.{name}]");
    let quoted_header = format!("[mcp_servers.\"{name}\"]");
    let command_line = format!("command = {}", toml_string(&entry.command));
    let args_line = format!("args = {}", toml_array(&entry.args));
    let lines: Vec<&str> = content.split('\n').collect();
    let start = lines.iter().position(|l| {
        let t = l.trim();
        t == header || t == quoted_header
    });
    let new_content = match start {
        Some(start) => {
            let mut out: Vec<String> = lines[..=start].iter().map(|s| s.to_string()).collect();
            let mut i = start + 1;
            let mut wrote_command = false;
            let mut wrote_args = false;
            // Lines of our table, up to the next header.
            while i < lines.len() && !lines[i].trim_start().starts_with('[') {
                let trimmed = lines[i].trim_start();
                if assigns(trimmed, "command") {
                    out.push(command_line.clone());
                    wrote_command = true;
                } else if assigns(trimmed, "args") {
                    out.push(args_line.clone());
                    wrote_args = true;
                    // A multi-line array: skip to its closing bracket.
                    if !trimmed.contains(']') {
                        while i + 1 < lines.len() && !lines[i].contains(']') {
                            i += 1;
                        }
                    }
                } else {
                    out.push(lines[i].to_string());
                }
                i += 1;
            }
            // Missing keys go after the table's last non-blank line.
            let mut insert_at = out.len();
            while insert_at > start + 1 && out[insert_at - 1].trim().is_empty() {
                insert_at -= 1;
            }
            if !wrote_args {
                out.insert(insert_at, args_line.clone());
            }
            if !wrote_command {
                out.insert(insert_at, command_line.clone());
            }
            out.extend(lines[i..].iter().map(|s| s.to_string()));
            out.join("\n")
        }
        None => {
            let section = format!("\n{header}\n{command_line}\n{args_line}\n");
            let mut text = content.to_string();
            match text.find("\n[features]") {
                Some(at) => text.insert_str(at, &section),
                None => {
                    if !text.is_empty() && !text.ends_with('\n') {
                        text.push('\n');
                    }
                    text.push_str(&section);
                }
            }
            text
        }
    };
    (new_content != content).then_some(new_content)
}

/// Write `text` to `path` atomically: a temporary file in the same folder
/// (permissions copied from the existing file), then a rename. A symbolic
/// link is followed so the link itself stays in place.
pub fn write_atomically(path: &Path, text: &str) -> std::io::Result<()> {
    write_checked(path, text, None)
}

/// Like [`write_atomically`], but the file is read again right before the
/// rename and nothing is written when it is no longer `expected` (`None`:
/// absent), because another tool (Claude Code rewrites `~/.claude.json`
/// often) changed it since it was read. That case is a `WouldBlock` error, so
/// the caller merges again.
pub fn write_if_unchanged(path: &Path, expected: Option<&str>, text: &str) -> std::io::Result<()> {
    write_checked(path, text, Some(expected))
}

fn write_checked(path: &Path, text: &str, expected: Option<Option<&str>>) -> std::io::Result<()> {
    let target = match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => std::fs::canonicalize(path)?,
        _ => path.to_path_buf(),
    };
    let dir = target
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    std::fs::create_dir_all(&dir)?;
    let file_name = target
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "config".into());
    let tmp = dir.join(format!(
        ".{file_name}.chau7-next-{}.tmp",
        std::process::id()
    ));
    let result = (|| {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        if let Ok(meta) = std::fs::metadata(&target) {
            std::fs::set_permissions(&tmp, meta.permissions())?;
        }
        if let Some(expected) = expected {
            let current = match std::fs::read_to_string(&target) {
                Ok(text) => Some(text),
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => None,
                Err(err) => return Err(err),
            };
            if current.as_deref() != expected {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "changed by another program while updating",
                ));
            }
        }
        std::fs::rename(&tmp, &target)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// Register `entry` under `name` in one tool's config.
pub fn register(client: Client, home: &Path, name: &str, entry: &ServerEntry) -> Outcome {
    if !client.is_installed(home) {
        return Outcome::NotInstalled;
    }
    let path = client.config_path(home);
    // Read, merge, and write only if nobody changed the file meanwhile;
    // otherwise merge again from the new content.
    for _ in 0..5 {
        let existing = match std::fs::read_to_string(&path) {
            Ok(text) => Some(text),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => None,
            Err(err) => return Outcome::Failed(err.to_string()),
        };
        let new_text = match client {
            Client::Codex => {
                let Some(content) = existing.as_deref() else {
                    return Outcome::NotInstalled;
                };
                merge_codex_toml(content, name, entry)
            }
            _ => match merge_json(existing.as_deref(), name, entry) {
                Ok(text) => text,
                Err(MergeError::NotAnObject) => return Outcome::SkippedInvalid,
                Err(MergeError::ServersNotAnObject) => {
                    log::warn!(
                        "MCP: {}: mcpServers is not an object; not changed",
                        path.display()
                    );
                    return Outcome::SkippedInvalid;
                }
            },
        };
        let Some(text) = new_text else {
            return Outcome::Unchanged;
        };
        match write_if_unchanged(&path, existing.as_deref(), &text) {
            Ok(()) => return Outcome::Written,
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(err) => return Outcome::Failed(err.to_string()),
        }
    }
    Outcome::Failed("the file kept changing while updating it".into())
}

/// Register in every tool, in the Swift order (Claude Code, Codex, Cursor,
/// Windsurf).
pub fn register_all(home: &Path, name: &str, entry: &ServerEntry) -> Vec<(Client, Outcome)> {
    Client::ALL
        .into_iter()
        .map(|client| (client, register(client, home, name, entry)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry() -> ServerEntry {
        ServerEntry {
            command: "/Users/me/.chau7-next/bin/chau7-next-mcp-bridge".into(),
            args: vec!["--socket".into(), "/Users/me/.chau7-next/mcp.sock".into()],
        }
    }

    fn temp_home(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chau7-next-mcp-cfg-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    const CLAUDE_SAMPLE: &str = r#"{
  "numStartups": 42,
  "projects": {"/repo": {"allowedTools": ["Bash"]}},
  "mcpServers": {
    "chau7": {"command": "/opt/swift-chau7/bin/chau7-mcp-bridge", "args": []},
    "github": {"type": "http", "url": "https://example.com/mcp"}
  },
  "zeta": [1, 2, 3]
}"#;

    #[test]
    fn json_adds_own_entry_and_keeps_everything_else() {
        let text = merge_json(Some(CLAUDE_SAMPLE), "chau7-next", &entry())
            .unwrap()
            .unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        let before: Value = serde_json::from_str(CLAUDE_SAMPLE).unwrap();
        assert_eq!(v["numStartups"], 42);
        assert_eq!(v["projects"], before["projects"]);
        assert_eq!(v["zeta"], before["zeta"]);
        assert_eq!(v["mcpServers"]["chau7"], before["mcpServers"]["chau7"]);
        assert_eq!(v["mcpServers"]["github"], before["mcpServers"]["github"]);
        assert_eq!(
            v["mcpServers"]["chau7-next"]["command"],
            "/Users/me/.chau7-next/bin/chau7-next-mcp-bridge"
        );
        assert_eq!(
            v["mcpServers"]["chau7-next"]["args"],
            serde_json::json!(["--socket", "/Users/me/.chau7-next/mcp.sock"])
        );
        // (Key order is kept when serde_json's `preserve_order` is on, as in
        // the app build; a core-only build sorts keys like Swift did.)
        assert_eq!(v.as_object().unwrap().len(), 4);
        // Second pass: nothing to do.
        assert_eq!(merge_json(Some(&text), "chau7-next", &entry()), Ok(None));
    }

    #[test]
    fn json_updates_a_stale_entry() {
        let mut old = entry();
        old.command = "/old/bridge".into();
        let first = merge_json(None, "chau7-next", &old).unwrap().unwrap();
        let second = merge_json(Some(&first), "chau7-next", &entry())
            .unwrap()
            .unwrap();
        let v: Value = serde_json::from_str(&second).unwrap();
        assert_eq!(v["mcpServers"]["chau7-next"]["command"], entry().command);
    }

    #[test]
    fn json_rejects_invalid_files() {
        assert_eq!(
            merge_json(Some("{not json"), "chau7-next", &entry()),
            Err(MergeError::NotAnObject)
        );
        assert_eq!(
            merge_json(Some(""), "chau7-next", &entry()),
            Err(MergeError::NotAnObject)
        );
        assert_eq!(
            merge_json(Some("[1]"), "chau7-next", &entry()),
            Err(MergeError::NotAnObject)
        );
    }

    #[test]
    fn json_refuses_a_non_object_server_map() {
        assert_eq!(
            merge_json(Some(r#"{"mcpServers": 3}"#), "chau7-next", &entry()),
            Err(MergeError::ServersNotAnObject)
        );
    }

    #[test]
    fn write_refuses_when_the_file_changed_since_the_read() {
        let home = temp_home("changed");
        let path = home.join("c.json");
        std::fs::write(&path, "{\"a\":1}").unwrap();
        let err = write_if_unchanged(&path, Some("{}"), "{\"b\":2}").unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::WouldBlock);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{\"a\":1}");
        write_if_unchanged(&path, Some("{\"a\":1}"), "{\"b\":2}").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{\"b\":2}");
        // Expected absent, but another tool created it.
        assert!(write_if_unchanged(&path, None, "x").is_err());
        let _ = std::fs::remove_dir_all(&home);
    }

    const CODEX_SAMPLE: &str = "model = \"o3\"\n\n[mcp_servers.chau7]\ncommand = \"/opt/swift-chau7/bin/chau7-mcp-bridge\"\nargs = []\n\n[mcp_servers.other]\ncommand = \"npx\"\nargs = [\"-y\", \"thing\"]\n\n[features]\nweb_search = true\n";

    #[test]
    fn codex_inserts_before_features_and_keeps_chau7() {
        let out = merge_codex_toml(CODEX_SAMPLE, "chau7-next", &entry()).unwrap();
        assert!(out.contains(
            "[mcp_servers.chau7]\ncommand = \"/opt/swift-chau7/bin/chau7-mcp-bridge\"\nargs = []\n"
        ));
        assert!(
            out.contains("[mcp_servers.other]\ncommand = \"npx\"\nargs = [\"-y\", \"thing\"]\n")
        );
        let ours = "\n[mcp_servers.chau7-next]\ncommand = \"/Users/me/.chau7-next/bin/chau7-next-mcp-bridge\"\nargs = [\"--socket\", \"/Users/me/.chau7-next/mcp.sock\"]\n";
        assert!(out.contains(ours), "{out}");
        assert!(out.find(ours).unwrap() < out.find("[features]").unwrap());
        assert!(out.ends_with("[features]\nweb_search = true\n"));
        // Idempotent.
        assert_eq!(merge_codex_toml(&out, "chau7-next", &entry()), None);
    }

    #[test]
    fn codex_appends_without_features() {
        let out = merge_codex_toml("model = \"o3\"", "chau7-next", &entry()).unwrap();
        assert!(out.starts_with("model = \"o3\"\n\n[mcp_servers.chau7-next]\n"));
        assert!(out.ends_with("mcp.sock\"]\n"));
    }

    #[test]
    fn codex_updates_existing_table_in_place() {
        let content = "[mcp_servers.chau7-next]\ncommand = \"/old\"\nargs = [\n  \"--socket\",\n  \"/old.sock\",\n]\nenv = { A = \"1\" }\n\n[mcp_servers.chau7]\ncommand = \"/swift\"\n";
        let out = merge_codex_toml(content, "chau7-next", &entry()).unwrap();
        assert_eq!(
            out,
            "[mcp_servers.chau7-next]\ncommand = \"/Users/me/.chau7-next/bin/chau7-next-mcp-bridge\"\nargs = [\"--socket\", \"/Users/me/.chau7-next/mcp.sock\"]\nenv = { A = \"1\" }\n\n[mcp_servers.chau7]\ncommand = \"/swift\"\n"
        );
    }

    #[test]
    fn codex_adds_missing_keys_at_end_of_table() {
        let content = "[mcp_servers.chau7-next]\nenabled = true\n\n[other]\nx = 1\n";
        let out = merge_codex_toml(content, "chau7-next", &entry()).unwrap();
        assert!(out.starts_with(
            "[mcp_servers.chau7-next]\nenabled = true\ncommand = \"/Users/me/.chau7-next/bin/chau7-next-mcp-bridge\"\nargs = "
        ));
        assert!(out.ends_with("\n\n[other]\nx = 1\n"));
    }

    #[test]
    fn codex_does_not_mistake_command_prefixes() {
        let content =
            "[mcp_servers.chau7-next]\ncommand_timeout = 5\ncommand = \"/old\"\nargs = []\n";
        let out = merge_codex_toml(content, "chau7-next", &entry()).unwrap();
        assert!(out.contains("command_timeout = 5\n"));
    }

    #[test]
    fn toml_strings_are_escaped() {
        assert_eq!(toml_string(r#"a"b\c"#), r#""a\"b\\c""#);
    }

    #[test]
    fn register_all_respects_installed_tools() {
        let home = temp_home("all");
        // Claude Code (folder only), Cursor; no Codex file, no Windsurf.
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        std::fs::create_dir_all(home.join(".cursor")).unwrap();
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        let outcomes = register_all(&home, "chau7-next", &entry());
        assert_eq!(
            outcomes,
            vec![
                (Client::ClaudeCode, Outcome::Written),
                (Client::Codex, Outcome::NotInstalled),
                (Client::Cursor, Outcome::Written),
                (Client::Windsurf, Outcome::NotInstalled),
            ]
        );
        assert!(home.join(".claude.json").exists());
        assert!(!home.join(".codex/config.toml").exists());
        assert!(!home.join(".codeium").exists());
        // Second run changes nothing.
        let again = register_all(&home, "chau7-next", &entry());
        assert_eq!(again[0].1, Outcome::Unchanged);
        assert_eq!(again[2].1, Outcome::Unchanged);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn register_skips_invalid_json_and_keeps_it() {
        let home = temp_home("invalid");
        std::fs::write(home.join(".claude.json"), "{oops").unwrap();
        assert_eq!(
            register(Client::ClaudeCode, &home, "chau7-next", &entry()),
            Outcome::SkippedInvalid
        );
        assert_eq!(
            std::fs::read_to_string(home.join(".claude.json")).unwrap(),
            "{oops"
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn register_codex_and_windsurf_files() {
        let home = temp_home("codex");
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        std::fs::write(home.join(".codex/config.toml"), CODEX_SAMPLE).unwrap();
        std::fs::create_dir_all(home.join(".codeium/windsurf")).unwrap();
        assert_eq!(
            register(Client::Codex, &home, "chau7-next", &entry()),
            Outcome::Written
        );
        assert_eq!(
            register(Client::Windsurf, &home, "chau7-next", &entry()),
            Outcome::Written
        );
        let codex = std::fs::read_to_string(home.join(".codex/config.toml")).unwrap();
        assert!(codex.contains("[mcp_servers.chau7]\n"));
        assert!(codex.contains("[mcp_servers.chau7-next]\n"));
        let windsurf =
            std::fs::read_to_string(home.join(".codeium/windsurf/mcp_config.json")).unwrap();
        let v: Value = serde_json::from_str(&windsurf).unwrap();
        assert_eq!(v["mcpServers"]["chau7-next"]["command"], entry().command);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[cfg(unix)]
    #[test]
    fn atomic_write_keeps_permissions_and_symlinks() {
        use std::os::unix::fs::PermissionsExt;
        let home = temp_home("atomic");
        let real = home.join("dotfiles").join("claude.json");
        std::fs::create_dir_all(real.parent().unwrap()).unwrap();
        std::fs::write(&real, "{}").unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o600)).unwrap();
        let link = home.join(".claude.json");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert_eq!(
            register(Client::ClaudeCode, &home, "chau7-next", &entry()),
            Outcome::Written
        );
        assert!(
            std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        let mode = std::fs::metadata(&real).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert!(
            std::fs::read_to_string(&real)
                .unwrap()
                .contains("chau7-next")
        );
        // No temporary file left behind.
        let leftovers = std::fs::read_dir(real.parent().unwrap())
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".tmp")
            })
            .count();
        assert_eq!(leftovers, 0);
        let _ = std::fs::remove_dir_all(&home);
    }
}
