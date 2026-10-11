//! CPU terminal grid rasterization. GPUI only composites the resulting bitmap.
//! The captured platform text system is the application's own instance, so shaped
//! font IDs and fallback fonts remain identical to the GPU path.

use std::collections::{HashMap, VecDeque};
use std::ops::{Deref, DerefMut};
use std::sync::Arc;

use gpui::{
    AnyWindowHandle, App, Bounds, Corners, DevicePixels, Global, Hsla, PaintQuad, Pixels,
    PlatformTextSystem, Point, RenderGlyphParams, RenderImage, ShapedLine, TextRun, Window, point,
    px, size,
};
use parking_lot::Mutex;

const MAX_SURFACE_BYTES: usize = 64 * 1024 * 1024;
const MAX_GLYPH_BYTES: usize = 32 * 1024 * 1024;
const MAX_GLYPHS: usize = 4096;

struct CpuText {
    platform: Arc<dyn PlatformTextSystem>,
    glyphs: Mutex<GlyphCache>,
}
struct CpuTextGlobal(Arc<CpuText>);
impl Global for CpuTextGlobal {}

pub(crate) fn glyph_cache_bytes(cx: &App) -> Option<u64> {
    cx.try_global::<CpuTextGlobal>()
        .map(|text| text.0.glyphs.lock().bytes as u64)
}

pub(crate) fn release_glyph_cache(cx: &App) -> u64 {
    let Some(text) = cx.try_global::<CpuTextGlobal>() else {
        return 0;
    };
    let mut glyphs = text.0.glyphs.lock();
    let bytes = glyphs.bytes as u64;
    *glyphs = GlyphCache::default();
    bytes
}

pub fn init(platform: Arc<dyn PlatformTextSystem>, cx: &mut App) {
    cx.set_global(CpuTextGlobal(Arc::new(CpuText {
        platform,
        glyphs: Mutex::new(GlyphCache::default()),
    })));
}

struct Raster {
    bounds: Bounds<DevicePixels>,
    width: usize,
    height: usize,
    bytes: Vec<u8>,
}
#[derive(Default)]
struct GlyphCache {
    items: HashMap<RenderGlyphParams, Arc<Raster>>,
    order: VecDeque<RenderGlyphParams>,
    bytes: usize,
}
impl GlyphCache {
    fn insert(&mut self, key: RenderGlyphParams, raster: Arc<Raster>) {
        if raster.bytes.len() > MAX_GLYPH_BYTES || self.items.contains_key(&key) {
            return;
        }
        while self.bytes + raster.bytes.len() > MAX_GLYPH_BYTES || self.items.len() >= MAX_GLYPHS {
            let Some(old) = self.order.pop_front() else {
                break;
            };
            if let Some(old) = self.items.remove(&old) {
                self.bytes -= old.bytes.len();
            }
        }
        self.bytes += raster.bytes.len();
        self.order.push_back(key.clone());
        self.items.insert(key, raster);
    }
}
impl CpuText {
    fn raster(&self, params: &RenderGlyphParams) -> anyhow::Result<Arc<Raster>> {
        if let Some(raster) = self.glyphs.lock().items.get(params).cloned() {
            return Ok(raster);
        }
        let bounds = self.platform.glyph_raster_bounds(params)?;
        let (size, bytes) = if bounds.size.width.0 <= 0 || bounds.size.height.0 <= 0 {
            (size(DevicePixels(0), DevicePixels(0)), Vec::new())
        } else {
            self.platform.rasterize_glyph(params, bounds)?
        };
        let raster = Arc::new(Raster {
            bounds,
            width: size.width.0.max(0) as usize,
            height: size.height.0.max(0) as usize,
            bytes,
        });
        self.glyphs.lock().insert(params.clone(), raster.clone());
        Ok(raster)
    }
}

