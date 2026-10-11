//! Text helpers of the editor and preview panes: the text editor model's
//! append and file name (`TextEditorModel` in
//! `SplitPanes/SplitPaneController.swift`), going to a line, and the
//! IDE-style editing of `Editor/EnhancedEditorView.swift` (outdent,
//! auto-indent, bracket matching).
//!
//! Offsets are byte offsets into UTF-8 text.

use sha2::{Digest, Sha256};
use std::path::Path;

pub type ContentHash = [u8; 32];
pub fn content_hash(bytes: &[u8]) -> ContentHash {
    Sha256::digest(bytes).into()
}

/// Missing files may be recreated; unreadable existing files must not be overwritten.
pub fn can_save_file(path: &Path, loaded: Option<ContentHash>) -> std::io::Result<bool> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(loaded.is_none_or(|hash| hash == content_hash(&bytes))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Err(error) => Err(error),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExternalChange {
    Unchanged,
    Reload,
    Conflict,
}
pub fn external_change(loaded: Option<ContentHash>, bytes: &[u8], dirty: bool) -> ExternalChange {
    if loaded == Some(content_hash(bytes)) {
        ExternalChange::Unchanged
    } else if dirty {
        ExternalChange::Conflict
    } else {
        ExternalChange::Reload
    }
}

/// Auto-save only files owned by Next, never shared repository metadata.
pub fn default_autosave(path: &Path, own_config: &Path) -> bool {
    path.starts_with(own_config)
        && (path.file_name().is_some_and(|name| name == "plan.md")
            || path
                .components()
                .any(|part| part.as_os_str() == "session-notes"))
}

#[cfg(test)]
mod persistence_tests {
    use super::*;
    #[test]
    fn clean_reload_and_dirty_conflict_are_distinct() {
        let hash = Some(content_hash(b"original"));
        assert_eq!(
            external_change(hash, b"original", true),
            ExternalChange::Unchanged
        );
        assert_eq!(external_change(hash, b"new", false), ExternalChange::Reload);
        assert_eq!(
            external_change(hash, b"new", true),
            ExternalChange::Conflict
        );
    }
    #[test]
    fn saves_guard_current_disk_and_allow_deleted_files() {
        let path = std::env::temp_dir().join(format!("editor-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, b"original").unwrap();
        let hash = Some(content_hash(b"original"));
        assert!(can_save_file(&path, hash).unwrap());
        std::fs::write(&path, b"external").unwrap();
        assert!(!can_save_file(&path, hash).unwrap());
        std::fs::remove_file(&path).unwrap();
        assert!(can_save_file(&path, hash).unwrap());
    }
}

/// Name shown in the editor header (`fileName`): the last path component,
/// or "Untitled".
pub fn editor_file_name(path: Option<&str>) -> String {
    file_name_or(path, "Untitled")
}

/// Name shown in the preview and diff headers: the last path component, or
/// "No File".
pub fn preview_file_name(path: Option<&str>) -> String {
    file_name_or(path, "No File")
}

fn file_name_or(path: Option<&str>, fallback: &str) -> String {
    match path {
        Some(path) => Path::new(path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.to_string()),
        None => fallback.to_string(),
    }
}

/// Image files the preview shows as pictures (`FilePreviewModel.imageExtensions`).
pub const IMAGE_EXTENSIONS: [&str; 10] = [
    "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "bmp", "tiff", "tif",
];

/// Whether the preview shows `path` as an image (extension, case-insensitive).
pub fn is_image_path(path: &str) -> bool {
    Path::new(path)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .is_some_and(|e| IMAGE_EXTENSIONS.contains(&e.as_str()))
}

/// `appendText`: the trimmed text added at the end, on a new line unless
/// the content is empty or already ends with one. `None` when the text is
/// only whitespace (nothing changes).
pub fn append_text(content: &str, text: &str) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(if content.is_empty() {
        trimmed.to_string()
    } else if content.ends_with('\n') {
        format!("{content}{trimmed}")
    } else {
        format!("{content}\n{trimmed}")
    })
}

/// Offset of the start of 1-based `line` (`scrollToLine`); past the last
/// line gives the end of the text.
pub fn line_start_offset(text: &str, line: usize) -> usize {
    if line <= 1 {
        return 0;
    }
    let mut current = 1;
    for (i, b) in text.bytes().enumerate() {
        if b == b'\n' {
            current += 1;
            if current == line {
                return i + 1;
            }
        }
    }
    text.len()
}

/// The leading spaces and tabs of the line before a newline just typed at
/// `cursor` (`handleAutoIndent`): what to insert after it. `None` when the
/// character before the cursor is not a newline or the line has no indent.
pub fn auto_indent_after_newline(text: &str, cursor: usize) -> Option<String> {
    if cursor == 0 || cursor > text.len() || text.as_bytes()[cursor - 1] != b'\n' {
        return None;
    }
    let before = &text[..cursor - 1];
    let line_start = before.rfind('\n').map_or(0, |i| i + 1);
    let indent: String = before[line_start..]
        .chars()
        .take_while(|c| *c == ' ' || *c == '\t')
        .collect();
    (!indent.is_empty()).then_some(indent)
}

/// What Enter inserts at `cursor` with auto-indent on (`handleAutoIndent`):
/// a newline followed by the leading spaces and tabs of the text between the
/// start of the cursor's line and the cursor. Unlike the code editor's own
/// Enter, no extra level is added after `{` or `:` and the next line's indent
/// is not looked at.
pub fn newline_with_indent(text: &str, cursor: usize) -> String {
    let mut cursor = cursor.min(text.len());
    while !text.is_char_boundary(cursor) {
        cursor -= 1;
    }
    let mut probe = text[..cursor].to_string();
    probe.push('\n');
    let indent = auto_indent_after_newline(&probe, probe.len()).unwrap_or_default();
    format!("\n{indent}")
}

/// The leading whitespace of the line containing `offset`.
pub fn line_indent_at(text: &str, offset: usize) -> String {
    let offset = offset.min(text.len());
    let start = text[..offset].rfind('\n').map_or(0, |i| i + 1);
    text[start..]
        .chars()
        .take_while(|c| *c == ' ' || *c == '\t')
        .collect()
}

/// Shift+Tab (`handleOutdent`): the range of the line at `offset` and the
/// number of leading bytes to delete, the tab string first, else one tab.
pub fn outdent(text: &str, offset: usize, tab_string: &str) -> Option<(usize, usize)> {
    let offset = offset.min(text.len());
    let start = text[..offset].rfind('\n').map_or(0, |i| i + 1);
    let line = &text[start..];
    if !tab_string.is_empty() && line.starts_with(tab_string) {
        Some((start, tab_string.len()))
    } else if line.starts_with('\t') {
        Some((start, 1))
    } else {
        None
    }
}

fn pair_of(c: u8) -> Option<(u8, u8, bool)> {
    match c {
        b'(' => Some((b'(', b')', true)),
        b'[' => Some((b'[', b']', true)),
        b'{' => Some((b'{', b'}', true)),
        b'<' => Some((b'<', b'>', true)),
        b')' => Some((b'(', b')', false)),
        b']' => Some((b'[', b']', false)),
        b'}' => Some((b'{', b'}', false)),
        b'>' => Some((b'<', b'>', false)),
        _ => None,
    }
}

/// The bracket matching the one at `offset` (`highlightMatchingBracket`,
/// `jumpToMatchingBracket`): `()[]{}<>`, searching forward from an opener
/// and backward from a closer, counting nesting.
pub fn matching_bracket(text: &str, offset: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    let &c = bytes.get(offset)?;
    let (open, close, forward) = pair_of(c)?;
    let mut depth = 0i64;
    if forward {
        for (i, &b) in bytes.iter().enumerate().skip(offset) {
            if b == open {
                depth += 1;
            }
            if b == close {
                depth -= 1;
            }
            if depth == 0 && i != offset {
                return Some(i);
            }
        }
    } else {
        for i in (0..=offset).rev() {
            let b = bytes[i];
            if b == close {
                depth += 1;
            }
            if b == open {
                depth -= 1;
            }
            if depth == 0 && i != offset {
                return Some(i);
            }
        }
    }
    None
}

/// Bracket next to the cursor and its match: the character at the cursor,
/// else the one just before it (moving "next to" a bracket).
pub fn bracket_pair_near(text: &str, cursor: usize) -> Option<(usize, usize)> {
    if let Some(m) = matching_bracket(text, cursor) {
        return Some((cursor, m));
    }
    let before = cursor.checked_sub(1)?;
    matching_bracket(text, before).map(|m| (before, m))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_names() {
        assert_eq!(editor_file_name(None), "Untitled");
        assert_eq!(editor_file_name(Some("/tmp/a/notes.txt")), "notes.txt");
        assert_eq!(preview_file_name(None), "No File");
        assert_eq!(preview_file_name(Some("/x/y.rs")), "y.rs");
    }

    #[test]
    fn image_detection() {
        assert!(is_image_path("/a/b.PNG"));
        assert!(is_image_path("x.tif"));
        assert!(!is_image_path("x.rs"));
        assert!(!is_image_path("png"));
    }

    #[test]
    fn append_like_swift() {
        assert_eq!(append_text("", "  hello \n").as_deref(), Some("hello"));
        assert_eq!(append_text("a", "b").as_deref(), Some("a\nb"));
        assert_eq!(append_text("a\n", "b").as_deref(), Some("a\nb"));
        assert_eq!(append_text("a", "  \n\t"), None);
    }

    #[test]
    fn line_offsets() {
        let text = "one\ntwo\nthree";
        assert_eq!(line_start_offset(text, 0), 0);
        assert_eq!(line_start_offset(text, 1), 0);
        assert_eq!(line_start_offset(text, 2), 4);
        assert_eq!(line_start_offset(text, 3), 8);
        assert_eq!(line_start_offset(text, 9), text.len());
    }

    #[test]
    fn auto_indent_copies_previous_whitespace() {
        let text = "    let x = 1;\n";
        assert_eq!(
            auto_indent_after_newline(text, text.len()).as_deref(),
            Some("    ")
        );
        assert_eq!(auto_indent_after_newline("x\n", 2), None);
        // Enter: the previous line's indent, nothing more.
        assert_eq!(newline_with_indent("    if x {", 10), "\n    ");
        assert_eq!(newline_with_indent("\tfoo\nbar", 4), "\n\t");
        assert_eq!(newline_with_indent("a\n  b", 5), "\n  ");
        assert_eq!(newline_with_indent("nothing", 7), "\n");
        // Cursor inside the indent: only the part before it.
        assert_eq!(newline_with_indent("    x", 2), "\n  ");
        assert_eq!(newline_with_indent("", 0), "\n");
        assert_eq!(auto_indent_after_newline("\tx", 2), None);
        assert_eq!(line_indent_at("a\n\t  b", 5), "\t  ");
    }

    #[test]
    fn outdent_removes_tab_string_or_tab() {
        let text = "a\n    b";
        assert_eq!(outdent(text, 5, "    "), Some((2, 4)));
        assert_eq!(outdent("\tb", 1, "    "), Some((0, 1)));
        assert_eq!(outdent("  b", 1, "    "), None);
    }

    #[test]
    fn brackets() {
        let text = "f(a[1], {b})";
        assert_eq!(matching_bracket(text, 1), Some(11));
        assert_eq!(matching_bracket(text, 11), Some(1));
        assert_eq!(matching_bracket(text, 3), Some(5));
        assert_eq!(matching_bracket(text, 8), Some(10));
        assert_eq!(matching_bracket(text, 0), None);
        assert_eq!(matching_bracket("(()", 0), None);
        assert_eq!(bracket_pair_near(text, 12), Some((11, 1)));
        assert_eq!(bracket_pair_near(text, 1), Some((1, 11)));
        assert_eq!(bracket_pair_near("ab", 1), None);
    }
}
