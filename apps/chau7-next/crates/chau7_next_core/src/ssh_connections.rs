//! Saved SSH connections (`SSHConnection` and `SSHConnectionManager` in
//! `Profiles/SSHConnectionManager.swift`, `SharedSSHProfileManager`).
//!
//! Chau7 Next keeps its own file (see `DataRoot::ssh_connections_file`); the
//! Swift app's UserDefaults entries are not touched.

use std::path::Path;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::shell_escaping::{
    SshValidationIssue, SshValidationResult, escape_argument, escape_path, validate_ssh_options,
};
use crate::ssh_config::SSHConfigEntry;

/// The tab colors of the editor.
pub const COLOR_TAGS: [&str; 7] = ["blue", "green", "orange", "red", "purple", "pink", "yellow"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SshConnection {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: i64,
    pub user: String,
    pub identity_file: String,
    /// ProxyJump / bastion host.
    pub jump_host: String,
    pub extra_options: String,
    pub color_tag: String,
    /// Unix seconds.
    pub last_connected: Option<i64>,
    pub group: String,
    pub tags: Vec<String>,
    pub notes: String,
}

/// The Port field of the connection editor: empty means 22; anything else
/// must be a port number from 1 to 65535.
pub fn parse_port(text: &str) -> Result<i64, &'static str> {
    let text = text.trim();
    if text.is_empty() {
        return Ok(22);
    }
    match text.parse::<i64>() {
        Ok(port) if (1..=65535).contains(&port) => Ok(port),
        _ => Err("Port must be a number from 1 to 65535."),
    }
}

impl Default for SshConnection {
    fn default() -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name: String::new(),
            host: String::new(),
            port: 22,
            user: String::new(),
            identity_file: String::new(),
            jump_host: String::new(),
            extra_options: String::new(),
            color_tag: "blue".to_string(),
            last_connected: None,
            group: String::new(),
            tags: Vec::new(),
            notes: String::new(),
        }
    }
}

fn expand_tilde(path: &str, home: &str) -> String {
    match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => format!("{home}{rest}"),
        _ => path.to_string(),
    }
}

impl SshConnection {
    pub fn display_name(&self) -> String {
        if !self.name.is_empty() {
            return self.name.clone();
        }
        if !self.user.is_empty() {
            return format!("{}@{}", self.user, self.host);
        }
        self.host.clone()
    }

    /// The command typed into a new tab. Extra options that fail validation
    /// are left out.
    pub fn ssh_command(&self, home: &str) -> String {
        let mut parts = vec!["ssh".to_string()];
        if self.port != 22 {
            parts.push(format!("-p {}", self.port));
        }
        if !self.identity_file.is_empty() {
            let expanded = expand_tilde(&self.identity_file, home);
            parts.push(format!("-i {}", escape_path(&expanded)));
        }
        if !self.jump_host.is_empty() {
            parts.push(format!("-J {}", escape_argument(&self.jump_host)));
        }
        if !self.extra_options.is_empty() && validate_ssh_options(&self.extra_options).is_valid {
            parts.push(self.extra_options.clone());
        }
        let destination = if self.user.is_empty() {
            self.host.clone()
        } else {
            format!("{}@{}", self.user, self.host)
        };
        parts.push(escape_argument(&destination));
        parts.join(" ")
    }

    pub fn extra_options_validation(&self) -> SshValidationResult {
        validate_ssh_options(&self.extra_options)
    }

    /// Case-insensitive match on name, host and user.
    pub fn matches_query(&self, query: &str) -> bool {
        let q = query.to_lowercase();
        self.display_name().to_lowercase().contains(&q)
            || self.host.to_lowercase().contains(&q)
            || self.user.to_lowercase().contains(&q)
    }

    /// This connection as an `~/.ssh/config` entry (`exportConnection`).
    pub fn to_config_entry(&self) -> SSHConfigEntry {
        let some = |s: &str| (!s.is_empty()).then(|| s.to_string());
        SSHConfigEntry {
            host: if self.name.is_empty() {
                self.host.clone()
            } else {
                self.name.clone()
            },
            hostname: Some(self.host.clone()),
            user: some(&self.user),
            port: (self.port != 22).then_some(self.port),
            identity_file: some(&self.identity_file),
            proxy_jump: some(&self.jump_host),
            ..SSHConfigEntry::default()
        }
    }