struct CachedFrame {
    window: AnyWindowHandle,
    image: Arc<RenderImage>,
}
#[derive(Default)]
pub(super) struct FrameCache {
    frame: Option<CachedFrame>,
    last_backend: Option<(bool, bool, std::time::Instant)>,
}
impl FrameCache {
    pub fn diagnostics(&self) -> serde_json::Value {
        let mode = |gpu: bool| if gpu { "gpu" } else { "cpu" };
        serde_json::json!({"requested_renderer":self.last_backend.map(|(requested,_,_)|mode(requested)),"actual_renderer":self.last_backend.map(|(_,actual,_)|mode(actual)),"last_paint_age_seconds":self.last_backend.map(|(_,_,at)|at.elapsed().as_secs_f64()),"fallback_reason":self.last_backend.and_then(|(requested,actual,_)|(!requested&&actual).then_some("cpu_text_system_unavailable")),"cached_cpu_bitmap_bytes":self.bytes()})
    }
    pub fn bytes(&self) -> u64 {
        self.frame
            .as_ref()
            .and_then(|frame| frame.image.as_bytes(0))
            .map_or(0, |bytes| bytes.len() as u64)
    }
    pub fn release(&mut self, cx: &mut App) {
        if let Some(frame) = self.frame.take() {
            // A closed window already released its atlas. A surviving window must
            // release this view's bitmap even when no further frame is painted.
            let _ = frame
                .window
                .update(cx, |_, window, _| window.drop_image(frame.image));
        }
    }
    fn drop_previous(&mut self, window: &mut Window, cx: &mut App) {
        if let Some(frame) = self.frame.take() {
            if frame.window == window.window_handle() {
                let _ = window.drop_image(frame.image);
            } else {
                let _ = frame
                    .window
                    .update(cx, |_, window, _| window.drop_image(frame.image));
            }
        }
    }
}

