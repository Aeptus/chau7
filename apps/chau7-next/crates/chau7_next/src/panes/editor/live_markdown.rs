//! GPUI's supported text attributes for the source Markdown editor.
//! A single nonoverlapping collection preserves Swift's last-attribute-wins order.
use super::super::highlight::Palette;
use chau7_next_core::editor::{
    HighlightColor,
    live_markdown::{Document, Kind},
};
use gpui::{FontStyle, FontWeight, HighlightStyle, StrikethroughStyle, UnderlineStyle, px};
use gpui_kit::base::input::TextDecoration;
use std::collections::BTreeMap;

fn style(kind: Kind, palette: Palette) -> HighlightStyle {
    let dim = palette.foreground().opacity(0.45);
    let line = || StrikethroughStyle {
        thickness: px(1.),
        color: None,
    };
    match kind {
        Kind::Heading(_) => HighlightStyle {
            color: Some(palette.foreground()),
            font_weight: Some(FontWeight::BOLD),
            ..Default::default()
        },
        Kind::Marker | Kind::HorizontalRule => HighlightStyle {
            color: Some(dim),
            ..Default::default()
        },
        Kind::Bold => HighlightStyle {
            font_weight: Some(FontWeight::BOLD),
            ..Default::default()
        },
        Kind::Italic => HighlightStyle {
            font_style: Some(FontStyle::Italic),
            ..Default::default()
        },
        Kind::CodeSpan => HighlightStyle {
            color: Some(palette.status(HighlightColor::Pink)),
            background_color: Some(palette.foreground().opacity(0.15)),
            ..Default::default()
        },
        Kind::CodeFence => HighlightStyle {
            color: Some(palette.status(HighlightColor::Pink)),
            ..Default::default()
        },
        Kind::Strikethrough => HighlightStyle {
            strikethrough: Some(line()),
            ..Default::default()
        },
        Kind::LinkText => HighlightStyle {
            color: Some(palette.status(HighlightColor::Blue)),
            underline: Some(UnderlineStyle {
                thickness: px(1.),
                color: None,
                wavy: false,
            }),
            ..Default::default()
        },
        Kind::Blockquote => HighlightStyle {
            font_style: Some(FontStyle::Italic),
            color: Some(palette.foreground().opacity(0.65)),
            ..Default::default()
        },
        Kind::ListMarker => HighlightStyle {
            color: Some(palette.status(HighlightColor::Blue)),
            ..Default::default()
        },
        Kind::TaskCheckbox(checked) => HighlightStyle {
            font_weight: Some(FontWeight::BOLD),
            color: Some(if checked {
                palette.status(HighlightColor::Green)
            } else {
                palette.foreground().opacity(0.65)
            }),
            ..Default::default()
        },
        Kind::CompletedTask => HighlightStyle {
            color: Some(dim),
            strikethrough: Some(line()),
            ..Default::default()
        },
    }
}
fn overlay(base: &mut HighlightStyle, later: &HighlightStyle) {
    if later.color.is_some() {
        base.color = later.color;
    }
    if later.font_weight.is_some() {
        base.font_weight = later.font_weight;
    }
    if later.font_style.is_some() {
        base.font_style = later.font_style;
    }
    if later.background_color.is_some() {
        base.background_color = later.background_color;
    }
    if later.underline.is_some() {
        base.underline = later.underline;
    }
    if later.strikethrough.is_some() {
        base.strikethrough = later.strikethrough;
    }
}
pub(super) fn decorations(doc: &Document, palette: Palette) -> Vec<TextDecoration> {
    let mut events = Vec::with_capacity(doc.runs().len() * 2);
    for (index, run) in doc.runs().iter().enumerate() {
        events.push((run.range.start, true, index));
        events.push((run.range.end, false, index));
    }
    events.sort_unstable();
    let mut active = BTreeMap::new();
    let mut previous = 0;
    let mut out: Vec<TextDecoration> = Vec::new();
    for (position, start, index) in events {
        if position > previous && !active.is_empty() {
            let mut style = HighlightStyle::default();
            for value in active.values() {
                overlay(&mut style, value);
            }
            if let Some(last) = out.last_mut()
                && last.range.end == previous
                && last.style == style
            {
                last.range.end = position;
            } else {
                out.push(TextDecoration {
                    range: previous..position,
                    style,
                });
            }
        }
        if start {
            active.insert(index, style(doc.runs()[index].kind, palette));
        } else {
            active.remove(&index);
        }
        previous = position;
    }
    out
}
#[cfg(test)]
mod tests {
    use super::*;
    use chau7_next_core::editor::config::EditorTheme;
    #[test]
    fn composed_overlaps_preserve_link_text_color_and_task_strike() {
        let text = "- [x] **done** [lien](url)";
        let mut doc = Document::default();
        doc.update(text);
        let palette = Palette {
            theme: EditorTheme::Default,
            dark: true,
        };
        let spans = decorations(&doc, palette);
        assert!(spans.windows(2).all(|w| w[0].range.end <= w[1].range.start));
        let at = |needle: &str| {
            let offset = text.find(needle).unwrap();
            &spans
                .iter()
                .find(|s| s.range.contains(&offset))
                .unwrap()
                .style
        };
        assert_eq!(at("done").font_weight, Some(FontWeight::BOLD));
        assert!(at("done").strikethrough.is_some());
        assert_eq!(at("lien").color, Some(palette.status(HighlightColor::Blue)));
        assert!(at("lien").underline.is_some());
        assert!(at("lien").strikethrough.is_some());
    }
}
