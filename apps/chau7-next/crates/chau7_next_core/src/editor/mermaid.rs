//! Native Mermaid compilation. No browser, process, or network is used at render time.
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};

use quick_xml::{
    Reader, Writer,
    events::{BytesStart, Event},
};

const MAX_SOURCE: usize = 50_000;
const MAX_CACHE_BYTES: usize = 8 * 1024 * 1024;
const DAY_MS: u64 = 86_400_000;

/// Opaque theme colours, resolved before the SVG reaches the native renderer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Theme {
    pub background: [u8; 3],
    pub foreground: [u8; 3],
    pub muted: [u8; 3],
    pub border: [u8; 3],
    pub accent: [u8; 3],
}

/// The complete input identity. Widths are quantized to avoid compilation per resize pixel.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Request {
    pub source: Arc<str>,
    pub width: u32,
    pub theme: Theme,
    /// Gantt's today marker must not survive a date change in the cache.
    pub day: u64,
}

impl Request {
    pub fn new(source: &str, width: f32, theme: Theme, now_ms: u64) -> Self {
        let width = if width.is_finite() {
            width.clamp(128.0, 4096.0) as u32
        } else {
            640
        };
        Self {
            source: source.into(),
            width: width / 32 * 32,
            theme,
            day: now_ms / DAY_MS,
        }
    }
}

/// Normalized SVG and its natural size, before fit or zoom.
#[derive(Clone, Debug)]
pub struct Diagram {
    pub svg: String,
    pub width: f32,
    pub height: f32,
}

pub fn is_mermaid(language: Option<&str>) -> bool {
    language
        .and_then(|l| l.split_whitespace().next())
        .is_some_and(|l| l.eq_ignore_ascii_case("mermaid"))
}

/// Bounded, process-local SVG cache. Call only from a background worker.
pub fn compile(request: &Request) -> Result<Arc<Diagram>, String> {
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(Cache::default()));
    if let Ok(mut cache) = cache.lock()
        && let Some(diagram) = cache.get(request)
    {
        return Ok(diagram);
    }
    let diagram = Arc::new(render(request)?);
    if let Ok(mut cache) = cache.lock() {
        cache.insert(request.clone(), diagram.clone());
    }
    Ok(diagram)
}

#[derive(Default)]
struct Cache {
    entries: VecDeque<(Request, Arc<Diagram>)>,
    bytes: usize,
}

impl Cache {
    fn get(&mut self, request: &Request) -> Option<Arc<Diagram>> {
        let at = self.entries.iter().position(|(key, _)| key == request)?;
        let entry = self.entries.remove(at)?;
        let diagram = entry.1.clone();
        self.entries.push_back(entry);
        Some(diagram)
    }

    fn insert(&mut self, key: Request, diagram: Arc<Diagram>) {
        let size = key.source.len() + diagram.svg.len();
        if size > MAX_CACHE_BYTES {
            return;
        }
        while self.entries.len() >= 32 || self.bytes + size > MAX_CACHE_BYTES {
            let Some((key, old)) = self.entries.pop_front() else {
                break;
            };
            self.bytes -= key.source.len() + old.svg.len();
        }
        self.bytes += size;
        self.entries.push_back((key, diagram));
    }
}

fn render(request: &Request) -> Result<Diagram, String> {
    if request.source.len() > MAX_SOURCE {
        return Err("Diagram exceeds the 50,000-byte source limit.".into());
    }
    let options = serde_json::json!({
        "maxWidth": request.width, "fontSize": 16, "padding": 16,
        "autoDirection": false, "responsive": false,
        "limit": MAX_SOURCE, "outputLimit": 2_000_000, "maxEdges": 2000,
        // Native images do not have browser link hit testing or remote image loading.
        "links": false, "images": false
    });
    let rendered = ondine::render(
        &request.source,
        &options.to_string(),
        (request.day * DAY_MS) as f64,
    )
    .map_err(|e| e.message)?;
    if !rendered.width.is_finite()
        || !rendered.height.is_finite()
        || rendered.width <= 0.0
        || rendered.height <= 0.0
        || rendered.width > 16_384.0
        || rendered.height > 16_384.0
    {
        return Err(
            "Diagram dimensions are too large to preview. Split it into smaller diagrams.".into(),
        );
    }
    Ok(Diagram {
        svg: native_svg(&rendered.svg, request.theme)?,
        width: rendered.width as f32,
        height: rendered.height as f32,
    })
}

