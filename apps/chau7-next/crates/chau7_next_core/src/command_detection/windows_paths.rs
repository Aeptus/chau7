//! Native Windows command discovery. This is a presence check only: it never
//! runs a command or promises that script execution policy permits it.
//! PowerShell command lookup uses PATH and PATHEXT, with qualified paths
//! required for the current directory unless it is explicitly on PATH.
//! The default Windows shell is PowerShell, which also discovers .ps1 scripts
//! without requiring that extension in PATHEXT.
//! https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables?view=powershell-5.1#path-information
//! https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_command_precedence

pub(super) fn tokenize(line: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut single = false;
    let mut double = false;
    let mut escaped = false;
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        if escaped {
            current.push(ch);
            escaped = false;
        } else if ch == '`' && !single {
            escaped = true;
        } else if ch == '\'' && !double {
            if single && chars.peek() == Some(&'\'') {
                chars.next();
                current.push('\'');
            } else {
                single = !single;
            }
        } else if ch == '"' && !single {
            double = !double;
        } else if !single && !double {
            // PowerShell's leading call operator is not a command separator.
            if ch == '&' && tokens.is_empty() && current.is_empty() {
                continue;
            }
            if matches!(ch, '#' | '|' | ';' | '&') {
                break;
            }
            if ch.is_whitespace() {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            } else {
                current.push(ch);
            }
        } else {
            current.push(ch);
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

fn executable_extensions(raw: Option<&str>) -> Vec<String> {
    let mut extensions = Vec::new();
    for extension in raw.unwrap_or(".COM;.EXE;.BAT;.CMD").split(';') {
        let extension = extension.trim();
        if !extension.starts_with('.')
            || extension.len() < 2
            || !extension[1..].bytes().all(|ch| ch.is_ascii_alphanumeric())
        {
            continue;
        }
        let extension = extension.to_ascii_lowercase();
        if !extensions.contains(&extension) {
            extensions.push(extension);
        }
    }
    // PowerShell script presence is independent of PATHEXT. Execution policy
    // remains a separate runtime decision and is never changed here.
    if !extensions.iter().any(|extension| extension == ".ps1") {
        extensions.push(".ps1".into());
    }
    extensions
}

#[cfg(windows)]
pub(super) fn last_path_component(path: &str) -> String {
    use std::path::Path;
    Path::new(path).file_name().map_or_else(
        || {
            if path == "/" {
                "/".to_string()
            } else {
                path.to_string()
            }
        },
        |name| name.to_string_lossy().into_owned(),
    )
}

#[cfg(windows)]
pub(super) fn deleting_path_extension(component: &str) -> String {
    match component.rfind('.') {
        Some(index) if index > 0 && index + 1 < component.len() => component[..index].to_string(),
        _ => component.to_string(),
    }
}

#[cfg(windows)]
fn expand_tilde(path: &str, home: Option<&std::path::Path>) -> std::path::PathBuf {
    let rest = path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\"));
    match (rest, home) {
        (Some(rest), Some(home)) => home.join(rest),
        _ => path.into(),
    }
}

#[cfg(windows)]
fn resolve_path(path: &std::path::Path, cwd: &std::path::Path) -> Option<std::path::PathBuf> {
    use std::path::{Component, PathBuf};
    let resolved = if path.is_absolute() {
        std::path::absolute(path).ok()?
    } else {
        if cwd.as_os_str().is_empty() {
            return None;
        }
        let base = std::path::absolute(cwd).ok()?;
        if let Some(Component::Prefix(prefix)) = path.components().next() {
            // C:foo is relative to that drive's directory, not C:\foo.
            // Prefer this terminal's cwd when it belongs to the same drive.
            if base.components().next() == Some(Component::Prefix(prefix)) {
                base.join(path.components().skip(1).collect::<PathBuf>())
            } else {
                std::path::absolute(path).ok()?
            }
        } else {
            // Native join preserves the drive for a rooted path such as \foo.
            base.join(path)
        }
    };
    // Lexical normalization avoids requiring a real file/directory. Never pop
    // a drive or UNC root when handling parent components.
    let mut normalized = PathBuf::new();
    for component in resolved.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            _ => normalized.push(component.as_os_str()),
        }
    }
    Some(normalized)
}

