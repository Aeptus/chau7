//! Output-style highlighting (`Editor/SyntaxHighlighter.swift`,
//! `SyntaxHighlighter`): numbers, quoted strings, file paths, URLs, JSON
//! keys, git hashes and branches, prompts, then success, warning and error
//! keywords (applied last, errors win). Used by the file preview pane.
//!
//! Results are cached per line (500 entries; a quarter is evicted when full,
//! oldest first). Swift's string rule uses a back-reference, which Rust's
//! `regex` lacks, so quoted strings are found by a small scanner with the
//! same matching.

use std::collections::{HashMap, VecDeque};
use std::sync::OnceLock;

use regex::Regex;

use super::{HighlightColor, HighlightSpan, paint, runs};

/// Lines kept in the cache (`maxCacheSize`).
pub const MAX_CACHE_SIZE: usize = 500;

/// What the highlighter does (`isSyntaxHighlightEnabled`,
/// `isClickableURLsEnabled`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutputHighlightOptions {
    pub enabled: bool,
    pub clickable_urls: bool,
}

impl Default for OutputHighlightOptions {
    fn default() -> Self {
        Self {
            enabled: true,
            clickable_urls: true,
        }
    }
}

struct Patterns {
    url: Regex,
    path: Regex,
    error: Regex,
    warning: Regex,
    success: Regex,
    number: Regex,
    json_key: Regex,
    git: Regex,
    prompt: Regex,
}

fn patterns() -> &'static Patterns {
    static P: OnceLock<Patterns> = OnceLock::new();
    P.get_or_init(|| Patterns {
        url: Regex::new(r#"(?i)https?://[^\s<>\[\]{}|\\^`"']+"#).unwrap(),
        path: Regex::new(r"(?:^|\s)([/~][\w./-]+)").unwrap(),
        error: Regex::new(r"(?i)\b(error|failed|failure|exception|fatal|critical|panic)\b")
            .unwrap(),
        warning: Regex::new(r"(?i)\b(warning|warn|deprecated|caution)\b").unwrap(),
        success: Regex::new(r"(?i)\b(success|passed|ok|done|complete|completed)\b").unwrap(),
        number: Regex::new(r"\b(0x[0-9a-fA-F]+|\d+\.?\d*)\b").unwrap(),
        json_key: Regex::new(r#""(\w+)"\s*:"#).unwrap(),
        git: Regex::new(r"\b([a-f0-9]{7,40})\b|(?:origin/|HEAD\s*->?\s*)(\S+)").unwrap(),
        prompt: Regex::new(r"(?m)^[\w@.-]+[:#$%>]\s").unwrap(),
    })
}

/// Quoted strings, as `(["'])(?:(?!\1)[^\\]|\\.)*\1`: the same quote
/// closes, a backslash escapes the next character (not a line break).
fn quoted_strings(text: &str) -> Vec<std::ops::Range<usize>> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let quote = bytes[i];
        if quote != b'"' && quote != b'\'' {
            i += 1;
            continue;
        }
        let mut j = i + 1;
        let mut end = None;
        while j < bytes.len() {
            match bytes[j] {
                b'\\' => {
                    if j + 1 < bytes.len() && bytes[j + 1] != b'\n' {
                        // Skip the escaped character (may be multi-byte).
                        let next = text[j + 1..].chars().next().map_or(1, char::len_utf8);
                        j += 1 + next;
                    } else {
                        break;
                    }
                }
                c if c == quote => {
                    end = Some(j);
                    break;
                }
                _ => j += 1,
            }
        }
        match end {
            Some(end) => {
                out.push(i..end + 1);
                i = end + 1;
            }
            None => i += 1,
        }
    }
    out
}

/// Highlight one piece of output (`performHighlight`), no cache.
pub fn highlight_uncached(text: &str, options: OutputHighlightOptions) -> Vec<HighlightSpan> {
    if !options.enabled || text.is_empty() {
        return Vec::new();
    }
    use HighlightColor::*;
    let p = patterns();
    let mut styles = vec![None; text.len()];
    let mut links: Vec<String> = Vec::new();
    let apply = |styles: &mut Vec<_>, regex: &Regex, color| {
        for m in regex.find_iter(text) {
            paint(styles, m.range(), color, false, None);
        }
    };
    apply(&mut styles, &p.number, Purple);
    for range in quoted_strings(text) {
        paint(&mut styles, range, Yellow, false, None);
    }
    apply(&mut styles, &p.path, Cyan);
    if options.clickable_urls {
        for m in p.url.find_iter(text) {
            links.push(m.as_str().to_string());
            paint(
                &mut styles,
                m.range(),
                Blue,
                false,
                Some(links.len() as u32 - 1),
            );
        }
    }
    apply(&mut styles, &p.json_key, Teal);
    apply(&mut styles, &p.git, Pink);
    apply(&mut styles, &p.prompt, Gray);
    // Status patterns last (most important).
    apply(&mut styles, &p.success, Green);
    apply(&mut styles, &p.warning, Orange);
    apply(&mut styles, &p.error, Red);
    runs(&styles, &links)
}

/// The highlighter with its line cache (`SyntaxHighlighter.shared`).
#[derive(Default)]
pub struct OutputHighlighter {
    cache: HashMap<String, Vec<HighlightSpan>>,
    order: VecDeque<String>,
    options: OutputHighlightOptions,
}

impl OutputHighlighter {
    pub fn new(options: OutputHighlightOptions) -> Self {
        Self {
            options,
            ..Default::default()
        }
    }

