//! Attribute-only native layout for the Rust Markdown source widget.
use chau7_next_core::editor::live_markdown::{Document, Kind};
use objc2::{MainThreadMarker, rc::Retained, runtime::AnyObject};
use objc2_app_kit::{
    NSBackgroundColorAttributeName, NSColor, NSFont, NSFontAttributeName, NSFontManager,
    NSFontTraitMask, NSForegroundColorAttributeName, NSLinkAttributeName, NSMutableParagraphStyle,
    NSParagraphStyle, NSParagraphStyleAttributeName, NSStrikethroughStyleAttributeName,
    NSStringDrawing, NSTextStorage, NSUnderlineStyleAttributeName,
};
use objc2_foundation::{NSDictionary, NSNumber, NSRange, NSString, NSURL};
use std::{
    collections::{BTreeMap, BTreeSet},
    ops::Range,
};

pub(super) struct Theme {
    size: f64,
    body: Retained<NSFont>,
    mono: Retained<NSFont>,
    mono_bold: Retained<NSFont>,
    mono_italic: Retained<NSFont>,
    mono_bold_italic: Retained<NSFont>,
    bold: Retained<NSFont>,
    italic: Retained<NSFont>,
    checkbox: Retained<NSFont>,
    headings: [Retained<NSFont>; 6],
    body_attributes: Retained<NSDictionary<NSString, AnyObject>>,
}
impl Theme {
    pub(super) fn new(size: f64, mtm: MainThreadMarker) -> Self {
        let body = NSFont::systemFontOfSize(size);
        let mono = NSFont::monospacedSystemFontOfSize_weight(size, 0.0);
        let manager = NSFontManager::sharedFontManager(mtm);
        let mono_bold = manager.convertFont_toHaveTrait(&mono, NSFontTraitMask::BoldFontMask);
        let mono_italic = manager.convertFont_toHaveTrait(&mono, NSFontTraitMask::ItalicFontMask);
        let mono_bold_italic =
            manager.convertFont_toHaveTrait(&mono_bold, NSFontTraitMask::ItalicFontMask);
        let bold = NSFont::boldSystemFontOfSize(size);
        let italic = manager.convertFont_toHaveTrait(&body, NSFontTraitMask::ItalicFontMask);
        let checkbox = NSFont::monospacedSystemFontOfSize_weight(size, 0.4);
        let headings = [1.7, 1.45, 1.25, 1.12, 1.05, 1.0]
            .map(|scale| NSFont::systemFontOfSize_weight(size * scale, 0.4));
        // SAFETY: static Foundation attribute key; its value is the documented NSFont class.
        let body_attributes = unsafe {
            NSDictionary::<NSString, AnyObject>::from_slices(&[NSFontAttributeName], &[&body])
        };
        Self {
            size,
            body,
            mono,
            mono_bold,
            mono_italic,
            mono_bold_italic,
            bold,
            italic,
            checkbox,
            headings,
            body_attributes,
        }
    }
    pub(super) fn size(&self) -> f64 {
        self.size
    }
    pub(super) fn apply(
        &self,
        storage: &NSTextStorage,
        document: &Document,
        restyled: Range<usize>,
    ) {
        let text = document.text();
        if restyled.is_empty() {
            return;
        }
        let ranges = document
            .runs()
            .iter()
            .filter(|r| r.range.start >= restyled.start && r.range.end <= restyled.end);
        let indents = document
            .indents()
            .iter()
            .filter(|i| i.paragraph.start >= restyled.start && i.paragraph.end <= restyled.end);
        // Terminal links and their color attributes are emitted as separate
        // runs. Index their ranges once so styling many links stays linearithmic
        // in the run count instead of rescanning all runs/links per link.
        let terminal_foregrounds: BTreeSet<(usize, usize)> = ranges
            .clone()
            .filter_map(|run| {
                matches!(
                    run.kind,
                    Kind::TerminalSpan {
                        foreground: Some(_),
                        ..
                    }
                )
                .then_some((run.range.start, run.range.end))
            })
            .collect();
        let mut terminal_hrefs: BTreeMap<(usize, usize), &str> = BTreeMap::new();
        for (range, href) in document
            .terminal_links()
            .iter()
            .filter(|(range, _)| range.start >= restyled.start && range.end <= restyled.end)
        {
            terminal_hrefs
                .entry((range.start, range.end))
                .or_insert(href.as_str());
        }
        let mut points: BTreeMap<usize, usize> = BTreeMap::new();
        points.insert(restyled.start, 0);
        points.insert(restyled.end, 0);
        for run in ranges.clone() {
            points.insert(run.range.start, 0);
            points.insert(run.range.end, 0);
        }
        for indent in indents.clone() {
            points.insert(indent.paragraph.start, 0);
            points.insert(indent.paragraph.end, 0);
        }
        // One UTF-8→UTF-16 pass for all attribute edges; no rewriting or range drift.
        let mut units = 0;
        for (offset, c) in text.char_indices() {
            if let Some(value) = points.get_mut(&offset) {
                *value = units;
            }
            units += c.len_utf16();
        }
        if let Some(value) = points.get_mut(&text.len()) {
            *value = units;
        }
        let nsrange =
            |r: Range<usize>| NSRange::new(points[&r.start], points[&r.end] - points[&r.start]);
        storage.beginEditing();
        // SAFETY: all ranges were emitted on validated UTF-8 boundaries and mapped above.
        unsafe {
            let full = nsrange(restyled.clone());
            storage.setAttributes_range(None, full);
            storage.addAttribute_value_range(NSFontAttributeName, &self.body, full);
            storage.addAttribute_value_range(
                NSForegroundColorAttributeName,
                &NSColor::textColor(),
                full,
            );
            storage.addAttribute_value_range(
                NSParagraphStyleAttributeName,
                &NSParagraphStyle::defaultParagraphStyle(),
                full,
            );
            for run in ranges {
                let range = nsrange(run.range.clone());
                let font = match run.kind {
                    Kind::Heading(level) => {
                        Some(&self.headings[level.saturating_sub(1).min(5) as usize])
                    }
                    Kind::Bold => Some(&self.bold),
                    Kind::Italic | Kind::Blockquote => Some(&self.italic),
                    Kind::CodeSpan | Kind::CodeFence => Some(&self.mono),
                    Kind::TerminalSpan {
                        bold: true,
                        italic: true,
                        ..
                    } => Some(&self.mono_bold_italic),
                    Kind::TerminalSpan { bold: true, .. } => Some(&self.mono_bold),
                    Kind::TerminalSpan { italic: true, .. } => Some(&self.mono_italic),
                    Kind::TerminalSpan { .. } => Some(&self.mono),
                    Kind::TaskCheckbox(_) => Some(&self.checkbox),
                    _ => None,
                };
                if let Some(font) = font {
                    storage.addAttribute_value_range(NSFontAttributeName, font, range);
                }
                let color = match run.kind {
                    Kind::Heading(_) => Some(NSColor::labelColor()),
                    Kind::Marker | Kind::HorizontalRule | Kind::CompletedTask => {
                        Some(NSColor::tertiaryLabelColor())
                    }
                    Kind::CodeSpan | Kind::CodeFence => Some(NSColor::systemPinkColor()),
                    Kind::LinkText | Kind::ListMarker => Some(NSColor::linkColor()),
                    Kind::Blockquote | Kind::TaskCheckbox(false) => {
                        Some(NSColor::secondaryLabelColor())
                    }
                    Kind::TaskCheckbox(true) => Some(NSColor::systemGreenColor()),
                    _ => None,
                };
                if let Some(color) = color {
                    storage.addAttribute_value_range(NSForegroundColorAttributeName, &color, range);
                }
                if run.kind == Kind::CodeSpan {
                    storage.addAttribute_value_range(
                        NSBackgroundColorAttributeName,
                        &NSColor::systemGrayColor().colorWithAlphaComponent(0.15),
                        range,
                    );
                }
                if matches!(run.kind, Kind::Strikethrough | Kind::CompletedTask) {
                    storage.addAttribute_value_range(
                        NSStrikethroughStyleAttributeName,
                        &NSNumber::new_i32(1),
                        range,
                    );
                }
                if run.kind == Kind::LinkText {
                    storage.addAttribute_value_range(
                        NSUnderlineStyleAttributeName,
                        &NSNumber::new_i32(1),
                        range,
                    );
                }
                if let Kind::TerminalSpan {
                    underline,
                    strikethrough,
                    foreground,
                    background,
                    ..
                } = run.kind
                {
                    if let Some([red, green, blue]) = foreground {
                        let color = NSColor::colorWithSRGBRed_green_blue_alpha(
                            f64::from(red) / 255.0,
                            f64::from(green) / 255.0,
                            f64::from(blue) / 255.0,
                            1.0,
                        );
                        storage.addAttribute_value_range(
                            NSForegroundColorAttributeName,
                            &color,
                            range,
                        );
                    } else {
                        storage.addAttribute_value_range(
                            NSForegroundColorAttributeName,
                            &NSColor::textColor(),
                            range,
                        );
                    }
                    if let Some([red, green, blue]) = background {
                        let color = NSColor::colorWithSRGBRed_green_blue_alpha(
                            f64::from(red) / 255.0,
                            f64::from(green) / 255.0,
                            f64::from(blue) / 255.0,
                            1.0,
                        );
                        storage.addAttribute_value_range(
                            NSBackgroundColorAttributeName,
                            &color,
                            range,
                        );
                    }
                    if underline {
                        storage.addAttribute_value_range(
                            NSUnderlineStyleAttributeName,
                            &NSNumber::new_i32(1),
                            range,
                        );
                    }
                    if strikethrough {
                        storage.addAttribute_value_range(
                            NSStrikethroughStyleAttributeName,
                            &NSNumber::new_i32(1),
                            range,
                        );
                    }
                }
                if run.kind == Kind::TerminalLink {
                    let link_key = (run.range.start, run.range.end);
                    let has_terminal_foreground = terminal_foregrounds.contains(&link_key);
                    if !has_terminal_foreground {
                        storage.addAttribute_value_range(
                            NSForegroundColorAttributeName,
                            &NSColor::linkColor(),
                            range,
                        );
                    }
                    storage.addAttribute_value_range(
                        NSUnderlineStyleAttributeName,
                        &NSNumber::new_i32(1),
                        range,
                    );
                    if let Some(href) = terminal_hrefs.get(&link_key)
                        && let Some(url) = NSURL::URLWithString(&NSString::from_str(href))
                    {
                        storage.addAttribute_value_range(NSLinkAttributeName, &url, range);
                    }
                }
            }
            for indent in indents {
                let prefix = NSString::from_str(&text[indent.prefix.clone()]);
                let width = prefix.sizeWithAttributes(Some(&self.body_attributes)).width;
                let paragraph = NSMutableParagraphStyle::new();
                paragraph.setHeadIndent(width);
                paragraph.setFirstLineHeadIndent(0.0);
                storage.addAttribute_value_range(
                    NSParagraphStyleAttributeName,
                    &paragraph,
                    nsrange(indent.paragraph.clone()),
                );
            }
        }
        storage.endEditing();
    }
}
