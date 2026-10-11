//! OpenSSH config file parsing and serialization.
//!
//! Port of `SSHConfigParser.swift` from `apps/chau7-macos/Sources/Chau7Core`.
//!
//! Differences from Swift: `SSHConfigEntry` has no `id: UUID` field (the
//! crate has no dependencies, so identity is left to the caller) and is not
//! `Codable`. `extra_options` is a `BTreeMap`, which keeps keys in the order
//! `serialize` writes them.

use std::collections::BTreeMap;

/// Parsed entry from an SSH config file.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SSHConfigEntry {
    /// `Host` pattern.
    pub host: String,
    /// `HostName`.
    pub hostname: Option<String>,
    /// `User`.
    pub user: Option<String>,
    /// `Port`. `None` when missing or not an integer.
    pub port: Option<i64>,
    /// `IdentityFile`.
    pub identity_file: Option<String>,
    /// `ProxyJump`.
    pub proxy_jump: Option<String>,
    /// `ForwardAgent` (`true` only for a case-insensitive `yes`).
    pub forward_agent: Option<bool>,
    /// Every other option, keyed by its original spelling.
    pub extra_options: BTreeMap<String, String>,
}

impl SSHConfigEntry {
    /// Creates an entry with only the `Host` pattern set.
    pub fn new(host: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            ..Self::default()
        }
    }

    /// Display-friendly name: `user@hostname`, `hostname`, or the host pattern.
    pub fn display_name(&self) -> String {
        match (&self.hostname, &self.user) {
            (Some(hostname), Some(user)) => format!("{user}@{hostname}"),
            (Some(hostname), None) => hostname.clone(),
            (None, _) => self.host.clone(),
        }
    }
}

/// Characters Foundation's `.newlines` set splits on.
fn is_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Foundation's `.whitespaces`: whitespace other than newlines.
fn is_horizontal_space(c: char) -> bool {
    c.is_whitespace() && !is_newline(c)
}

fn trim_spaces(s: &str) -> &str {
    s.trim_matches(is_horizontal_space)
}

/// Splits a trimmed config line into key and value. Supports `key value`,
/// `key=value` and `key = value` (the `=` form only when the text before
/// `=` has no space). Returns `None` when there is no separator.
fn split_key_value(trimmed: &str) -> Option<(&str, &str)> {
    if let Some((before, after)) = trimmed.split_once('=')
        && !before.contains(' ')
    {
        return Some((trim_spaces(before), trim_spaces(after)));
    }
    let (key, value) = trimmed.split_once(' ')?;
    Some((trim_spaces(key), trim_spaces(value)))
}

/// Parses SSH config file content into entries. Options before the first
/// `Host` line are ignored; comments and blank lines are skipped.
pub fn parse(content: &str) -> Vec<SSHConfigEntry> {
    let mut entries = Vec::new();
    let mut current: Option<SSHConfigEntry> = None;

    for line in content.split(is_newline) {
        let trimmed = trim_spaces(line);
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let Some((raw_key, value)) = split_key_value(trimmed) else {
            continue;
        };
        let key = raw_key.to_lowercase();

        if key == "host" {
            if let Some(entry) = current.take() {
                entries.push(entry);
            }
            current = Some(SSHConfigEntry::new(value));
        } else if let Some(entry) = current.as_mut() {
            let value_owned = value.to_string();
            match key.as_str() {
                "hostname" => entry.hostname = Some(value_owned),
                "user" => entry.user = Some(value_owned),
                "port" => entry.port = value.parse().ok(),
                "identityfile" => entry.identity_file = Some(value_owned),
                "proxyjump" => entry.proxy_jump = Some(value_owned),
                "forwardagent" => entry.forward_agent = Some(value.to_lowercase() == "yes"),
                _ => {
                    entry.extra_options.insert(raw_key.to_string(), value_owned);
                }
            }
        }
    }

    entries.extend(current);
    entries
}

/// Serializes entries back to SSH config format. Each entry ends with a
/// blank line; extra options are written sorted by key.
pub fn serialize(entries: &[SSHConfigEntry]) -> String {
    let mut lines: Vec<String> = Vec::new();

    for entry in entries {
        lines.push(format!("Host {}", entry.host));
        if let Some(v) = &entry.hostname {
            lines.push(format!("    HostName {v}"));
        }
        if let Some(v) = &entry.user {
            lines.push(format!("    User {v}"));
        }
        if let Some(v) = entry.port {
            lines.push(format!("    Port {v}"));
        }
        if let Some(v) = &entry.identity_file {
            lines.push(format!("    IdentityFile {v}"));
        }
        if let Some(v) = &entry.proxy_jump {
            lines.push(format!("    ProxyJump {v}"));
        }
        if let Some(v) = entry.forward_agent {
            lines.push(format!("    ForwardAgent {}", if v { "yes" } else { "no" }));
        }
        for (k, v) in &entry.extra_options {
            lines.push(format!("    {k} {v}"));
        }
        lines.push(String::new());
    }

    lines.join("\n")
}

