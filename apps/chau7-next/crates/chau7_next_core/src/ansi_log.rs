//! Port of `Terminal/Rendering/AnsiParser.swift`: one line of AI tool
//! output with ANSI escape sequences into styled spans for the log view
//! (`AnsiLogView`).
//!
//! SGR colors (16, 256 and true color), bold, dim, italic, underline and
//! inverse are kept; other CSI sequences and OSC/DCS/APC/PM strings are
//! dropped, as are control characters other than tab. Backspaces are
//! applied first.

use crate::shell_output::apply_backspaces;

/// RGB in 0..1.
pub type Rgb = (f32, f32, f32);

/// `AnsiParser.Style`.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct AnsiStyle {
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
    pub bold: bool,
    pub dim: bool,
    pub underline: bool,
    pub inverse: bool,
    pub italic: bool,
}

/// A run of text with one style.
#[derive(Debug, Clone, PartialEq)]
pub struct AnsiSpan {
    pub text: String,
    pub style: AnsiStyle,
}

const STANDARD: [Rgb; 8] = [
    (0.0, 0.0, 0.0),
    (0.80, 0.20, 0.20),
    (0.20, 0.70, 0.30),
    (0.80, 0.65, 0.15),
    (0.25, 0.45, 0.85),
    (0.70, 0.35, 0.85),
    (0.20, 0.70, 0.75),
    (0.85, 0.85, 0.85),
];

const BRIGHT: [Rgb; 8] = [
    (0.30, 0.30, 0.30),
    (0.95, 0.35, 0.35),
    (0.35, 0.90, 0.45),
    (0.95, 0.80, 0.35),
    (0.45, 0.65, 0.95),
    (0.85, 0.55, 0.95),
    (0.45, 0.90, 0.95),
    (0.95, 0.95, 0.95),
];

/// `ansiColor`.
pub fn ansi_color(index: i64, bright: bool) -> Rgb {
    let palette = if bright { &BRIGHT } else { &STANDARD };
    palette[index.clamp(0, 7) as usize]
}

/// `ansi256Color`: 16 base colors, the 6x6x6 cube, 24 grays.
pub fn ansi_256_color(index: i64) -> Rgb {
    if index < 16 {
        return ansi_color(index.rem_euclid(8), index >= 8);
    }
    if index <= 231 {
        const STEPS: [f32; 6] = [0.0, 0.37, 0.53, 0.69, 0.84, 1.0];
        let i = (index - 16) as usize;
        return (STEPS[i / 36], STEPS[(i / 6) % 6], STEPS[i % 6]);
    }
    if index <= 255 {
        let level = (index - 232) as f32 / 23.0;
        let v = 0.08 + 0.84 * level;
        return (v, v, v);
    }
    ansi_color(7, false)
}

