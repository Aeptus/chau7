//! Pure logic of the app shell: quit and close confirmations, paste escaping
//! and the `chau7-next://` URL scheme.
//!
//! Mirrors `AppDelegate.swift` (`applicationShouldTerminate`, `pasteEscaped`,
//! `handleChau7URL`) and `PasteEscaper.swift`. Swift registers `chau7://`;
//! Chau7 Next registers `chau7-next://` so both apps can be installed
//! (`docs/rust-port/DUAL-SHIP.md`) and handles only its own scheme. Hosts and
//! paths are the same. `ssh` targets are validated (a target such as
//! `-oProxyCommand=...` would run a command) and confirmed before running.

/// URL scheme Chau7 Next registers.
pub const URL_SCHEME: &str = "chau7-next";

/// Title and detail of the "Quit" confirmation, or `None` when nothing runs.
/// Names are de-duplicated and sorted, empty names dropped
/// (`applicationShouldTerminate`).
pub fn quit_confirmation(process_names: &[String]) -> Option<(String, String)> {
    quit_confirmation_localized(process_names, crate::l10n::Lang::En)
}

/// Actual UI variant using the current Swift plural table and isolated app name.
pub fn quit_confirmation_localized(
    process_names: &[String],
    lang: crate::l10n::Lang,
) -> Option<(String, String)> {
    let mut unique: Vec<&str> = process_names
        .iter()
        .map(String::as_str)
        .filter(|n| !n.is_empty())
        .collect();
    unique.sort_unstable();
    unique.dedup();
    if unique.is_empty() {
        return None;
    }
    let count = unique.len();
    Some((
        crate::l10n::localized(lang, "alert.quit.title", "Quit Chau7?")
            .replace("Chau7", "Chau7 Next"),
        crate::l10n::localized_format(
            lang,
            "alert.quit.message",
            "%d running process(es) will be terminated: %@",
            &[
                crate::l10n::Arg::Int(count as i64),
                crate::l10n::Arg::Str(unique.join(", ")),
            ],
        ),
    ))
}

/// What an app URL asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppUrl {
    /// `run/<base64 command>`: confirm, then run in a new tab.
    Run { command: String, source: String },
    /// `ssh/user@host[:port]`.
    Ssh { target: String },
    /// `cd/<path>`.
    Cd { path: String },
    /// `open/<path>`: open the file in an editor pane.
    Open { path: String },
}

/// Why a URL was not understood.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UrlError {
    WrongScheme,
    InvalidCommand,
    MissingTarget,
    /// The `ssh` target is not `[user@]host[:port]` (for example it starts
    /// with `-` and would be read as an ssh option).
    InvalidTarget,
    UnknownHost(String),
}

/// Whether `target` is a plausible `[user@]host[:port]`: no leading `-`,
/// user of `[A-Za-z0-9._-]`, host of `[A-Za-z0-9.-]` (or a bracketed IPv6
/// address), numeric port.
pub fn is_valid_ssh_target(target: &str) -> bool {
    if target.is_empty() || target.len() > 255 || target.starts_with('-') {
        return false;
    }
    let (user, host_port) = match target.rsplit_once('@') {
        Some((user, rest)) => (Some(user), rest),
        None => (None, target),
    };
    if let Some(user) = user
        && (user.is_empty()
            || user.starts_with('-')
            || !user
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')))
    {
        return false;
    }
    let (host, port) = if let Some(rest) = host_port.strip_prefix('[') {
        let Some((addr, after)) = rest.split_once(']') else {
            return false;
        };
        if addr.is_empty() || !addr.chars().all(|c| c.is_ascii_hexdigit() || c == ':') {
            return false;
        }
        match after {
            "" => (addr, None),
            p => match p.strip_prefix(':') {
                Some(port) => (addr, Some(port)),
                None => return false,
            },
        }
    } else {
        match host_port.split_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (host_port, None),
        }
    };
    if host.is_empty() || host.starts_with('-') {
        return false;
    }
    if !host_port.starts_with('[')
        && !host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
    {
        return false;
    }
    match port {
        None => true,
        Some(p) => !p.is_empty() && p.len() <= 5 && p.parse::<u16>().is_ok_and(|n| n > 0),
    }
}

/// Detail of the "Connect with SSH?" confirmation.
pub fn ssh_confirmation_detail(target: &str, source: &str) -> String {
    format!("A URL is requesting an SSH connection to:\n\n{target}\n\nSource: {source}")
}

/// Single-quote a value for the shell (`'` becomes `'\''`).
pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

impl AppUrl {
    /// Command typed into the new tab (`run`, `ssh`, `cd`); `None` for `open`.
    pub fn tab_command(&self) -> Option<String> {
        match self {
            AppUrl::Run { command, .. } => Some(command.clone()),
            AppUrl::Ssh { target } => Some(format!("ssh -- {}", shell_quote(target))),
            AppUrl::Cd { path } => Some(format!("cd {} && clear", shell_quote(path))),
            AppUrl::Open { .. } => None,
        }
    }
}

