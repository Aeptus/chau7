//! Four-sample triangle coverage and implicit quadratic curve antialiasing.
//! Path batches render into a bounded premultiplied intermediate region and
//! resolve/copy once, preserving transparent overlaps and GPUI draw order.
use super::{
    canvas::{Canvas, quantize},
    fills::{Color, Fill, Rect, saturate},
};
use anyhow::{Result, ensure};
use gpui::{Path, ScaledPixels};
const MAX_INTERMEDIATE_BYTES: usize = 512 * 1024 * 1024;
const SAMPLES: [[f32; 2]; 4] = [
    [0.375, 0.125],
    [0.875, 0.375],
    [0.125, 0.625],
    [0.625, 0.875],
];
fn edge(a: [f32; 2], b: [f32; 2], p: [f32; 2]) -> f32 {
    (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
}
fn top_left(a: [f32; 2], b: [f32; 2]) -> bool {
    b[1] < a[1] || (b[1] == a[1] && b[0] > a[0])
}
fn union(a: Rect, b: Rect) -> Rect {
    let x = a.x.min(b.x);
    let y = a.y.min(b.y);
    Rect {
        x,
        y,
        width: (a.x + a.width).max(b.x + b.width) - x,
        height: (a.y + a.height).max(b.y + b.height) - y,
    }
}

/// Mirrors one Metal paths batch, including four-sample BGRA8 resolve.
pub fn draw(canvas: &mut Canvas, paths: &[Path<ScaledPixels>]) -> Result<()> {
    if paths.is_empty() {
        return Ok(());
    }
    let mut spanning = Rect::from(paths[0].clipped_bounds());
    for p in paths.iter().skip(1) {
        spanning = union(spanning, p.clipped_bounds().into());
    }
    let (xs, ys) = canvas.region(spanning.expand(1.))?;
    let width = xs.len();
    let height = ys.len();
    if width == 0 || height == 0 {
        return Ok(());
    }
    let count = width
        .checked_mul(height)
        .and_then(|v| v.checked_mul(16))
        .filter(|v| *v <= MAX_INTERMEDIATE_BYTES)
        .ok_or_else(|| anyhow::anyhow!("software path intermediate limit exceeded"))?;
    let mut intermediate = Vec::new();
    intermediate.try_reserve_exact(count)?;
    intermediate.resize(count, 0u8);
    for path in paths {
        ensure!(
            path.vertices.len().is_multiple_of(3),
            "software path triangle list is incomplete"
        );
        let clip = Rect::from(path.clipped_bounds());
        ensure!(clip.finite(), "nonfinite software path bounds");
        let fill = Fill::new(path.color);
        for vertices in path.vertices.chunks_exact(3) {
            let mut xy: [[f32; 2]; 3] =
                std::array::from_fn(|i| [vertices[i].xy_position.x.0, vertices[i].xy_position.y.0]);
            let mut st: [[f32; 2]; 3] =
                std::array::from_fn(|i| [vertices[i].st_position.x, vertices[i].st_position.y]);
            ensure!(
                xy.iter().chain(st.iter()).flatten().all(|v| v.is_finite()),
                "nonfinite software path vertex"
            );
            let mut area = edge(xy[0], xy[1], xy[2]);
            ensure!(area.is_finite(), "software path triangle area overflow");
            if area == 0. {
                continue;
            }
            if area < 0. {
                xy.swap(1, 2);
                st.swap(1, 2);
                area = -area;
            }
            let bounds = Rect {
                x: xy.iter().map(|p| p[0]).fold(f32::INFINITY, f32::min),
                y: xy.iter().map(|p| p[1]).fold(f32::INFINITY, f32::min),
                width: 0.,
                height: 0.,
            };
            let bounds = Rect {
                width: xy.iter().map(|p| p[0]).fold(f32::NEG_INFINITY, f32::max) - bounds.x,
                height: xy.iter().map(|p| p[1]).fold(f32::NEG_INFINITY, f32::max) - bounds.y,
                ..bounds
            };
            let (tx, ty) = canvas.region(bounds.intersect(clip).expand(1.))?;
            let derivative = |axis: usize| {
                [
                    (st[1][axis] - st[0][axis]) * (xy[2][1] - xy[0][1])
                        - (st[2][axis] - st[0][axis]) * (xy[1][1] - xy[0][1]),
                    (xy[1][0] - xy[0][0]) * (st[2][axis] - st[0][axis])
                        - (xy[2][0] - xy[0][0]) * (st[1][axis] - st[0][axis]),
                ]
                .map(|v| v / area)
            };
            let ds = derivative(0);
            let dt = derivative(1);
            for y in ty {
                for x in tx.clone() {
                    if !xs.contains(&x) || !ys.contains(&y) {
                        continue;
                    }
                    // Fragment inputs are interpolated at the pixel center; sample
                    // locations affect raster coverage, as in the non-sample MSL.
                    let p = [x as f32 + 0.5, y as f32 + 0.5];
                    let weights = [
                        edge(xy[1], xy[2], p) / area,
                        edge(xy[2], xy[0], p) / area,
                        edge(xy[0], xy[1], p) / area,
                    ];
                    let interpolated: [f32; 2] =
                        std::array::from_fn(|axis| (0..3).map(|i| weights[i] * st[i][axis]).sum());
                    let alpha = if ds[0].hypot(ds[1]) < 0.001 {
                        1.
                    } else {
                        let gradient = [
                            2. * interpolated[0] * ds[0] - dt[0],
                            2. * interpolated[0] * ds[1] - dt[1],
                        ];
                        saturate(
                            0.5 - (interpolated[0] * interpolated[0] - interpolated[1])
                                / gradient[0].hypot(gradient[1]),
                        )
                    };
                    let mut color = fill.sample(p, clip);
                    color[3] *= alpha;
                    let color: Color = [
                        color[0] * color[3],
                        color[1] * color[3],
                        color[2] * color[3],
                        color[3],
                    ];
                    for (sample_index, sample) in SAMPLES.iter().enumerate() {
                        let position = [x as f32 + sample[0], y as f32 + sample[1]];
                        if !clip.contains(position) {
                            continue;
                        }
                        let inside = (0..3).all(|i| {
                            let j = (i + 1) % 3;
                            let e = edge(xy[i], xy[j], position);
                            e > 0. || (e == 0. && top_left(xy[i], xy[j]))
                        });
                        if !inside {
                            continue;
                        }
                        let offset =
                            ((y - ys.start) * width + (x - xs.start)) * 16 + sample_index * 4;
                        for (channel, source) in [color[2], color[1], color[0], color[3]]
                            .into_iter()
                            .enumerate()
                        {
                            intermediate[offset + channel] = quantize(
                                source
                                    + intermediate[offset + channel] as f32 / 255.
                                        * (1. - saturate(color[3])),
                            );
                        }
                    }
                }
            }
        }
    }
    let same_order = paths[0].order == paths[paths.len() - 1].order;
    for y in ys.clone() {
        for x in xs.clone() {
            let p = [x as f32 + 0.5, y as f32 + 0.5];
            // Copy each path's disjoint rect when all draw orders agree; otherwise
            // the spanning rect. Each intermediate pixel is copied at most once.
            if if same_order {
                !paths
                    .iter()
                    .any(|path| Rect::from(path.clipped_bounds()).contains(p))
            } else {
                !spanning.contains(p)
            } {
                continue;
            }
            let offset = ((y - ys.start) * width + (x - xs.start)) * 16;
            let average = |channel| {
                (0..4)
                    .map(|i| intermediate[offset + i * 4 + channel] as f32)
                    .sum::<f32>()
                    / (4. * 255.)
            };
            canvas.blend(x, y, [average(2), average(1), average(0), average(3)], true);
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{ContentMask, point, rgba};
    #[test]
    fn transparent_adjacent_triangles_do_not_double_blend_and_curves_clip() {
        let mut p = Path::new(point(gpui::px(1.), gpui::px(1.)));
        p.line_to(point(gpui::px(7.), gpui::px(1.)));
        p.line_to(point(gpui::px(7.), gpui::px(7.)));
        p.line_to(point(gpui::px(1.), gpui::px(7.)));
        p.line_to(point(gpui::px(1.), gpui::px(1.)));
        let mut p = p.scale(1.);
        p.color = rgba(0xff000080).into();
        p.content_mask = ContentMask { bounds: p.bounds };
        let mut c = Canvas::new(8, 8, true).unwrap();
        draw(&mut c, &[p.clone()]).unwrap();
        for y in 2..6 {
            for x in 2..6 {
                assert_eq!(c.bytes[(y * 8 + x) * 4 + 2], 128);
                assert_eq!(c.bytes[(y * 8 + x) * 4 + 3], 128);
            }
        }
        p.order = 1;
        let mut second = p.clone();
        second.order = 2;
        let mut c = Canvas::new(8, 8, true).unwrap();
        draw(&mut c, &[p, second]).unwrap();
        assert!((c.bytes[(3 * 8 + 3) * 4 + 2] as i32 - 192).abs() <= 1);
        assert!((c.bytes[(3 * 8 + 3) * 4 + 3] as i32 - 192).abs() <= 1);
        let mut p = Path::new(point(gpui::px(0.), gpui::px(0.)));
        p.curve_to(
            point(gpui::px(8.), gpui::px(8.)),
            point(gpui::px(8.), gpui::px(0.)),
        );
        p.line_to(point(gpui::px(0.), gpui::px(8.)));
        p.line_to(point(gpui::px(0.), gpui::px(0.)));
        let mut p = p.scale(1.);
        p.color = rgba(0x00ff00ff).into();
        p.content_mask = ContentMask {
            bounds: gpui::Bounds::new(
                point(ScaledPixels(2.), ScaledPixels(2.)),
                gpui::size(ScaledPixels(4.), ScaledPixels(4.)),
            ),
        };
        let mut c = Canvas::new(8, 8, true).unwrap();
        draw(&mut c, &[p]).unwrap();
        assert_eq!(&c.bytes[..4], &[0; 4]);
        assert!(c.bytes.iter().any(|v| *v > 0));
    }
}
