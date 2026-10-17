//! Profile auto-switch rules: triggers, priority and matching.
//!
//! Port of `ProfileSwitchRule.swift` from `apps/chau7-macos/Sources/Chau7Core`.
//!
//! Differences from Swift: `~/` expansion uses a caller-supplied `home`
//! (`None` leaves `~/` untouched) instead of reading the process environment.
//! JSON matches Swift's synthesized `Codable`: triggers are externally tagged
//! (`{"directory":{"path":"/x"}}`) and ids are upper-case UUID strings.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

/// Serde adapter writing UUIDs as upper-case strings like Swift's `UUID`
/// (reading accepts either case).
pub mod uuid_upper {
    use serde::{Deserialize, Deserializer, Serializer};
    use uuid::Uuid;

    pub fn serialize<S: Serializer>(id: &Uuid, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&id.hyphenated().to_string().to_uppercase())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Uuid, D::Error> {
        let raw = String::deserialize(d)?;
        Uuid::parse_str(&raw).map_err(serde::de::Error::custom)
    }
}

/// The condition that triggers an automatic profile switch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProfileSwitchTrigger {
    Directory { path: String },
    GitRepository { name: String },
    SshHost { hostname: String },
    ProcessRunning { name: String },
    EnvironmentVariable { key: String, value: String },
}

impl ProfileSwitchTrigger {
    pub fn type_display_name(&self) -> &'static str {
        match self {
            Self::Directory { .. } => "Directory",
            Self::GitRepository { .. } => "Git Repository",
            Self::SshHost { .. } => "SSH Host",
            Self::ProcessRunning { .. } => "Process",
            Self::EnvironmentVariable { .. } => "Environment Variable",
        }
    }

    pub fn display_summary(&self) -> String {
        match self {
            Self::Directory { path } => format!("cd {path}"),
            Self::GitRepository { name } => format!("repo: {name}"),
            Self::SshHost { hostname } => format!("ssh {hostname}"),
            Self::ProcessRunning { name } => format!("process: {name}"),
            Self::EnvironmentVariable { key, value } => format!("{key}={value}"),
        }
    }
}

/// A rule mapping a trigger to a named profile.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileSwitchRule {
    #[serde(with = "uuid_upper")]
    pub id: Uuid,
    pub name: String,
    pub is_enabled: bool,
    pub trigger: ProfileSwitchTrigger,
    pub profile_name: String,
    pub priority: i64,
}

impl ProfileSwitchRule {
    /// Defaults: new id, enabled, priority 0.
    pub fn new(name: &str, trigger: ProfileSwitchTrigger, profile_name: &str) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.to_string(),
            is_enabled: true,
            trigger,
            profile_name: profile_name.to_string(),
            priority: 0,
        }
    }

    /// Whether the rule matches the given tab state. A disabled rule never
    /// matches; a trigger whose input is `None` does not match.
    pub fn matches(
        &self,
        directory: Option<&str>,
        _git_branch: Option<&str>,
        ssh_host: Option<&str>,
        processes: Option<&[String]>,
        environment: Option<&HashMap<String, String>>,
        home: Option<&str>,
    ) -> bool {
        if !self.is_enabled {
            return false;
        }
        match &self.trigger {
            ProfileSwitchTrigger::Directory { path } => match directory {
                Some(d) => Self::matches_glob(d, path, home),
                None => false,
            },
            ProfileSwitchTrigger::GitRepository { name } => match directory {
                Some(d) => matches_repo_name(d, name),
                None => false,
            },
            ProfileSwitchTrigger::SshHost { hostname } => match ssh_host {
                Some(h) => h.to_lowercase() == hostname.to_lowercase(),
                None => false,
            },
            ProfileSwitchTrigger::ProcessRunning { name } => match processes {
                Some(list) => {
                    let lowered = name.to_lowercase();
                    list.iter().any(|p| p.to_lowercase() == lowered)
                }
                None => false,
            },
            ProfileSwitchTrigger::EnvironmentVariable { key, value } => match environment {
                Some(env) => env.get(key).is_some_and(|v| v == value),
                None => false,
            },
        }
    }

    /// Glob match of `path` against `pattern` (`*`, `**`, partial wildcards,
    /// `~/` expansion, trailing slash ignored).
    pub fn matches_glob(path: &str, pattern: &str, home: Option<&str>) -> bool {
        let expanded_pattern = expand_tilde(pattern, home);
        let expanded_path = expand_tilde(path, home);
        let np = expanded_pattern
            .strip_suffix('/')
            .unwrap_or(&expanded_pattern);
        let npath = expanded_path.strip_suffix('/').unwrap_or(&expanded_path);
        if np.contains("**") {
            let ps: Vec<&str> = npath.split('/').collect();
            let pp: Vec<&str> = np.split('/').collect();
            return match_segments(&ps, &pp, 0, 0);
        }
        let ps: Vec<&str> = npath.split('/').collect();
        let pp: Vec<&str> = np.split('/').collect();
        if ps.len() != pp.len() {
            return false;
        }
        ps.iter()
            .zip(pp.iter())
            .all(|(s, p)| *p == "*" || matches_simple_wildcard(s, p))
    }
}

