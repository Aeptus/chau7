//! Images drawn in the terminal grid: iTerm2 inline images (`imgcat`),
//! Sixel and Kitty graphics (`Rendering/InlineImageSupport.swift`,
//! `RustTerminalView.swift` `renderInlineImages`, `updateInlineImagePositions`).
//!
//! `chau7_terminal` strips the escape sequences from the output and queues
//! the decoded payloads; the view takes them after each output batch
//! ([`ImageLayer::ingest`]). Each image is anchored to the absolute line the
//! cursor was on (scrollback size plus screen row), so it scrolls with the
//! output and with the scroll bar, and is painted with the grid
//! (`paint.rs`). Images are dropped by Clear Scrollback, when they leave the
//! scrollback, and oldest first past the Kitty cache limit.
//!
//! Swift shows only iTerm2 images (Sixel and Kitty are intercepted but never
//! drawn, see RBK-056); Chau7 Next draws all three.

use std::sync::Arc;

use chau7_next_core::inline_image::{self, InlineImageArgs, SniffedFormat};
use chau7_terminal::graphics::{DecodedImage, ImageProtocol};
use gpui::{Bounds, Pixels, RenderImage, point, px, size};

use crate::settings::Settings;

/// Right-click menu of an inline image (`InlineImageView` menu).
#[derive(Clone, PartialEq, Debug, gpui::Action)]
#[action(namespace = chau7, no_json)]
pub struct InlineImageMenu {
    pub image: u64,
    pub op: InlineImageOp,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum InlineImageOp {
    Copy,
    Save,
    OpenInPreview,
}

/// One image placed in the terminal.
pub struct InlineImage {
    pub id: u64,
    pub render: Arc<RenderImage>,
    /// Pixel size of the decoded image.
    pub natural: (u32, u32),
    /// RGBA pixels, kept for Copy Image and Save Image.
    rgba: Arc<Vec<u8>>,
    /// iTerm2 arguments (size, name); `None` for Sixel and Kitty.
    pub args: Option<InlineImageArgs>,
    /// Absolute line: scrollback size when the image arrived plus the cursor row.
    pub anchor_line: i64,
    pub anchor_col: u16,
}

impl InlineImage {
    pub fn file_name(&self) -> String {
        self.args
            .as_ref()
            .map(|a| a.file_name())
            .unwrap_or_else(|| "image.png".into())
    }

    /// The image as PNG bytes (Copy Image, Save Image..., Open in Preview).
    pub fn png(&self) -> Option<Vec<u8>> {
        let mut out = Vec::new();
        let encoder = image::codecs::png::PngEncoder::new(&mut out);
        image::ImageEncoder::write_image(
            encoder,
            &self.rgba,
            self.natural.0,
            self.natural.1,
            image::ExtendedColorType::Rgba8,
        )
        .ok()?;
        Some(out)
    }

    /// Drawn size in points, for cells of `cell` points and a `grid` of cells.
    fn draw_size(&self, cell: (f32, f32), grid: (u16, u16)) -> (f32, f32) {
        let natural = (self.natural.0 as f32, self.natural.1 as f32);
        match &self.args {
            Some(args) => args.target_size(natural, cell, grid),
            // Sixel and Kitty: one image pixel per point, same caps as iTerm2.
            None => InlineImageArgs::default().target_size(natural, cell, grid),
        }
    }
}

/// Where to draw one image this frame (relative to the grid origin).
#[derive(Clone)]
pub struct Placement {
    pub id: u64,
    pub bounds: Bounds<Pixels>,
    pub render: Arc<RenderImage>,
}

#[derive(Default)]
pub struct ImageLayer {
    images: Vec<InlineImage>,
    next_id: u64,
    /// Scrollback size last seen, to follow history being cleared or trimmed.
    last_history: u32,
    /// Placements of the last frame, for right-click hit tests.
    pub last_placements: Vec<Placement>,
}

impl ImageLayer {
    pub fn is_empty(&self) -> bool {
        self.images.is_empty()
    }

    pub fn get(&self, id: u64) -> Option<&InlineImage> {
        self.images.iter().find(|i| i.id == id)
    }

    /// Clear Scrollback (Swift removes every inline image).
    pub fn clear(&mut self) {
        self.images.clear();
        self.last_placements.clear();
    }