    /// A config entry as a connection (`importEntry`).
    pub fn from_config_entry(entry: &SSHConfigEntry) -> Self {
        Self {
            name: entry.host.clone(),
            host: entry.hostname.clone().unwrap_or_else(|| entry.host.clone()),
            port: entry.port.unwrap_or(22),
            user: entry.user.clone().unwrap_or_default(),
            identity_file: entry.identity_file.clone().unwrap_or_default(),
            jump_host: entry.proxy_jump.clone().unwrap_or_default(),
            ..Self::default()
        }
    }
}

/// The editor's warning for rejected extra options.
pub fn validation_message(issue: Option<&SshValidationIssue>) -> String {
    match issue {
        None => "Invalid options".to_string(),
        Some(SshValidationIssue::DangerousOption(option)) => {
            format!("Option \"{option}\" is not allowed for security reasons")
        }
        Some(SshValidationIssue::CommandSubstitution) => {
            "Command substitution is not allowed".to_string()
        }
        Some(SshValidationIssue::ShellRedirection) => {
            "Shell redirection is not allowed".to_string()
        }
        Some(SshValidationIssue::ShellControlChars) => {
            "Shell control characters are not allowed".to_string()
        }
    }
}

/// All saved connections and folders.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SshConnections {
    pub connections: Vec<SshConnection>,
    pub folders: Vec<String>,
}

impl SshConnections {
    pub fn load(path: &Path) -> Self {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let text = serde_json::to_string_pretty(self).map_err(std::io::Error::other)?;
        std::fs::write(path, text)
    }

    pub fn get(&self, id: &str) -> Option<&SshConnection> {
        self.connections.iter().find(|c| c.id == id)
    }

    pub fn add(&mut self, connection: SshConnection) {
        self.connections.push(connection);
    }

    pub fn update(&mut self, connection: SshConnection) {
        if let Some(slot) = self.connections.iter_mut().find(|c| c.id == connection.id) {
            *slot = connection;
        }
    }

    pub fn delete(&mut self, id: &str) {
        self.connections.retain(|c| c.id != id);
    }

    pub fn mark_connected(&mut self, id: &str, now: i64) {
        if let Some(c) = self.connections.iter_mut().find(|c| c.id == id) {
            c.last_connected = Some(now);
        }
    }

    /// A copy with a new id, " (Copy)" in the name and no last-connected time.
    pub fn duplicate(&mut self, id: &str) -> Option<String> {
        let mut copy = self.get(id)?.clone();
        copy.id = Uuid::new_v4().to_string();
        copy.name = format!("{} (Copy)", copy.name);
        copy.last_connected = None;
        let new_id = copy.id.clone();
        self.connections.push(copy);
        Some(new_id)
    }

    /// The five most recently used.
    pub fn recent(&self) -> Vec<&SshConnection> {
        let mut used: Vec<&SshConnection> = self
            .connections
            .iter()
            .filter(|c| c.last_connected.is_some())
            .collect();
        used.sort_by_key(|c| std::cmp::Reverse(c.last_connected));
        used.truncate(5);
        used
    }

    /// Connections matching `query` (all when empty), sorted by name.
    pub fn search(&self, query: &str) -> Vec<&SshConnection> {
        let mut found: Vec<&SshConnection> = self
            .connections
            .iter()
            .filter(|c| query.is_empty() || c.matches_query(query))
            .collect();
        found.sort_by_key(|c| c.display_name());
        found
    }

    pub fn all_groups(&self) -> Vec<String> {
        let mut groups: Vec<String> = self
            .connections
            .iter()
            .filter(|c| !c.group.is_empty())
            .map(|c| c.group.clone())
            .collect();
        groups.sort();
        groups.dedup();
        groups
    }

    pub fn all_tags(&self) -> Vec<String> {
        let mut tags: Vec<String> = self
            .connections
            .iter()
            .flat_map(|c| c.tags.iter().cloned())
            .collect();
        tags.sort();
        tags.dedup();
        tags
    }

    pub fn in_group_with_tag(&self, group: &str, tag: &str) -> Vec<&SshConnection> {
        self.connections
            .iter()
            .filter(|c| {
                (group.is_empty() || c.group == group)
                    && (tag.is_empty() || c.tags.iter().any(|t| t == tag))
            })
            .collect()
    }

