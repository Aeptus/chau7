import AppKit

// MARK: - ANSI Escape Sequence Parser

/// Parses ANSI escape sequences in terminal output and converts them to attributed strings.
///
/// Supports:
/// - SGR (Select Graphic Rendition) codes for text styling
/// - 16-color (standard), 256-color, and 24-bit true color
/// - Text attributes: bold, dim, italic, underline, inverse
/// - OSC (Operating System Command) sequences (skipped)
///
/// ## Usage
/// ```swift
/// let attributed = AnsiParser.attributedString(
///     for: "\u{1B}[31mRed text\u{1B}[0m",
///     baseFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
///     baseFg: .white,
///     baseBg: .black
/// )
/// ```
enum AnsiParser {
    /// Text styling attributes extracted from ANSI SGR codes.
    struct Style: Equatable {
        var fg: NSColor?
        var bg: NSColor?
        var bold: Bool
        var dim: Bool
        var underline: Bool
        var inverse: Bool
        var italic: Bool

        static let `default` = Style(
            fg: nil,
            bg: nil,
            bold: false,
            dim: false,
            underline: false,
            inverse: false,
            italic: false
        )
    }

    /// Converts a line of terminal text with ANSI escape sequences to an attributed string.
    ///
    /// - Parameters:
    ///   - line: Raw terminal line potentially containing ANSI escape sequences
    ///   - baseFont: Font to use for unstyled text
    ///   - baseFg: Default foreground color
    ///   - baseBg: Default background color
    /// - Returns: Styled attributed string with colors and formatting applied
    static func attributedString(for line: String, baseFont: NSFont, baseFg: NSColor, baseBg: NSColor) -> NSAttributedString {
        let token = FeatureProfiler.shared.begin(.ansiParse, bytes: line.utf8.count)
        defer { FeatureProfiler.shared.end(token) }
        let input = TerminalNormalizer.applyBackspacesOnly(line)
        if let segments = RustAnsiParser.shared.parse(input) {
            return attributedString(from: segments, baseFont: baseFont, baseFg: baseFg, baseBg: baseBg)
        }
        return swiftAttributedString(for: input, baseFont: baseFont, baseFg: baseFg, baseBg: baseBg)
    }

    private static func swiftAttributedString(for input: String, baseFont: NSFont, baseFg: NSColor, baseBg: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentStyle = Style.default
        var buffer = ""

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            let attrs = attributes(for: currentStyle, baseFont: baseFont, baseFg: baseFg, baseBg: baseBg)
            result.append(NSAttributedString(string: buffer, attributes: attrs))
            buffer = ""
        }

        var index = input.startIndex
        while index < input.endIndex {
            let ch = input[index]
            if ch == "\u{1B}" {
                let nextIndex = input.index(after: index)
                if nextIndex < input.endIndex {
                    let nextChar = input[nextIndex]
                    if nextChar == "[" {
                        if let (endIndex, params, command) = parseCsiSequence(in: input, start: nextIndex) {
                            if command == "m" {
                                flushBuffer()
                                applySgr(params: params, style: &currentStyle)
                            }
                            index = endIndex
                            continue
                        }
                    } else if nextChar == "]" || nextChar == "P" || nextChar == "^" || nextChar == "_" {
                        if let endIndex = skipEscapeSequence(in: input, start: nextIndex) {
                            index = endIndex
                            continue
                        }
                    }
                }
                index = input.index(after: index)
                continue
            }

            if let scalar = ch.unicodeScalars.first, scalar.value < 0x20, ch != "\t" {
                index = input.index(after: index)
                continue
            }

            buffer.append(ch)
            index = input.index(after: index)
        }