/// A straight-alpha BGRA surface. Allocation is bounded even on very large
/// HiDPI displays; oversized terminal views are rasterized at a lower scale.
struct Surface {
    bounds: Bounds<Pixels>,
    scale: f32,
    width: usize,
    height: usize,
    bytes: Vec<u8>,
}
impl Surface {
    fn new(bounds: Bounds<Pixels>, requested_scale: f32) -> Self {
        let w = f32::from(bounds.size.width).max(1.0);
        let h = f32::from(bounds.size.height).max(1.0);
        let maximum = ((MAX_SURFACE_BYTES as f64 / 4.0 / f64::from(w) / f64::from(h)).sqrt()
            as f32)
            .min(8192.0 / w)
            .min(8192.0 / h);
        let scale = requested_scale.max(0.01).min(maximum * 0.999);
        let width = (w * scale).ceil().max(1.0) as usize;
        let height = (h * scale).ceil().max(1.0) as usize;
        Self {
            bounds,
            scale,
            width,
            height,
            bytes: vec![0; width * height * 4],
        }
    }
    fn pixel(&mut self, x: i32, y: i32, color: [u8; 4]) {
        if x < 0 || y < 0 || x as usize >= self.width || y as usize >= self.height || color[3] == 0
        {
            return;
        }
        let offset = (y as usize * self.width + x as usize) * 4;
        blend(&mut self.bytes[offset..offset + 4], color);
    }
    fn rect(&mut self, bounds: Bounds<Pixels>, color: Hsla) {
        let color = bgra(color);
        if color[3] == 0 {
            return;
        }
        let left = f32::from(bounds.left() - self.bounds.left()) * self.scale;
        let top = f32::from(bounds.top() - self.bounds.top()) * self.scale;
        let right = left + f32::from(bounds.size.width) * self.scale;
        let bottom = top + f32::from(bounds.size.height) * self.scale;
        for y in (top.floor() as i32).max(0)..(bottom.ceil() as i32).min(self.height as i32) {
            for x in (left.floor() as i32).max(0)..(right.ceil() as i32).min(self.width as i32) {
                let coverage = (right.min(x as f32 + 1.0) - left.max(x as f32)).max(0.0)
                    * (bottom.min(y as f32 + 1.0) - top.max(y as f32)).max(0.0);
                let mut c = color;
                c[3] = (f32::from(c[3]) * coverage).round() as u8;
                self.pixel(x, y, c);
            }
        }
    }
    fn glyph(&mut self, raster: &Raster, origin: Point<i32>, color: Hsla, emoji: bool) {
        let x0 = origin.x + raster.bounds.origin.x.0;
        let y0 = origin.y + raster.bounds.origin.y.0;
        let color = bgra(color);
        for y in 0..raster.height {
            for x in 0..raster.width {
                let i = y * raster.width + x;
                let c = if emoji {
                    let Some(bytes) = raster.bytes.get(i * 4..i * 4 + 4) else {
                        continue;
                    };
                    [bytes[0], bytes[1], bytes[2], bytes[3]]
                } else {
                    let Some(mask) = raster.bytes.get(i) else {
                        continue;
                    };
                    let mut c = color;
                    c[3] = ((u16::from(c[3]) * u16::from(*mask) + 127) / 255) as u8;
                    c
                };
                self.pixel(x0 + x as i32, y0 + y as i32, c);
            }
        }
    }
    fn image(
        &mut self,
        mask: Bounds<Pixels>,
        bounds: Bounds<Pixels>,
        image: &RenderImage,
        frame: usize,
    ) {
        let Some(bytes) = image.as_bytes(frame) else {
            return;
        };
        let dimensions = image.size(frame);
        let (width, height) = (dimensions.width.0 as usize, dimensions.height.0 as usize);
        if width == 0
            || height == 0
            || bounds.size.width <= px(0.0)
            || bounds.size.height <= px(0.0)
        {
            return;
        }
        let left = f32::from(bounds.left() - self.bounds.left()) * self.scale;
        let top = f32::from(bounds.top() - self.bounds.top()) * self.scale;
        let dw = f32::from(bounds.size.width) * self.scale;
        let dh = f32::from(bounds.size.height) * self.scale;
        let clip = bounds.intersect(&mask).intersect(&self.bounds);
        if clip.size.width <= px(0.0) || clip.size.height <= px(0.0) {
            return;
        }
        let x0 = (f32::from(clip.left() - self.bounds.left()) * self.scale)
            .floor()
            .max(0.0) as usize;
        let y0 = (f32::from(clip.top() - self.bounds.top()) * self.scale)
            .floor()
            .max(0.0) as usize;
        let x1 = (f32::from(clip.right() - self.bounds.left()) * self.scale)
            .ceil()
            .min(self.width as f32) as usize;
        let y1 = (f32::from(clip.bottom() - self.bounds.top()) * self.scale)
            .ceil()
            .min(self.height as f32) as usize;
        for y in y0..y1 {
            for x in x0..x1 {
                let sx = (((x as f32 + 0.5 - left) / dw) * width as f32)
                    .floor()
                    .clamp(0.0, (width - 1) as f32) as usize;
                let sy = (((y as f32 + 0.5 - top) / dh) * height as f32)
                    .floor()
                    .clamp(0.0, (height - 1) as f32) as usize;
                let i = (sy * width + sx) * 4;
                if let Some(c) = bytes.get(i..i + 4) {
                    self.pixel(x as i32, y as i32, [c[0], c[1], c[2], c[3]]);
                }
            }
        }
    }
}
// Match GPUI's nearest-quarter positioning, carrying a rounded fraction into
// the integer origin. Floor keeps subpixel variants nonnegative off the left edge.
fn round_half_toward_zero(value: f32) -> f32 {
    if value > 0.0 {
        (value - 0.5).ceil()
    } else {
        (value + 0.5).floor()
    }
}
fn glyph_origin(position: Point<f32>, emoji: bool) -> (Point<i32>, Point<u8>) {
    if emoji {
        return (
            position.map(|p| round_half_toward_zero(p) as i32),
            point(0, 0),
        );
    }
    let x = round_half_toward_zero(position.x * 4.0) / 4.0;
    let y = round_half_toward_zero(position.y);
    (
        point(x.floor() as i32, y as i32),
        point(((x - x.floor()) * 4.0) as u8, 0),
    )
}
fn bgra(color: Hsla) -> [u8; 4] {
    let c = color.to_rgb();
    [
        (c.b * 255.0).round() as u8,
        (c.g * 255.0).round() as u8,
        (c.r * 255.0).round() as u8,
        (c.a * 255.0).round() as u8,
    ]
}
fn blend(destination: &mut [u8], source: [u8; 4]) {
    let sa = u32::from(source[3]);
    if sa == 255 {
        destination.copy_from_slice(&source);
        return;
    }
    let da = u32::from(destination[3]);
    if da == 0 {
        destination.copy_from_slice(&source);
        return;
    }
    let alpha = sa * 255 + da * (255 - sa);
    if alpha == 0 {
        return;
    }
    for i in 0..3 {
        destination[i] = ((u32::from(source[i]) * sa * 255
            + u32::from(destination[i]) * da * (255 - sa)
            + alpha / 2)
            / alpha) as u8;
    }
    destination[3] = ((alpha + 127) / 255) as u8;
}

