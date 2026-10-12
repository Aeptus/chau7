//! Atlas sprite sampling and transformed clipping. Source formats match the
//! exact locked GPUI wgpu_atlas BGRA upload contract, including LCD coverage.
use super::{
    atlas::Texture,
    canvas::Canvas,
    fills::{Rect, quad_distance, rgba, saturate},
};
use anyhow::{Result, ensure};
use gpui::{
    AtlasTile, Bounds, MonochromeSprite, PolychromeSprite, ScaledPixels, SubpixelSprite,
    TransformationMatrix,
};

struct Mapping {
    bounds: Rect,
    clip: Rect,
    matrix: TransformationMatrix,
    determinant: f32,
    outer: Rect,
}
impl Mapping {
    fn new(
        bounds: Bounds<ScaledPixels>,
        clip: Bounds<ScaledPixels>,
        matrix: TransformationMatrix,
    ) -> Result<Self> {
        let bounds = Rect::from(bounds);
        let clip = Rect::from(clip);
        ensure!(
            bounds.finite()
                && clip.finite()
                && matrix
                    .rotation_scale
                    .iter()
                    .flatten()
                    .chain(matrix.translation.iter())
                    .all(|v| v.is_finite()),
            "nonfinite sprite geometry"
        );
        let m = matrix.rotation_scale;
        let determinant = m[0][0] * m[1][1] - m[0][1] * m[1][0];
        let transform = |p: [f32; 2]| {
            [
                m[0][0] * p[0] + m[0][1] * p[1] + matrix.translation[0],
                m[1][0] * p[0] + m[1][1] * p[1] + matrix.translation[1],
            ]
        };
        let corners = [
            [bounds.x, bounds.y],
            [bounds.x + bounds.width, bounds.y],
            [bounds.x, bounds.y + bounds.height],
            [bounds.x + bounds.width, bounds.y + bounds.height],
        ]
        .map(transform);
        let min_x = corners.iter().map(|p| p[0]).fold(f32::INFINITY, f32::min);
        let max_x = corners
            .iter()
            .map(|p| p[0])
            .fold(f32::NEG_INFINITY, f32::max);
        let min_y = corners.iter().map(|p| p[1]).fold(f32::INFINITY, f32::min);
        let max_y = corners
            .iter()
            .map(|p| p[1])
            .fold(f32::NEG_INFINITY, f32::max);
        Ok(Self {
            bounds,
            clip,
            matrix,
            determinant,
            outer: Rect {
                x: min_x,
                y: min_y,
                width: max_x - min_x,
                height: max_y - min_y,
            },
        })
    }
    fn texel(&self, p: [f32; 2], tile: AtlasTile) -> Option<[f32; 2]> {
        if !self.clip.contains(p) || self.determinant.abs() < f32::MIN_POSITIVE {
            return None;
        }
        let p = [
            p[0] - self.matrix.translation[0],
            p[1] - self.matrix.translation[1],
        ];
        let m = self.matrix.rotation_scale;
        let local = [
            (m[1][1] * p[0] - m[0][1] * p[1]) / self.determinant,
            (-m[1][0] * p[0] + m[0][0] * p[1]) / self.determinant,
        ];
        if !self.bounds.contains(local) {
            return None;
        }
        Some([
            tile.bounds.origin.x.0 as f32
                + (local[0] - self.bounds.x) / self.bounds.width * tile.bounds.size.width.0 as f32,
            tile.bounds.origin.y.0 as f32
                + (local[1] - self.bounds.y) / self.bounds.height
                    * tile.bounds.size.height.0 as f32,
        ])
    }
}
pub fn monochrome(canvas: &mut Canvas, sprite: &MonochromeSprite, texture: &Texture) -> Result<()> {
    let mapping = Mapping::new(
        sprite.bounds,
        sprite.content_mask.bounds,
        sprite.transformation,
    )?;
    let (xs, ys) = canvas.region(mapping.outer.intersect(mapping.clip))?;
    let color = rgba(sprite.color);
    for y in ys {
        for x in xs.clone() {
            if let Some(t) = mapping.texel([x as f32 + 0.5, y as f32 + 0.5], sprite.tile) {
                let mut c = color;
                c[3] *= texture.sample(t)[3];
                canvas.blend(x, y, c, false);
            }
        }
    }
    Ok(())
}
pub fn subpixel(canvas: &mut Canvas, sprite: &SubpixelSprite, texture: &Texture) -> Result<()> {
    let mapping = Mapping::new(
        sprite.bounds,
        sprite.content_mask.bounds,
        sprite.transformation,
    )?;
    let (xs, ys) = canvas.region(mapping.outer.intersect(mapping.clip))?;
    let color = rgba(sprite.color);
    // macOS's existing text system is grayscale by default. Explicit LCD scenes
    // use RGB coverage with gamma=1/contrast=0 rather than Windows display tuning.
    for y in ys {
        for x in xs.clone() {
            if let Some(t) = mapping.texel([x as f32 + 0.5, y as f32 + 0.5], sprite.tile) {
                let sample = texture.sample(t);
                canvas.blend_lcd(x, y, color, [sample[0], sample[1], sample[2]]);
            }
        }
    }
    Ok(())
}
pub fn polychrome(canvas: &mut Canvas, sprite: &PolychromeSprite, texture: &Texture) -> Result<()> {
    let bounds = Rect::from(sprite.bounds);
    let clip = bounds.intersect(sprite.content_mask.bounds.into());
    let (xs, ys) = canvas.region(clip)?;
    for y in ys {
        for x in xs.clone() {
            let p = [x as f32 + 0.5, y as f32 + 0.5];
            let texel = [
                sprite.tile.bounds.origin.x.0 as f32
                    + (p[0] - bounds.x) / bounds.width * sprite.tile.bounds.size.width.0 as f32,
                sprite.tile.bounds.origin.y.0 as f32
                    + (p[1] - bounds.y) / bounds.height * sprite.tile.bounds.size.height.0 as f32,
            ];
            let mut color = texture.sample(texel);
            if sprite.grayscale.get() {
                let gray = 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2];
                color[..3].fill(gray);
            }
            color[3] *=
                sprite.opacity * saturate(0.5 - quad_distance(p, bounds, sprite.corner_radii));
            canvas.blend(x, y, color, false);
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{
        AtlasTextureId, AtlasTextureKind, ContentMask, Corners, DevicePixels, TileId, point, size,
        white,
    };
    fn bounds() -> Bounds<ScaledPixels> {
        Bounds::new(
            point(ScaledPixels(0.), ScaledPixels(0.)),
            size(ScaledPixels(2.), ScaledPixels(2.)),
        )
    }
    fn tile(kind: AtlasTextureKind) -> AtlasTile {
        AtlasTile {
            texture_id: AtlasTextureId { index: 1, kind },
            tile_id: TileId(1),
            padding: 0,
            bounds: Bounds::new(
                point(DevicePixels(0), DevicePixels(0)),
                size(DevicePixels(1), DevicePixels(1)),
            ),
        }
    }
    #[test]
    fn transformed_mask_clips_in_screen_space_and_color_coverage_is_bgra() {
        let texture = Texture {
            size: size(DevicePixels(1), DevicePixels(1)),
            bytes: vec![255],
            kind: AtlasTextureKind::Monochrome,
        };
        let mask = ContentMask {
            bounds: Bounds::new(
                point(ScaledPixels(1.), ScaledPixels(0.)),
                size(ScaledPixels(1.), ScaledPixels(2.)),
            ),
        };
        let s = MonochromeSprite {
            order: 0,
            pad: 0,
            bounds: bounds(),
            content_mask: mask,
            color: white(),
            tile: tile(texture.kind),
            transformation: TransformationMatrix::unit(),
        };
        let mut canvas = Canvas::new(2, 2, true).unwrap();
        monochrome(&mut canvas, &s, &texture).unwrap();
        assert_eq!(&canvas.bytes[0..4], &[0; 4]);
        assert_eq!(&canvas.bytes[4..8], &[255; 4]);
        let texture = Texture {
            size: size(DevicePixels(1), DevicePixels(1)),
            bytes: vec![0, 128, 255, 255],
            kind: AtlasTextureKind::Subpixel,
        };
        let s = SubpixelSprite {
            order: 0,
            pad: 0,
            bounds: bounds(),
            content_mask: ContentMask { bounds: bounds() },
            color: white(),
            tile: tile(texture.kind),
            transformation: TransformationMatrix::unit(),
        };
        let mut canvas = Canvas::new(2, 2, false).unwrap();
        subpixel(&mut canvas, &s, &texture).unwrap();
        assert_eq!(&canvas.bytes[..4], &[0, 128, 255, 255]);
        let s = PolychromeSprite {
            order: 0,
            pad: 0,
            bounds: bounds(),
            content_mask: ContentMask { bounds: bounds() },
            grayscale: true.into(),
            opacity: 0.5,
            corner_radii: Corners::all(ScaledPixels(0.)),
            tile: tile(AtlasTextureKind::Polychrome),
        };
        let texture = Texture {
            kind: AtlasTextureKind::Polychrome,
            ..texture
        };
        let mut canvas = Canvas::new(2, 2, false).unwrap();
        polychrome(&mut canvas, &s, &texture).unwrap();
        assert_eq!(canvas.bytes[0], canvas.bytes[1]);
        assert_eq!(canvas.bytes[1], canvas.bytes[2]);
        assert_eq!(
            canvas.bytes[0],
            super::super::canvas::quantize((0.2126 + 0.7152 * 128. / 255.) * 0.5)
        );
    }
}
