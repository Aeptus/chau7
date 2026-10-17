//! Cmd-click on URLs and file paths in the terminal (`PathClickHandler.swift`).
//!
//! Order matches Swift: an OSC 8 hyperlink first, then a URL in the text,
//! then a file path that exists (relative to the tab's directory).

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use chau7_next_core::link_detect::{self, EDITOR_SEARCH_DIRS, EditorLaunch, LinkTarget, PathMatch};
use gpui::{App, Entity, Modifiers};

use super::session::TerminalSession;
use crate::settings::Settings;

/// What a Cmd-click should open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Url(String),
    Path(PathMatch),
}

/// Cmd on macOS, Ctrl elsewhere (the Linux and Windows stand-in for Cmd).
pub fn is_link_modifier(m: &Modifiers) -> bool {
    m.platform || (m.control && !cfg!(target_os = "macos"))
}

/// The link under a viewport cell, if any.
pub fn target_at(
    session: &Entity<TerminalSession>,
    col: i32,
    row: i32,
    cx: &App,
) -> Option<Target> {
    let settings = Settings::get(cx);
    let urls = settings.appearance.display.clickable_urls;
    let paths = settings.productivity.cmd_click_paths;
    let session = session.read(cx);
    let grid = &session.grid;
    let cell = grid
        .cells
        .get(row as usize * grid.cols as usize + col as usize)?;
    // OSC 8 hyperlinks always open; plain URLs follow "Clickable URLs"
    // (Display) and paths follow "Cmd-click paths" (`feature.cmdClickPaths`).
    if cell.link_id != 0 {
        return session
            .link_url(cell.link_id)
            .map(|url| url_target(url, session.cwd.as_deref()));
    }
    if !urls && !paths {
        return None;
    }
    let line = row - grid.display_offset as i32;
    let (text, utf16) = session.logical_line_hit(line, col as usize)?;
    let index = utf16_to_char_index(&text, utf16);
    match link_detect::target_at(&text, index)? {
        LinkTarget::Url(url) => urls.then(|| url_target(url.url, session.cwd.as_deref())),
        LinkTarget::Path(path) if paths => {
            let resolved = resolve(&path.path, session.cwd.as_deref());
            resolved.exists().then_some(Target::Path(path))
        }
        LinkTarget::Path(_) => None,
    }
}

/// OSC 8 and detected file URIs must take the same editor route as file paths.
/// Preserve the original URL when it is remote, malformed or unavailable locally.
fn url_target(url: String, cwd: Option<&Path>) -> Target {
    if let Some(path) = link_detect::hyperlink_path(&url)
        && resolve(&path.path, cwd).is_file()
    {
        return Target::Path(path);
    }
    Target::Url(url)
}

/// The logical-line hit counts UTF-16 units; the matcher counts characters.
fn utf16_to_char_index(text: &str, utf16: usize) -> usize {
    let mut units = 0;
    for (i, c) in text.chars().enumerate() {
        if units >= utf16 {
            return i;
        }
        units += c.len_utf16();
    }
    text.chars().count()
}

fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

fn resolve(path: &str, cwd: Option<&Path>) -> PathBuf {
    let dir = cwd
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(home);
    link_detect::resolve_path(path, &dir, &home())
}

fn find_executable(name: &str) -> Option<String> {
    EDITOR_SEARCH_DIRS
        .iter()
        .map(|dir| Path::new(dir).join(name))
        .find(|p| p.is_file())
        .map(|p| p.to_string_lossy().into_owned())
}

/// A Cmd-clicked file that "Open in internal editor" sends to the tab's
/// editor pane (`onFilePathClicked`, CMD-040): the resolved path and line.
pub fn internal_editor_target(
    session: &Entity<TerminalSession>,
    target: &Target,
    cx: &App,
) -> Option<(PathBuf, Option<usize>)> {
    let Target::Path(path) = target else {
        return None;
    };
    if !Settings::get(cx).productivity.cmd_click_internal_editor {
        return None;
    }
    let full = resolve(&path.path, session.read(cx).cwd.as_deref());
    full.exists().then(|| (full, path.line.map(|l| l as usize)))
}

/// Open the link. Returns false when nothing was opened.
pub fn activate(session: &Entity<TerminalSession>, target: Target, cx: &mut App) -> bool {
    match target {
        Target::Url(url) => {
            open_url(&url, cx);
            true
        }
        Target::Path(path) => {
            let cwd = session.read(cx).cwd.clone();
            open_path(&path, cwd.as_deref(), cx)
        }
    }
}

fn open_url(url: &str, cx: &mut App) {
    let handler = Settings::get(cx).productivity.url_handler;
    // Remaining URLs (including remote file and ssh URLs) go to the system.
    let is_web = url.starts_with("http://") || url.starts_with("https://");
    if is_web
        && let Some(bundle) = handler.bundle_identifier()
        && crate::platform::workspace::open_url_with(url, bundle).is_ok()
    {
        return;
    }
    cx.open_url(url);
}

fn open_path(path: &PathMatch, cwd: Option<&Path>, cx: &mut App) -> bool {
    let full = resolve(&path.path, cwd);
    if !full.exists() {
        return false;
    }
    let full_str = full.to_string_lossy().into_owned();
    let productivity = &Settings::get(cx).productivity;
    // With "Open in internal editor" on, the terminal view sends the click to
    // the editor pane first (`internal_editor_target`).
    let env_editor = std::env::var("EDITOR").unwrap_or_default();
    match link_detect::editor_launch(
        &full_str,
        path.line,
        path.column,
        &productivity.default_editor,
        &env_editor,
        &find_executable,
    ) {
        EditorLaunch::Run { program, args } => {
            let spawned = Command::new(&program)
                .args(&args)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .is_ok();
            if !spawned {
                cx.open_url(&link_detect::file_uri(&full_str));
            }
            true
        }
        EditorLaunch::SystemOpen => {
            cx.open_url(&link_detect::file_uri(&full_str));
            true
        }
        EditorLaunch::Refused => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_uri_routes_to_the_same_path_target_as_plain_text() {
        let fixture = std::env::temp_dir().join(format!("chau7 link {}.md", uuid::Uuid::new_v4()));
        std::fs::write(&fixture, "# fixture").unwrap();
        let url = link_detect::file_uri(&fixture.to_string_lossy());
        let target = url_target(url, None);
        std::fs::remove_file(&fixture).unwrap();
        assert!(matches!(target, Target::Path(p) if Path::new(&p.path) == fixture));
        let remote = "file://remote/fixture/Notes.md".to_string();
        assert_eq!(url_target(remote.clone(), None), Target::Url(remote));
    }

    #[test]
    fn utf16_offsets_map_to_chars() {
        assert_eq!(utf16_to_char_index("a😀b", 3), 2);
        assert_eq!(utf16_to_char_index("abc", 1), 1);
    }

    #[test]
    fn encodes_spaces_and_unicode() {
        assert_eq!(
            link_detect::file_uri("/a b/é.rs"),
            "file:///a%20b/%C3%A9.rs"
        );
    }

    #[test]
    fn relative_paths_use_the_tab_directory() {
        assert_eq!(
            resolve("src/a.rs", Some(Path::new("/w"))),
            PathBuf::from("/w/src/a.rs")
        );
    }
}
