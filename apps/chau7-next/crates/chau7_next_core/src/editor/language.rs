//! Editor languages (`Editor/EditorLanguage.swift`): detection from the file
//! extension and the regex highlighting rules of each language.
//!
//! The rules are the Swift ones, applied in order over the whole text (later
//! rules recolor earlier matches, bold stays). Rust's `regex` has no
//! look-ahead, so the TOML key rule `^[\w.-]+(?=\s*=)` is written with a
//! capture group and only the group is colored.

use std::sync::OnceLock;

use regex::Regex;

use super::{HighlightColor, HighlightSpan, paint, runs};

/// One highlighting rule.
pub struct HighlightRule {
    pub pattern: &'static str,
    /// `.anchorsMatchLines`: `^` and `$` match at line breaks.
    pub multi_line: bool,
    pub color: HighlightColor,
    pub bold: bool,
    /// Color only this capture group (stands in for a look-ahead).
    pub group: usize,
}

const fn rule(pattern: &'static str, color: HighlightColor) -> HighlightRule {
    HighlightRule {
        pattern,
        multi_line: false,
        color,
        bold: false,
        group: 0,
    }
}

const fn bold(pattern: &'static str, color: HighlightColor) -> HighlightRule {
    HighlightRule {
        bold: true,
        ..rule(pattern, color)
    }
}

const fn lines(rule: HighlightRule) -> HighlightRule {
    HighlightRule {
        multi_line: true,
        ..rule
    }
}

/// An editor language (`EditorLanguage`).
pub struct EditorLanguage {
    pub id: &'static str,
    pub display_name: &'static str,
    pub extensions: &'static [&'static str],
    pub rules: &'static [HighlightRule],
}

use HighlightColor::*;

const DQ_STRING: &str = r#""[^"\\]*(?:\\.[^"\\]*)*""#;
const SQ_STRING: &str = r"'[^'\\]*(?:\\.[^'\\]*)*'";
const NUMBER: &str = r"\b\d+\.?\d*\b";

pub static SWIFT: EditorLanguage = EditorLanguage {
    id: "swift",
    display_name: "Swift",
    extensions: &["swift"],
    rules: &[
        bold(
            r"\b(func|var|let|class|struct|enum|protocol|import|return|if|else|guard|switch|case|for|while|do|try|catch|throw|throws|async|await|actor|@[A-Za-z]+)\b",
            Pink,
        ),
        rule(
            r"\b(String|Int|Bool|Double|Float|Array|Dictionary|Optional|Any|Void|Self|self|nil|true|false)\b",
            Purple,
        ),
        rule(DQ_STRING, Red),
        lines(rule(r"//.*$", Green)),
        rule(r"/\*[\s\S]*?\*/", Green),
        rule(NUMBER, Blue),
    ],
};