/// First 500 characters of a command, as shown in the confirmation.
pub fn run_confirmation_detail(command: &str, source: &str) -> String {
    let shown: String = command.chars().take(500).collect();
    format!("A URL is requesting to run:\n\n{shown}\n\nSource: {source}")
}

/// Parse `chau7-next://<host>/<path>`. `chau7://` belongs to the Swift app and
/// is rejected.
pub fn parse_url(url: &str) -> Result<AppUrl, UrlError> {
    let (scheme, rest) = url.split_once("://").ok_or(UrlError::WrongScheme)?;
    if !scheme.eq_ignore_ascii_case(URL_SCHEME) {
        return Err(UrlError::WrongScheme);
    }
    let rest = rest.split(['?', '#']).next().unwrap_or("");
    let (host, path) = rest.split_once('/').unwrap_or((rest, ""));
    let path = percent_decode(path.trim_matches('/'));
    match host {
        "run" => {
            if path.is_empty() {
                return Err(UrlError::InvalidCommand);
            }
            let bytes = base64_decode(&path).ok_or(UrlError::InvalidCommand)?;
            let command = String::from_utf8(bytes).map_err(|_| UrlError::InvalidCommand)?;
            Ok(AppUrl::Run {
                command,
                source: url.to_string(),
            })
        }
        "ssh" if !path.is_empty() => {
            if is_valid_ssh_target(&path) {
                Ok(AppUrl::Ssh { target: path })
            } else {
                Err(UrlError::InvalidTarget)
            }
        }
        "ssh" => Err(UrlError::MissingTarget),
        "cd" => Ok(AppUrl::Cd {
            path: format!("/{path}"),
        }),
        "open" => Ok(AppUrl::Open {
            path: format!("/{path}"),
        }),
        other => Err(UrlError::UnknownHost(other.to_string())),
    }
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2]))
        {
            out.push(h * 16 + l);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Standard base64 (also accepts URL-safe characters and missing padding).
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut acc = 0u32;
    let mut bits = 0;
    for c in text.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' => break,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

/// The `<string>` value of `key` in a plain XML `Info.plist`.
pub fn plist_string(xml: &str, key: &str) -> Option<String> {
    let marker = format!("<key>{key}</key>");
    let after = &xml[xml.find(&marker)? + marker.len()..];
    let start = after.find("<string>")? + "<string>".len();
    // The value must come right after the key, not belong to a later key.
    if after[..start - "<string>".len()].contains("<key>") {
        return None;
    }
    let end = after[start..].find("</string>")?;
    Some(after[start..start + end].trim().to_string())
}

/// `path` with the home folder written as `~` (`abbreviatingWithTildeInPath`).
pub fn abbreviate_home(path: &str, home: &str) -> String {
    let home = home.trim_end_matches('/');
    if home.is_empty() {
        return path.to_string();
    }
    match path.strip_prefix(home) {
        Some("") => "~".to_string(),
        Some(rest) if rest.starts_with('/') => format!("~{rest}"),
        _ => path.to_string(),
    }
}

/// How long ago, for "Last Loaded": "just now", "5 min ago", "2 h ago".
pub fn relative_age(seconds: u64) -> String {
    match seconds {
        0..=9 => "just now".to_string(),
        10..=59 => format!("{seconds} s ago"),
        60..=3599 => format!("{} min ago", seconds / 60),
        3600..=86399 => format!("{} h ago", seconds / 3600),
        _ => format!("{} d ago", seconds / 86400),
    }
}

/// The CPU architecture as the About pane writes it.
pub fn architecture_label(arch: &str) -> &'static str {
    match arch {
        "aarch64" => "Apple Silicon (arm64)",
        "x86_64" => "Intel (x86_64)",
        _ => "Unknown",
    }
}

