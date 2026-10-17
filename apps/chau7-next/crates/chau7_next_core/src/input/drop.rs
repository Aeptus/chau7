//! Drag and drop onto a terminal.
//!
//! Ports `RustTerminalView.performDragOperation` and its helpers: dropped
//! files paste their single-quoted paths separated by spaces; Option-drop of
//! one image file pastes a markdown data URI (`![name](data:mime;base64,...)`)
//! that AI CLIs read, refused (beep) at 10 MB or more.

use base64::Engine;

/// Images at or above this size are refused.
pub const MAX_IMAGE_DROP_SIZE: usize = 10_000_000;

/// `'path'`, with single quotes inside escaped as `'\''`.
pub fn shell_quote(path: &str) -> String {
    format!("'{}'", path.replace('\'', "'\\''"))
}

/// Text pasted for dropped file paths.
pub fn paths_text<S: AsRef<str>>(paths: &[S]) -> String {
    paths
        .iter()
        .map(|p| shell_quote(p.as_ref()))
        .collect::<Vec<_>>()
        .join(" ")
}

/// File extensions treated as images for Option-drop.
pub fn is_image_file(name: &str) -> bool {
    let ext = extension(name);
    matches!(
        ext.as_str(),
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "tiff" | "tif" | "svg"
    )
}

/// MIME type for an image extension (PNG when unknown).
pub fn image_mime(ext: &str) -> &'static str {
    match ext.to_ascii_lowercase().as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "bmp" => "image/bmp",
        _ => "image/png",
    }
}

/// Markdown data URI for image bytes, or `None` when too large.
pub fn image_data_uri(data: &[u8], filename: Option<&str>) -> Option<String> {
    if data.len() >= MAX_IMAGE_DROP_SIZE {
        return None;
    }
    let name = filename.unwrap_or("image.png");
    let mime = image_mime(&extension(name));
    let b64 = base64::engine::general_purpose::STANDARD.encode(data);
    Some(format!("![{name}](data:{mime};base64,{b64})"))
}

fn extension(name: &str) -> String {
    std::path::Path::new(name)
        .extension()
        .map(|e| e.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_paths() {
        assert_eq!(shell_quote("/tmp/a b"), "'/tmp/a b'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(paths_text(&["/a", "/b c"]), "'/a' '/b c'");
    }

    #[test]
    fn detects_images_and_mime() {
        assert!(is_image_file("shot.PNG"));
        assert!(is_image_file("x.tif"));
        assert!(!is_image_file("notes.txt"));
        assert_eq!(image_mime("JPG"), "image/jpeg");
        assert_eq!(image_mime("tiff"), "image/png");
    }

    #[test]
    fn builds_data_uri_with_limit() {
        assert_eq!(
            image_data_uri(b"abc", Some("a.gif")).as_deref(),
            Some("![a.gif](data:image/gif;base64,YWJj)")
        );
        assert_eq!(
            image_data_uri(b"abc", None).as_deref(),
            Some("![image.png](data:image/png;base64,YWJj)")
        );
        assert!(image_data_uri(&vec![0; MAX_IMAGE_DROP_SIZE], None).is_none());
    }
}