/// The host an `ssh` command line connects to (`argv`, first word `ssh`):
/// the first argument that is not an option or an option's value, without
/// `user@`, `ssh://` or `:port`. `None` when there is no destination.
/// Feeds the SSH host trigger of the rules.
pub fn ssh_destination_host(args: &[String]) -> Option<String> {
    // ssh options that take a value (`ssh -h`).
    const WITH_VALUE: &str = "BbcDEeFIiJLlmOoPpQRSWw";
    let mut iter = args.iter().skip(1);
    while let Some(arg) = iter.next() {
        if arg == "--" {
            return iter.next().and_then(|d| host_of(d));
        }
        if let Some(flags) = arg.strip_prefix('-').filter(|f| !f.is_empty()) {
            // `-p22` carries its value; `-p 22` takes the next argument.
            // Flags can be grouped (`-tt`, `-vp 22`).
            for (i, flag) in flags.char_indices() {
                if WITH_VALUE.contains(flag) {
                    if i + flag.len_utf8() == flags.len() {
                        iter.next();
                    }
                    break;
                }
            }
            continue;
        }
        return host_of(arg);
    }
    None
}

fn host_of(destination: &str) -> Option<String> {
    let rest = destination.strip_prefix("ssh://").unwrap_or(destination);
    let rest = rest.rsplit_once('@').map(|(_, h)| h).unwrap_or(rest);
    let host = if let Some(inner) = rest.strip_prefix('[') {
        inner.split(']').next().unwrap_or(inner)
    } else if destination.starts_with("ssh://") {
        rest.split(':').next().unwrap_or(rest)
    } else {
        rest
    };
    let host = host.trim_end_matches('/');
    (!host.is_empty()).then(|| host.to_string())
}

/// Rules sorted by priority descending, then name ascending.
pub fn sorted_by_priority(rules: &[ProfileSwitchRule]) -> Vec<ProfileSwitchRule> {
    let mut out = rules.to_vec();
    out.sort_by(|l, r| {
        r.priority
            .cmp(&l.priority)
            .then_with(|| l.name.cmp(&r.name))
    });
    out
}

fn match_segments(path: &[&str], pattern: &[&str], pi: usize, qi: usize) -> bool {
    if qi >= pattern.len() && pi >= path.len() {
        return true;
    }
    if qi >= pattern.len() {
        return false;
    }
    let pat = pattern[qi];
    if pat == "**" {
        if match_segments(path, pattern, pi, qi + 1) {
            return true;
        }
        if pi < path.len() {
            return match_segments(path, pattern, pi + 1, qi);
        }
        return false;
    }
    if pi >= path.len() {
        return false;
    }
    if pat == "*" || matches_simple_wildcard(path[pi], pat) {
        return match_segments(path, pattern, pi + 1, qi + 1);
    }
    false
}