fn hex(rgb: [u8; 3]) -> String {
    format!("#{:02x}{:02x}{:02x}", rgb[0], rgb[1], rgb[2])
}

fn variables(theme: Theme) -> HashMap<String, String> {
    let mut vars = HashMap::new();
    for (name, value) in [
        ("bg", hex(theme.background)),
        ("fg", hex(theme.foreground)),
        ("muted", hex(theme.muted)),
        ("border", hex(theme.border)),
        ("line", hex(theme.muted)),
        ("accent", hex(theme.accent)),
        ("critical", "#e06c75".into()),
        ("surface", hex(theme.background)),
        (
            "surface-alt",
            hex(std::array::from_fn(|i| {
                (u16::from(theme.foreground[i]) / 5 + u16::from(theme.background[i]) * 4 / 5) as u8
            })),
        ),
        (
            "font",
            "Menlo, Consolas, DejaVu Sans Mono, Liberation Mono, monospace".into(),
        ),
        ("radius", "5".into()),
        ("stroke", "1.5".into()),
    ] {
        vars.insert(format!("--ondine-{name}"), value);
    }
    // Foreground shades keep the background-coloured text of pie/bar charts legible.
    for (i, percent) in [100_u16, 57, 86, 50, 79, 64, 93, 71]
        .into_iter()
        .enumerate()
    {
        let colour = std::array::from_fn(|j| {
            ((u16::from(theme.foreground[j]) * percent
                + u16::from(theme.background[j]) * (100 - percent))
                / 100) as u8
        });
        vars.insert(format!("--ondine-series-{}", i + 1), hex(colour));
    }
    vars
}