#[cfg(test)]
mod tests {
    // Ported from SSHConfigParserTests.swift. No tests skipped (none need
    // AppKit). Adapted: testEntryEquatable compares entries without the
    // Swift `id`; testEntryCodable has no serde equivalent, so it checks a
    // serialize/parse round trip of the same entry instead.
    use super::*;

    fn entry(host: &str, hostname: Option<&str>, user: Option<&str>) -> SSHConfigEntry {
        SSHConfigEntry {
            hostname: hostname.map(str::to_string),
            user: user.map(str::to_string),
            ..SSHConfigEntry::new(host)
        }
    }

    // Parsing

    #[test]
    fn parse_standard_config() {
        let config = "Host myserver\n    HostName 192.168.1.100\n    User admin\n    Port 2222";
        let entries = parse(config);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].host, "myserver");
        assert_eq!(entries[0].hostname.as_deref(), Some("192.168.1.100"));
        assert_eq!(entries[0].user.as_deref(), Some("admin"));
        assert_eq!(entries[0].port, Some(2222));
    }

    #[test]
    fn parse_host_name_user_port_identity_file() {
        let config = "Host production\n    HostName prod.example.com\n    User deploy\n    Port 22\n    IdentityFile ~/.ssh/id_ed25519";
        let entries = parse(config);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].host, "production");
        assert_eq!(entries[0].hostname.as_deref(), Some("prod.example.com"));
        assert_eq!(entries[0].user.as_deref(), Some("deploy"));
        assert_eq!(entries[0].port, Some(22));
        assert_eq!(
            entries[0].identity_file.as_deref(),
            Some("~/.ssh/id_ed25519")
        );
    }

    #[test]
    fn parse_proxy_jump_and_forward_agent() {
        let config =
            "Host internal\n    HostName 10.0.0.5\n    ProxyJump bastion\n    ForwardAgent yes";
        let entries = parse(config);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].proxy_jump.as_deref(), Some("bastion"));
        assert_eq!(entries[0].forward_agent, Some(true));
    }

    #[test]
    fn parse_forward_agent_no() {
        let config = "Host noagent\n    HostName example.com\n    ForwardAgent no";
        let entries = parse(config);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].forward_agent, Some(false));
    }

    #[test]
    fn parse_wildcard_host() {
        let entries = parse("Host *\n    ServerAliveInterval 60");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].host, "*");
        assert_eq!(entries[0].hostname, None);
    }

    #[test]
    fn parse_comments_and_empty_lines_skipped() {
        let config =
            "# This is a comment\n\nHost myhost\n    # Another comment\n    HostName example.com\n";
        let entries = parse(config);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].host, "myhost");
        assert_eq!(entries[0].hostname.as_deref(), Some("example.com"));
    }

    #[test]
    fn parse_extra_options_preserved() {
        let config = "Host custom\n    HostName example.com\n    ServerAliveInterval 60\n    ServerAliveCountMax 3";
        let entries = parse(config);
        assert_eq!(entries.len(), 1);
        let extra = &entries[0].extra_options;
        assert_eq!(
            extra.get("ServerAliveInterval").map(String::as_str),
            Some("60")
        );
        assert_eq!(
            extra.get("ServerAliveCountMax").map(String::as_str),
            Some("3")
        );
    }

    #[test]
    fn parse_multi_entry_config() {
        let config = "Host server1\n    HostName 10.0.0.1\n    User alice\n\nHost server2\n    HostName 10.0.0.2\n    User bob\n    Port 2222\n\nHost server3\n    HostName 10.0.0.3";
        let entries = parse(config);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].host, "server1");
        assert_eq!(entries[0].user.as_deref(), Some("alice"));
        assert_eq!(entries[1].host, "server2");
        assert_eq!(entries[1].user.as_deref(), Some("bob"));
        assert_eq!(entries[1].port, Some(2222));
        assert_eq!(entries[2].host, "server3");
        assert_eq!(entries[2].hostname.as_deref(), Some("10.0.0.3"));
    }

    // Serialization

    #[test]
    fn serialization_round_trip() {
        let original = SSHConfigEntry {
            hostname: Some("192.168.1.50".into()),
            user: Some("testuser".into()),
            port: Some(2222),
            identity_file: Some("~/.ssh/test_key".into()),
            proxy_jump: Some("bastion".into()),
            forward_agent: Some(true),
            ..SSHConfigEntry::new("roundtrip")
        };
        let parsed = parse(&serialize(std::slice::from_ref(&original)));
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].host, original.host);
        assert_eq!(parsed[0].hostname, original.hostname);
        assert_eq!(parsed[0].user, original.user);
        assert_eq!(parsed[0].port, original.port);
        assert_eq!(parsed[0].identity_file, original.identity_file);
        assert_eq!(parsed[0].proxy_jump, original.proxy_jump);
        assert_eq!(parsed[0].forward_agent, original.forward_agent);
    }

    #[test]
    fn serialize_multiple_entries() {
        let entries = [
            entry("host1", Some("1.1.1.1"), None),
            entry("host2", Some("2.2.2.2"), Some("admin")),
        ];
        let serialized = serialize(&entries);
        assert!(serialized.contains("Host host1"));
        assert!(serialized.contains("Host host2"));
        assert!(serialized.contains("HostName 1.1.1.1"));
        assert!(serialized.contains("User admin"));
    }

    #[test]
    fn serialize_omits_nil_fields() {
        let serialized = serialize(&[entry("minimal", Some("example.com"), None)]);
        assert!(serialized.contains("Host minimal"));
        assert!(serialized.contains("HostName example.com"));
        assert!(!serialized.contains("User"));
        assert!(!serialized.contains("Port"));
        assert!(!serialized.contains("IdentityFile"));
        assert!(!serialized.contains("ProxyJump"));
        assert!(!serialized.contains("ForwardAgent"));
    }

    // Display name

    #[test]
    fn display_name_with_user_and_hostname() {
        let e = entry("myhost", Some("example.com"), Some("admin"));
        assert_eq!(e.display_name(), "admin@example.com");
    }

    #[test]
    fn display_name_with_hostname_only() {
        let e = entry("myhost", Some("example.com"), None);
        assert_eq!(e.display_name(), "example.com");
    }

    #[test]
    fn display_name_falls_back_to_host() {
        assert_eq!(SSHConfigEntry::new("myhost").display_name(), "myhost");
    }

    // Edge cases

    #[test]
    fn parse_empty_string() {
        assert!(parse("").is_empty());
    }

    #[test]
    fn parse_only_comments() {
        assert!(parse("# Just a comment\n# Another comment").is_empty());
    }

    #[test]
    fn parse_options_before_first_host() {
        let entries = parse("ServerAliveInterval 60\nHost actual\n    HostName example.com");
        // Options before the first Host are ignored.
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].host, "actual");
    }

    #[test]
    fn entry_equatable() {
        let entry1 = entry("test", Some("example.com"), None);
        let entry2 = entry("test", Some("example.com"), None);
        assert_eq!(entry1, entry2);
    }

    #[test]
    fn entry_codable() {
        let mut original = SSHConfigEntry {
            hostname: Some("example.com".into()),
            user: Some("test".into()),
            port: Some(22),
            ..SSHConfigEntry::new("codable")
        };
        original
            .extra_options
            .insert("Compression".into(), "yes".into());
        let decoded = parse(&serialize(std::slice::from_ref(&original)));
        assert_eq!(decoded.len(), 1);
        assert_eq!(decoded[0].host, original.host);
        assert_eq!(decoded[0].hostname, original.hostname);
        assert_eq!(decoded[0].user, original.user);
        assert_eq!(decoded[0].port, original.port);
        assert_eq!(
            decoded[0]
                .extra_options
                .get("Compression")
                .map(String::as_str),
            Some("yes")
        );
    }

    // Extra coverage for separator handling.

    #[test]
    fn parse_equals_separator_and_invalid_port() {
        let entries = parse("Host=eq\n  HostName = example.com\n  Port=abc\n  Ciphers aes128-ctr");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].host, "eq");
        // As in Swift, `=` only separates when no space precedes it, so this
        // line splits on the first space and keeps the `=` in the value.
        assert_eq!(entries[0].hostname.as_deref(), Some("= example.com"));
        assert_eq!(entries[0].port, None);
        assert_eq!(
            entries[0].extra_options.get("Ciphers").map(String::as_str),
            Some("aes128-ctr")
        );
    }
}