/// Retain one painter for grid layout, colors, overlays and cursor behavior.
/// Only the target for its primitives changes when the renderer setting changes.
pub(super) struct GridCanvas<'a> {
    window: &'a mut Window,
    surface: Option<Surface>,
    text: Option<Arc<CpuText>>,
    cache: Arc<Mutex<FrameCache>>,
}
impl<'a> GridCanvas<'a> {
    pub fn new(
        window: &'a mut Window,
        bounds: Bounds<Pixels>,
        gpu: bool,
        cache: Arc<Mutex<FrameCache>>,
        cx: &mut App,
    ) -> Self {
        let text = (!gpu)
            .then(|| {
                cx.try_global::<CpuTextGlobal>()
                    .map(|global| global.0.clone())
            })
            .flatten();
        let actual_gpu = gpu || text.is_none();
        if actual_gpu {
            cache.lock().drop_previous(window, cx);
        }
        cache.lock().last_backend = Some((gpu, actual_gpu, std::time::Instant::now()));
        Self {
            surface: (!actual_gpu).then(|| Surface::new(bounds, window.scale_factor())),
            text,
            window,
            cache,
        }
    }

    pub fn paint_quad(&mut self, quad: PaintQuad) {
        let Some(surface) = self.surface.as_mut() else {
            self.window.paint_quad(quad);
            return;
        };
        if let Some(color) = quad.background.as_solid() {
            surface.rect(quad.bounds, color);
        }
        let b = quad.bounds;
        let e = quad.border_widths;
        for (origin, dimensions) in [
            (b.origin, size(b.size.width, e.top)),
            (
                point(b.left(), b.bottom() - e.bottom),
                size(b.size.width, e.bottom),
            ),
            (b.origin, size(e.left, b.size.height)),
            (
                point(b.right() - e.right, b.top()),
                size(e.right, b.size.height),
            ),
        ] {
            surface.rect(Bounds::new(origin, dimensions), quad.border_color);
        }
    }
    pub fn paint_line(
        &mut self,
        line: &ShapedLine,
        origin: Point<Pixels>,
        height: Pixels,
        runs: &[TextRun],
        cx: &mut App,
    ) -> anyhow::Result<()> {
        let Some(surface) = self.surface.as_mut() else {
            return line.paint(origin, height, gpui::TextAlign::Left, None, self.window, cx);
        };
        let text = self
            .text
            .as_ref()
            .expect("CPU text system initialized at application startup");
        let baseline = (height - line.ascent - line.descent) / 2.0 + line.ascent;
        for shaped in &line.runs {
            for glyph in &shaped.glyphs {
                let mut end = 0;
                let style = runs.iter().find(|run| {
                    end += run.len;
                    glyph.index < end
                });
                let color = style.map_or(gpui::black(), |run| run.color);
                let pen = origin + glyph.position + point(px(0.0), baseline);
                let (integer_origin, subpixel) = glyph_origin(
                    point(
                        f32::from(pen.x - surface.bounds.left()) * surface.scale,
                        f32::from(pen.y - surface.bounds.top()) * surface.scale,
                    ),
                    glyph.is_emoji,
                );
                let params = RenderGlyphParams {
                    font_id: shaped.font_id,
                    glyph_id: glyph.id,
                    font_size: line.font_size,
                    subpixel_variant: subpixel,
                    scale_factor: surface.scale,
                    is_emoji: glyph.is_emoji,
                    subpixel_rendering: false,
                    dilation: if glyph.is_emoji {
                        0
                    } else {
                        text.platform.glyph_dilation_for_color(color)
                    },
                };
                let raster = text.raster(&params)?;
                surface.glyph(&raster, integer_origin, color, glyph.is_emoji);
            }
        }
        let mut index = 0;
        for run in runs {
            let x = origin.x + line.x_for_index(index);
            index += run.len;
            let width = line.x_for_index(index) - (x - origin.x);
            if let Some(style) = run.underline {
                let y = origin.y + gpui::underline_y_offset(height, line.ascent, line.descent);
                let color = style.color.unwrap_or(run.color);
                if style.wavy {
                    let thickness = f32::from(style.thickness).max(0.5);
                    let mut offset = 0.0;
                    while offset < f32::from(width) {
                        let phase = (offset / (thickness * 4.0) * std::f32::consts::TAU).sin();
                        surface.rect(
                            Bounds::new(
                                point(x + px(offset), y + px(phase * thickness)),
                                size(px((f32::from(width) - offset).min(0.5)), style.thickness),
                            ),
                            color,
                        );
                        offset += 0.5;
                    }
                } else {
                    surface.rect(
                        Bounds::new(point(x, y), size(width, style.thickness)),
                        color,
                    );
                }
            }
            if let Some(style) = run.strikethrough {
                let y = origin.y + (line.ascent * 0.5 + baseline) * 0.5;
                surface.rect(
                    Bounds::new(point(x, y), size(width, style.thickness)),
                    style.color.unwrap_or(run.color),
                );
            }
        }
        Ok(())
    }
    pub fn paint_image(
        &mut self,
        mask: Bounds<Pixels>,
        bounds: Bounds<Pixels>,
        corners: Corners<Pixels>,
        image: Arc<RenderImage>,
        frame: usize,
        grayscale: bool,
    ) -> anyhow::Result<()> {
        if let Some(surface) = self.surface.as_mut() {
            surface.image(mask, bounds, &image, frame);
            Ok(())
        } else {
            self.window
                .paint_image(mask, bounds, corners, image, frame, grayscale)
        }
    }
    pub fn finish(mut self, cx: &mut App) {
        let Some(surface) = self.surface.take() else {
            return;
        };
        let mut cache = self.cache.lock();
        let unchanged = cache.frame.as_ref().is_some_and(|frame| {
            frame.window == self.window.window_handle()
                && frame.image.size(0)
                    == size(
                        DevicePixels(surface.width as i32),
                        DevicePixels(surface.height as i32),
                    )
                && frame.image.as_bytes(0) == Some(surface.bytes.as_slice())
        });
        if !unchanged {
            cache.drop_previous(self.window, cx);
            let pixels = image::RgbaImage::from_raw(
                surface.width as u32,
                surface.height as u32,
                surface.bytes,
            )
            .expect("surface dimensions checked at allocation");
            cache.frame = Some(CachedFrame {
                window: self.window.window_handle(),
                image: Arc::new(RenderImage::new(vec![image::Frame::new(pixels)])),
            });
        }
        if let Some(frame) = &cache.frame {
            let _ = self.window.paint_image(
                surface.bounds,
                surface.bounds,
                Corners::default(),
                frame.image.clone(),
                0,
                false,
            );
        }
    }
}
impl Deref for GridCanvas<'_> {
    type Target = Window;
    fn deref(&self) -> &Window {
        self.window
    }
}
impl DerefMut for GridCanvas<'_> {
    fn deref_mut(&mut self) -> &mut Window {
        self.window
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn surface() -> Surface {
        Surface::new(
            Bounds::new(point(px(10.0), px(20.0)), size(px(4.0), px(3.0))),
            2.0,
        )
    }
    struct RecordingText {
        noop: gpui::NoopTextSystem,
        calls: std::sync::atomic::AtomicUsize,
    }
    impl PlatformTextSystem for RecordingText {
        fn add_fonts(&self, fonts: Vec<std::borrow::Cow<'static, [u8]>>) -> anyhow::Result<()> {
            self.noop.add_fonts(fonts)
        }
        fn all_font_names(&self) -> Vec<String> {
            self.noop.all_font_names()
        }
        fn font_id(&self, font: &gpui::Font) -> anyhow::Result<gpui::FontId> {
            self.noop.font_id(font)
        }
        fn font_metrics(&self, id: gpui::FontId) -> gpui::FontMetrics {
            self.noop.font_metrics(id)
        }
        fn typographic_bounds(
            &self,
            f: gpui::FontId,
            g: gpui::GlyphId,
        ) -> anyhow::Result<Bounds<f32>> {
            self.noop.typographic_bounds(f, g)
        }
        fn advance(&self, f: gpui::FontId, g: gpui::GlyphId) -> anyhow::Result<gpui::Size<f32>> {
            self.noop.advance(f, g)
        }
        fn glyph_for_char(&self, f: gpui::FontId, c: char) -> Option<gpui::GlyphId> {
            self.noop.glyph_for_char(f, c)
        }
        fn glyph_raster_bounds(
            &self,
            params: &RenderGlyphParams,
        ) -> anyhow::Result<Bounds<DevicePixels>> {
            if params.glyph_id.0 == 0 {
                Ok(Bounds::default())
            } else {
                Ok(Bounds::new(
                    point(DevicePixels(0), DevicePixels(0)),
                    size(DevicePixels(1), DevicePixels(1)),
                ))
            }
        }
        fn rasterize_glyph(
            &self,
            _: &RenderGlyphParams,
            bounds: Bounds<DevicePixels>,
        ) -> anyhow::Result<(gpui::Size<DevicePixels>, Vec<u8>)> {
            assert!(
                bounds.size.width.0 > 0 && bounds.size.height.0 > 0,
                "empty glyphs must not reach the native rasterizer"
            );
            self.calls
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            Ok((bounds.size, vec![255]))
        }
        fn layout_line(
            &self,
            text: &str,
            size: Pixels,
            runs: &[gpui::FontRun],
        ) -> gpui::LineLayout {
            self.noop.layout_line(text, size, runs)
        }
        fn recommended_rendering_mode(
            &self,
            f: gpui::FontId,
            s: Pixels,
        ) -> gpui::TextRenderingMode {
            self.noop.recommended_rendering_mode(f, s)
        }
    }
    fn params(glyph: u32) -> RenderGlyphParams {
        RenderGlyphParams {
            font_id: gpui::FontId(0),
            glyph_id: gpui::GlyphId(glyph),
            font_size: px(14.0),
            subpixel_variant: point(0, 0),
            scale_factor: 2.0,
            is_emoji: false,
            subpixel_rendering: false,
            dilation: 0,
        }
    }
    #[test]
    fn renderer_diagnostics_report_observed_path_without_faking_unpainted_values() {
        let mut cache = FrameCache::default();
        let empty = cache.diagnostics();
        assert!(empty["actual_renderer"].is_null());
        assert!(empty["last_paint_age_seconds"].is_null());
        assert_eq!(empty["cached_cpu_bitmap_bytes"], 0);
        cache.last_backend = Some((false, true, std::time::Instant::now()));
        let fallback = cache.diagnostics();
        assert_eq!(fallback["requested_renderer"], "cpu");
        assert_eq!(fallback["actual_renderer"], "gpu");
        assert_eq!(fallback["fallback_reason"], "cpu_text_system_unavailable");
        cache.last_backend = Some((false, false, std::time::Instant::now()));
        let cpu = cache.diagnostics();
        assert_eq!(cpu["actual_renderer"], "cpu");
        assert!(cpu["fallback_reason"].is_null());
    }

    #[test]
    fn empty_glyphs_are_skipped_and_repeated_glyphs_use_the_cpu_cache() {
        let platform = Arc::new(RecordingText {
            noop: gpui::NoopTextSystem::new(),
            calls: Default::default(),
        });
        let text = CpuText {
            platform: platform.clone(),
            glyphs: Mutex::default(),
        };
        assert!(text.raster(&params(0)).unwrap().bytes.is_empty());
        assert_eq!(platform.calls.load(std::sync::atomic::Ordering::Relaxed), 0);
        let first = text.raster(&params(1)).unwrap();
        assert!(Arc::ptr_eq(&first, &text.raster(&params(1)).unwrap()));
        assert_eq!(platform.calls.load(std::sync::atomic::Ordering::Relaxed), 1);
    }
    #[test]
    fn glyph_cache_has_a_hard_count_and_byte_bound() {
        let mut cache = GlyphCache::default();
        let raster = Arc::new(Raster {
            bounds: Bounds::default(),
            width: 1,
            height: 1,
            bytes: vec![255],
        });
        for glyph in 0..=MAX_GLYPHS as u32 {
            cache.insert(params(glyph), raster.clone());
        }
        assert_eq!(cache.items.len(), MAX_GLYPHS);
        assert!(!cache.items.contains_key(&params(0)));
        let large = Arc::new(Raster {
            bounds: Bounds::default(),
            width: 1,
            height: 1,
            bytes: vec![0; MAX_GLYPH_BYTES / 2 + 1],
        });
        cache.insert(params(u32::MAX - 1), large.clone());
        cache.insert(params(u32::MAX), large);
        assert!(cache.bytes <= MAX_GLYPH_BYTES);
        assert_eq!(cache.items.len(), 1);
    }
    #[test]
    fn straight_alpha_composition_retains_transparency_and_bgra() {
        let mut p = [0, 0, 0, 0];
        blend(&mut p, [0, 0, 255, 128]);
        assert_eq!(p, [0, 0, 255, 128]);
        blend(&mut p, [255, 0, 0, 128]);
        assert_eq!(p, [170, 0, 85, 192]);
        blend(&mut p, [4, 5, 6, 255]);
        assert_eq!(p, [4, 5, 6, 255]);
    }
    #[test]
    fn rectangles_clip_and_cover_fractional_device_pixels() {
        let mut s = surface();
        s.rect(
            Bounds::new(point(px(9.0), px(20.25)), size(px(2.0), px(1.0))),
            gpui::white(),
        );
        assert_eq!(s.bytes[3], 128);
        assert_eq!(s.bytes[(s.width * 4) + 3], 255);
        assert_eq!(s.bytes[2 * 4 + 3], 0);
    }
    #[test]
    fn glyph_masks_and_color_emoji_are_both_composited_in_software() {
        let mut s = surface();
        let bounds = Bounds::new(
            point(DevicePixels(0), DevicePixels(0)),
            size(DevicePixels(1), DevicePixels(1)),
        );
        let glyph = Raster {
            bounds,
            width: 1,
            height: 1,
            bytes: vec![128],
        };
        s.glyph(&glyph, point(0, 0), gpui::rgb(0xff0000).into(), false);
        assert_eq!(&s.bytes[..4], &[0, 0, 255, 128]);
        let emoji = Raster {
            bounds,
            width: 1,
            height: 1,
            bytes: vec![255, 0, 0, 255],
        };
        s.glyph(&emoji, point(0, 0), gpui::black(), true);
        assert_eq!(&s.bytes[..4], &[255, 0, 0, 255]);
    }
    #[test]
    fn glyph_origin_carries_rounded_subpixels_and_handles_negative_positions() {
        assert_eq!(
            glyph_origin(point(1.99, 2.9), false),
            (point(2, 3), point(0, 0))
        );
        assert_eq!(
            glyph_origin(point(-0.3, -1.5), false),
            (point(-1, -1), point(3, 0))
        );
        assert_eq!(
            glyph_origin(point(2.5, -2.5), true),
            (point(2, -2), point(0, 0))
        );
    }
    #[test]
    fn inline_image_is_scaled_and_clipped_on_the_cpu() {
        let mut s = surface();
        let image = RenderImage::new(vec![image::Frame::new(
            image::RgbaImage::from_raw(1, 1, vec![4, 5, 6, 255]).unwrap(),
        )]);
        let image_bounds = Bounds::new(point(px(9.0), px(20.0)), size(px(3.0), px(2.0)));
        let mask = Bounds::new(point(px(11.0), px(20.0)), size(px(1.0), px(1.0)));
        s.image(mask, image_bounds, &image, 0);
        assert!(s.bytes[..2 * 4].iter().all(|b| *b == 0));
        assert_eq!(&s.bytes[2 * 4..3 * 4], &[4, 5, 6, 255]);
        assert!(s.bytes[2 * s.width * 4..].iter().all(|b| *b == 0));
    }
    #[test]
    fn oversized_hidpi_surface_stays_within_memory_budget() {
        let s = Surface::new(
            Bounds::new(point(px(0.0), px(0.0)), size(px(16000.0), px(10000.0))),
            4.0,
        );
        assert!(s.bytes.len() <= MAX_SURFACE_BYTES);
        assert!(s.scale < 1.0);
        for (w, h) in [(1_000_000.0, 1.0), (1.0, 1_000_000.0)] {
            let s = Surface::new(
                Bounds::new(point(px(0.0), px(0.0)), size(px(w), px(h))),
                4.0,
            );
            assert!(s.bytes.len() <= MAX_SURFACE_BYTES);
            assert!(s.width <= 8192 && s.height <= 8192);
        }
    }
}