    pub fn export_json(&self) -> String {
        serde_json::to_string_pretty(&self.connections).unwrap_or_else(|_| "[]".to_string())
    }

    /// Add the connections of `json` whose host, user and port are not saved
    /// yet. Returns how many were added.
    pub fn import_json(&mut self, json: &str) -> usize {
        let Ok(imported) = serde_json::from_str::<Vec<SshConnection>>(json) else {
            return 0;
        };
        let mut added = 0;
        for conn in imported {
            let exists = self
                .connections
                .iter()
                .any(|c| c.host == conn.host && c.user == conn.user && c.port == conn.port);
            if !exists {
                self.connections.push(conn);
                added += 1;
            }
        }
        added
    }

    /// Add hosts from parsed `~/.ssh/config` entries that have a HostName and
    /// are not saved yet (same host and user). Returns how many were added.
    pub fn import_config_entries(&mut self, entries: &[SSHConfigEntry]) -> usize {
        let mut added = 0;
        for entry in entries {
            if entry.hostname.as_deref().unwrap_or("").is_empty() {
                continue;
            }
            let connection = SshConnection::from_config_entry(entry);
            let exists = self
                .connections
                .iter()
                .any(|c| c.host == connection.host && c.user == connection.user);
            if !exists {
                self.connections.push(connection);
                added += 1;
            }
        }
        added
    }

    /// Entries for connections whose host alias is not in `existing_hosts`
    /// (`SSHProfilesSettingsView.exportAllConnections`).
    pub fn config_entries_to_export(&self, existing_hosts: &[String]) -> Vec<SSHConfigEntry> {
        let mut seen: Vec<String> = existing_hosts.to_vec();
        let mut out = Vec::new();
        for connection in &self.connections {
            let entry = connection.to_config_entry();
            if !seen.contains(&entry.host) {
                seen.push(entry.host.clone());
                out.push(entry);
            }
        }
        out
    }
}

