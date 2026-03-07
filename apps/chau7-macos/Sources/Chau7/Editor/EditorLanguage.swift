import AppKit

// MARK: - Editor Language Definitions

/// Language definition for syntax highlighting in the editor.
/// Each language defines regex patterns for keywords, strings, comments, etc.
struct EditorLanguage: Identifiable {
    let id: String
    let displayName: String
    let extensions: [String]
    let highlightingRules: [HighlightRule]

    struct HighlightRule {
        let pattern: String
        let options: NSRegularExpression.Options
        let color: NSColor
        let isBold: Bool

        init(pattern: String, color: NSColor, isBold: Bool = false, options: NSRegularExpression.Options = []) {
            self.pattern = pattern
            self.options = options
            self.color = color
            self.isBold = isBold
        }
    }

    // MARK: - Built-in Languages

    static let swift = EditorLanguage(
        id: "swift", displayName: "Swift", extensions: ["swift"],
        highlightingRules: [
            HighlightRule(
                pattern: "\\b(func|var|let|class|struct|enum|protocol|import|return|if|else|guard|switch|case|for|while|do|try|catch|throw|throws|async|await|actor|@[A-Za-z]+)\\b",
                color: .systemPink, isBold: true
            ),
            HighlightRule(
                pattern: "\\b(String|Int|Bool|Double|Float|Array|Dictionary|Optional|Any|Void|Self|self|nil|true|false)\\b",
                color: .systemPurple
            ),
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: .systemRed),
            HighlightRule(pattern: "//.*$", color: .systemGreen, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", color: .systemGreen),
            HighlightRule(pattern: "\\b\\d+\\.?\\d*\\b", color: .systemBlue)
        ]
    )