    /// Add images decoded by the emulator, following the settings.
    pub fn ingest(&mut self, decoded: Vec<DecodedImage>, settings: &Settings) {
        let graphics = &settings.appearance.graphics;
        for image in decoded {
            let allowed = match image.protocol {
                ImageProtocol::ITerm2 => settings.appearance.display.inline_images,
                ImageProtocol::Sixel => graphics.sixel,
                ImageProtocol::Kitty => graphics.kitty,
            };
            if !allowed {
                continue;
            }
            let Some((rgba, w, h, args)) = decode(&image) else {
                log::warn!(
                    "inline image: could not decode a {:?} image",
                    image.protocol
                );
                continue;
            };
            if args.as_ref().is_some_and(|a| !a.inline) {
                // `inline=0` is a file download in iTerm2; Swift skips it too.
                continue;
            }
            self.next_id += 1;
            let render = render_image(&rgba, w, h);
            self.images.push(InlineImage {
                id: self.next_id,
                render,
                natural: (w, h),
                rgba: Arc::new(rgba),
                args,
                // Where the image arrived in the stream (the C API's
                // `anchor_*` is the cursor after the whole output chunk).
                anchor_line: image.history_size as i64 + image.arrival_row as i64,
                anchor_col: image.arrival_col,
            });
        }
        self.enforce_limit(graphics.kitty_cache_limit_mb as usize * 1024 * 1024);
    }

    /// Drop the oldest images past `limit` bytes of pixels.
    fn enforce_limit(&mut self, limit: usize) {
        let mut total: usize = self.images.iter().map(|i| i.rgba.len()).sum();
        while total > limit && self.images.len() > 1 {
            total -= self.images.remove(0).rgba.len();
        }
    }

    /// Follow scrollback changes: when history shrinks (cleared, trimmed by a
    /// smaller limit), lines left the top, so every anchor moves up with them.
    /// Images whose line left the scrollback are dropped.
    pub fn track_history(&mut self, history: u32) {
        if history < self.last_history {
            let removed = (self.last_history - history) as i64;
            for image in &mut self.images {
                image.anchor_line -= removed;
            }
        }
        self.last_history = history;
        self.images.retain(|i| {
            let rows = (i.natural.1 as i64).max(1);
            // Keep while any part could still be on a scrollback line.
            i.anchor_line + rows >= 0
        });
    }

    /// Placements for this frame. `history` and `display_offset` come from
    /// the grid snapshot.
    pub fn place(
        &mut self,
        cell: (f32, f32),
        grid: (u16, u16),
        history: u32,
        display_offset: u32,
    ) -> Vec<Placement> {
        let mut out = Vec::new();
        for image in &self.images {
            let row = inline_image::viewport_row(image.anchor_line, history, display_offset);
            let (w, h) = image.draw_size(cell, grid);
            if w <= 0.0 || h <= 0.0 {
                continue;
            }
            let top = row as f32 * cell.1;
            // Hidden when entirely above or below the viewport.
            if top + h <= 0.0 || top >= grid.1 as f32 * cell.1 {
                continue;
            }
            out.push(Placement {
                id: image.id,
                bounds: Bounds::new(
                    point(px(image.anchor_col as f32 * cell.0), px(top)),
                    size(px(w), px(h)),
                ),
                render: image.render.clone(),
            });
        }
        self.last_placements = out.clone();
        out
    }

    /// The image under a point relative to the grid origin (last frame).
    pub fn hit(&self, local: gpui::Point<Pixels>) -> Option<u64> {
        self.last_placements
            .iter()
            .rev()
            .find(|p| p.bounds.contains(&local))
            .map(|p| p.id)
    }
}

/// Decode a queued image into RGBA pixels.
fn decode(image: &DecodedImage) -> Option<(Vec<u8>, u32, u32, Option<InlineImageArgs>)> {
    match image.protocol {
        ImageProtocol::ITerm2 => {
            use base64::Engine;
            let args = InlineImageArgs::parse(&image.args);
            // `Data(base64Encoded:options: .ignoreUnknownCharacters)`.
            let clean: Vec<u8> = image
                .rgba
                .iter()
                .copied()
                .filter(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'='))
                .collect();
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(&clean)
                .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(&clean))
                .ok()?;
            let (rgba, w, h) = decode_encoded(&bytes)?;
            Some((rgba, w, h, Some(args)))
        }
        ImageProtocol::Sixel => {
            let expected = image.width as usize * image.height as usize * 4;
            (image.width > 0 && image.rgba.len() >= expected).then(|| {
                (
                    image.rgba[..expected].to_vec(),
                    image.width,
                    image.height,
                    None,
                )
            })
        }
        ImageProtocol::Kitty => {
            // `f=100` arrives as PNG bytes, `f=24` and `f=32` as RGBA.
            if inline_image::sniff_format(&image.rgba) == Some(SniffedFormat::Png) {
                let (rgba, w, h) = decode_encoded(&image.rgba)?;
                return Some((rgba, w, h, None));
            }
            let expected = image.width as usize * image.height as usize * 4;
            (image.width > 0 && image.rgba.len() >= expected).then(|| {
                (
                    image.rgba[..expected].to_vec(),
                    image.width,
                    image.height,
                    None,
                )
            })
        }
    }
}