/// Entries `Import All` takes: wildcard hosts are skipped.
pub fn importable_entries(entries: &[SSHConfigEntry]) -> Vec<&SSHConfigEntry> {
    entries.iter().filter(|e| !e.host.contains('*')).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ssh_config;

    fn conn(name: &str, host: &str, user: &str) -> SshConnection {
        SshConnection {
            name: name.into(),
            host: host.into(),
            user: user.into(),
            ..Default::default()
        }
    }

    #[test]
    fn port_field_rejects_invalid_ports() {
        assert_eq!(parse_port(""), Ok(22));
        assert_eq!(parse_port(" 2222 "), Ok(2222));
        assert_eq!(parse_port("65535"), Ok(65535));
        for bad in ["0", "-1", "65536", "22x", "ssh"] {
            assert!(parse_port(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn command_has_port_identity_jump_and_escaped_destination() {
        let c = SshConnection {
            host: "h.example.com".into(),
            user: "me".into(),
            port: 2200,
            identity_file: "~/.ssh/my key".into(),
            jump_host: "bastion".into(),
            extra_options: "-A".into(),
            ..Default::default()
        };
        assert_eq!(
            c.ssh_command("/home/me"),
            "ssh -p 2200 -i '/home/me/.ssh/my key' -J 'bastion' -A 'me@h.example.com'"
        );
        assert_eq!(conn("", "h", "").ssh_command("/h"), "ssh 'h'");
    }

    #[test]
    fn unsafe_extra_options_are_left_out() {
        let mut c = conn("", "h", "u");
        c.extra_options = "-o ProxyCommand=evil".into();
        assert_eq!(c.ssh_command("/h"), "ssh 'u@h'");
        assert!(!c.extra_options_validation().is_valid);
        assert_eq!(
            validation_message(c.extra_options_validation().issue.as_ref()),
            "Option \"-o ProxyCommand\" is not allowed for security reasons"
        );
    }

    #[test]
    fn display_name_falls_back_to_user_at_host() {
        assert_eq!(conn("web", "h", "u").display_name(), "web");
        assert_eq!(conn("", "h", "u").display_name(), "u@h");
        assert_eq!(conn("", "h", "").display_name(), "h");
    }

    #[test]
    fn search_sorts_and_matches_name_host_user() {
        let mut s = SshConnections::default();
        s.add(conn("b-box", "10.0.0.2", "root"));
        s.add(conn("a-box", "example.org", "deploy"));
        let names = |q: &str| {
            s.search(q)
                .iter()
                .map(|c| c.display_name())
                .collect::<Vec<_>>()
        };
        assert_eq!(names(""), ["a-box", "b-box"]);
        assert_eq!(names("EXAMPLE"), ["a-box"]);
        assert_eq!(names("root"), ["b-box"]);
    }

    #[test]
    fn recent_keeps_the_five_latest() {
        let mut s = SshConnections::default();
        for i in 0..7 {
            let c = conn(&format!("c{i}"), "h", "");
            let id = c.id.clone();
            s.add(c);
            s.mark_connected(&id, 100 + i);
        }
        s.add(conn("never", "h", ""));
        let recent: Vec<String> = s.recent().iter().map(|c| c.name.clone()).collect();
        assert_eq!(recent, ["c6", "c5", "c4", "c3", "c2"]);
    }

    #[test]
    fn duplicate_copies_without_history() {
        let mut s = SshConnections::default();
        let c = conn("web", "h", "u");
        let id = c.id.clone();
        s.add(c);
        s.mark_connected(&id, 5);
        let copy = s.duplicate(&id).unwrap();
        let copy = s.get(&copy).unwrap();
        assert_eq!(copy.name, "web (Copy)");
        assert_eq!(copy.last_connected, None);
        assert_ne!(copy.id, id);
    }

    #[test]
    fn json_import_skips_duplicates_by_host_user_port() {
        let mut a = SshConnections::default();
        a.add(conn("x", "h", "u"));
        let json = a.export_json();
        let mut b = SshConnections::default();
        b.add(conn("other", "h", "u"));
        assert_eq!(b.import_json(&json), 0);
        let mut c = SshConnections::default();
        assert_eq!(c.import_json(&json), 1);
        assert_eq!(c.import_json("not json"), 0);
    }

    #[test]
    fn config_import_needs_a_hostname_and_skips_saved_hosts() {
        let entries = ssh_config::parse(
            "Host web\n  HostName w.example.com\n  User me\n  Port 2222\nHost *\n  User x\nHost nohost\n",
        );
        let mut s = SshConnections::default();
        assert_eq!(s.import_config_entries(&entries), 1);
        assert_eq!(s.import_config_entries(&entries), 0);
        let c = &s.connections[0];
        assert_eq!(
            (c.name.as_str(), c.host.as_str(), c.port),
            ("web", "w.example.com", 2222)
        );
    }

    #[test]
    fn export_skips_hosts_already_in_the_config() {
        let mut s = SshConnections::default();
        s.add(conn("web", "w.example.com", "me"));
        s.add(conn("", "bare.example.com", ""));
        let entries = s.config_entries_to_export(&["web".to_string()]);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].host, "bare.example.com");
        assert_eq!(entries[0].hostname.as_deref(), Some("bare.example.com"));
    }

    #[test]
    fn importable_entries_skip_wildcards() {
        let entries = ssh_config::parse("Host *\n  User x\nHost a\n  HostName h\n");
        assert_eq!(importable_entries(&entries).len(), 1);
    }

    #[test]
    fn groups_and_tags_are_unique_and_sorted() {
        let mut s = SshConnections::default();
        let mut a = conn("a", "h", "");
        a.group = "Prod".into();
        a.tags = vec!["web".into(), "aws".into()];
        let mut b = conn("b", "h2", "");
        b.group = "Prod".into();
        b.tags = vec!["aws".into()];
        s.add(a);
        s.add(b);
        s.add(conn("c", "h3", ""));
        assert_eq!(s.all_groups(), ["Prod"]);
        assert_eq!(s.all_tags(), ["aws", "web"]);
        assert_eq!(s.in_group_with_tag("Prod", "web").len(), 1);
        assert_eq!(s.in_group_with_tag("", "").len(), 3);
    }

    #[test]
    fn store_round_trips_through_a_file() {
        let dir = std::env::temp_dir().join(format!("chau7-sshc-{}", std::process::id()));
        let path = dir.join("ssh.json");
        let mut s = SshConnections::default();
        s.add(conn("web", "h", "u"));
        s.save(&path).unwrap();
        assert_eq!(SshConnections::load(&path), s);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