    /// Change the settings; the cache is cleared when they differ.
    pub fn set_options(&mut self, options: OutputHighlightOptions) {
        if self.options != options {
            self.options = options;
            self.clear_cache();
        }
    }

    pub fn options(&self) -> OutputHighlightOptions {
        self.options
    }

    /// Highlight one line (`highlight(_:)`), from the cache when seen before.
    pub fn highlight(&mut self, text: &str) -> Vec<HighlightSpan> {
        if !self.options.enabled {
            return Vec::new();
        }
        if let Some(cached) = self.cache.get(text) {
            return cached.clone();
        }
        let result = highlight_uncached(text, self.options);
        if self.cache.len() >= MAX_CACHE_SIZE {
            // Simple eviction: remove about 25% of the entries, oldest first.
            for _ in 0..MAX_CACHE_SIZE / 4 {
                if let Some(old) = self.order.pop_front() {
                    self.cache.remove(&old);
                }
            }
        }
        self.cache.insert(text.to_string(), result.clone());
        self.order.push_back(text.to_string());
        result
    }

    /// Highlight several lines (`highlightLines`). Run it on a background
    /// thread for the async variant (`highlightLinesAsync`).
    pub fn highlight_lines<S: AsRef<str>>(&mut self, lines: &[S]) -> Vec<Vec<HighlightSpan>> {
        lines.iter().map(|l| self.highlight(l.as_ref())).collect()
    }

    /// Forget cached lines (`clearCache`).
    pub fn clear_cache(&mut self) {
        self.cache.clear();
        self.order.clear();
    }

    pub fn cache_len(&self) -> usize {
        self.cache.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use HighlightColor::*;

    fn color_at(text: &str, offset: usize) -> Option<HighlightColor> {
        highlight_uncached(text, OutputHighlightOptions::default())
            .into_iter()
            .find(|s| s.range.contains(&offset))
            .map(|s| s.color)
    }

    #[test]
    fn empty_and_plain_text() {
        assert!(highlight_uncached("", Default::default()).is_empty());
        assert!(highlight_uncached("   ", Default::default()).is_empty());
        assert!(highlight_uncached("hello world", Default::default()).is_empty());
    }

    #[test]
    fn status_keywords() {
        assert_eq!(color_at("error: something went wrong", 0), Some(Red));
        assert_eq!(color_at("fatal error encountered", 0), Some(Red));
        assert_eq!(color_at("ERROR: build failed", 0), Some(Red));
        assert_eq!(color_at("warning: unused variable", 0), Some(Orange));
        assert_eq!(
            color_at("deprecated: use newMethod instead", 0),
            Some(Orange)
        );
        assert_eq!(color_at("Build success", 6), Some(Green));
    }

    #[test]
    fn urls_are_links_only_when_clickable() {
        let text = "Visit https://example.com for details";
        let spans = highlight_uncached(text, Default::default());
        let url = spans.iter().find(|s| s.link.is_some()).unwrap();
        assert_eq!(url.link.as_deref(), Some("https://example.com"));
        assert_eq!(url.color, Blue);
        let off = OutputHighlightOptions {
            enabled: true,
            clickable_urls: false,
        };
        assert!(
            highlight_uncached(text, off)
                .iter()
                .all(|s| s.link.is_none())
        );
    }

    #[test]
    fn numbers_strings_keys_prompts() {
        assert_eq!(color_at("count 42 items", 6), Some(Purple));
        assert_eq!(color_at("value 0xff", 7), Some(Purple));
        assert_eq!(color_at("say \"hello\" now", 5), Some(Yellow));
        assert_eq!(color_at("say 'it\\'s' now", 6), Some(Yellow));
        assert_eq!(color_at(r#"{"name": 1}"#, 2), Some(Teal));
        assert_eq!(color_at("user@host$ ls", 0), Some(Gray));
        assert_eq!(color_at("cat /usr/bin/env", 6), Some(Cyan));
        assert_eq!(color_at("commit abc1234 done", 8), Some(Pink));
    }

    #[test]
    fn unterminated_quote_is_not_a_string() {
        assert_eq!(color_at("it's fine", 3), None);
        assert_eq!(quoted_strings(r#"a "b\" c" d"#), vec![2..9]);
    }

    #[test]
    fn disabled_returns_plain() {
        let off = OutputHighlightOptions {
            enabled: false,
            clickable_urls: true,
        };
        assert!(highlight_uncached("error: x", off).is_empty());
        let mut h = OutputHighlighter::new(off);
        assert!(
            h.highlight_lines(&["error: bad", "hello"])
                .iter()
                .all(Vec::is_empty)
        );
    }

    #[test]
    fn batches_and_cache() {
        let mut h = OutputHighlighter::new(Default::default());
        let out = h.highlight_lines(&["error: bad", "warning: check", "all ok"]);
        assert_eq!(out.len(), 3);
        assert_eq!(out[0][0].color, Red);
        let first = h.highlight("cached error");
        assert_eq!(h.highlight("cached error"), first);
        h.clear_cache();
        assert_eq!(h.cache_len(), 0);
        for i in 0..600 {
            h.highlight(&format!("line {i} with error marker"));
        }
        assert!(h.cache_len() <= MAX_CACHE_SIZE);
        assert!(!h.highlight("post-eviction test error").is_empty());
    }

    #[test]
    fn spans_stay_on_char_boundaries() {
        let text = "é \"ü\" error 12 ✓";
        for span in highlight_uncached(text, Default::default()) {
            assert!(text.is_char_boundary(span.range.start));
            assert!(text.is_char_boundary(span.range.end));
        }
    }
}