#[cfg(windows)]
fn candidate_exists(path: &std::path::Path, extensions: &[String]) -> bool {
    if path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            extensions
                .iter()
                .any(|allowed| allowed[1..].eq_ignore_ascii_case(extension))
        })
        && path.is_file()
    {
        return true;
    }
    extensions.iter().any(|extension| {
        let mut candidate = path.as_os_str().to_os_string();
        candidate.push(extension);
        std::path::Path::new(&candidate).is_file()
    })
}

#[cfg(windows)]
fn appears_executable_with(
    token: &str,
    cwd: &std::path::Path,
    search_path: &std::ffi::OsStr,
    extensions: &[String],
    home: Option<&std::path::Path>,
) -> bool {
    use std::path::{Component, Path};
    let token = token.trim();
    if token.is_empty() {
        return false;
    }
    let expanded = expand_tilde(token, home);
    let qualified = token.contains(['/', '\\'])
        || token.starts_with('~')
        || matches!(expanded.components().next(), Some(Component::Prefix(_)));
    if qualified {
        return resolve_path(&expanded, cwd)
            .is_some_and(|path| candidate_exists(&path, extensions));
    }
    std::env::split_paths(search_path)
        .filter(|directory| !directory.as_os_str().is_empty())
        .filter_map(|directory| resolve_path(&directory, cwd))
        .any(|directory| candidate_exists(&directory.join(Path::new(token)), extensions))
}

