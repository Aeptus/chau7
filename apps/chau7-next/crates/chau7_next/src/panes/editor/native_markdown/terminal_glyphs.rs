//! Hide terminal wrapper source lines in TextKit without changing the source.
//!
//! The document remains literal Markdown in `NSTextStorage`, so its UTF-16
//! offsets, selection, and undo history stay unchanged. Only generated glyphs
//! for wrapper content become null glyphs; line separators remain intact and
//! their otherwise-empty line fragments collapse to zero height.

use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send,
    rc::Retained,
    runtime::{Bool, ProtocolObject},
};
use objc2_app_kit::{
    NSFont, NSGlyphProperty, NSLayoutManager, NSLayoutManagerDelegate, NSTextView,
};
use objc2_core_graphics::CGGlyph;
use objc2_foundation::{NSObject, NSObjectProtocol, NSRange, NSRect};
use std::{cell::RefCell, collections::BTreeMap, ops::Range, ptr::NonNull, rc::Rc};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct GlyphRanges {
    /// Full UTF-16 ranges, including line separators, used to collapse lines.
    hidden_lines: Vec<Range<usize>>,
    /// Wrapper characters excluding line separators, whose glyphs are nulled.
    hidden_content: Vec<Range<usize>>,
}

struct TerminalGlyphDelegateIvars {
    ranges: Rc<RefCell<GlyphRanges>>,
}

define_class!(
    #[unsafe(super = NSObject)]
    #[name = "Chau7NextTerminalGlyphDelegate"]
    #[thread_kind = MainThreadOnly]
    #[ivars = TerminalGlyphDelegateIvars]
    struct TerminalGlyphDelegate;

    unsafe impl NSObjectProtocol for TerminalGlyphDelegate {}

    unsafe impl NSLayoutManagerDelegate for TerminalGlyphDelegate {
        #[unsafe(method(layoutManager:shouldGenerateGlyphs:properties:characterIndexes:font:forGlyphRange:))]
        unsafe fn generate_glyphs(
            &self,
            layout_manager: &NSLayoutManager,
            glyphs: NonNull<CGGlyph>,
            properties: NonNull<NSGlyphProperty>,
            character_indexes: NonNull<usize>,
            font: &NSFont,
            glyph_range: NSRange,
        ) -> usize {
            let count = glyph_range.length;
            if count == 0 {
                return 0;
            }

            let ranges = self.ivars().ranges.borrow();
            if ranges.hidden_content.is_empty() {
                return 0;
            }

            // SAFETY: AppKit supplies valid arrays for the full glyph range;
            // the protocol's callback contract guarantees all three pointers.
            let original_properties =
                unsafe { std::slice::from_raw_parts(properties.as_ptr(), count) };
            let characters =
                unsafe { std::slice::from_raw_parts(character_indexes.as_ptr(), count) };
            let mut updated_properties = original_properties.to_vec();
            let mut changed = false;
            for (property, character_index) in updated_properties.iter_mut().zip(characters) {
                if contains(&ranges.hidden_content, *character_index) {
                    *property = NSGlyphProperty::Null;
                    changed = true;
                }
            }
            drop(ranges);

            if !changed {
                // Returning zero lets NSLayoutManager use its regular glyph
                // generation path for lines outside the terminal wrapper.
                return 0;
            }

            // SAFETY: the original glyph and character-index arrays remain
            // valid for this synchronous delegate call. The local property
            // array remains alive through setGlyphs, which copies its values.
            let properties = NonNull::new(updated_properties.as_mut_ptr())
                .expect("nonempty glyph property array");
            unsafe {
                layout_manager.setGlyphs_properties_characterIndexes_font_forGlyphRange(
                    glyphs,
                    properties,
                    character_indexes,
                    font,
                    glyph_range,
                );
            }
            count
        }

        #[unsafe(method(layoutManager:shouldSetLineFragmentRect:lineFragmentUsedRect:baselineOffset:inTextContainer:forGlyphRange:))]
        unsafe fn set_line_fragment(
            &self,
            layout_manager: &NSLayoutManager,
            line_fragment_rect: NonNull<NSRect>,
            line_fragment_used_rect: NonNull<NSRect>,
            baseline_offset: NonNull<f64>,
            _text_container: &objc2_app_kit::NSTextContainer,
            glyph_range: NSRange,
        ) -> Bool {
            if glyph_range.length == 0 {
                return Bool::NO;
            }

            let ranges = self.ivars().ranges.borrow();
            if ranges.hidden_lines.is_empty() {
                return Bool::NO;
            }
            let mut all_characters_hidden = true;
            let mut has_null_glyph = false;
            for glyph_index in glyph_range.location..glyph_range.location + glyph_range.length {
                let character_index = layout_manager.characterIndexForGlyphAtIndex(glyph_index);
                if !contains(&ranges.hidden_lines, character_index) {
                    all_characters_hidden = false;
                    break;
                }
                has_null_glyph |= layout_manager
                    .propertyForGlyphAtIndex(glyph_index)
                    .contains(NSGlyphProperty::Null);
            }
            drop(ranges);

            if !all_characters_hidden || !has_null_glyph {
                return Bool::NO;
            }

            // Preserve the proposed origins and widths so TextKit can keep
            // source offsets and line mapping, but remove this line's height.
            // SAFETY: AppKit supplies valid mutable rectangle and baseline
            // pointers for this delegate callback.
            unsafe {
                (*line_fragment_rect.as_ptr()).size.height = 0.0;
                (*line_fragment_used_rect.as_ptr()).size.height = 0.0;
                *baseline_offset.as_ptr() = 0.0;
            }
            Bool::YES
        }
    }
);