pub static PYTHON: EditorLanguage = EditorLanguage {
    id: "python",
    display_name: "Python",
    extensions: &["py"],
    rules: &[
        bold(
            r"\b(def|class|import|from|return|if|elif|else|for|while|try|except|finally|with|as|yield|lambda|pass|break|continue|raise|async|await)\b",
            Pink,
        ),
        rule(
            r"\b(str|int|float|bool|list|dict|tuple|set|None|True|False|self|cls)\b",
            Purple,
        ),
        rule(r#""""[\s\S]*?""""#, Red),
        rule(DQ_STRING, Red),
        rule(SQ_STRING, Red),
        lines(rule(r"#.*$", Green)),
        rule(NUMBER, Blue),
    ],
};

pub static JAVASCRIPT: EditorLanguage = EditorLanguage {
    id: "javascript",
    display_name: "JavaScript",
    extensions: &["js", "jsx", "ts", "tsx"],
    rules: &[
        bold(
            r"\b(function|const|let|var|class|return|if|else|for|while|do|try|catch|throw|new|typeof|instanceof|import|export|default|from|async|await|yield)\b",
            Pink,
        ),
        rule(
            r"\b(string|number|boolean|object|null|undefined|true|false|this|super|NaN|Infinity)\b",
            Purple,
        ),
        rule(r"`[^`]*`", Red),
        rule(DQ_STRING, Red),
        rule(SQ_STRING, Red),
        lines(rule(r"//.*$", Green)),
        rule(r"/\*[\s\S]*?\*/", Green),
        rule(NUMBER, Blue),
    ],
};

pub static SHELL: EditorLanguage = EditorLanguage {
    id: "shell",
    display_name: "Shell",
    extensions: &["sh", "bash", "zsh", "fish"],
    rules: &[
        bold(
            r"\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|return|local|export|source|alias|unalias)\b",
            Pink,
        ),
        rule(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?", Purple),
        rule(DQ_STRING, Red),
        rule(r"'[^']*'", Red),
        lines(rule(r"#.*$", Green)),
    ],
};

pub static JSON: EditorLanguage = EditorLanguage {
    id: "json",
    display_name: "JSON",
    extensions: &["json"],
    rules: &[
        rule(r#""[^"\\]*(?:\\.[^"\\]*)*"\s*:"#, Purple),
        rule(DQ_STRING, Red),
        rule(r"\b(true|false|null)\b", Pink),
        rule(r"-?\b\d+\.?\d*([eE][+-]?\d+)?\b", Blue),
    ],
};

pub static YAML: EditorLanguage = EditorLanguage {
    id: "yaml",
    display_name: "YAML",
    extensions: &["yml", "yaml"],
    rules: &[
        lines(rule(r"^[\w.-]+:", Purple)),
        rule(DQ_STRING, Red),
        rule(r"'[^']*'", Red),
        rule(r"\b(true|false|null|yes|no)\b", Pink),
        lines(rule(r"#.*$", Green)),
        rule(r"-?\b\d+\.?\d*\b", Blue),
    ],
};

pub static TOML: EditorLanguage = EditorLanguage {
    id: "toml",
    display_name: "TOML",
    extensions: &["toml"],
    rules: &[
        lines(bold(r"^\[+[^\]]+\]+", Purple)),
        HighlightRule {
            group: 1,
            ..lines(rule(r"^([\w.-]+)\s*=", Teal))
        },
        rule(DQ_STRING, Red),
        rule(r"'[^']*'", Red),
        rule(r"\b(true|false)\b", Pink),
        lines(rule(r"#.*$", Green)),
        rule(r"-?\b\d+\.?\d*\b", Blue),
    ],
};

pub static MARKDOWN: EditorLanguage = EditorLanguage {
    id: "markdown",
    display_name: "Markdown",
    extensions: &["md", "markdown"],
    rules: &[
        lines(bold(r"^#{1,6}\s.*$", Purple)),
        bold(r"\*\*[^*]+\*\*", Label),
        rule(r"\*[^*]+\*", Teal),
        rule(r"`[^`]+`", Red),
        rule(r"```[\s\S]*?```", Red),
        lines(rule(r"^\s*[-*+]\s", Orange)),
        lines(rule(r"^\s*\d+\.\s", Orange)),
        rule(r"\[([^\]]+)\]\(([^)]+)\)", Blue),
    ],
};

pub static GO: EditorLanguage = EditorLanguage {
    id: "go",
    display_name: "Go",
    extensions: &["go"],
    rules: &[
        bold(
            r"\b(func|var|const|type|struct|interface|map|chan|package|import|return|if|else|for|range|switch|case|default|go|defer|select|break|continue|fallthrough)\b",
            Pink,
        ),
        rule(
            r"\b(string|int|int8|int16|int32|int64|uint|float32|float64|bool|byte|rune|error|nil|true|false|iota)\b",
            Purple,
        ),
        rule(DQ_STRING, Red),
        rule(r"`[^`]*`", Red),
        lines(rule(r"//.*$", Green)),
        rule(r"/\*[\s\S]*?\*/", Green),
        rule(NUMBER, Blue),
    ],
};

pub static RUST: EditorLanguage = EditorLanguage {
    id: "rust",
    display_name: "Rust",
    extensions: &["rs"],
    rules: &[
        bold(
            r"\b(fn|let|mut|const|struct|enum|impl|trait|pub|use|mod|crate|self|super|return|if|else|match|for|while|loop|break|continue|async|await|move|unsafe|where)\b",
            Pink,
        ),
        rule(
            r"\b(i8|i16|i32|i64|i128|u8|u16|u32|u64|u128|f32|f64|bool|char|str|String|Vec|Option|Result|Box|Self|self|true|false|None|Some|Ok|Err)\b",
            Purple,
        ),
        rule(DQ_STRING, Red),
        lines(rule(r"//.*$", Green)),
        rule(r"/\*[\s\S]*?\*/", Green),
        rule(NUMBER, Blue),
    ],
};

pub static RUBY: EditorLanguage = EditorLanguage {
    id: "ruby",
    display_name: "Ruby",
    extensions: &["rb"],
    rules: &[
        bold(
            r"\b(def|class|module|end|if|elsif|else|unless|case|when|for|while|until|do|begin|rescue|ensure|raise|return|yield|require|include|extend|attr_accessor|attr_reader|attr_writer)\b",
            Pink,
        ),
        rule(r"\b(nil|true|false|self|super)\b", Purple),
        rule(DQ_STRING, Red),
        rule(SQ_STRING, Red),
        lines(rule(r"#.*$", Green)),
        rule(r":[A-Za-z_][A-Za-z0-9_]*", Teal),
        rule(NUMBER, Blue),
    ],
};

pub static PLAIN_TEXT: EditorLanguage = EditorLanguage {
    id: "text",
    display_name: "Plain Text",
    extensions: &["txt", "log"],
    rules: &[],
};

/// Every language, in Swift's order (`allLanguages`).
pub static ALL_LANGUAGES: [&EditorLanguage; 12] = [
    &SWIFT,
    &PYTHON,
    &JAVASCRIPT,
    &SHELL,
    &JSON,
    &YAML,
    &TOML,
    &MARKDOWN,
    &GO,
    &RUST,
    &RUBY,
    &PLAIN_TEXT,
];

impl EditorLanguage {
    /// Language from a file name or path (`detect(from:)`): the extension,
    /// lowercased; anything unknown (or no extension) is plain text.
    pub fn detect(filename: &str) -> &'static EditorLanguage {
        let name = filename.rsplit('/').next().unwrap_or(filename);
        let ext = match name.rfind('.') {
            // A leading dot names a hidden file, not an extension (NSString).
            Some(i) if i > 0 => name[i + 1..].to_lowercase(),
            _ => String::new(),
        };
        ALL_LANGUAGES
            .iter()
            .find(|lang| lang.extensions.contains(&ext.as_str()))
            .copied()
            .unwrap_or(&PLAIN_TEXT)
    }

    /// The language with this id (`"rust"`, `"text"`, ...).
    pub fn by_id(id: &str) -> Option<&'static EditorLanguage> {
        ALL_LANGUAGES.iter().find(|l| l.id == id).copied()
    }

    fn compiled(&self) -> &'static [Option<Regex>] {
        static CACHE: OnceLock<Vec<Vec<Option<Regex>>>> = OnceLock::new();
        let all = CACHE.get_or_init(|| {
            ALL_LANGUAGES
                .iter()
                .map(|lang| {
                    lang.rules
                        .iter()
                        .map(|rule| {
                            let pattern = if rule.multi_line {
                                format!("(?m){}", rule.pattern)
                            } else {
                                rule.pattern.to_string()
                            };
                            Regex::new(&pattern).ok()
                        })
                        .collect()
                })
                .collect()
        });
        let index = ALL_LANGUAGES
            .iter()
            .position(|l| std::ptr::eq(*l, self))
            .unwrap_or(ALL_LANGUAGES.len() - 1);
        &all[index]
    }

    /// Highlight a whole document (`applySyntaxHighlighting`): style runs
    /// over byte ranges, text without a rule left out.
    pub fn highlight(&self, text: &str) -> Vec<HighlightSpan> {
        if text.is_empty() || self.rules.is_empty() {
            return Vec::new();
        }
        let mut styles = vec![None; text.len()];
        for (rule, regex) in self.rules.iter().zip(self.compiled()) {
            let Some(regex) = regex else { continue };
            for caps in regex.captures_iter(text) {
                if let Some(m) = caps.get(rule.group) {
                    paint(&mut styles, m.range(), rule.color, rule.bold, None);
                }
            }
        }
        runs(&styles, &[])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(name: &str) -> &'static str {
        EditorLanguage::detect(name).id
    }

    #[test]
    fn detects_languages_from_extensions() {
        assert_eq!(EditorLanguage::detect("main.swift").display_name, "Swift");
        assert_eq!(EditorLanguage::detect("script.py").display_name, "Python");
        for name in ["app.js", "Component.jsx", "index.ts", "Component.tsx"] {
            assert_eq!(id(name), "javascript");
        }
        for name in ["setup.sh", "init.bash", "config.zsh", "setup.fish"] {
            assert_eq!(id(name), "shell");
        }
        assert_eq!(id("package.json"), "json");
        assert_eq!(id("config.yml"), "yaml");
        assert_eq!(id("config.yaml"), "yaml");
        assert_eq!(id("Cargo.toml"), "toml");
        assert_eq!(id("README.md"), "markdown");
        assert_eq!(id("docs.markdown"), "markdown");
        assert_eq!(id("main.go"), "go");
        assert_eq!(id("lib.rs"), "rust");
        assert_eq!(id("Gemfile.rb"), "ruby");
        assert_eq!(id("notes.txt"), "text");
        assert_eq!(id("output.log"), "text");
    }

    #[test]
    fn unknown_or_missing_extension_is_plain_text() {
        assert_eq!(
            EditorLanguage::detect("data.csv").display_name,
            "Plain Text"
        );
        assert_eq!(id("Makefile"), "text");
        assert_eq!(id(".bashrc"), "text");
    }

    #[test]
    fn detection_is_case_insensitive_and_takes_paths() {
        assert_eq!(id("App.SWIFT"), "swift");
        assert_eq!(id("module.JS"), "javascript");
        assert_eq!(id("Config.YML"), "yaml");
        assert_eq!(id("/Users/dev/project/src/main.swift"), "swift");
        assert_eq!(id("/a.b/Makefile"), "text");
    }

    #[test]
    fn rule_structure() {
        assert!(!SWIFT.rules.is_empty());
        assert!(PLAIN_TEXT.rules.is_empty());
        let ids: std::collections::HashSet<_> = ALL_LANGUAGES.iter().map(|l| l.id).collect();
        assert_eq!(ids.len(), ALL_LANGUAGES.len());
        let expected: std::collections::HashSet<_> = [
            "swift",
            "python",
            "javascript",
            "shell",
            "json",
            "yaml",
            "toml",
            "markdown",
            "go",
            "rust",
            "ruby",
            "text",
        ]
        .into();
        assert_eq!(ids, expected);
        for lang in ALL_LANGUAGES {
            assert!(!lang.display_name.is_empty());
            assert!(!lang.extensions.is_empty());
            for (i, regex) in lang.compiled().iter().enumerate() {
                assert!(
                    regex.is_some(),
                    "{} rule[{i}] is not a valid regex",
                    lang.id
                );
            }
        }
    }

    fn rule_matches(lang: &EditorLanguage, index: usize, input: &str) -> usize {
        lang.compiled()[index]
            .as_ref()
            .unwrap()
            .find_iter(input)
            .count()
    }

    #[test]
    fn rules_match_like_swift() {
        assert_eq!(rule_matches(&SWIFT, 0, "func hello() { return }"), 2);
        let comment = PYTHON
            .rules
            .iter()
            .position(|r| r.pattern == "#.*$")
            .unwrap();
        assert_eq!(
            rule_matches(&PYTHON, comment, "x = 1  # this is a comment"),
            1
        );
        assert_eq!(rule_matches(&JSON, 1, r#""hello""#), 1);
        assert_eq!(rule_matches(&RUST, 0, "let mut x = 5;"), 2);
    }

    #[test]
    fn later_rules_win_and_bold_stays() {
        let text = "let s = \"fn\"; // let";
        let spans = RUST.highlight(text);
        let at = |offset: usize| spans.iter().find(|s| s.range.contains(&offset)).cloned();
        // `let` keyword: pink bold.
        assert_eq!(at(0).map(|s| (s.color, s.bold)), Some((Pink, true)));
        // "fn" inside a string: the string rule (later) recolors the keyword.
        let inner = text.find("fn").unwrap();
        assert_eq!(at(inner).map(|s| (s.color, s.bold)), Some((Red, true)));
        // The comment wins over the keyword inside it.
        let comment = text.rfind("let").unwrap();
        assert_eq!(at(comment).map(|s| s.color), Some(Green));
        // Plain text has no span.
        assert!(at(text.find('=').unwrap()).is_none());
    }

    #[test]
    fn toml_key_rule_colors_only_the_key() {
        let spans = TOML.highlight("name = \"x\"\n[package]\n");
        let key = spans.iter().find(|s| s.color == Teal).unwrap();
        assert_eq!(key.range, 0..4);
        assert!(spans.iter().any(|s| s.color == Purple && s.bold));
    }

    #[test]
    fn plain_text_has_no_spans() {
        assert!(PLAIN_TEXT.highlight("fn main() {}").is_empty());
        assert!(RUST.highlight("").is_empty());
    }
}
