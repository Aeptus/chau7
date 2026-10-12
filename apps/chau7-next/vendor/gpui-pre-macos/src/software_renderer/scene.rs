//! Complete scene dispatch in GPUI's ordered primitive batches. Every supported
//! primitive is sampled; missing atlas data or unsupported surfaces are explicit
//! errors and never silently become a successful partial frame.
use super::{
    atlas::SoftwareAtlas,
    canvas::Canvas,
    fills::{Fill, Rect},
    paths, primitives, sprites, surfaces,
};
use anyhow::{Result, ensure};
use gpui::{AtlasTextureKind, Scene};

/// Completed software draw, with measured output storage and primitive counts.
pub struct Frame {
    pub canvas: Canvas,
    pub primitive_counts: [u64; 8],
}
/// Renders all eight public Scene primitive families without Metal resources.
pub fn render(
    scene: &Scene,
    atlas: &SoftwareAtlas,
    width: usize,
    height: usize,
    transparent: bool,
) -> Result<Frame> {
    let mut canvas = Canvas::new(width, height, transparent)?;
    let mut counts = [0u64; 8];
    for batch in scene.batches() {
        match batch {
            gpui::PrimitiveBatch::Shadows(range) => {
                for shadow in &scene.shadows[range] {
                    let bounds = if shadow.inset != 0 {
                        Rect::from(shadow.element_bounds)
                    } else {
                        Rect::from(shadow.bounds).expand(3. * shadow.blur_radius.0)
                    };
                    let (xs, ys) =
                        canvas.region(bounds.intersect(shadow.content_mask.bounds.into()))?;
                    for y in ys {
                        for x in xs.clone() {
                            canvas.blend(
                                x,
                                y,
                                primitives::shadow(shadow, [x as f32 + 0.5, y as f32 + 0.5]),
                                false,
                            );
                        }
                    }
                    counts[0] += 1;
                }
            }
            gpui::PrimitiveBatch::Quads(range) => {
                for quad in &scene.quads[range] {
                    let fill = Fill::new(quad.background);
                    let (xs, ys) = canvas.region(
                        Rect::from(quad.bounds).intersect(quad.content_mask.bounds.into()),
                    )?;
                    for y in ys {
                        for x in xs.clone() {
                            canvas.blend(
                                x,
                                y,
                                primitives::quad(quad, [x as f32 + 0.5, y as f32 + 0.5], fill),
                                false,
                            );
                        }
                    }
                    counts[1] += 1;
                }
            }
            gpui::PrimitiveBatch::Paths(range) => {
                counts[2] += range.len() as u64;
                paths::draw(&mut canvas, &scene.paths[range])?;
            }
            gpui::PrimitiveBatch::Underlines(range) => {
                for underline in &scene.underlines[range] {
                    let (xs, ys) = canvas.region(
                        Rect::from(underline.bounds)
                            .intersect(underline.content_mask.bounds.into()),
                    )?;
                    for y in ys {
                        for x in xs.clone() {
                            canvas.blend(
                                x,
                                y,
                                primitives::underline(underline, [x as f32 + 0.5, y as f32 + 0.5]),
                                false,
                            );
                        }
                    }
                    counts[3] += 1;
                }
            }
            gpui::PrimitiveBatch::MonochromeSprites { texture_id, range } => {
                ensure!(
                    texture_id.kind == AtlasTextureKind::Monochrome,
                    "monochrome batch has wrong atlas format"
                );
                let texture = atlas.texture(texture_id).ok_or_else(|| {
                    anyhow::anyhow!("software monochrome atlas texture unavailable")
                })?;
                for sprite in &scene.monochrome_sprites[range] {
                    sprites::monochrome(&mut canvas, sprite, &texture)?;
                    counts[4] += 1;
                }
            }
            gpui::PrimitiveBatch::SubpixelSprites { texture_id, range } => {
                ensure!(
                    texture_id.kind == AtlasTextureKind::Subpixel,
                    "LCD batch has wrong atlas format"
                );
                let texture = atlas
                    .texture(texture_id)
                    .ok_or_else(|| anyhow::anyhow!("software LCD atlas texture unavailable"))?;
                for sprite in &scene.subpixel_sprites[range] {
                    sprites::subpixel(&mut canvas, sprite, &texture)?;
                    counts[5] += 1;
                }
            }
            gpui::PrimitiveBatch::PolychromeSprites { texture_id, range } => {
                ensure!(
                    texture_id.kind == AtlasTextureKind::Polychrome,
                    "color batch has wrong atlas format"
                );
                let texture = atlas
                    .texture(texture_id)
                    .ok_or_else(|| anyhow::anyhow!("software color atlas texture unavailable"))?;
                for sprite in &scene.polychrome_sprites[range] {
                    sprites::polychrome(&mut canvas, sprite, &texture)?;
                    counts[6] += 1;
                }
            }
            gpui::PrimitiveBatch::Surfaces(range) => {
                for surface in &scene.surfaces[range] {
                    surfaces::draw(&mut canvas, surface)?;
                    counts[7] += 1;
                }
            }
        }
    }
    Ok(Frame {
        canvas,
        primitive_counts: counts,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{
        Bounds, ContentMask, Corners, DevicePixels, Edges, ImageId, MonochromeSprite,
        PlatformAtlas, PolychromeSprite, Quad, RenderGlyphParams, RenderImageParams,
        RenderSvgParams, ScaledPixels, Shadow, SubpixelSprite, TransformationMatrix, Underline,
        black, point, size, white,
    };
    use std::borrow::Cow;
    fn b(x: f32, y: f32, w: f32, h: f32) -> Bounds<ScaledPixels> {
        Bounds::new(
            point(ScaledPixels(x), ScaledPixels(y)),
            size(ScaledPixels(w), ScaledPixels(h)),
        )
    }
    #[test]
    fn ordered_scene_renders_every_family_and_requires_pixels() {
        let atlas = SoftwareAtlas::default();
        let insert = |key: gpui::AtlasKey, bytes: Vec<u8>| {
            atlas
                .get_or_insert_with(key, &mut || {
                    Ok(Some((
                        size(DevicePixels(1), DevicePixels(1)),
                        Cow::Borrowed(&bytes),
                    )))
                })
                .unwrap()
                .unwrap()
        };
        let mono = insert(
            RenderSvgParams {
                path: "owned-scene".into(),
                size: size(DevicePixels(1), DevicePixels(1)),
            }
            .into(),
            vec![255],
        );
        let color = insert(
            RenderImageParams {
                image_id: ImageId(101),
                frame_index: 0,
            }
            .into(),
            vec![0, 0, 255, 255],
        );
        // Glyph parameters choose the public LCD texture kind. The exact glyph
        // need not touch a font system because the fixture supplies known bytes.
        let lcd_key = gpui::AtlasKey::Glyph(RenderGlyphParams {
            font_id: gpui::FontId(0),
            glyph_id: gpui::GlyphId(1),
            font_size: gpui::px(12.),
            scale_factor: 1.,
            subpixel_variant: Default::default(),
            subpixel_rendering: true,
            dilation: 0,
            is_emoji: false,
        });
        let lcd = insert(lcd_key, vec![0, 128, 255, 255]);
        let mut scene = Scene::default();
        let mask = ContentMask {
            bounds: b(0., 0., 64., 64.),
        };
        scene.insert_primitive(Shadow {
            order: 0,
            blur_radius: ScaledPixels(2.),
            bounds: b(2., 2., 10., 10.),
            corner_radii: Corners::all(ScaledPixels(2.)),
            content_mask: mask,
            color: black(),
            element_bounds: b(2., 2., 10., 10.),
            element_corner_radii: Corners::all(ScaledPixels(2.)),
            inset: 0,
            pad: 0,
        });
        scene.insert_primitive(Quad {
            bounds: b(2., 2., 10., 10.),
            content_mask: mask,
            background: white().into(),
            border_color: black(),
            corner_radii: Corners::all(ScaledPixels(2.)),
            border_widths: Edges::all(ScaledPixels(1.)),
            ..Default::default()
        });
        let mut path = gpui::Path::new(point(gpui::px(16.), gpui::px(2.)));
        path.line_to(point(gpui::px(26.), gpui::px(2.)));
        path.line_to(point(gpui::px(26.), gpui::px(12.)));
        path.line_to(point(gpui::px(16.), gpui::px(12.)));
        let mut path = path.scale(1.);
        path.content_mask = mask;
        path.color = white().into();
        scene.insert_primitive(path);
        scene.insert_primitive(Underline {
            order: 0,
            pad: 0,
            bounds: b(2., 16., 20., 4.),
            content_mask: mask,
            color: white(),
            thickness: ScaledPixels(1.),
            wavy: true.into(),
        });
        scene.insert_primitive(MonochromeSprite {
            order: 0,
            pad: 0,
            bounds: b(2., 24., 8., 8.),
            content_mask: mask,
            color: white(),
            tile: mono,
            transformation: TransformationMatrix::unit(),
        });
        scene.insert_primitive(SubpixelSprite {
            order: 0,
            pad: 0,
            bounds: b(16., 24., 8., 8.),
            content_mask: mask,
            color: white(),
            tile: lcd,
            transformation: TransformationMatrix::unit(),
        });
        scene.insert_primitive(PolychromeSprite {
            order: 0,
            pad: 0,
            bounds: b(30., 24., 8., 8.),
            content_mask: mask,
            grayscale: false.into(),
            opacity: 1.,
            corner_radii: Corners::all(ScaledPixels(2.)),
            tile: color,
        });
        let buffer = core_video::pixel_buffer::CVPixelBuffer::new(
            core_video::pixel_buffer::kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            4,
            4,
            None,
        )
        .unwrap();
        scene.insert_primitive(gpui::PaintSurface {
            order: 0,
            bounds: b(40., 24., 8., 8.),
            content_mask: mask,
            image_buffer: buffer,
        });
        scene.finish();
        let frame = render(&scene, &atlas, 64, 64, false).unwrap();
        assert_eq!(frame.primitive_counts, [1; 8]);
        assert_eq!(frame.canvas.bytes.len(), 64 * 64 * 4);
        assert!(frame.canvas.bytes.iter().any(|v| *v > 0));
        atlas.remove(&gpui::AtlasKey::Svg(RenderSvgParams {
            path: "owned-scene".into(),
            size: size(DevicePixels(1), DevicePixels(1)),
        }));
        assert!(render(&scene, &atlas, 64, 64, false).is_err());
    }
}
