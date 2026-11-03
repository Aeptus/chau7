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
//! serde_json's `preserve_order`; Swift sorted every key), editable TOML syntax. A file is rewritten only when the entry changes, atomically
//! (temporary file in the same folder, then rename), with the original
//! permissions, and through symbolic links (dotfile managers). A JSON file
//! that exists but does not parse as an object is left alone.

use std::io::Write;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};
use toml_edit::{Array, DocumentMut, InlineTable, Item, Table, TableLike, Value as TomlValue};

/// What the configs launch: the bridge binary and its arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerEntry {
    pub command: String,
    pub args: Vec<String>,
}

/// A direct HTTP endpoint. The bearer credential must never appear in logs.
#[derive(Clone)]
pub struct HttpEntry {
    pub url: String,
    pub(crate) authorization: String,
}

#[derive(Clone, Copy)]
enum Transport<'a> {
    Stdio(&'a ServerEntry),
    Http(&'a HttpEntry),
}

const TRANSPORT_KEYS: &[&str] = &[
    "command",
    "args",
    "type",
    "url",
    "headers",
    "http_headers",
    "bearer_token_env_var",
];

impl Transport<'_> {
    fn json(self) -> Value {
        match self {
            Self::Stdio(entry) => serde_json::json!({"command":entry.command,"args":entry.args}),
            Self::Http(entry) => {
                serde_json::json!({"type":"http","url":entry.url,"headers":{"Authorization":entry.authorization}})
            }
        }
    }

    fn matches(self, server: &dyn TableLike) -> bool {
        let wanted = self.toml(server.get("args").and_then(Item::as_array));
        if TRANSPORT_KEYS
            .iter()
            .any(|key| server.get(key).is_some() && !wanted.iter().any(|(wanted, _)| wanted == key))
        {
            return false;
        }
        match self {
            Self::Stdio(entry) => {
                server.get("command").and_then(Item::as_str) == Some(entry.command.as_str())
                    && server
                        .get("args")
                        .and_then(Item::as_array)
                        .is_some_and(|args| {
                            args.len() == entry.args.len()
                                && args.iter().zip(&entry.args).all(|(actual, wanted)| {
                                    actual.as_str() == Some(wanted.as_str())
                                })
                        })
            }
            Self::Http(entry) => {
                server.get("url").and_then(Item::as_str) == Some(entry.url.as_str())
                    && server
                        .get("http_headers")
                        .and_then(Item::as_table_like)
                        .is_some_and(|headers| {
                            headers.len() == 1
                                && headers.get("Authorization").and_then(Item::as_str)
                                    == Some(entry.authorization.as_str())
                        })
            }
        }
    }

    fn toml(self, previous_args: Option<&Array>) -> Vec<(&'static str, TomlValue)> {
        match self {
            Self::Stdio(entry) => vec![
                ("command", entry.command.as_str().into()),
                (
                    "args",
                    TomlValue::Array(replacement_args(previous_args, &entry.args)),
                ),
            ],
            Self::Http(entry) => {
                let mut headers = InlineTable::new();
                headers.insert("Authorization", entry.authorization.as_str().into());
                vec![
                    ("url", entry.url.as_str().into()),
                    ("http_headers", TomlValue::InlineTable(headers)),
                ]
            }
        }
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
    merge_json_transport(existing, name, Transport::Stdio(entry))
}

fn merge_json_transport(
    existing: Option<&str>,
    name: &str,
    entry: Transport<'_>,
) -> Result<Option<String>, MergeError> {
    let mut root = match existing {
        None => Map::new(),
        Some(text) => match serde_json::from_str::<Value>(text) {
            Ok(Value::Object(map)) => map,
            _ => return Err(MergeError::NotAnObject),
        },
    };
    let mut wanted = root
        .get("mcpServers")
        .and_then(|servers| servers.get(name))
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    for key in TRANSPORT_KEYS {
        wanted.remove(*key);
    }
    wanted.extend(entry.json().as_object().expect("transport object").clone());
    let wanted = Value::Object(wanted);
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
/// Upsert only the requested Codex server. Parse before editing so quoted or
/// commented headers, multiline strings/arrays and inline tables cannot be
/// mistaken for section boundaries. Invalid TOML or server shapes are untouched.
pub fn merge_codex_toml(content: &str, name: &str, entry: &ServerEntry) -> Option<String> {
    try_merge_codex_toml(content, name, Transport::Stdio(entry))
        .ok()
        .flatten()
}

fn try_merge_codex_toml(
    content: &str,
    name: &str,
    entry: Transport<'_>,
) -> Result<Option<String>, ()> {
    let mut document = content.parse::<DocumentMut>().map_err(|_| ())?;
    let servers = document
        .get("mcp_servers")
        .map(|item| item.as_table_like().ok_or(()))
        .transpose()?;
    let existing = servers.and_then(|servers| servers.get(name));
    if let Some(server) = existing {
        let server = server.as_table_like().ok_or(())?;
        if entry.matches(server) {
            return Ok(None);
        }
    }
    let new_server = existing.is_none();
    let inline_parent = document
        .get("mcp_servers")
        .is_some_and(|item| item.as_inline_table().is_some());
    let position = if new_server && !inline_parent {
        let before_features = document
            .get("features")
            .and_then(Item::as_table)
            .and_then(Table::position);
        let mut max = 0;
        walk_tables(document.as_table_mut(), &mut |table| {
            max = max.max(table.position().unwrap_or(0))
        });
        let position = before_features.unwrap_or(max.saturating_add(1));
        walk_tables(document.as_table_mut(), &mut |table| {
            if let Some(old) = table.position().filter(|old| *old >= position) {
                table.set_position(Some(old.saturating_add(1)));
            }
        });
        position
    } else {
        0
    };
    if document.get("mcp_servers").is_none() {
        let mut servers = Table::new();
        servers.set_implicit(true);
        document
            .as_table_mut()
            .insert("mcp_servers", Item::Table(servers));
    }
    let servers = document
        .get_mut("mcp_servers")
        .and_then(Item::as_table_like_mut)
        .ok_or(())?;
    if new_server {
        let server = if inline_parent {
            Item::Value(TomlValue::InlineTable(InlineTable::new()))
        } else {
            let mut table = Table::new();
            table.set_position(Some(position));
            table.decor_mut().set_prefix("\n");
            Item::Table(table)
        };
        servers.insert(name, server);
    }
    let server = servers
        .get_mut(name)
        .and_then(Item::as_table_like_mut)
        .ok_or(())?;
    let wanted = entry.toml(server.get("args").and_then(Item::as_array));
    for key in TRANSPORT_KEYS {
        if !wanted.iter().any(|(wanted, _)| wanted == key) {
            server.remove(key);
        }
    }
    for (key, value) in wanted {
        replace_owned_value(server, key, value);
    }
    let output = document.to_string();
    // Defensive shape/layout validation, without logging user config content.
    output.parse::<DocumentMut>().map_err(|_| ())?;
    Ok((output != content).then_some(output))
}

fn walk_tables(table: &mut Table, visit: &mut impl FnMut(&mut Table)) {
    visit(table);
    for (_, item) in table.iter_mut() {
        if let Some(table) = item.as_table_mut() {
            walk_tables(table, visit);
        } else if let Some(tables) = item.as_array_of_tables_mut() {
            for table in tables.iter_mut() {
                walk_tables(table, visit);
            }
        }
    }
}

fn replace_owned_value(table: &mut dyn TableLike, key: &str, mut value: TomlValue) {
    if let Some(previous) = table.get(key).and_then(Item::as_value) {
        *value.decor_mut() = previous.decor().clone();
    }
    table.insert(key, Item::Value(value));
}

/// Keep argument comments when a previously formatted array contains them.
/// Old values themselves are always replaced, including obsolete extra args.
fn replacement_args(previous: Option<&Array>, args: &[String]) -> Array {
    let previous = previous.filter(|array| array.to_string().contains('#'));
    let mut array = Array::new();
    for (index, arg) in args.iter().enumerate() {
        let mut value = TomlValue::from(arg.as_str());
        if let Some(previous) = previous.and_then(|array| array.get(index)) {
            *value.decor_mut() = previous.decor().clone();
        }
        array.push_formatted(value);
    }
    if let Some(previous) = previous {
        let mut trailing = String::new();
        for removed in previous.iter().skip(args.len()) {
            for decoration in [removed.decor().prefix(), removed.decor().suffix()]
                .into_iter()
                .flatten()
            {
                if let Some(trivia) = decoration.as_str() {
                    trailing.push_str(trivia);
                }
            }
        }
        trailing.push_str(previous.trailing().as_str().unwrap_or_default());
        array.set_trailing(trailing);
        array.set_trailing_comma(previous.trailing_comma() && !args.is_empty());
    }
    array
}

/// Write `text` to `path` atomically: a temporary file in the same folder
/// (permissions copied from the existing file), then a rename. A symbolic
/// link is followed so the link itself stays in place.
pub fn write_atomically(path: &Path, text: &str) -> std::io::Result<()> {
    write_checked(path, text, None, false)
}

/// Like [`write_atomically`], but the file is read again right before the
/// rename and nothing is written when it is no longer `expected` (`None`:
/// absent), because another tool (Claude Code rewrites `~/.claude.json`
/// often) changed it since it was read. That case is a `WouldBlock` error, so
/// the caller merges again.
pub fn write_if_unchanged(path: &Path, expected: Option<&str>, text: &str) -> std::io::Result<()> {
    write_checked(path, text, Some(expected), false)
}

fn write_checked(
    path: &Path,
    text: &str,
    expected: Option<Option<&str>>,
    private: bool,
) -> std::io::Result<()> {
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
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        if !private && let Ok(meta) = std::fs::metadata(&target) {
            std::fs::set_permissions(&tmp, meta.permissions())?;
        }
        if private {
            make_private(&tmp)?;
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

fn make_private(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

/// Register compatible clients directly; other clients retain their stdio bridge.
pub fn register_http(client: Client, home: &Path, name: &str, entry: &HttpEntry) -> Outcome {
    if !matches!(client, Client::ClaudeCode | Client::Codex) {
        return Outcome::NotInstalled;
    }
    register_transport(client, home, name, Transport::Http(entry))
}

/// Register `entry` under `name` in one tool's config.
pub fn register(client: Client, home: &Path, name: &str, entry: &ServerEntry) -> Outcome {
    register_transport(client, home, name, Transport::Stdio(entry))
}

fn register_transport(client: Client, home: &Path, name: &str, entry: Transport<'_>) -> Outcome {
    let private = matches!(entry, Transport::Http(_));
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
                match try_merge_codex_toml(content, name, entry) {
                    Ok(text) => text,
                    Err(()) => return Outcome::SkippedInvalid,
                }
            }
            _ => match merge_json_transport(existing.as_deref(), name, entry) {
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
            if private && let Err(err) = make_private(&path) {
                return Outcome::Failed(err.to_string());
            }
            return Outcome::Unchanged;
        };
        match write_checked(&path, &text, Some(existing.as_deref()), private) {
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
        assert_eq!(TomlValue::from(r#"a"b\c"#).to_string(), r#"'a"b\c'"#);
    }

    fn assert_codex_entry(out: &str, wanted: &ServerEntry) -> DocumentMut {
        let doc = out
            .parse::<DocumentMut>()
            .expect("formatter output must remain valid TOML");
        let server = doc["mcp_servers"]["chau7-next"].as_table_like().unwrap();
        assert_eq!(
            server.get("command").and_then(Item::as_str),
            Some(wanted.command.as_str())
        );
        let args: Vec<_> = server
            .get("args")
            .and_then(Item::as_array)
            .unwrap()
            .iter()
            .map(|arg| arg.as_str().unwrap())
            .collect();
        assert_eq!(
            args,
            wanted.args.iter().map(String::as_str).collect::<Vec<_>>()
        );
        doc
    }

    #[test]
    fn codex_commented_and_quoted_headers_update_once_without_duplicate_tables() {
        for header in [
            "[mcp_servers.chau7-next] # own server",
            "[mcp_servers.\"chau7-next\"] # own server",
            "[ 'mcp_servers' . 'chau7-next' ] # own server",
        ] {
            let text = format!(
                "# user heading\n{header}\ncommand = '/old' # command note\nargs = [] # args note\nenabled = true\n\n[mcp_servers.chau7] # production\ncommand = '/swift'\n"
            );
            let out = merge_codex_toml(&text, "chau7-next", &entry()).unwrap();
            let doc = assert_codex_entry(&out, &entry());
            assert_eq!(
                doc["mcp_servers"]["chau7"]["command"].as_str(),
                Some("/swift")
            );
            for comment in [
                "# user heading",
                "# own server",
                "# command note",
                "# args note",
                "# production",
            ] {
                assert!(out.contains(comment), "lost {comment}");
            }
            assert_eq!(merge_codex_toml(&out, "chau7-next", &entry()), None);
        }
    }

    #[test]
    fn codex_multiline_args_do_not_end_at_brackets_inside_values_or_comments() {
        let text = r#"[mcp_servers.chau7-next] # own
command = "/old"
args = [
  "] is data", # ] is a comment
  '''literal
] and [features] are data''',
  "obsolete", # preserve this note
] # closing note
enabled = true

[mcp_servers.other]
command = "npx"
args = ["untouched]", "--flag"] # other note
"#;
        let out = merge_codex_toml(text, "chau7-next", &entry()).unwrap();
        let doc = assert_codex_entry(&out, &entry());
        assert_eq!(
            doc["mcp_servers"]["chau7-next"]["enabled"].as_bool(),
            Some(true)
        );
        assert_eq!(
            doc["mcp_servers"]["other"]["args"][0].as_str(),
            Some("untouched]")
        );
        for comment in [
            "# own",
            "# ] is a comment",
            "# preserve this note",
            "# closing note",
            "# other note",
        ] {
            assert!(out.contains(comment), "lost {comment}");
        }
        assert!(!out.contains("obsolete"));
        assert_eq!(merge_codex_toml(&out, "chau7-next", &entry()), None);
    }

    #[test]
    fn codex_fake_sections_in_multiline_strings_are_not_insertion_points() {
        let text = "description = '''keep this\n[features]\n[mcp_servers.chau7-next]\ncommand = \"not a config entry\"\n'''\n\n[features] # actual features\nweb_search = true\n";
        let out = merge_codex_toml(text, "chau7-next", &entry()).unwrap();
        let doc = assert_codex_entry(&out, &entry());
        assert!(out.contains("description = '''keep this\n[features]\n[mcp_servers.chau7-next]\ncommand = \"not a config entry\"\n'''"));
        assert_eq!(doc["features"]["web_search"].as_bool(), Some(true));
        assert!(out.contains("[features] # actual features"));
        assert_eq!(merge_codex_toml(&out, "chau7-next", &entry()), None);
    }

    #[test]
    fn codex_semantically_current_entry_keeps_its_exact_user_formatting() {
        let wanted = entry();
        let text = format!(
            "[mcp_servers.'chau7-next'] # keep\ncommand='{}'\nargs = [\n '{}', # first\n '{}',\n] # last\n",
            wanted.command, wanted.args[0], wanted.args[1]
        );
        assert_eq!(merge_codex_toml(&text, "chau7-next", &wanted), None);
    }

    #[test]
    fn codex_inline_and_dotted_tables_keep_unrelated_fields() {
        for text in [
            "mcp_servers = { chau7-next = { command = '/old', args = [], env = { SAFE = 'yes' } }, chau7 = { command = '/swift' } } # keep\nmodel = 'unchanged'\n",
            "mcp_servers.chau7-next.command = '/old'\nmcp_servers.chau7-next.args = []\nmcp_servers.chau7-next.env.SAFE = 'yes'\nmcp_servers.chau7.command = '/swift'\nmodel = 'unchanged'\n",
        ] {
            let out = merge_codex_toml(text, "chau7-next", &entry()).unwrap();
            let doc = assert_codex_entry(&out, &entry());
            assert_eq!(
                doc["mcp_servers"]["chau7-next"]["env"]["SAFE"].as_str(),
                Some("yes")
            );
            assert_eq!(
                doc["mcp_servers"]["chau7"]["command"].as_str(),
                Some("/swift")
            );
            assert_eq!(merge_codex_toml(&out, "chau7-next", &entry()), None);
        }
    }

    #[test]
    fn codex_argument_count_changes_preserve_comments_and_valid_syntax() {
        let text = "[mcp_servers.chau7-next]\ncommand = '/old'\nargs = [\n 'first', # first note\n 'second', # second note\n] # outer note\n";
        for count in 0..5 {
            let mut wanted = entry();
            wanted.args = (0..count).map(|i| format!("new-{i}")).collect();
            let out = merge_codex_toml(text, "chau7-next", &wanted).unwrap();
            assert_codex_entry(&out, &wanted);
            for comment in ["# first note", "# second note", "# outer note"] {
                assert!(
                    out.contains(comment),
                    "lost {comment} for {count} arguments"
                );
            }
            assert_eq!(merge_codex_toml(&out, "chau7-next", &wanted), None);
        }
    }

    #[test]
    fn codex_invalid_toml_or_server_shapes_are_refused_without_writing() {
        let home = temp_home("invalid-codex");
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        let path = home.join(".codex/config.toml");
        for text in [
            "model = [",
            "mcp_servers = false\n",
            "[mcp_servers]\nchau7-next = false\n",
            "[mcp_servers.chau7-next]\n[mcp_servers.chau7-next]\n",
        ] {
            assert_eq!(merge_codex_toml(text, "chau7-next", &entry()), None);
            std::fs::write(&path, text).unwrap();
            assert_eq!(
                register(Client::Codex, &home, "chau7-next", &entry()),
                Outcome::SkippedInvalid
            );
            assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
        }
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn codex_complex_escaped_values_round_trip_as_data() {
        let wanted = ServerEntry {
            command: "é /odd\" path\\next\nbridge".into(),
            args: vec!["] # not a comment".into(), "[not a table]".into()],
        };
        let out = merge_codex_toml("model = 'unchanged'\n", "chau7-next", &wanted).unwrap();
        assert_codex_entry(&out, &wanted);
        assert_eq!(merge_codex_toml(&out, "chau7-next", &wanted), None);
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

#[cfg(test)]
mod http_tests {
    use super::*;

    #[test]
    fn codex_round_trip_preserves_policy_and_removes_obsolete_transport_fields() {
        let original = "# keep\n[mcp_servers.chau7-next]\ncommand = \"bridge\"\nargs = []\nstartup_timeout_sec = 40 # policy\n[mcp_servers.other]\ncommand = \"other\"\n";
        let http = HttpEntry {
            url: "http://127.0.0.1:1234/mcp".into(),
            authorization: "Bearer private".into(),
        };
        let updated = try_merge_codex_toml(original, "chau7-next", Transport::Http(&http))
            .unwrap()
            .unwrap();
        assert!(updated.contains("# keep"));
        assert!(updated.contains("40 # policy"));
        let document: DocumentMut = updated.parse().unwrap();
        let entry = &document["mcp_servers"]["chau7-next"];
        assert_eq!(entry["url"].as_str(), Some(http.url.as_str()));
        assert!(entry.get("command").is_none());
        assert!(entry.get("args").is_none());
        assert_eq!(
            entry["http_headers"]["Authorization"].as_str(),
            Some("Bearer private")
        );
        assert_eq!(
            try_merge_codex_toml(&updated, "chau7-next", Transport::Http(&http)),
            Ok(None)
        );
        let stdio = ServerEntry {
            command: "bridge".into(),
            args: vec![],
        };
        let restored = merge_codex_toml(&updated, "chau7-next", &stdio).unwrap();
        let document: DocumentMut = restored.parse().unwrap();
        assert!(
            document["mcp_servers"]["chau7-next"]
                .get("http_headers")
                .is_none()
        );
        assert!(document["mcp_servers"]["chau7-next"].get("url").is_none());
        assert_eq!(
            document["mcp_servers"]["other"]["command"].as_str(),
            Some("other")
        );
    }

    #[cfg(unix)]
    #[test]
    fn http_json_registration_keeps_policy_and_makes_existing_configs_private() {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("chau7-http-config-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        let path = home.join(".claude.json");
        std::fs::write(&path, r#"{"mcpServers":{"chau7-next":{"command":"old","args":[],"disabled":false},"other":{"command":"other"}}}"#).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let http = HttpEntry {
            url: "http://127.0.0.1:1234/mcp".into(),
            authorization: "Bearer private".into(),
        };
        assert_eq!(
            register_http(Client::ClaudeCode, &home, "chau7-next", &http),
            Outcome::Written
        );
        let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(value["mcpServers"]["chau7-next"]["type"], "http");
        assert_eq!(
            value["mcpServers"]["chau7-next"]["headers"]["Authorization"],
            "Bearer private"
        );
        assert_eq!(value["mcpServers"]["chau7-next"]["disabled"], false);
        assert!(value["mcpServers"]["chau7-next"].get("command").is_none());
        assert_eq!(value["mcpServers"]["other"]["command"], "other");
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            register_http(Client::ClaudeCode, &home, "chau7-next", &http),
            Outcome::Unchanged
        );
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        std::fs::remove_dir_all(home).unwrap();
    }
}