/// PNG, JPEG, GIF (first frame), WebP, BMP or TIFF bytes to RGBA.
pub fn decode_encoded(bytes: &[u8]) -> Option<(Vec<u8>, u32, u32)> {
    let format = match inline_image::sniff_format(bytes)? {
        SniffedFormat::Png => image::ImageFormat::Png,
        SniffedFormat::Jpeg => image::ImageFormat::Jpeg,
        SniffedFormat::Gif => image::ImageFormat::Gif,
        SniffedFormat::Webp => image::ImageFormat::WebP,
        SniffedFormat::Bmp => image::ImageFormat::Bmp,
        SniffedFormat::Tiff => image::ImageFormat::Tiff,
    };
    let decoded = image::load_from_memory_with_format(bytes, format).ok()?;
    let rgba = decoded.into_rgba8();
    let (w, h) = rgba.dimensions();
    (w > 0 && h > 0).then(|| (rgba.into_raw(), w, h))
}

/// GPUI wants BGRA frames.
fn render_image(rgba: &[u8], w: u32, h: u32) -> Arc<RenderImage> {
    let mut bgra = rgba.to_vec();
    for px in bgra.as_chunks_mut::<4>().0 {
        px.swap(0, 2);
    }
    let buffer = image::RgbaImage::from_raw(w, h, bgra).expect("buffer matches size");
    Arc::new(RenderImage::new(vec![image::Frame::new(buffer)]))
}