        flushBuffer()
        return result
    }

    private static func attributedString(from segments: [RustAnsiParsedSegment], baseFont: NSFont, baseFg: NSColor, baseBg: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments {
            guard !segment.text.isEmpty else { continue }
            let style = style(from: segment)
            let attrs = attributes(for: style, baseFont: baseFont, baseFg: baseFg, baseBg: baseBg)
            result.append(NSAttributedString(string: segment.text, attributes: attrs))
        }
        return result
    }

    private static func style(from segment: RustAnsiParsedSegment) -> Style {
        var style = Style.default
        let flags = segment.flags
        style.bold = (flags & 1) != 0
        style.dim = (flags & 2) != 0
        style.underline = (flags & 4) != 0
        style.inverse = (flags & 8) != 0
        style.italic = (flags & 16) != 0
        style.fg = color(from: segment.fg)
        style.bg = color(from: segment.bg)
        return style
    }

    private static func color(from spec: RustAnsiColorSpec) -> NSColor? {
        switch spec.kind {
        case 1:
            let idx = Int(spec.index)
            return ansiColor(idx % 8, bright: idx >= 8)
        case 2:
            return ansi256Color(Int(spec.index))
        case 3:
            return NSColor(calibratedRed: CGFloat(spec.r) / 255.0,
                           green: CGFloat(spec.g) / 255.0,
                           blue: CGFloat(spec.b) / 255.0,
                           alpha: 1.0)
        default:
            return nil
        }
    }

    private static func skipEscapeSequence(in input: String, start: String.Index) -> String.Index? {
        var i = input.index(after: start)
        while i < input.endIndex {
            let ch = input[i]
            if ch == "\u{07}" {
                return input.index(after: i)
            }
            if ch == "\u{1B}" {
                let next = input.index(after: i)
                if next < input.endIndex, input[next] == "\\" {
                    return input.index(after: next)
                }
            }
            i = input.index(after: i)
        }
        return input.endIndex
    }

    private static func parseCsiSequence(in input: String, start: String.Index) -> (String.Index, [Int], Character)? {
        var i = start
        i = input.index(after: i) // skip '['
        var params = ""
        var command: Character? = nil

        while i < input.endIndex {
            let ch = input[i]
            if ch >= "@" && ch <= "~" {
                command = ch
                i = input.index(after: i)
                break
            }
            params.append(ch)
            i = input.index(after: i)
        }

        guard let command else { return nil }
        let parsed = params
            .split(separator: ";", omittingEmptySubsequences: false)
            .compactMap { Int($0) }

        return (i, parsed.isEmpty ? [0] : parsed, command)
    }

    private static func applySgr(params: [Int], style: inout Style) {
        var i = 0
        while i < params.count {
            let code = params[i]
            switch code {
            case 0:
                style = .default
            case 1:
                style.bold = true
                style.dim = false
            case 2:
                style.dim = true
                style.bold = false
            case 3:
                style.italic = true
            case 4:
                style.underline = true
            case 7:
                style.inverse = true
            case 22:
                style.bold = false
                style.dim = false
            case 23:
                style.italic = false
            case 24:
                style.underline = false
            case 27:
                style.inverse = false
            case 30...37:
                style.fg = ansiColor(code - 30, bright: false)
            case 90...97:
                style.fg = ansiColor(code - 90, bright: true)
            case 39:
                style.fg = nil
            case 40...47:
                style.bg = ansiColor(code - 40, bright: false)
            case 100...107:
                style.bg = ansiColor(code - 100, bright: true)
            case 49:
                style.bg = nil
            case 38, 48:
                let isForeground = (code == 38)
                if i + 1 < params.count {
                    let mode = params[i + 1]
                    if mode == 2, i + 4 < params.count {
                        let r = params[i + 2]
                        let g = params[i + 3]
                        let b = params[i + 4]
                        let color = NSColor(calibratedRed: CGFloat(r) / 255.0,
                                            green: CGFloat(g) / 255.0,
                                            blue: CGFloat(b) / 255.0,
                                            alpha: 1.0)
                        if isForeground { style.fg = color } else { style.bg = color }
                        i += 4
                    } else if mode == 5, i + 2 < params.count {
                        let idx = params[i + 2]
                        let color = ansi256Color(idx)
                        if isForeground { style.fg = color } else { style.bg = color }
                        i += 2
                    }
                }
            default:
                break
            }
            i += 1
        }
    }

    private static func attributes(for style: Style, baseFont: NSFont, baseFg: NSColor, baseBg: NSColor) -> [NSAttributedString.Key: Any] {
        var font = baseFont
        if style.bold {
            let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            font = boldFont
        }
        if style.italic {
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            font = italic
        }

        var fg = style.fg ?? baseFg
        var bg = style.bg ?? baseBg
        if style.inverse {
            let tmp = fg
            fg = bg
            bg = tmp
        }
        if style.dim {
            fg = fg.withAlphaComponent(0.6)
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
        ]

        if bg != baseBg {
            attrs[.backgroundColor] = bg
        }

        if style.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        return attrs
    }

    // MARK: - Pre-computed Color Palettes (Memory Optimization)
    // Colors computed once at startup instead of on every call

    private static let standardColors: [NSColor] = [
        .black,
        NSColor(calibratedRed: 0.80, green: 0.20, blue: 0.20, alpha: 1.0),
        NSColor(calibratedRed: 0.20, green: 0.70, blue: 0.30, alpha: 1.0),
        NSColor(calibratedRed: 0.80, green: 0.65, blue: 0.15, alpha: 1.0),
        NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.85, alpha: 1.0),
        NSColor(calibratedRed: 0.70, green: 0.35, blue: 0.85, alpha: 1.0),
        NSColor(calibratedRed: 0.20, green: 0.70, blue: 0.75, alpha: 1.0),
        NSColor(calibratedWhite: 0.85, alpha: 1.0)
    ]

    private static let brightColors: [NSColor] = [
        NSColor(calibratedWhite: 0.30, alpha: 1.0),
        NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.35, alpha: 1.0),
        NSColor(calibratedRed: 0.35, green: 0.90, blue: 0.45, alpha: 1.0),
        NSColor(calibratedRed: 0.95, green: 0.80, blue: 0.35, alpha: 1.0),
        NSColor(calibratedRed: 0.45, green: 0.65, blue: 0.95, alpha: 1.0),
        NSColor(calibratedRed: 0.85, green: 0.55, blue: 0.95, alpha: 1.0),
        NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.95, alpha: 1.0),
        NSColor(calibratedWhite: 0.95, alpha: 1.0)
    ]

    // Pre-computed 256-color palette (indices 16-255)
    private static let extendedPalette: [NSColor] = {
        var colors: [NSColor] = []
        colors.reserveCapacity(240)

        // 6x6x6 color cube (indices 16-231)
        let steps: [CGFloat] = [0.0, 0.37, 0.53, 0.69, 0.84, 1.0]
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    colors.append(NSColor(calibratedRed: steps[r], green: steps[g], blue: steps[b], alpha: 1.0))
                }
            }
        }

        // Grayscale (indices 232-255)
        for i in 0..<24 {
            let level = CGFloat(i) / 23.0
            let value = 0.08 + (0.84 * level)
            colors.append(NSColor(calibratedWhite: value, alpha: 1.0))
        }

        return colors
    }()

    private static func ansiColor(_ index: Int, bright: Bool) -> NSColor {
        let palette = bright ? brightColors : standardColors
        let idx = max(0, min(index, palette.count - 1))
        return palette[idx]
    }

    private static func ansi256Color(_ index: Int) -> NSColor {
        if index < 16 {
            return ansiColor(index % 8, bright: index >= 8)
        }
        if index >= 16 && index <= 255 {
            // Use pre-computed extended palette (indices 16-255 map to 0-239)
            return extendedPalette[index - 16]
        }
        return .labelColor
    }
}