fn matches_simple_wildcard(string: &str, pattern: &str) -> bool {
    if pattern == "*" {
        return true;
    }
    if !pattern.contains('*') {
        return string == pattern;
    }
    let parts: Vec<&str> = pattern.split('*').collect();
    let mut remaining = string;
    let first = parts[0];
    if !first.is_empty() {
        match remaining.strip_prefix(first) {
            Some(rest) => remaining = rest,
            None => return false,
        }
    }
    let last = parts[parts.len() - 1];
    if !last.is_empty() {
        match remaining.strip_suffix(last) {
            Some(rest) => remaining = rest,
            None => return false,
        }
    }
    for part in &parts[1..parts.len() - 1] {
        if part.is_empty() {
            continue;
        }
        match remaining.find(part) {
            Some(idx) => remaining = &remaining[idx + part.len()..],
            None => return false,
        }
    }
    true
}

/// `RuntimeIsolation.expandTilde`: only a leading `~/` is expanded.
fn expand_tilde(path: &str, home: Option<&str>) -> String {
    match (path.strip_prefix('~'), home) {
        (Some(rest), Some(h)) if rest.starts_with('/') => format!("{h}{rest}"),
        _ => path.to_string(),
    }
}

/// `(directory as NSString).lastPathComponent`.
fn last_path_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { "" } else { "/" };
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed)
}