/// The Graphics settings "Render Test Image": a 128 x 64 gradient from
/// system blue through purple to pink at 45 degrees, as PNG.
pub fn test_image_png() -> Vec<u8> {
    const STOPS: [(f32, f32, f32); 3] = [
        (0.0, 122.0, 255.0),
        (175.0, 82.0, 222.0),
        (255.0, 45.0, 85.0),
    ];
    let (w, h) = (128u32, 64u32);
    let mut rgba = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            // 45 degrees: bottom left to top right.
            let t = (x as f32 / (w - 1) as f32 + (1.0 - y as f32 / (h - 1) as f32)) / 2.0;
            let (a, b, f) = if t < 0.5 {
                (STOPS[0], STOPS[1], t * 2.0)
            } else {
                (STOPS[1], STOPS[2], (t - 0.5) * 2.0)
            };
            let mix = |p: f32, q: f32| (p + (q - p) * f).round() as u8;
            rgba.extend_from_slice(&[mix(a.0, b.0), mix(a.1, b.1), mix(a.2, b.2), 255]);
        }
    }
    let mut out = Vec::new();
    let _ = image::ImageEncoder::write_image(
        image::codecs::png::PngEncoder::new(&mut out),
        &rgba,
        w,
        h,
        image::ExtendedColorType::Rgba8,
    );
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_image_is_a_128_by_64_png() {
        let (rgba, w, h) = decode_encoded(&test_image_png()).unwrap();
        assert_eq!((w, h), (128, 64));
        // Bottom left is system blue, top right system pink.
        let px = |x: u32, y: u32| &rgba[((y * w + x) * 4) as usize..((y * w + x) * 4 + 3) as usize];
        assert_eq!(px(0, 63), &[0, 122, 255]);
        assert_eq!(px(127, 0), &[255, 45, 85]);
    }

    fn png_bytes(w: u32, h: u32) -> Vec<u8> {
        let rgba = vec![200u8; (w * h * 4) as usize];
        let mut out = Vec::new();
        image::ImageEncoder::write_image(
            image::codecs::png::PngEncoder::new(&mut out),
            &rgba,
            w,
            h,
            image::ExtendedColorType::Rgba8,
        )
        .unwrap();
        out
    }

    fn iterm(args: &str, png: &[u8], row: i32, history: u32) -> DecodedImage {
        use base64::Engine;
        DecodedImage {
            id: 0,
            width: 0,
            height: 0,
            rgba: base64::engine::general_purpose::STANDARD
                .encode(png)
                .into_bytes(),
            anchor_row: row,
            anchor_col: 2,
            protocol: ImageProtocol::ITerm2,
            args: args.into(),
            arrival_row: row,
            arrival_col: 2,
            history_size: history,
        }
    }

    #[test]
    fn iterm_images_are_decoded_and_placed_at_their_line() {
        let mut layer = ImageLayer::default();
        let settings = Settings::default();
        layer.ingest(
            vec![iterm(
                "name=a.png;inline=1;width=4",
                &png_bytes(20, 10),
                1,
                5,
            )],
            &settings,
        );
        assert!(!layer.is_empty());
        let image = layer.get(1).unwrap();
        assert_eq!(image.natural, (20, 10));
        assert_eq!(image.anchor_line, 6);
        assert_eq!(image.file_name(), "a.png");
        assert!(image.png().is_some());
        // 4 cells (32 pt) wide, auto height (10): Swift fits the aspect
        // ratio inside both, so 20 x 10, at row 1, column 2.
        let placed = layer.place((8.0, 16.0), (80, 24), 5, 0);
        assert_eq!(placed.len(), 1);
        assert_eq!(placed[0].bounds.origin, point(px(16.0), px(16.0)));
        assert_eq!(placed[0].bounds.size, size(px(20.0), px(10.0)));
        // 30 lines of output later the image has scrolled off the top...
        assert!(layer.place((8.0, 16.0), (80, 24), 35, 0).is_empty());
        // ...and scrolling back shows it again.
        assert_eq!(layer.place((8.0, 16.0), (80, 24), 35, 30).len(), 1);
        assert_eq!(layer.hit(point(px(20.0), px(20.0))), Some(1));
        assert_eq!(layer.hit(point(px(0.0), px(0.0))), None);
    }

    #[test]
    fn settings_gate_each_protocol() {
        let mut layer = ImageLayer::default();
        let mut settings = Settings::default();
        settings.appearance.display.inline_images = false;
        layer.ingest(vec![iterm("inline=1", &png_bytes(2, 2), 0, 0)], &settings);
        assert!(layer.is_empty());
        let sixel = || DecodedImage {
            id: 0,
            width: 2,
            height: 2,
            rgba: vec![1; 16],
            anchor_row: 0,
            anchor_col: 0,
            protocol: ImageProtocol::Sixel,
            args: String::new(),
            arrival_row: 0,
            arrival_col: 0,
            history_size: 0,
        };
        layer.ingest(vec![sixel()], &settings);
        assert!(layer.is_empty(), "Sixel is off by default");
        settings.appearance.graphics.sixel = true;
        layer.ingest(vec![sixel()], &settings);
        assert!(!layer.is_empty());
        // inline=0 is a download, not shown.
        settings.appearance.display.inline_images = true;
        layer.clear();
        layer.ingest(vec![iterm("inline=0", &png_bytes(2, 2), 0, 0)], &settings);
        assert!(layer.is_empty());
    }

    #[test]
    fn cleared_history_moves_anchors_up() {
        let mut layer = ImageLayer::default();
        layer.ingest(
            vec![iterm("", &png_bytes(2, 2), 3, 10)],
            &Settings::default(),
        );
        layer.track_history(10);
        // History cleared: the image was on screen row 3, it stays there.
        layer.track_history(0);
        assert_eq!(layer.get(1).unwrap().anchor_line, 3);
        let placed = layer.place((8.0, 16.0), (80, 24), 0, 0);
        assert_eq!(placed[0].bounds.origin.y, px(48.0));
    }

    #[test]
    fn cache_limit_drops_oldest() {
        let mut layer = ImageLayer::default();
        for _ in 0..3 {
            layer.ingest(
                vec![iterm("", &png_bytes(10, 10), 0, 0)],
                &Settings::default(),
            );
        }
        layer.enforce_limit(400 * 2);
        assert_eq!(layer.images.len(), 2);
        assert!(layer.get(1).is_none());
    }
}