/// Resolve balanced CSS var() expressions, including nested comma-containing fallbacks.
/// This operates on presentation attributes only, never on labels or link identifiers.
fn resolve(value: &str, vars: &HashMap<String, String>, depth: usize) -> Result<String, String> {
    if depth > 16 {
        return Err("Diagram style contains cyclic or deeply nested variables.".into());
    }
    let mut rest = value;
    let mut out = String::new();
    while let Some(start) = rest.find("var(") {
        out.push_str(&rest[..start]);
        let tail = &rest[start + 4..];
        let mut level = 0;
        let mut comma = None;
        let mut end = None;
        for (i, c) in tail.char_indices() {
            match c {
                '(' => level += 1,
                ')' if level == 0 => {
                    end = Some(i);
                    break;
                }
                ')' => level -= 1,
                ',' if level == 0 && comma.is_none() => comma = Some(i),
                _ => {}
            }
        }
        let end = end.ok_or("Unclosed diagram style variable.")?;
        let name = tail[..comma.unwrap_or(end)].trim();
        let fallback = comma.map(|c| tail[c + 1..end].trim());
        let selected = vars
            .get(name)
            .map(String::as_str)
            .or(fallback)
            .ok_or_else(|| format!("Unknown diagram style variable: {name}"))?;
        out.push_str(&resolve(selected, vars, depth + 1)?);
        rest = &tail[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

fn presentation(name: &str) -> bool {
    matches!(
        name,
        "style"
            | "fill"
            | "stroke"
            | "color"
            | "font-family"
            | "font-weight"
            | "font-size"
            | "stroke-width"
            | "rx"
            | "ry"
    )
}

/// XML-aware conversion: browser CSS variables and CSS rectangle radii are unsupported by usvg.
/// Labels, accessibility text, author colours and IDs are preserved verbatim.
fn native_svg(svg: &str, theme: Theme) -> Result<String, String> {
    let mut vars = variables(theme);
    let mut reader = Reader::from_str(svg);
    let mut writer = Writer::new(Vec::with_capacity(svg.len()));
    let mut root = true;
    loop {
        let event = reader.read_event().map_err(|e| e.to_string())?;
        let empty = matches!(&event, Event::Empty(_));
        let event = match event {
            Event::Start(tag) | Event::Empty(tag) => {
                let name = tag.name().as_ref().to_string();
                let mut attrs = Vec::new();
                for attribute in tag.attributes() {
                    let attribute = attribute.map_err(|e| e.to_string())?;
                    let key = attribute.key.as_ref().to_string();
                    let value = attribute
                        .normalized_value(quick_xml::XmlVersion::Implicit1_0)
                        .map_err(|e| e.to_string())?
                        .into_owned();
                    if root && key == "style" {
                        for declaration in value.split(';') {
                            if let Some((key, value)) = declaration.split_once(':')
                                && key.trim().starts_with("--_")
                            {
                                vars.insert(key.trim().into(), value.trim().into());
                            }
                        }
                    }
                    attrs.push((key, value));
                }
                let mut radii = Vec::new();
                for (key, value) in &mut attrs {
                    if !presentation(key) {
                        continue;
                    }
                    if key == "style" {
                        let mut styles = Vec::new();
                        for declaration in value.split(';') {
                            let Some((prop, val)) = declaration.split_once(':') else {
                                continue;
                            };
                            let prop = prop.trim();
                            if prop.starts_with("--")
                                || matches!(prop, "font" | "max-width" | "height")
                            {
                                continue;
                            }
                            let val = resolve(val.trim(), &vars, 0)?;
                            if matches!(prop, "rx" | "ry") {
                                radii.push((prop.to_string(), val));
                            } else {
                                styles.push(format!("{prop}:{val}"));
                            }
                        }
                        *value = styles.join(";");
                    } else {
                        *value = resolve(value, &vars, 0)?;
                    }
                }
                for (key, val) in radii {
                    attrs.retain(|(old, _)| *old != key);
                    attrs.push((key, val));
                }
                if root {
                    attrs.push(("font-size".into(), "16".into()));
                    attrs.push((
                        "font-family".into(),
                        "Menlo, Consolas, DejaVu Sans Mono, Liberation Mono, monospace".into(),
                    ));
                    root = false;
                }
                let mut output = BytesStart::new(name);
                for (key, value) in &attrs {
                    output.push_attribute((key.as_str(), value.as_str()));
                }
                if empty {
                    Event::Empty(output)
                } else {
                    Event::Start(output)
                }
            }
            Event::Eof => break,
            other => other.into_owned(),
        };
        writer.write_event(event).map_err(|e| e.to_string())?;
    }
    String::from_utf8(writer.into_inner()).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn theme() -> Theme {
        Theme {
            background: [24, 24, 28],
            foreground: [230, 230, 235],
            muted: [170, 170, 180],
            border: [95, 95, 110],
            accent: [90, 150, 240],
        }
    }
    fn request(source: &str) -> Request {
        Request::new(source, 480.0, theme(), DAY_MS)
    }

    #[test]
    fn renders_common_diagram_families_as_native_svg() {
        for source in [
            "flowchart LR\n subgraph Client\n A[Long label with spaces] --> B[Résumé 日本語]\n end\n B --> C[(Database)]",
            "sequenceDiagram\n Alice->>Bob: Hello\n Bob-->>Alice: World",
            "classDiagram\n Animal <|-- Duck",
            "stateDiagram-v2\n [*] --> Ready\n Ready --> [*]",
            "erDiagram\n CUSTOMER ||--o{ ORDER : places",
            "pie title Languages\n \"Rust\" : 60\n \"Other\" : 40",
            "gantt\n title Work\n dateFormat YYYY-MM-DD\n section Tasks\n Build :2026-10-20, 2d",
        ] {
            let diagram = render(&request(source)).unwrap_or_else(|e| panic!("{source}: {e}"));
            assert!(diagram.width > 0.0 && diagram.height > 0.0);
            assert!(!diagram.svg.contains("var("));
            assert!(!diagram.svg.contains("color-mix("));
            assert!(diagram.svg.contains("font-size=\"16\""));
        }
    }

    #[test]
    fn labels_are_never_treated_as_css() {
        let diagram = render(&request(
            "flowchart LR\n A[\"var(--_fg) & <text>\"] --> B[OK]",
        ))
        .unwrap();
        assert!(diagram.svg.contains("var(--_fg)"));
        assert!(diagram.svg.contains("&amp;"));
        // Mermaid treats raw HTML-like tags as markup. Verify XML preservation at
        // the adapter boundary independently of the compiler's label semantics.
        let svg = native_svg(r#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><text>var(--_fg) &amp; &lt;text&gt;</text></svg>"#, theme()).unwrap();
        assert!(svg.contains("var(--_fg) &amp; &lt;text&gt;"));
        assert!(diagram.svg.contains("#e6e6eb"));
    }

    #[test]
    fn errors_and_limits_are_recoverable() {
        assert!(render(&request("not a diagram")).is_err());
        assert!(render(&request(&"x".repeat(MAX_SOURCE + 1))).is_err());
        assert!(render(&request("flowchart LR\n A --> B")).is_ok());
    }

    #[test]
    fn request_identity_includes_source_width_theme_and_date() {
        let a = request("flowchart LR\n A --> B");
        assert_eq!(a, Request::new(&a.source, 490.0, theme(), DAY_MS + 1000));
        for b in [
            request("flowchart LR\n A --> C"),
            Request::new(&a.source, 320.0, theme(), DAY_MS),
            Request::new(
                &a.source,
                480.0,
                Theme {
                    background: [255; 3],
                    ..theme()
                },
                DAY_MS,
            ),
            Request::new(&a.source, 480.0, theme(), 2 * DAY_MS),
        ] {
            assert_ne!(a, b);
        }
        assert_eq!(Request::new("x", f32::NAN, theme(), 0).width, 640);
    }

    #[test]
    fn cache_reuses_results_and_evicts_oldest() {
        let mut cache = Cache::default();
        let first = Arc::new(render(&request("flowchart LR\n A --> B")).unwrap());
        let key = request("flowchart LR\n A --> B");
        cache.insert(key.clone(), first.clone());
        assert!(Arc::ptr_eq(&cache.get(&key).unwrap(), &first));
        for i in 0..33 {
            let key = request(&format!("flowchart LR\n A --> N{i}"));
            cache.insert(key, first.clone());
        }
        assert!(cache.get(&key).is_none());
        assert!(cache.entries.len() <= 32 && cache.bytes <= MAX_CACHE_BYTES);
    }

    #[test]
    fn nested_fallbacks_and_cycles_are_bounded() {
        let mut vars = variables(theme());
        assert_eq!(
            resolve("var(--missing,var(--ondine-fg))", &vars, 0).unwrap(),
            "#e6e6eb"
        );
        vars.insert("--cycle".into(), "var(--cycle)".into());
        assert!(resolve("var(--cycle)", &vars, 0).is_err());
        assert!(resolve("var(--missing)", &vars, 0).is_err());
        assert!(resolve("var(--missing", &vars, 0).is_err());
    }

    #[test]
    fn only_mermaid_fences_are_selected() {
        assert!(is_mermaid(Some("Mermaid extra")));
        for language in [None, Some(""), Some("rust"), Some("mermaid-js")] {
            assert!(!is_mermaid(language));
        }
    }

    #[test]
    fn native_renderer_preserves_shapes_labels_and_theme_colours() {
        use resvg::{tiny_skia, usvg};
        static FONTS: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();
        let fonts = FONTS.get_or_init(|| {
            let mut fonts = usvg::fontdb::Database::new();
            fonts.load_system_fonts();
            Arc::new(fonts)
        });
        for colours in [
            theme(),
            Theme {
                background: [250; 3],
                foreground: [25; 3],
                ..theme()
            },
        ] {
            let diagram = render(&Request::new(
                "flowchart LR\n A[Readable label] --> B[Done]",
                640.0,
                colours,
                0,
            ))
            .unwrap();
            let options = usvg::Options {
                fontdb: fonts.clone(),
                ..Default::default()
            };
            let tree = usvg::Tree::from_str(&diagram.svg, &options).unwrap();
            fn glyph_paths(group: &usvg::Group) -> usize {
                group
                    .children()
                    .iter()
                    .map(|node| match node {
                        usvg::Node::Text(text) => text.flattened().children().len(),
                        usvg::Node::Group(group) => glyph_paths(group),
                        _ => 0,
                    })
                    .sum()
            }
            assert!(
                glyph_paths(tree.root()) > 0,
                "Native labels must contain drawable glyph paths"
            );
            let mut pixmap = tiny_skia::Pixmap::new(
                tree.size().width().ceil() as u32,
                tree.size().height().ceil() as u32,
            )
            .unwrap();
            resvg::render(
                &tree,
                tiny_skia::Transform::identity(),
                &mut pixmap.as_mut(),
            );
            assert!(pixmap.pixels().iter().filter(|p| p.alpha() > 0).count() > 100);
            let expected = colours.foreground;
            assert!(
                pixmap.pixels().iter().any(|p| p.alpha() == 255
                    && p.red().abs_diff(expected[0]) < 3
                    && p.green().abs_diff(expected[1]) < 3
                    && p.blue().abs_diff(expected[2]) < 3),
                "Theme foreground must actually render"
            );
        }
    }
}