    static let python = EditorLanguage(
        id: "python", displayName: "Python", extensions: ["py"],
        highlightingRules: [
            HighlightRule(
                pattern: "\\b(def|class|import|from|return|if|elif|else|for|while|try|except|finally|with|as|yield|lambda|pass|break|continue|raise|async|await)\\b",
                color: .systemPink, isBold: true
            ),
            HighlightRule(
                pattern: "\\b(str|int|float|bool|list|dict|tuple|set|None|True|False|self|cls)\\b",
                color: .systemPurple
            ),
            HighlightRule(pattern: "\"\"\"[\\s\\S]*?\"\"\"", color: .systemRed),
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: .systemRed),
            HighlightRule(pattern: "'[^'\\\\]*(?:\\\\.[^'\\\\]*)*'", color: .systemRed),
            HighlightRule(pattern: "#.*$", color: .systemGreen, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "\\b\\d+\\.?\\d*\\b", color: .systemBlue)
        ]
    )

    static let javascript = EditorLanguage(
        id: "javascript", displayName: "JavaScript", extensions: ["js", "jsx", "ts", "tsx"],
        highlightingRules: [
            HighlightRule(
                pattern: "\\b(function|const|let|var|class|return|if|else|for|while|do|try|catch|throw|new|typeof|instanceof|import|export|default|from|async|await|yield)\\b",
                color: .systemPink, isBold: true
            ),
            HighlightRule(
                pattern: "\\b(string|number|boolean|object|null|undefined|true|false|this|super|NaN|Infinity)\\b",
                color: .systemPurple
            ),
            HighlightRule(pattern: "`[^`]*`", color: .systemRed),
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: .systemRed),
            HighlightRule(pattern: "'[^'\\\\]*(?:\\\\.[^'\\\\]*)*'", color: .systemRed),
            HighlightRule(pattern: "//.*$", color: .systemGreen, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", color: .systemGreen),
            HighlightRule(pattern: "\\b\\d+\\.?\\d*\\b", color: .systemBlue)
        ]
    )

    static let shell = EditorLanguage(
        id: "shell", displayName: "Shell", extensions: ["sh", "bash", "zsh", "fish"],
        highlightingRules: [
            HighlightRule(
                pattern: "\\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|return|local|export|source|alias|unalias)\\b",
                color: .systemPink, isBold: true
            ),
            HighlightRule(pattern: "\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?", color: .systemPurple),
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: .systemRed),
            HighlightRule(pattern: "'[^']*'", color: .systemRed),
            HighlightRule(pattern: "#.*$", color: .systemGreen, options: [.anchorsMatchLines])
        ]
    )

    static let json = EditorLanguage(
        id: "json", displayName: "JSON", extensions: ["json"],
        highlightingRules: [
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"\\s*:", color: .systemPurple),
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: .systemRed),
            HighlightRule(pattern: "\\b(true|false|null)\\b", color: .systemPink),
            HighlightRule(pattern: "-?\\b\\d+\\.?\\d*([eE][+-]?\\d+)?\\b", color: .systemBlue)
        ]
    )

    static let yaml = EditorLanguage(
        id: "yaml", displayName: "YAML", extensions: ["yml", "yaml"],
        highlightingRules: [
            HighlightRule(pattern: "^[\\w.-]+:", color: .systemPurple, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: .systemRed),
            HighlightRule(pattern: "'[^']*'", color: .systemRed),
            HighlightRule(pattern: "\\b(true|false|null|yes|no)\\b", color: .systemPink),
            HighlightRule(pattern: "#.*$", color: .systemGreen, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "-?\\b\\d+\\.?\\d*\\b", color: .systemBlue)
        ]
    )

    static let toml = EditorLanguage(
        id: "toml", displayName: "TOML", extensions: ["toml"],
        highlightingRules: [
            HighlightRule(pattern: "^\\[+[^\\]]+\\]+", color: .systemPurple, isBold: true, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "^[\\w.-]+(?=\\s*=)", color: .systemTeal, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: .systemRed),
            HighlightRule(pattern: "'[^']*'", color: .systemRed),
            HighlightRule(pattern: "\\b(true|false)\\b", color: .systemPink),
            HighlightRule(pattern: "#.*$", color: .systemGreen, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "-?\\b\\d+\\.?\\d*\\b", color: .systemBlue)
        ]
    )

    static let markdown = EditorLanguage(
        id: "markdown", displayName: "Markdown", extensions: ["md", "markdown"],
        highlightingRules: [
            HighlightRule(pattern: "^#{1,6}\\s.*$", color: .systemPurple, isBold: true, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "\\*\\*[^*]+\\*\\*", color: .labelColor, isBold: true),
            HighlightRule(pattern: "\\*[^*]+\\*", color: .systemTeal),
            HighlightRule(pattern: "`[^`]+`", color: .systemRed),
            HighlightRule(pattern: "```[\\s\\S]*?```", color: .systemRed),
            HighlightRule(pattern: "^\\s*[-*+]\\s", color: .systemOrange, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "^\\s*\\d+\\.\\s", color: .systemOrange, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", color: .systemBlue)
        ]
    )

    static let go = EditorLanguage(
        id: "go", displayName: "Go", extensions: ["go"],
        highlightingRules: [
            HighlightRule(
                pattern: "\\b(func|var|const|type|struct|interface|map|chan|package|import|return|if|else|for|range|switch|case|default|go|defer|select|break|continue|fallthrough)\\b",
                color: .systemPink, isBold: true
            ),
            HighlightRule(
                pattern: "\\b(string|int|int8|int16|int32|int64|uint|float32|float64|bool|byte|rune|error|nil|true|false|iota)\\b",
                color: .systemPurple
            ),
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: .systemRed),
            HighlightRule(pattern: "`[^`]*`", color: .systemRed),
            HighlightRule(pattern: "//.*$", color: .systemGreen, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", color: .systemGreen),
            HighlightRule(pattern: "\\b\\d+\\.?\\d*\\b", color: .systemBlue)
        ]
    )

    static let rust = EditorLanguage(
        id: "rust", displayName: "Rust", extensions: ["rs"],
        highlightingRules: [
            HighlightRule(
                pattern: "\\b(fn|let|mut|const|struct|enum|impl|trait|pub|use|mod|crate|self|super|return|if|else|match|for|while|loop|break|continue|async|await|move|unsafe|where)\\b",
                color: .systemPink, isBold: true
            ),
            HighlightRule(
                pattern: "\\b(i8|i16|i32|i64|i128|u8|u16|u32|u64|u128|f32|f64|bool|char|str|String|Vec|Option|Result|Box|Self|self|true|false|None|Some|Ok|Err)\\b",
                color: .systemPurple
            ),
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: .systemRed),
            HighlightRule(pattern: "//.*$", color: .systemGreen, options: [.anchorsMatchLines]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", color: .systemGreen),
            HighlightRule(pattern: "\\b\\d+\\.?\\d*\\b", color: .systemBlue)
        ]
    )

    static let ruby = EditorLanguage(
        id: "ruby", displayName: "Ruby", extensions: ["rb"],
        highlightingRules: [
            HighlightRule(
                pattern: "\\b(def|class|module|end|if|elsif|else|unless|case|when|for|while|until|do|begin|rescue|ensure|raise|return|yield|require|include|extend|attr_accessor|attr_reader|attr_writer)\\b",
                color: .systemPink, isBold: true
            ),
            HighlightRule(
                pattern: "\\b(nil|true|false|self|super)\\b",
                color: .systemPurple
            ),
            HighlightRule(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: .systemRed),
            HighlightRule(pattern: "'[^'\\\\]*(?:\\\\.[^'\\\\]*)*'", color: .systemRed),
            HighlightRule(pattern: "#.*$", color: .systemGreen, options: [.anchorsMatchLines]),
            HighlightRule(pattern: ":[A-Za-z_][A-Za-z0-9_]*", color: .systemTeal),
            HighlightRule(pattern: "\\b\\d+\\.?\\d*\\b", color: .systemBlue)
        ]
    )

    static let plainText = EditorLanguage(
        id: "text", displayName: "Plain Text", extensions: ["txt", "log"],
        highlightingRules: []
    )

    static let allLanguages: [EditorLanguage] = [
        .swift, .python, .javascript, .shell, .json, .yaml, .toml,
        .markdown, .go, .rust, .ruby, .plainText
    ]

    /// Detect language from file extension.
    static func detect(from filename: String) -> EditorLanguage {
        let ext = (filename as NSString).pathExtension.lowercased()
        return allLanguages.first { $0.extensions.contains(ext) } ?? .plainText
    }
}
