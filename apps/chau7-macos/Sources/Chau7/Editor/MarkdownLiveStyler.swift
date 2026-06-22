import AppKit

/// "Light" live rendering for a markdown document shown in an *editable* NSTextView.
///
/// Light = we keep the raw markers visible (dimmed) and style in place; we never
/// hide markers, reflow, or render tables/images. The text stays fully editable —
/// this only changes attributes (font, weight, size, color, background), so the
/// character ranges are untouched and the cursor/selection math is unaffected.
///
/// Structure (`styleRuns`) is separated from appearance (`attributes(for:theme:)`)
/// so the parsing can be unit-tested without AppKit colors/fonts.
enum MarkdownLiveStyler {
    /// A semantic span discovered in the markdown source.
    enum Kind: Equatable {
        case heading(Int)     // # .. ###### → 1...6
        case marker           // the punctuation itself (#, **, `, >, -, [, ](url)) — dimmed
        case bold
        case italic
        case codeSpan         // `inline code`
        case codeFence        // a line inside a ``` fenced block
        case strikethrough
        case linkText         // the visible [text] of a link
        case blockquote       // text after `>`
        case listMarker       // -, *, +, or 1. at the start of a list item
        case horizontalRule
    }

    struct StyleRun: Equatable {
        let kind: Kind
        let range: NSRange
    }

    struct Theme {
        var baseFontSize: CGFloat
        var bodyFont: NSFont
        var monoFont: NSFont
        var textColor: NSColor = .textColor
        var headingColor: NSColor = .labelColor
        var markerColor: NSColor = .tertiaryLabelColor
        var codeColor: NSColor = .systemPink
        var codeBackground: NSColor = NSColor.systemGray.withAlphaComponent(0.15)
        var linkColor: NSColor = .linkColor
        var quoteColor: NSColor = .secondaryLabelColor
    }

    static func defaultTheme(fontSize: CGFloat) -> Theme {
        Theme(
            baseFontSize: fontSize,
            bodyFont: .systemFont(ofSize: fontSize),
            monoFont: .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        )
    }

    // MARK: - Apply