fn matches_repo_name(directory: &str, repo_name: &str) -> bool {
    last_path_component(directory).to_lowercase() == repo_name.to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ssh(line: &str) -> Option<String> {
        let args: Vec<String> = line.split_whitespace().map(str::to_string).collect();
        ssh_destination_host(&args)
    }

    #[test]
    fn ssh_destination_from_command_line() {
        assert_eq!(
            ssh("ssh prod.example.com").as_deref(),
            Some("prod.example.com")
        );
        assert_eq!(ssh("ssh me@prod").as_deref(), Some("prod"));
        assert_eq!(ssh("ssh -p 2222 -i key me@db -- ls").as_deref(), Some("db"));
        assert_eq!(ssh("ssh -p2222 -tt host uptime").as_deref(), Some("host"));
        assert_eq!(
            ssh("ssh -vo StrictHostKeyChecking=no box").as_deref(),
            Some("box")
        );
        assert_eq!(ssh("ssh ssh://me@web:2200").as_deref(), Some("web"));
        assert_eq!(ssh("ssh -- edge").as_deref(), Some("edge"));
        assert_eq!(ssh("ssh -V"), None);
    }

    fn make_rule(
        trigger: ProfileSwitchTrigger,
        is_enabled: bool,
        priority: i64,
    ) -> ProfileSwitchRule {
        let mut r = ProfileSwitchRule::new("Test Rule", trigger, "dark-theme");
        r.is_enabled = is_enabled;
        r.priority = priority;
        r
    }

    fn rule(trigger: ProfileSwitchTrigger) -> ProfileSwitchRule {
        make_rule(trigger, true, 0)
    }

    fn dir(p: &str) -> ProfileSwitchTrigger {
        ProfileSwitchTrigger::Directory { path: p.into() }
    }

    fn m_dir(r: &ProfileSwitchRule, d: Option<&str>) -> bool {
        r.matches(d, None, None, None, None, None)
    }

    fn m_ssh(r: &ProfileSwitchRule, h: Option<&str>) -> bool {
        r.matches(None, None, h, None, None, None)
    }

    fn m_proc(r: &ProfileSwitchRule, p: Option<&[&str]>) -> bool {
        let owned: Option<Vec<String>> = p.map(|l| l.iter().map(|s| s.to_string()).collect());
        r.matches(None, None, None, owned.as_deref(), None, None)
    }

    fn m_env(r: &ProfileSwitchRule, e: Option<&[(&str, &str)]>) -> bool {
        let owned: Option<HashMap<String, String>> = e.map(|l| {
            l.iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        });
        r.matches(None, None, None, None, owned.as_ref(), None)
    }

    fn glob(path: &str, pattern: &str) -> bool {
        ProfileSwitchRule::matches_glob(path, pattern, None)
    }

    // ProfileSwitchTrigger

    #[test]
    fn test_type_display_names() {
        assert_eq!(dir("/tmp").type_display_name(), "Directory");
        assert_eq!(
            ProfileSwitchTrigger::GitRepository {
                name: "repo".into()
            }
            .type_display_name(),
            "Git Repository"
        );
        assert_eq!(
            ProfileSwitchTrigger::SshHost {
                hostname: "host".into()
            }
            .type_display_name(),
            "SSH Host"
        );
        assert_eq!(
            ProfileSwitchTrigger::ProcessRunning { name: "vim".into() }.type_display_name(),
            "Process"
        );
        assert_eq!(
            ProfileSwitchTrigger::EnvironmentVariable {
                key: "K".into(),
                value: "V".into()
            }
            .type_display_name(),
            "Environment Variable"
        );
    }

    #[test]
    fn test_display_summaries() {
        assert_eq!(dir("/tmp").display_summary(), "cd /tmp");
        assert_eq!(
            ProfileSwitchTrigger::GitRepository {
                name: "myrepo".into()
            }
            .display_summary(),
            "repo: myrepo"
        );
        assert_eq!(
            ProfileSwitchTrigger::SshHost {
                hostname: "server.com".into()
            }
            .display_summary(),
            "ssh server.com"
        );
        assert_eq!(
            ProfileSwitchTrigger::ProcessRunning {
                name: "node".into()
            }
            .display_summary(),
            "process: node"
        );
        assert_eq!(
            ProfileSwitchTrigger::EnvironmentVariable {
                key: "ENV".into(),
                value: "prod".into()
            }
            .display_summary(),
            "ENV=prod"
        );
    }

    #[test]
    fn test_codable_round_trip() {
        let triggers = vec![
            dir("/home/user"),
            ProfileSwitchTrigger::GitRepository {
                name: "my-project".into(),
            },
            ProfileSwitchTrigger::SshHost {
                hostname: "prod.example.com".into(),
            },
            ProfileSwitchTrigger::ProcessRunning {
                name: "docker".into(),
            },
            ProfileSwitchTrigger::EnvironmentVariable {
                key: "NODE_ENV".into(),
                value: "production".into(),
            },
        ];
        for original in triggers {
            let json = serde_json::to_string(&original).unwrap();
            let decoded: ProfileSwitchTrigger = serde_json::from_str(&json).unwrap();
            assert_eq!(decoded, original);
        }
    }

    #[test]
    fn test_trigger_json_matches_swift_synthesized_shape() {
        assert_eq!(
            serde_json::to_string(&dir("/x")).unwrap(),
            r#"{"directory":{"path":"/x"}}"#
        );
        assert_eq!(
            serde_json::to_string(&ProfileSwitchTrigger::EnvironmentVariable {
                key: "K".into(),
                value: "V".into()
            })
            .unwrap(),
            r#"{"environmentVariable":{"key":"K","value":"V"}}"#
        );
        let t: ProfileSwitchTrigger =
            serde_json::from_str(r#"{"gitRepository":{"name":"r"}}"#).unwrap();
        assert_eq!(t, ProfileSwitchTrigger::GitRepository { name: "r".into() });
    }

    #[test]
    fn test_equality() {
        assert_eq!(dir("/tmp"), dir("/tmp"));
        assert_ne!(dir("/tmp"), dir("/home"));
    }

    // ProfileSwitchRule

    #[test]
    fn test_disabled_rule_never_matches() {
        let r = make_rule(dir("/tmp"), false, 0);
        assert!(!m_dir(&r, Some("/tmp")));
    }

    #[test]
    fn test_directory_exact_match() {
        let r = rule(dir("/Users/dev/project"));
        assert!(m_dir(&r, Some("/Users/dev/project")));
    }

    #[test]
    fn test_directory_no_match() {
        let r = rule(dir("/Users/dev/project"));
        assert!(!m_dir(&r, Some("/Users/dev/other")));
    }

    #[test]
    fn test_directory_nil_returns_false() {
        assert!(!m_dir(&rule(dir("/tmp")), None));
    }

    #[test]
    fn test_directory_wildcard() {
        let r = rule(dir("/Users/*/project"));
        assert!(m_dir(&r, Some("/Users/dev/project")));
        assert!(!m_dir(&r, Some("/Users/dev/other")));
    }

    #[test]
    fn test_directory_double_star_glob() {
        let r = rule(dir("/Users/**/node_modules"));
        assert!(m_dir(&r, Some("/Users/dev/project/node_modules")));
        assert!(m_dir(&r, Some("/Users/dev/deep/nested/node_modules")));
    }

    #[test]
    fn test_directory_trailing_slash_ignored() {
        let r = rule(dir("/tmp/"));
        assert!(m_dir(&r, Some("/tmp")));
        assert!(m_dir(&r, Some("/tmp/")));
    }

    #[test]
    fn test_git_repo_matches_directory_basename() {
        let r = rule(ProfileSwitchTrigger::GitRepository {
            name: "my-project".into(),
        });
        assert!(m_dir(&r, Some("/Users/dev/my-project")));
    }

    #[test]
    fn test_git_repo_matches_case_insensitive() {
        let r = rule(ProfileSwitchTrigger::GitRepository {
            name: "MyProject".into(),
        });
        assert!(m_dir(&r, Some("/home/user/myproject")));
    }

    #[test]
    fn test_git_repo_no_match() {
        let r = rule(ProfileSwitchTrigger::GitRepository {
            name: "my-project".into(),
        });
        assert!(!m_dir(&r, Some("/Users/dev/other-project")));
    }

    #[test]
    fn test_git_repo_nil_directory_returns_false() {
        let r = rule(ProfileSwitchTrigger::GitRepository {
            name: "repo".into(),
        });
        assert!(!m_dir(&r, None));
    }

    #[test]
    fn test_ssh_host_exact_match() {
        let r = rule(ProfileSwitchTrigger::SshHost {
            hostname: "prod.example.com".into(),
        });
        assert!(m_ssh(&r, Some("prod.example.com")));
    }

    #[test]
    fn test_ssh_host_case_insensitive() {
        let r = rule(ProfileSwitchTrigger::SshHost {
            hostname: "Prod.Example.COM".into(),
        });
        assert!(m_ssh(&r, Some("prod.example.com")));
    }

    #[test]
    fn test_ssh_host_no_match() {
        let r = rule(ProfileSwitchTrigger::SshHost {
            hostname: "prod.example.com".into(),
        });
        assert!(!m_ssh(&r, Some("dev.example.com")));
    }

    #[test]
    fn test_ssh_host_nil_returns_false() {
        let r = rule(ProfileSwitchTrigger::SshHost {
            hostname: "host".into(),
        });
        assert!(!m_ssh(&r, None));
    }

    #[test]
    fn test_process_running_match() {
        let r = rule(ProfileSwitchTrigger::ProcessRunning {
            name: "docker".into(),
        });
        assert!(m_proc(&r, Some(&["zsh", "docker", "node"])));
    }

    #[test]
    fn test_process_running_case_insensitive() {
        let r = rule(ProfileSwitchTrigger::ProcessRunning {
            name: "Docker".into(),
        });
        assert!(m_proc(&r, Some(&["docker"])));
    }

    #[test]
    fn test_process_running_no_match() {
        let r = rule(ProfileSwitchTrigger::ProcessRunning {
            name: "docker".into(),
        });
        assert!(!m_proc(&r, Some(&["zsh", "node"])));
    }

    #[test]
    fn test_process_running_nil_returns_false() {
        let r = rule(ProfileSwitchTrigger::ProcessRunning { name: "vim".into() });
        assert!(!m_proc(&r, None));
    }

    fn env_rule() -> ProfileSwitchRule {
        rule(ProfileSwitchTrigger::EnvironmentVariable {
            key: "NODE_ENV".into(),
            value: "production".into(),
        })
    }

    #[test]
    fn test_env_var_match() {
        assert!(m_env(
            &env_rule(),
            Some(&[("NODE_ENV", "production"), ("PATH", "/usr/bin")])
        ));
    }

    #[test]
    fn test_env_var_no_match_wrong_value() {
        assert!(!m_env(&env_rule(), Some(&[("NODE_ENV", "development")])));
    }

    #[test]
    fn test_env_var_no_match_missing_key() {
        assert!(!m_env(&env_rule(), Some(&[("PATH", "/usr/bin")])));
    }

    #[test]
    fn test_env_var_nil_returns_false() {
        let r = rule(ProfileSwitchTrigger::EnvironmentVariable {
            key: "K".into(),
            value: "V".into(),
        });
        assert!(!m_env(&r, None));
    }

    // matchesGlob

    #[test]
    fn test_glob_exact_path() {
        assert!(glob("/usr/local/bin", "/usr/local/bin"));
    }

    #[test]
    fn test_glob_single_star() {
        assert!(glob("/Users/dev/project", "/Users/*/project"));
        assert!(!glob("/Users/dev/other", "/Users/*/project"));
    }

    #[test]
    fn test_glob_double_star() {
        assert!(glob("/a/b/c/d", "/a/**/d"));
        assert!(glob("/a/d", "/a/**/d"));
    }

    #[test]
    fn test_glob_no_match() {
        assert!(!glob("/foo/bar", "/baz/qux"));
    }

    #[test]
    fn test_glob_different_depth() {
        assert!(!glob("/a/b/c", "/a/b"));
    }

    #[test]
    fn test_glob_partial_wildcard() {
        assert!(glob("/Users/dev/project-v2", "/Users/dev/project-*"));
    }

    // sortedByPriority

    #[test]
    fn test_sorted_by_priority_descending() {
        let low = make_rule(dir("/a"), true, 1);
        let high = make_rule(dir("/b"), true, 10);
        let mid = make_rule(dir("/c"), true, 5);
        let sorted = sorted_by_priority(&[low, high, mid]);
        let priorities: Vec<i64> = sorted.iter().map(|r| r.priority).collect();
        assert_eq!(priorities, vec![10, 5, 1]);
    }

    #[test]
    fn test_sorted_by_priority_tiebreaks_by_name() {
        let mut a = ProfileSwitchRule::new("Alpha", dir("/a"), "p");
        a.priority = 5;
        let mut b = ProfileSwitchRule::new("Beta", dir("/b"), "p");
        b.priority = 5;
        let sorted = sorted_by_priority(&[b, a]);
        let names: Vec<&str> = sorted.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["Alpha", "Beta"]);
    }

    // Codable / Equatable

    #[test]
    fn test_rule_codable_round_trip() {
        let original = make_rule(dir("/Users/dev/work"), true, 5);
        let json = serde_json::to_string(&original).unwrap();
        let decoded: ProfileSwitchRule = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, original);
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["profileName"], "dark-theme");
        assert_eq!(v["isEnabled"], true);
        assert_eq!(v["id"], original.id.to_string().to_uppercase());
    }

    #[test]
    fn test_rule_equality() {
        let id = Uuid::new_v4();
        let t = ProfileSwitchTrigger::SshHost {
            hostname: "h".into(),
        };
        let mut a = ProfileSwitchRule::new("R", t.clone(), "p");
        a.id = id;
        let mut b = ProfileSwitchRule::new("R", t, "p");
        b.id = id;
        assert_eq!(a, b);
    }

    // Branches not covered by the Swift tests

    #[test]
    fn test_glob_expands_tilde_with_home() {
        assert!(ProfileSwitchRule::matches_glob(
            "/Users/me/work",
            "~/work",
            Some("/Users/me")
        ));
        assert!(!ProfileSwitchRule::matches_glob(
            "/Users/me/work",
            "~/work",
            None
        ));
    }

    #[test]
    fn test_glob_middle_wildcard_and_overlap() {
        assert!(glob("/x/abcxyz", "/x/a*c*z"));
        assert!(!glob("/x/a", "/x/a*a"));
        assert!(!glob("/x/ab", "/x/a*c*b"));
    }

    #[test]
    fn test_last_path_component() {
        assert_eq!(last_path_component("/a/b/"), "b");
        assert_eq!(last_path_component("/"), "/");
        assert_eq!(last_path_component(""), "");
        assert_eq!(last_path_component("name"), "name");
    }
}
