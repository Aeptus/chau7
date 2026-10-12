//! Bounded BGRA8 framebuffer. Blending matches the locked Metal attachment
//! factors: normal RGB uses source alpha, path RGB is already premultiplied;
//! attachment alpha adds and saturates rather than multiplying destination alpha.
use super::fills::{Color, Rect, saturate};
use anyhow::{Result, ensure};
const MAX_FRAME_BYTES: usize = 256 * 1024 * 1024;

/// Device-space framebuffer retained by the software window renderer.
pub struct Canvas {
    pub(super) width: usize,
    pub(super) height: usize,
    pub(super) bytes: Vec<u8>,
}
impl Canvas {
    /// Allocates checked storage before publishing a frame.
    pub fn new(width: usize, height: usize, transparent: bool) -> Result<Self> {
        ensure!(
            width > 0 && height > 0,
            "software viewport must be positive"
        );
        let len = width
            .checked_mul(height)
            .and_then(|n| n.checked_mul(4))
            .filter(|n| *n <= MAX_FRAME_BYTES)
            .ok_or_else(|| anyhow::anyhow!("software viewport byte limit exceeded"))?;
        let mut bytes = Vec::new();
        bytes.try_reserve_exact(len)?;
        bytes.resize(len, 0);
        if !transparent {
            for pixel in bytes.chunks_exact_mut(4) {
                pixel[3] = 255;
            }
        }
        Ok(Self {
            width,
            height,
            bytes,
        })
    }
    /// Device-pixel viewport dimensions.
    pub fn dimensions(&self) -> (usize, usize) {
        (self.width, self.height)
    }
    /// Actual retained premultiplied BGRA8 output bytes.
    pub fn bgra(&self) -> &[u8] {
        &self.bytes
    }
    /// Pixel-center region clipped to the viewport. Rejects invalid geometry.
    pub fn region(&self, rect: Rect) -> Result<(std::ops::Range<usize>, std::ops::Range<usize>)> {
        ensure!(rect.finite(), "nonfinite software scene geometry");
        let start = |v: f32, max: usize| (v - 0.5).ceil().clamp(0., max as f32) as usize;
        let x = start(rect.x, self.width);
        let y = start(rect.y, self.height);
        let right = start(rect.x + rect.width.max(0.), self.width).max(x);
        let bottom = start(rect.y + rect.height.max(0.), self.height).max(y);
        Ok((x..right, y..bottom))
    }
    /// Straight-alpha ordinary pipeline or premultiplied path-copy pipeline.
    pub fn blend(&mut self, x: usize, y: usize, color: Color, premultiplied: bool) {
        let offset = (y * self.width + x) * 4;
        let alpha = saturate(color[3]);
        for (channel, source) in [color[2], color[1], color[0]].into_iter().enumerate() {
            let destination = self.bytes[offset + channel] as f32 / 255.;
            let out = saturate(source) * if premultiplied { 1. } else { alpha }
                + destination * (1. - alpha);
            self.bytes[offset + channel] = quantize(out);
        }
        self.bytes[offset + 3] = quantize(self.bytes[offset + 3] as f32 / 255. + alpha);
    }
    /// Fill a validated pixel-center region with a fully opaque straight color.
    /// Quantization is identical to `blend(..., false)` with alpha exactly one,
    /// but is performed once rather than for every covered pixel.
    pub(super) fn opaque_rect(
        &mut self,
        xs: std::ops::Range<usize>,
        ys: std::ops::Range<usize>,
        color: Color,
    ) {
        debug_assert_eq!(color[3], 1.);
        let pixel = [
            quantize(color[2]),
            quantize(color[1]),
            quantize(color[0]),
            255,
        ];
        for y in ys {
            let begin = (y * self.width + xs.start) * 4;
            let end = (y * self.width + xs.end) * 4;
            for output in self.bytes[begin..end].chunks_exact_mut(4) {
                // Keep this fixed-width store local. The no-LTO native fixture
                // otherwise calls the generic slice memcpy helper per pixel.
                output[0] = pixel[0];
                output[1] = pixel[1];
                output[2] = pixel[2];
                output[3] = pixel[3];
            }
        }
    }
    /// Dual-source RGB coverage blending; alpha is opaque as in the locked
    /// upstream LCD shader, independent of its fourth texture channel.
    pub fn blend_lcd(&mut self, x: usize, y: usize, foreground: Color, coverage: [f32; 3]) {
        let offset = (y * self.width + x) * 4;
        for (channel, source_channel) in [2, 1, 0].into_iter().enumerate() {
            let alpha = saturate(foreground[3] * coverage[source_channel]);
            self.bytes[offset + channel] = quantize(
                foreground[source_channel] * alpha
                    + self.bytes[offset + channel] as f32 / 255. * (1. - alpha),
            );
        }
        self.bytes[offset + 3] = 255;
    }
    /// Premultiplied RGBA bytes for GPUI's existing image/test capture contract.
    pub fn rgba(&self) -> Result<Vec<u8>> {
        let mut bytes = Vec::new();
        bytes.try_reserve_exact(self.bytes.len())?;
        bytes.extend_from_slice(&self.bytes);
        for pixel in bytes.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
        Ok(bytes)
    }
}
pub fn quantize(value: f32) -> u8 {
    (saturate(value) * 255.).round() as u8
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn opaque_rect_fixed_stores_match_scalar_across_large_and_empty_rows() {
        for width in [1, 7, 32, 2048] {
            for color in [[0.2, 0.4, 0.6, 1.], [f32::NAN, -2., 3., 1.]] {
                for inset in [0, 1] {
                    let mut actual = Canvas::new(width, 4, true).unwrap();
                    for (index, byte) in actual.bytes.iter_mut().enumerate() {
                        *byte = (index % 251) as u8;
                    }
                    let mut expected = Canvas::new(width, 4, true).unwrap();
                    expected.bytes.copy_from_slice(&actual.bytes);
                    let xs = inset.min(width)..width.saturating_sub(inset).max(inset.min(width));
                    let ys = 1..3;
                    for y in ys.clone() {
                        for x in xs.clone() {
                            expected.blend(x, y, color, false);
                        }
                    }
                    actual.opaque_rect(xs, ys, color);
                    assert_eq!(actual.bytes, expected.bytes, "width={width}, inset={inset}");
                }
            }
        }
    }

    #[test]
    fn alpha_blending_matches_attachment_factors_and_lcd_is_per_channel() {
        let mut c = Canvas::new(1, 1, true).unwrap();
        c.blend(0, 0, [1., 0., 0., 0.5], false);
        assert_eq!(c.bytes, [0, 0, 128, 128]);
        c.blend(0, 0, [0., 0., 0.5, 0.5], true);
        assert_eq!(c.bytes, [128, 0, 64, 255]);
        c.blend_lcd(0, 0, [1., 1., 1., 1.], [1., 0., 0.]);
        assert_eq!(c.bytes, [128, 0, 255, 255]);
        assert!(Canvas::new(usize::MAX, 2, true).is_err());
        assert!(Canvas::new(0, 1, true).is_err());
        assert!(
            c.region(Rect {
                x: f32::NAN,
                ..Default::default()
            })
            .is_err()
        );
    }
}