fn apply_sgr(params: &[i64], style: &mut AnsiStyle) {
    let mut i = 0;
    while i < params.len() {
        let code = params[i];
        match code {
            0 => *style = AnsiStyle::default(),
            1 => {
                style.bold = true;
                style.dim = false;
            }
            2 => {
                style.dim = true;
                style.bold = false;
            }
            3 => style.italic = true,
            4 => style.underline = true,
            7 => style.inverse = true,
            22 => {
                style.bold = false;
                style.dim = false;
            }
            23 => style.italic = false,
            24 => style.underline = false,
            27 => style.inverse = false,
            30..=37 => style.fg = Some(ansi_color(code - 30, false)),
            90..=97 => style.fg = Some(ansi_color(code - 90, true)),
            39 => style.fg = None,
            40..=47 => style.bg = Some(ansi_color(code - 40, false)),
            100..=107 => style.bg = Some(ansi_color(code - 100, true)),
            49 => style.bg = None,
            38 | 48 => {
                let foreground = code == 38;
                if i + 1 < params.len() {
                    let mode = params[i + 1];
                    let color = if mode == 2 && i + 4 < params.len() {
                        let c = |v: i64| v.clamp(0, 255) as f32 / 255.0;
                        let rgb = (c(params[i + 2]), c(params[i + 3]), c(params[i + 4]));
                        i += 4;
                        Some(rgb)
                    } else if mode == 5 && i + 2 < params.len() {
                        let rgb = ansi_256_color(params[i + 2]);
                        i += 2;
                        Some(rgb)
                    } else {
                        None
                    };
                    if let Some(rgb) = color {
                        if foreground {
                            style.fg = Some(rgb);
                        } else {
                            style.bg = Some(rgb);
                        }
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }
}

/// Parses one line into styled spans (`attributedString(for:)`).
pub fn parse_line(line: &str) -> Vec<AnsiSpan> {
    let input: Vec<char> = apply_backspaces(line).chars().collect();
    let mut spans = Vec::new();
    let mut style = AnsiStyle::default();
    let mut buffer = String::new();
    let flush = |buffer: &mut String, style: AnsiStyle, spans: &mut Vec<AnsiSpan>| {
        if !buffer.is_empty() {
            spans.push(AnsiSpan {
                text: std::mem::take(buffer),
                style,
            });
        }
    };
    let mut i = 0;
    while i < input.len() {
        let c = input[i];
        if c == '\u{1b}' {
            match input.get(i + 1) {
                Some('[') => {
                    // CSI: parameters up to a final byte in @..~.
                    let mut j = i + 2;
                    let mut params = String::new();
                    let mut command = None;
                    while j < input.len() {
                        let ch = input[j];
                        j += 1;
                        if ('@'..='~').contains(&ch) {
                            command = Some(ch);
                            break;
                        }
                        params.push(ch);
                    }
                    if let Some(command) = command {
                        if command == 'm' {
                            flush(&mut buffer, style, &mut spans);
                            let mut parsed: Vec<i64> =
                                params.split(';').filter_map(|p| p.parse().ok()).collect();
                            if parsed.is_empty() {
                                parsed.push(0);
                            }
                            apply_sgr(&parsed, &mut style);
                        }
                        i = j;
                        continue;
                    }
                }
                Some(']') | Some('P') | Some('^') | Some('_') => {
                    // String sequences end at BEL or ESC \ (or the line end).
                    let mut j = i + 2;
                    while j < input.len() {
                        if input[j] == '\u{7}' {
                            j += 1;
                            break;
                        }
                        if input[j] == '\u{1b}' && input.get(j + 1) == Some(&'\\') {
                            j += 2;
                            break;
                        }
                        j += 1;
                    }
                    i = j;
                    continue;
                }
                _ => {}
            }
            i += 1;
            continue;
        }
        if (c as u32) < 0x20 && c != '\t' {
            i += 1;
            continue;
        }
        buffer.push(c);
        i += 1;
    }
    flush(&mut buffer, style, &mut spans);
    spans
}

/// Plain text of the spans.
pub fn plain_text(spans: &[AnsiSpan]) -> String {
    spans.iter().map(|s| s.text.as_str()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colors_and_reset() {
        let spans = parse_line("\x1b[31mRed\x1b[0m plain");
        assert_eq!(spans.len(), 2);
        assert_eq!(spans[0].text, "Red");
        assert_eq!(spans[0].style.fg, Some(ansi_color(1, false)));
        assert_eq!(spans[1].style, AnsiStyle::default());
    }

    #[test]
    fn extended_colors() {
        let spans = parse_line("\x1b[38;5;196ma\x1b[48;2;255;0;128mb\x1b[38;5;240mc");
        assert_eq!(spans[0].style.fg, Some(ansi_256_color(196)));
        assert_eq!(spans[1].style.bg, Some((1.0, 0.0, 128.0 / 255.0)));
        let gray = ansi_256_color(240);
        assert_eq!(spans[2].style.fg, Some(gray));
        assert!((gray.0 - (0.08 + 0.84 * 8.0 / 23.0)).abs() < 1e-6);
        assert_eq!(ansi_256_color(9), ansi_color(1, true));
        assert_eq!(ansi_256_color(16), (0.0, 0.0, 0.0));
        assert_eq!(ansi_256_color(231), (1.0, 1.0, 1.0));
    }

    #[test]
    fn attributes() {
        let spans = parse_line("\x1b[1;3;4;7mx\x1b[2my\x1b[22;23;24;27mz");
        let s = spans[0].style;
        assert!(s.bold && s.italic && s.underline && s.inverse && !s.dim);
        assert!(spans[1].style.dim && !spans[1].style.bold);
        assert_eq!(
            spans[2].style,
            AnsiStyle {
                fg: None,
                bg: None,
                ..AnsiStyle::default()
            }
        );
    }

    #[test]
    fn other_sequences_and_controls_are_dropped() {
        let spans = parse_line("a\x1b]0;title\x07b\x1b[2Kc\x01d\te\x08f");
        assert_eq!(plain_text(&spans), "abcd\tf");
        assert_eq!(parse_line("\x1b[m"), vec![]);
    }
}