impl TerminalGlyphDelegate {
    fn new(mtm: MainThreadMarker, ranges: Rc<RefCell<GlyphRanges>>) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(TerminalGlyphDelegateIvars { ranges });
        // SAFETY: NSObject's `init` has the standard zero-argument signature.
        unsafe { msg_send![super(this), init] }
    }
}

/// Owns the layout manager and keeps AppKit's weak delegate alive.
pub(super) struct TerminalGlyphs {
    layout_manager: Retained<NSLayoutManager>,
    delegate: Retained<TerminalGlyphDelegate>,
    ranges: Rc<RefCell<GlyphRanges>>,
}

impl TerminalGlyphs {
    pub(super) fn new(text: &NSTextView, mtm: MainThreadMarker) -> Option<Self> {
        // SourceTextView forces this manager to exist before any live input.
        let layout_manager = unsafe { text.layoutManager() }?;
        let ranges = Rc::new(RefCell::new(GlyphRanges::default()));
        let delegate = TerminalGlyphDelegate::new(mtm, ranges.clone());
        layout_manager.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
        Some(Self {
            layout_manager,
            delegate,
            ranges,
        })
    }

    /// Update ranges after Document::update; UTF-8 source text is never edited.
    pub(super) fn update(&self, source: &str, hidden_utf8: &[Range<usize>]) {
        let next = ranges_for_source(source, hidden_utf8);
        let previous = {
            let mut current = self.ranges.borrow_mut();
            if *current == next {
                return;
            }
            std::mem::replace(&mut *current, next.clone())
        };

        // Invalidate just the old/new wrapper regions. Ordinary edits with
        // unchanged ranges use NSTextStorage's own invalidation path.
        let mut affected = previous.hidden_lines;
        affected.extend(next.hidden_lines);
        let text_length = source.encode_utf16().count();
        for range in merge_ranges(affected) {
            let start = range.start.min(text_length);
            let end = range.end.min(text_length);
            if start >= end {
                continue;
            }
            let range = NSRange::new(start, end - start);
            // SAFETY: null actual-range outputs are explicitly allowed by
            // NSLayoutManager's optional actualCharacterRange parameters.
            unsafe {
                self.layout_manager
                    .invalidateGlyphsForCharacterRange_changeInLength_actualCharacterRange(
                        range,
                        0,
                        std::ptr::null_mut(),
                    );
                self.layout_manager
                    .invalidateLayoutForCharacterRange_actualCharacterRange(
                        range,
                        std::ptr::null_mut(),
                    );
            }
            self.layout_manager
                .invalidateDisplayForCharacterRange(range);
        }
    }
}

impl Drop for TerminalGlyphs {
    fn drop(&mut self) {
        if let Some(current) = self.layout_manager.delegate()
            && std::ptr::eq(&*current, ProtocolObject::from_ref(&*self.delegate))
        {
            self.layout_manager.setDelegate(None);
        }
    }
}

