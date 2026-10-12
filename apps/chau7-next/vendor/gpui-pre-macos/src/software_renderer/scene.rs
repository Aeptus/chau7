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
    /// Cached sprite batches whose texture was already retired, as in Metal.
    pub retired_sprite_batches: u64,
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
    let mut retired_sprite_batches = 0u64;
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
                    if let Some(color) = opaque_rect_color(quad, fill) {
                        canvas.opaque_rect(xs, ys, color);
                        counts[1] += 1;
                        continue;
                    }
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
                let Some(texture) = atlas.texture(texture_id) else {
                    // GPUI may replay a cached scene after image/glyph eviction.
                    // Match Metal's retired texture skip, while exposing it.
                    retired_sprite_batches += 1;
                    continue;
                };
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
                let Some(texture) = atlas.texture(texture_id) else {
                    retired_sprite_batches += 1;
                    continue;
                };
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
                let Some(texture) = atlas.texture(texture_id) else {
                    retired_sprite_batches += 1;
                    continue;
                };
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
        retired_sprite_batches,
    })
}
// Only integer full-coverage rectangles use the bulk path. Fractional
// geometry, borders, rounded edges, gradients and patterns retain the scalar
// shader translation, including its existing edge/clip behavior.
fn opaque_rect_color(quad: &gpui::Quad, fill: Fill) -> Option<[f32; 4]> {
    let Fill::Solid(color) = fill else {
        return None;
    };
    if color[3] != 1. {
        return None;
    }
    let corners = quad.corner_radii;
    let borders = quad.border_widths;
    if [
        corners.top_left.0,
        corners.top_right.0,
        corners.bottom_right.0,
        corners.bottom_left.0,
        borders.top.0,
        borders.right.0,
        borders.bottom.0,
        borders.left.0,
    ]
    .iter()
    .any(|value| *value != 0.)
    {
        return None;
    }
    for rect in [
        Rect::from(quad.bounds),
        Rect::from(quad.content_mask.bounds),
    ] {
        if !rect.finite()
            || [rect.x, rect.y, rect.width, rect.height]
                .iter()
                .any(|value| value.fract() != 0.)
        {
            return None;
        }
    }
    Some(color)
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
    fn bulk_opaque_rect_matches_scalar_bytes_and_fractional_edges_stay_scalar() {
        let geometries = [
            (b(-2., -1., 7., 6.), b(1., 1., 3., 2.)),
            (b(0., 0., 8., 5.), b(0., 0., 8., 5.)),
            (b(0.25, 0.5, 7.5, 4.25), b(1.25, 1., 4.5, 3.)),
            (b(1., 1., 3., 2.), b(0.5, 0., 7., 5.)),
        ];
        for (bounds, clip) in geometries {
            for alpha in [0., 0.25, 0.5, 1.] {
                for foreground in [
                    [1., 0., 0., 1.],
                    [0.1, 0.37, 0.91, 1.],
                    [f32::NAN, -1., 2., 1.],
                ] {
                    let mut scalar = Canvas::new(8, 5, true).unwrap();
                    for y in 0..5 {
                        for x in 0..8 {
                            scalar.blend(x, y, [0.7, 0.2, 0.4, alpha], false);
                        }
                    }
                    let mut actual = Canvas::new(8, 5, true).unwrap();
                    actual.bytes.copy_from_slice(scalar.bgra());
                    let quad = Quad {
                        bounds,
                        content_mask: ContentMask { bounds: clip },
                        ..Default::default()
                    };
                    let fill = Fill::Solid(foreground);
                    let region = Rect::from(bounds).intersect(clip.into());
                    let (xs, ys) = scalar.region(region).unwrap();
                    for y in ys.clone() {
                        for x in xs.clone() {
                            scalar.blend(
                                x,
                                y,
                                primitives::quad(&quad, [x as f32 + 0.5, y as f32 + 0.5], fill),
                                false,
                            );
                        }
                    }
                    if let Some(color) = opaque_rect_color(&quad, fill) {
                        actual.opaque_rect(xs, ys, color);
                    } else {
                        for y in ys {
                            for x in xs.clone() {
                                actual.blend(
                                    x,
                                    y,
                                    primitives::quad(&quad, [x as f32 + 0.5, y as f32 + 0.5], fill),
                                    false,
                                );
                            }
                        }
                    }
                    assert_eq!(actual.bgra(), scalar.bgra());
                }
            }
        }
        let mut quad = Quad {
            bounds: b(0., 0., 8., 5.),
            content_mask: ContentMask {
                bounds: b(0., 0., 8., 5.),
            },
            ..Default::default()
        };
        assert!(opaque_rect_color(&quad, Fill::Solid([1.; 4])).is_some());
        assert!(opaque_rect_color(&quad, Fill::Solid([0.; 4])).is_none());
        quad.corner_radii.top_left = ScaledPixels(1.);
        assert!(opaque_rect_color(&quad, Fill::Solid([1.; 4])).is_none());
        quad.corner_radii.top_left = ScaledPixels(0.);
        quad.border_widths.left = ScaledPixels(1.);
        assert!(opaque_rect_color(&quad, Fill::Solid([1.; 4])).is_none());
    }
    fn fixture(atlas: &dyn PlatformAtlas, lcd_enabled: bool) -> Scene {
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
        let lcd = lcd_enabled.then(|| insert(lcd_key, vec![0, 128, 255, 255]));
        let mut scene = Scene::default();
        let mask = ContentMask {
            bounds: b(0., 0., 64., 64.),
        };
        scene.insert_primitive(Shadow {
            order: 0,
            blur_radius: ScaledPixels(2.),
            bounds: b(48., 2., 10., 10.),
            corner_radii: Corners::all(ScaledPixels(2.)),
            content_mask: mask,
            color: white(),
            element_bounds: b(48., 2., 10., 10.),
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
        if let Some(lcd) = lcd {
            scene.insert_primitive(SubpixelSprite {
                order: 0,
                pad: 0,
                bounds: b(16., 24., 8., 8.),
                content_mask: mask,
                color: white(),
                tile: lcd,
                transformation: TransformationMatrix::unit(),
            });
        }
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
        use core_foundation::{base::TCFType, dictionary::CFDictionary, string::CFString};
        let empty = CFDictionary::<CFString, core_foundation::base::CFType>::from_CFType_pairs(&[]);
        let key = unsafe {
            CFString::wrap_under_get_rule(
                core_video::pixel_buffer::kCVPixelBufferIOSurfacePropertiesKey,
            )
        };
        let attributes = CFDictionary::from_CFType_pairs(&[(key, empty.as_CFType())]);
        let buffer = core_video::pixel_buffer::CVPixelBuffer::new(
            core_video::pixel_buffer::kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            4,
            4,
            Some(&attributes),
        )
        .unwrap();
        // Deterministic planar video pixels also make the native Metal/CPU
        // comparator independent of allocator contents.
        assert_eq!(buffer.lock_base_address(0), 0);
        for plane in 0..2 {
            let pointer = unsafe { buffer.get_base_address_of_plane(plane) }.cast::<u8>();
            assert!(!pointer.is_null());
            let length =
                buffer.get_bytes_per_row_of_plane(plane) * buffer.get_height_of_plane(plane);
            unsafe {
                std::ptr::write_bytes(pointer, 128, length);
            }
        }
        assert_eq!(buffer.unlock_base_address(0), 0);
        scene.insert_primitive(gpui::PaintSurface {
            order: 0,
            bounds: b(40., 24., 8., 8.),
            content_mask: mask,
            image_buffer: buffer,
        });
        scene.finish();
        scene
    }
    #[test]
    fn ordered_scene_renders_every_family_and_requires_pixels() {
        let atlas = SoftwareAtlas::default();
        let scene = fixture(&atlas, true);
        let frame = render(&scene, &atlas, 64, 64, false).unwrap();
        assert_eq!(frame.primitive_counts, [1; 8]);
        assert_eq!(frame.canvas.bytes.len(), 64 * 64 * 4);
        assert!(frame.canvas.bytes.iter().any(|v| *v > 0));
        atlas.remove(&gpui::AtlasKey::Svg(RenderSvgParams {
            path: "owned-scene".into(),
            size: size(DevicePixels(1), DevicePixels(1)),
        }));
        let retired = render(&scene, &atlas, 64, 64, false).unwrap();
        assert_eq!(retired.retired_sprite_batches, 1);
        assert_eq!(retired.primitive_counts[4], 0);
        assert_eq!(retired.primitive_counts[6], 1);
    }
    #[test]
    fn native_metal_and_software_compare_all_seven_drawable_scene_families() {
        objc2::rc::autoreleasepool(|_| {
            let mut metal =
                gpui_apple::metal_renderer::MetalRenderer::try_new(Default::default(), false)
                    .unwrap();
            let viewport = size(DevicePixels(64), DevicePixels(64));
            metal.try_prepare_startup(viewport).unwrap();
            let metal_scene = fixture(&**metal.sprite_atlas(), false);
            let metal_image = metal.render_scene_to_image(&metal_scene, viewport).unwrap();
            let atlas = SoftwareAtlas::default();
            let software_scene = fixture(&atlas, false);
            let frame = render(&software_scene, &atlas, 64, 64, false).unwrap();
            assert_eq!(frame.primitive_counts, [1, 1, 1, 1, 1, 0, 1, 1]);
            let software = frame.canvas.rgba().unwrap();
            let gpu = metal_image.into_raw();
            assert_eq!(gpu.len(), software.len());
            let absolute_error: u64 = gpu
                .iter()
                .zip(&software)
                .map(|(a, b)| a.abs_diff(*b) as u64)
                .sum();
            let max_error = gpu
                .iter()
                .zip(&software)
                .map(|(a, b)| a.abs_diff(*b))
                .max()
                .unwrap();
            eprintln!(
                "Seven-family native Metal comparator: mean_byte_error={} max_byte_error={max_error}",
                absolute_error as f64 / gpu.len() as f64
            );
            assert!(
                absolute_error as f64 / (gpu.len() as f64) < 2.,
                "CPU/Metal mean byte discrepancy exceeds explicit AA tolerance"
            );
            let shadow_offset = (7 * 64 + 53) * 4;
            assert!(
                gpu[shadow_offset] > 100 && software[shadow_offset] > 100,
                "independent white shadow must visibly contribute over black clear"
            );
            // Interior samples in each independent family, distinct from edge
            // rasterization/MSAA and driver-dependent dither quantization.
            for (x, y) in [
                (53, 7),
                (7, 7),
                (21, 7),
                (8, 17),
                (6, 28),
                (34, 28),
                (44, 28),
            ] {
                let offset = (y * 64 + x) * 4;
                for channel in 0..4 {
                    assert!(
                        gpu[offset + channel].abs_diff(software[offset + channel]) <= 3,
                        "family interior mismatch ({x},{y}) channel{channel}: GPU{} CPU{}",
                        gpu[offset + channel],
                        software[offset + channel]
                    );
                }
            }
        });
    }
}