#[cfg(windows)]
pub(super) fn command_appears_executable(
    token: &str,
    cwd: &str,
    search_path: Option<&str>,
) -> bool {
    use std::path::PathBuf;
    let search_path = search_path
        .filter(|value| !value.is_empty())
        .map(std::ffi::OsString::from)
        .unwrap_or_else(|| std::env::var_os("PATH").unwrap_or_default());
    let home = ["CHAU7_HOME_ROOT", "USERPROFILE", "HOME"]
        .iter()
        .find_map(|key| {
            std::env::var_os(key)
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
        });
    let extensions = executable_extensions(std::env::var("PATHEXT").ok().as_deref());
    appears_executable_with(
        token,
        std::path::Path::new(cwd),
        &search_path,
        &extensions,
        home.as_deref(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_tokens_preserve_native_paths_and_call_operator() {
        assert_eq!(
            tokenize(r#"& "C:\Owned Home\bin\claude.exe" --resume abc"#),
            [r"C:\Owned Home\bin\claude.exe", "--resume", "abc"]
        );
        assert_eq!(
            tokenize(r".\claude.exe --help | other"),
            [r".\claude.exe", "--help"]
        );
        assert_eq!(tokenize("echo 'it''s native'"), ["echo", "it's native"]);
        assert_eq!(tokenize("echo hello` world"), ["echo", "hello world"]);
        assert_eq!(
            tokenize(r"C:\tools\claude.exe; other"),
            [r"C:\tools\claude.exe"]
        );
    }

    #[test]
    fn pathext_is_bounded_to_extensions_and_deduplicated() {
        assert_eq!(
            executable_extensions(Some(" .EXE;.exe;.CMD;txt;.;.a/b;.a\\b;.PS1 ")),
            [".exe", ".cmd", ".ps1"]
        );
        assert_eq!(
            executable_extensions(None),
            [".com", ".exe", ".bat", ".cmd", ".ps1"]
        );
        assert_eq!(executable_extensions(Some("")), [".ps1"]);
    }

    #[cfg(windows)]
    struct OwnedHome(std::path::PathBuf);
    #[cfg(windows)]
    impl OwnedHome {
        fn new() -> Self {
            let home =
                std::env::temp_dir().join(format!("chau7-owned-command-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(home.join("bin with spaces")).unwrap();
            std::fs::create_dir_all(home.join("work")).unwrap();
            Self(home)
        }
        fn executable(&self, relative: &str) -> std::path::PathBuf {
            let path = self.0.join(relative);
            assert!(path.starts_with(&self.0));
            std::fs::write(&path, b"presence fixture only; never executed").unwrap();
            path
        }
    }
    #[cfg(windows)]
    impl Drop for OwnedHome {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[cfg(windows)]
    #[test]
    fn native_path_entries_extensions_and_qualified_commands() {
        let home = OwnedHome::new();
        let exe = home.executable("bin with spaces/claude.exe");
        let cmd = home.executable("bin with spaces/codex.cmd");
        let script = home.executable("bin with spaces/gemini.ps1");
        let local = home.executable("work/claude.exe");
        let text = home.executable("work/claude.txt");
        std::fs::create_dir_all(home.0.join("work/directory.exe")).unwrap();
        let cwd = home.0.join("work");
        let path =
            std::env::join_paths([home.0.join("missing"), home.0.join("bin with spaces")]).unwrap();
        let extensions = executable_extensions(Some(".EXE;.CMD"));
        let check =
            |token: &str| appears_executable_with(token, &cwd, &path, &extensions, Some(&home.0));
        assert!(check("claude"));
        assert!(check("codex"));
        assert!(check("gemini"));
        assert!(check(&script.to_string_lossy()));
        assert!(check(&exe.to_string_lossy()));
        assert!(check(&cmd.to_string_lossy()));
        assert!(check(r".\claude.exe"));
        assert!(check(r"..\bin with spaces\claude"));
        assert!(check(r"~\bin with spaces\claude.exe"));
        assert!(!check(&text.to_string_lossy()));
        assert!(!check(r".\directory.exe"));
        assert!(!check("missing"));
        assert_eq!(
            resolve_path(std::path::Path::new(r".\unused\..\claude.exe"), &cwd),
            Some(local)
        );
        assert_eq!(last_path_component(&exe.to_string_lossy()), "claude.exe");
        let drive = cwd.components().next().unwrap();
        let drive_relative = format!("{}claude.exe", drive.as_os_str().to_string_lossy());
        assert!(check(&drive_relative));
        let rooted_local = cwd
            .components()
            .skip(1)
            .collect::<std::path::PathBuf>()
            .join("claude.exe");
        assert!(check(&rooted_local.to_string_lossy()));
        assert!(appears_executable_with(
            &exe.to_string_lossy(),
            std::path::Path::new(""),
            &path,
            &extensions,
            None
        ));
        let dotted = home.executable("work/claude.wrapper.exe");
        assert!(check(r".\claude.wrapper"));
        assert!(dotted.is_file());
        // Explicit PATH never implicitly adds the terminal working directory.
        let empty_path = std::ffi::OsStr::new(";");
        assert!(!appears_executable_with(
            "claude",
            &cwd,
            empty_path,
            &extensions,
            None
        ));
        let local_path = std::env::join_paths([std::path::Path::new(".")]).unwrap();
        assert!(appears_executable_with(
            "claude",
            &cwd,
            &local_path,
            &extensions,
            None
        ));
        let quoted_path = format!("\"{}\"", home.0.join("bin with spaces").display());
        assert!(appears_executable_with(
            "claude",
            &cwd,
            std::ffi::OsStr::new(&quoted_path),
            &extensions,
            None
        ));
    }

    #[cfg(windows)]
    #[test]
    fn actual_detection_uses_native_basename_and_tokenization() {
        let home = OwnedHome::new();
        let exe = home.executable("bin with spaces/claude.exe");
        let cwd = home.0.join("work");
        let path = std::env::join_paths([home.0.join("bin with spaces")]).unwrap();
        let cwd = cwd.to_str().unwrap();
        let path = path.to_str().unwrap();
        assert_eq!(
            super::super::detect_launchable_app("claude", cwd, Some(path)),
            Some("Claude".into())
        );
        let command = format!("& \"{}\" --help", exe.display());
        assert_eq!(
            super::super::detect_launchable_app(&command, cwd, Some(path)),
            Some("Claude".into())
        );
        assert_eq!(
            super::super::command_token(&command),
            Some(exe.to_string_lossy().into_owned())
        );
        assert_eq!(
            super::super::detect_app(r"C:\Tools\claude.exe --help"),
            Some("Claude".into())
        );
    }
}