fn ranges_for_source(source: &str, hidden_utf8: &[Range<usize>]) -> GlyphRanges {
    let mut valid_ranges = Vec::new();
    let mut utf16_offsets = BTreeMap::new();
    for bytes in hidden_utf8 {
        if bytes.start < bytes.end && source.get(bytes.clone()).is_some() {
            utf16_offsets.insert(bytes.start, 0);
            utf16_offsets.insert(bytes.end, 0);
            valid_ranges.push(bytes);
        }
    }
    // Convert all requested boundaries in one source pass. A note may have
    // several terminal blocks; avoid rescanning the prefix for each one.
    let mut units = 0;
    for (byte, character) in source.char_indices() {
        if let Some(offset) = utf16_offsets.get_mut(&byte) {
            *offset = units;
        }
        units += character.len_utf16();
    }
    if let Some(offset) = utf16_offsets.get_mut(&source.len()) {
        *offset = units;
    }

    let mut hidden_lines = Vec::new();
    let mut hidden_content = Vec::new();
    for bytes in valid_ranges {
        let start_units = utf16_offsets[&bytes.start];
        let end_units = utf16_offsets[&bytes.end];
        hidden_lines.push(start_units..end_units);

        let mut units = start_units;
        let mut content_start = None;
        for character in source[bytes.clone()].chars() {
            let character_start = units;
            units += character.len_utf16();
            if is_line_break(character) {
                if let Some(start) = content_start.take()
                    && start < character_start
                {
                    hidden_content.push(start..character_start);
                }
            } else if content_start.is_none() {
                content_start = Some(character_start);
            }
        }
        if let Some(start) = content_start
            && start < end_units
        {
            hidden_content.push(start..end_units);
        }
    }
    GlyphRanges {
        hidden_lines: merge_ranges(hidden_lines),
        hidden_content: merge_ranges(hidden_content),
    }
}

fn is_line_break(character: char) -> bool {
    matches!(character, '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn merge_ranges(mut ranges: Vec<Range<usize>>) -> Vec<Range<usize>> {
    ranges.retain(|range| range.start < range.end);
    ranges.sort_unstable_by_key(|range| (range.start, range.end));
    let mut merged: Vec<Range<usize>> = Vec::with_capacity(ranges.len());
    for range in ranges {
        if let Some(last) = merged.last_mut()
            && range.start <= last.end
        {
            last.end = last.end.max(range.end);
        } else {
            merged.push(range);
        }
    }
    merged
}

fn contains(ranges: &[Range<usize>], index: usize) -> bool {
    let first_after = ranges.partition_point(|range| range.start <= index);
    first_after
        .checked_sub(1)
        .is_some_and(|candidate| index < ranges[candidate].end)
}

#[cfg(test)]
mod tests {
    use super::ranges_for_source;

    #[test]
    fn utf8_ranges_map_to_utf16_and_preserve_crlf_breaks() {
        let source = "😀head\r\n<!-- wrapper 😀 -->\r\nbody\n";
        let start = source.find("<!--").unwrap();
        let end = source.find("body").unwrap();
        let hidden = start..end;
        let ranges = ranges_for_source(source, std::slice::from_ref(&hidden));
        let expected_start = source[..start].encode_utf16().count();
        let expected_end = source[..end].encode_utf16().count();
        assert_eq!(ranges.hidden_lines, vec![expected_start..expected_end]);
        assert_eq!(
            ranges.hidden_content,
            vec![expected_start..expected_end - 2],
            "CRLF stays available to TextKit as a paragraph break",
        );
    }

    #[test]
    fn adjacent_hidden_lines_merge_without_hiding_neighboring_body() {
        let source = "before\n<!-- one -->\n<!-- two -->\nafter";
        let first = source.find("<!-- one").unwrap();
        let second = source.find("<!-- two").unwrap();
        let after = source.find("after").unwrap();
        let ranges = ranges_for_source(source, &[first..second, second..after]);
        assert_eq!(ranges.hidden_lines.len(), 1);
        let after_utf16 = source[..after].encode_utf16().count();
        assert!(!ranges.hidden_lines[0].contains(&after_utf16));
    }
}