/// "1.2 (45)", "1.2", "45" or "Development Build" from the short version and
/// the build number (`bundleVersion`).
pub fn version_label(short: Option<&str>, build: Option<&str>) -> String {
    match (short, build) {
        (Some(short), Some(build)) => format!("{short} ({build})"),
        (Some(short), None) => short.to_string(),
        (None, Some(build)) => build.to_string(),
        (None, None) => "Development Build".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_plist_strings() {
        let xml = "<dict>\n<key>CFBundleVersion</key>\n<string>45</string>\n<key>Flag</key>\n<true/>\n<key>Other</key><string>x</string></dict>";
        assert_eq!(plist_string(xml, "CFBundleVersion").as_deref(), Some("45"));
        assert_eq!(plist_string(xml, "Other").as_deref(), Some("x"));
        assert_eq!(plist_string(xml, "Flag"), None);
        assert_eq!(plist_string(xml, "Missing"), None);
    }

    #[test]
    fn about_labels() {
        assert_eq!(abbreviate_home("/Users/me/code", "/Users/me"), "~/code");
        assert_eq!(abbreviate_home("/Users/me", "/Users/me/"), "~");
        assert_eq!(abbreviate_home("/Users/meow", "/Users/me"), "/Users/meow");
        assert_eq!(relative_age(3), "just now");
        assert_eq!(relative_age(125), "2 min ago");
        assert_eq!(relative_age(7200), "2 h ago");
        assert_eq!(relative_age(200000), "2 d ago");
        assert_eq!(architecture_label("aarch64"), "Apple Silicon (arm64)");
        assert_eq!(architecture_label("riscv"), "Unknown");
        assert_eq!(version_label(Some("1.2"), Some("45")), "1.2 (45)");
        assert_eq!(version_label(None, None), "Development Build");
    }

    #[test]
    fn quit_message_lists_unique_sorted_names() {
        assert_eq!(quit_confirmation(&[]), None);
        assert_eq!(quit_confirmation(&[String::new()]), None);
        let (title, detail) =
            quit_confirmation(&["vim".into(), "sleep".into(), "vim".into()]).unwrap();
        assert_eq!(title, "Quit Chau7 Next?");
        assert_eq!(detail, "2 running processes will be terminated: sleep, vim");
        let (_, one) = quit_confirmation(&["top".into()]).unwrap();
        assert_eq!(one, "1 running process will be terminated: top");
    }

    #[test]
    fn localized_quit_uses_sorted_unique_count_and_preserves_process_text() {
        for lang in crate::l10n::Lang::ALL {
            assert_eq!(quit_confirmation_localized(&[], lang), None);
            for count in [1, 2, 3, 11] {
                let mut names: Vec<String> = (0..count).map(|n| format!("job-{n}%@")).collect();
                names.push(names[0].clone());
                names.push(String::new());
                let (title, detail) = quit_confirmation_localized(&names, lang).unwrap();
                names.retain(|s| !s.is_empty());
                names.sort();
                names.dedup();
                let expected = crate::l10n::localized_format(
                    lang,
                    "alert.quit.message",
                    "",
                    &[
                        crate::l10n::Arg::Int(count),
                        crate::l10n::Arg::Str(names.join(", ")),
                    ],
                );
                assert_eq!(detail, expected);
                assert!(detail.contains("job-0%@"));
                assert!(title.contains("Chau7 Next"));
            }
        }
    }

    #[test]
    fn parses_urls() {
        assert_eq!(
            parse_url("chau7-next://ssh/me@host:2200"),
            Ok(AppUrl::Ssh {
                target: "me@host:2200".into()
            })
        );
        assert_eq!(
            parse_url("chau7-next://cd/Users/me/My%20Code"),
            Ok(AppUrl::Cd {
                path: "/Users/me/My Code".into()
            })
        );
        assert_eq!(
            parse_url("chau7-next://open/tmp/a.md"),
            Ok(AppUrl::Open {
                path: "/tmp/a.md".into()
            })
        );
        // "ls -la" in base64.
        let run = parse_url("chau7-next://run/bHMgLWxh").unwrap();
        assert_eq!(run.tab_command().as_deref(), Some("ls -la"));
        assert_eq!(parse_url("http://x"), Err(UrlError::WrongScheme));
        // The Swift app's scheme is not handled by Chau7 Next.
        assert_eq!(parse_url("chau7://cd/tmp"), Err(UrlError::WrongScheme));
        assert_eq!(parse_url("chau7-next://ssh/"), Err(UrlError::MissingTarget));
        assert_eq!(
            parse_url("chau7-next://run/!!"),
            Err(UrlError::InvalidCommand)
        );
        assert_eq!(
            parse_url("chau7-next://nope/x"),
            Err(UrlError::UnknownHost("nope".into()))
        );
    }

    #[test]
    fn tab_commands_quote_arguments() {
        assert_eq!(
            AppUrl::Ssh {
                target: "o'brien@h".into()
            }
            .tab_command()
            .as_deref(),
            Some(r#"ssh -- 'o'\''brien@h'"#)
        );
        assert_eq!(
            AppUrl::Cd {
                path: "/a b".into()
            }
            .tab_command()
            .as_deref(),
            Some("cd '/a b' && clear")
        );
    }

    #[test]
    fn rejects_ssh_option_injection() {
        for bad in [
            "chau7-next://ssh/-oProxyCommand=touch%20%2Ftmp%2Fpwned",
            "chau7-next://ssh/-p",
            "chau7-next://ssh/me@-oProxyCommand=x",
            "chau7-next://ssh/host;rm",
            "chau7-next://ssh/host%20-oX",
            "chau7-next://ssh/host:abc",
            "chau7-next://ssh/host:99999",
            "chau7-next://ssh/@host",
            "chau7-next://ssh/a$(id)@host",
        ] {
            assert_eq!(parse_url(bad), Err(UrlError::InvalidTarget), "{bad}");
        }
        for good in [
            "host",
            "me@host.example.com",
            "me.x@h-1:22",
            "[::1]:2222",
            "u@10.0.0.1",
        ] {
            assert!(is_valid_ssh_target(good), "{good}");
        }
        let detail = ssh_confirmation_detail("me@h", "src");
        assert!(detail.contains("me@h") && detail.contains("src"));
    }

    #[test]
    fn run_detail_is_capped() {
        let long = "x".repeat(600);
        let detail = run_confirmation_detail(&long, "src");
        assert!(detail.contains(&"x".repeat(500)));
        assert!(!detail.contains(&"x".repeat(501)));
    }
}