    /// Re-style `storage` over its full range. Safe to call repeatedly (the editor
    /// calls it debounced on every change).
    static func apply(to storage: NSTextStorage, theme: Theme) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.setAttributes([.font: theme.bodyFont, .foregroundColor: theme.textColor], range: full)
        for run in styleRuns(in: text) {
            for (key, value) in attributes(for: run.kind, theme: theme) {
                storage.addAttribute(key, value: value, range: run.range)
            }
        }
    }

    // MARK: - Parsing (pure / testable)

    static func styleRuns(in text: NSString) -> [StyleRun] {
        var runs: [StyleRun] = []
        var insideFence = false

        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines]) { _, lineRange, _, _ in
            let line = text.substring(with: lineRange) as NSString
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks (``` or ~~~). The fence lines and everything between
            // them render monospaced; inline parsing is suppressed inside.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                runs.append(StyleRun(kind: .codeFence, range: lineRange))
                insideFence.toggle()
                return
            }
            if insideFence {
                runs.append(StyleRun(kind: .codeFence, range: lineRange))
                return
            }

            if styleHeading(line, lineRange, &runs) { return }
            if styleHorizontalRule(trimmed, lineRange, &runs) { return }
            let contentRange = styleLinePrefix(line, lineRange, &runs) // blockquote / list marker
            styleInline(text, in: contentRange, &runs)
        }

        return runs
    }

    // MARK: - Block constructs

    /// `# .. ###### heading`. Returns true if the line was a heading.
    private static func styleHeading(_ line: NSString, _ lineRange: NSRange, _ runs: inout [StyleRun]) -> Bool {
        guard let regex = Self.headingRegex,
              let m = regex.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)),
              m.numberOfRanges >= 4 else { return false }
        let hashes = m.range(at: 2)
        let level = min(6, max(1, hashes.length))
        let content = m.range(at: 3)
        runs.append(StyleRun(kind: .marker, range: offset(hashes, by: lineRange.location)))
        if content.length > 0 {
            runs.append(StyleRun(kind: .heading(level), range: offset(content, by: lineRange.location)))
        }
        return true
    }

    private static func styleHorizontalRule(_ trimmed: String, _ lineRange: NSRange, _ runs: inout [StyleRun]) -> Bool {
        let chars = Set(trimmed)
        guard trimmed.count >= 3, chars.count == 1, let c = chars.first, c == "-" || c == "*" || c == "_" else { return false }
        runs.append(StyleRun(kind: .horizontalRule, range: lineRange))
        return true
    }

    /// Style a leading `>` blockquote or `-`/`*`/`+`/`1.` list marker. Returns the
    /// range of the remaining line content for inline styling.
    private static func styleLinePrefix(_ line: NSString, _ lineRange: NSRange, _ runs: inout [StyleRun]) -> NSRange {
        let whole = NSRange(location: 0, length: line.length)
        if let regex = Self.blockquoteRegex,
           let m = regex.firstMatch(in: line as String, range: whole), m.numberOfRanges >= 3 {
            runs.append(StyleRun(kind: .marker, range: offset(m.range(at: 1), by: lineRange.location)))
            let content = m.range(at: 2)
            let abs = offset(content, by: lineRange.location)
            if content.length > 0 { runs.append(StyleRun(kind: .blockquote, range: abs)) }
            return abs
        }
        if let regex = Self.listRegex,
           let m = regex.firstMatch(in: line as String, range: whole), m.numberOfRanges >= 3 {
            runs.append(StyleRun(kind: .listMarker, range: offset(m.range(at: 1), by: lineRange.location)))
            return offset(m.range(at: 2), by: lineRange.location)
        }
        return lineRange
    }

    // MARK: - Inline constructs

    private static func styleInline(_ text: NSString, in range: NSRange, _ runs: inout [StyleRun]) {
        guard range.length > 0 else { return }
        apply(Self.codeSpanRegex, in: text, range: range, runs: &runs) { m in
            [StyleRun(kind: .codeSpan, range: m.range)]
        }
        apply(Self.linkRegex, in: text, range: range, runs: &runs) { m in
            // [text](url): style the visible text, dim the surrounding punctuation+url
            guard m.numberOfRanges >= 2 else { return [StyleRun(kind: .linkText, range: m.range)] }
            return [
                StyleRun(kind: .marker, range: m.range),
                StyleRun(kind: .linkText, range: m.range(at: 1))
            ]
        }
        apply(Self.boldRegex, in: text, range: range, runs: &runs) { m in
            [StyleRun(kind: .bold, range: m.range)]
        }
        apply(Self.italicRegex, in: text, range: range, runs: &runs) { m in
            [StyleRun(kind: .italic, range: m.range)]
        }
        apply(Self.strikeRegex, in: text, range: range, runs: &runs) { m in
            [StyleRun(kind: .strikethrough, range: m.range)]
        }
    }

    private static func apply(
        _ regex: NSRegularExpression?,
        in text: NSString,
        range: NSRange,
        runs: inout [StyleRun],
        _ make: (NSTextCheckingResult) -> [StyleRun]
    ) {
        guard let regex else { return }
        for m in regex.matches(in: text as String, range: range) {
            runs.append(contentsOf: make(m))
        }
    }

    // MARK: - Appearance

    static func attributes(for kind: Kind, theme: Theme) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .heading(let level):
            let scale: CGFloat = [1: 1.7, 2: 1.45, 3: 1.25, 4: 1.12, 5: 1.05, 6: 1.0][level] ?? 1.0
            return [
                .font: NSFont.systemFont(ofSize: theme.baseFontSize * scale, weight: .bold),
                .foregroundColor: theme.headingColor
            ]
        case .marker:
            return [.foregroundColor: theme.markerColor]
        case .bold:
            return [.font: NSFont.boldSystemFont(ofSize: theme.baseFontSize)]
        case .italic:
            return [.font: italicFont(size: theme.baseFontSize)]
        case .codeSpan:
            return [.font: theme.monoFont, .foregroundColor: theme.codeColor, .backgroundColor: theme.codeBackground]
        case .codeFence:
            return [.font: theme.monoFont, .foregroundColor: theme.codeColor]
        case .strikethrough:
            return [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .linkText:
            return [.foregroundColor: theme.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .blockquote:
            return [.font: italicFont(size: theme.baseFontSize), .foregroundColor: theme.quoteColor]
        case .listMarker:
            return [.foregroundColor: theme.linkColor]
        case .horizontalRule:
            return [.foregroundColor: theme.markerColor]
        }
    }

    // MARK: - Helpers

    private static func italicFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    private static func offset(_ range: NSRange, by delta: Int) -> NSRange {
        range.location == NSNotFound ? range : NSRange(location: range.location + delta, length: range.length)
    }

    // MARK: - Compiled regexes

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        // Patterns are static/known-valid; on the impossible failure the construct is
        // simply skipped (styling degrades, editor still works) rather than crashing.
        let regex = try? NSRegularExpression(pattern: pattern, options: options)
        assert(regex != nil, "invalid markdown styler regex: \(pattern)")
        return regex
    }

    private static let headingRegex = re("^(\\s*)(#{1,6})\\s+(.*)$")
    private static let blockquoteRegex = re("^\\s*(>+)\\s?(.*)$")
    private static let listRegex = re("^\\s*([-*+]|\\d+[.)])\\s+(.*)$")
    private static let codeSpanRegex = re("`[^`\\n]+`")
    private static let boldRegex = re("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    // Single `*`/`_` only: the marker must not be adjacent to another marker (so it
    // never fires on the inner `*` of `**bold**`) and must hug non-space content.
    private static let italicRegex = re("(?<![*_])([*_])(?![*_\\s])(.+?)(?<![*_\\s])\\1(?![*_])")
    private static let strikeRegex = re("~~(?=\\S)(.+?)(?<=\\S)~~")
    private static let linkRegex = re("\\[([^\\]\\n]+)\\]\\([^)\\n]+\\)")
}
