//! OSC 7 (current working directory) from raw PTY output.
//!
//! Ports `parseOSC7(from:)` and `processOSC7URL(_:)` from
//! `apps/chau7-macos/Sources/Chau7/RustBackend/RustTerminalView.swift`:
//! `ESC ] 7 ; file://host/path` terminated by BEL or `ESC \`. The path is
//! percent-decoded and the host dropped, so directories reported by remote
//! shells (ssh) come through too. Unlike the Swift scan, which only looks at
//! one output chunk, [`Osc7Scanner`] keeps a partial sequence across chunks.

/// Longest OSC 7 body kept while waiting for its terminator.
const MAX_BODY: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum State {
    #[default]
    Ground,
    Esc,
    /// After `ESC ]`: matching the `7;` prefix (count of bytes matched).
    Prefix(u8),
    Body,
    BodyEsc,
}

/// Streaming OSC 7 scanner: feed output chunks, get the directories reported.
#[derive(Debug, Clone, Default)]
pub struct Osc7Scanner {
    state: State,
    body: Vec<u8>,
}

impl Osc7Scanner {
    pub fn new() -> Self {
        Self::default()
    }

    /// Scans `data` and returns each reported path, in order.
    pub fn feed(&mut self, data: &[u8]) -> Vec<String> {
        let mut out = Vec::new();
        for &byte in data {
            self.state = match self.state {
                State::Ground => {
                    if byte == 0x1b {
                        State::Esc
                    } else {
                        State::Ground
                    }
                }
                State::Esc => match byte {
                    b']' => State::Prefix(0),
                    0x1b => State::Esc,
                    _ => State::Ground,
                },
                State::Prefix(0) if byte == b'7' => State::Prefix(1),
                State::Prefix(1) if byte == b';' => {
                    self.body.clear();
                    State::Body
                }
                State::Prefix(_) => {
                    if byte == 0x1b {
                        State::Esc
                    } else {
                        State::Ground
                    }
                }
                State::Body => match byte {
                    0x07 => {
                        self.finish(&mut out);
                        State::Ground
                    }
                    0x1b => State::BodyEsc,
                    _ => {
                        if self.body.len() < MAX_BODY {
                            self.body.push(byte);
                            State::Body
                        } else {
                            self.body.clear();
                            State::Ground
                        }
                    }
                },
                State::BodyEsc => {
                    if byte == b'\\' {
                        self.finish(&mut out);
                        State::Ground
                    } else {
                        // Not a terminator: the sequence was cut off.
                        self.body.clear();
                        if byte == b']' {
                            State::Prefix(0)
                        } else {
                            State::Ground
                        }
                    }
                }
            };
        }
        out
    }

    fn finish(&mut self, out: &mut Vec<String>) {
        if let Ok(url) = std::str::from_utf8(&self.body)
            && let Some(path) = path_from_url(url)
        {
            out.push(path);
        }
        self.body.clear();
    }
}

/// Path of an OSC 7 URL (`file://host/path`, percent-encoded). `None` when
/// the URL has no path. A bare absolute path is accepted too (some prompt
/// frameworks send one).
pub fn path_from_url(url: &str) -> Option<String> {
    let url = url.trim();
    let path = if let Some(rest) = url.strip_prefix("file://") {
        // Drop the host: everything up to the first slash.
        let slash = rest.find('/')?;
        &rest[slash..]
    } else if url.starts_with('/') {
        url
    } else {
        return None;
    };
    // `URL.path` drops a query or fragment.
    let path = path.split(['?', '#']).next().unwrap_or(path);
    let decoded = percent_decode(path);
    if decoded.is_empty() {
        None
    } else {
        Some(decoded)
    }
}

/// Percent-decoding; invalid escapes are kept as they are (the Swift fallback
/// keeps the raw text when decoding fails).
pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(hi), Some(lo)) = (hex(bytes[i + 1]), hex(bytes[i + 2]))
        {
            out.push(hi << 4 | lo);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    match String::from_utf8(out) {
        Ok(s) => s,
        Err(_) => text.to_string(),
    }
}

fn hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Whether `data` contains an OSC 7 introducer (`ESC ] 7 ;`). Swift treats
/// it as "the prompt came back" (`maybeHandlePromptUpdate`).
pub fn contains_osc7(data: &[u8]) -> bool {
    data.windows(4).any(|w| w == b"\x1b]7;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bel_and_st_terminators() {
        let mut s = Osc7Scanner::new();
        assert_eq!(
            s.feed(b"a\x1b]7;file://host/Users/me\x07b\x1b]7;file://h/tmp\x1b\\"),
            vec!["/Users/me".to_string(), "/tmp".to_string()]
        );
    }

    #[test]
    fn split_across_chunks() {
        let mut s = Osc7Scanner::new();
        assert!(s.feed(b"\x1b]7;file://ho").is_empty());
        assert!(s.feed(b"st/a%20b").is_empty());
        assert_eq!(s.feed(b"\x07"), vec!["/a b".to_string()]);
    }

    #[test]
    fn other_osc_ignored() {
        let mut s = Osc7Scanner::new();
        assert!(
            s.feed(b"\x1b]0;title\x07\x1b]133;A\x07\x1b]777;x\x07")
                .is_empty()
        );
    }

    #[test]
    fn url_forms() {
        assert_eq!(path_from_url("file:///tmp").as_deref(), Some("/tmp"));
        assert_eq!(
            path_from_url("file://mac.local/Users/me/My%20Dir").as_deref(),
            Some("/Users/me/My Dir")
        );
        assert_eq!(path_from_url("/plain").as_deref(), Some("/plain"));
        assert_eq!(path_from_url("file://hostonly"), None);
        assert_eq!(path_from_url("http://x/y"), None);
        // Malformed escapes are kept.
        assert_eq!(path_from_url("file://h/a%zz").as_deref(), Some("/a%zz"));
        assert_eq!(path_from_url("file://h/a%e2%82%ac").as_deref(), Some("/a€"));
    }

    #[test]
    fn detects_introducer() {
        assert!(contains_osc7(b"x\x1b]7;file://h/"));
        assert!(!contains_osc7(b"x\x1b]0;"));
    }
}
