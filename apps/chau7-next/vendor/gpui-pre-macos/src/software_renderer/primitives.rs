//! CPU translations of the locked Metal quad, shadow and underline shaders.
use super::fills::{
    Color, Fill, Rect, corner_dash_velocity, corner_radius, dash_alpha, mix, over, quad_distance,
    rgba, saturate, sdf_impl,
};
use gpui::{BorderStyle, Quad, Shadow, Underline};

/// Rounded quads with asymmetric borders and the exact perimeter dash policy.
pub fn quad(q: &Quad, p: [f32; 2], fill: Fill) -> Color {
    let bounds = Rect::from(q.bounds);
    let background = fill.sample(p, bounds);
    let r = q.corner_radii;
    let w = q.border_widths;
    let unrounded = [
        r.top_left.0,
        r.top_right.0,
        r.bottom_right.0,
        r.bottom_left.0,
    ]
    .iter()
    .all(|r| *r == 0.);
    if unrounded
        && [w.top.0, w.right.0, w.bottom.0, w.left.0]
            .iter()
            .all(|w| *w == 0.)
    {
        return background;
    }
    let point = [p[0] - bounds.x, p[1] - bounds.y];
    let c = bounds.center_to(p);
    let radius = corner_radius(c, r);
    let border = [
        if c[0] < 0. { w.left.0 } else { w.right.0 },
        if c[1] < 0. { w.top.0 } else { w.bottom.0 },
    ];
    let reduced = border.map(|w| if w == 0. { -0.5 } else { w });
    let corner = [
        c[0].abs() - bounds.width * 0.5,
        c[1].abs() - bounds.height * 0.5,
    ];
    let cc = corner.map(|v| v + radius);
    let rounded = cc[0] >= 0. && cc[1] >= 0.;
    let inner_corner = [corner[0] + reduced[0], corner[1] + reduced[1]];
    if inner_corner[0] < -0.5 && inner_corner[1] < -0.5 && !rounded {
        return background;
    }
    let outer = sdf_impl(cc, radius);
    let inner = if cc[0] <= 0. || cc[1] <= 0. {
        -inner_corner[0].max(inner_corner[1])
    } else if inner_corner[0] > 0. || inner_corner[1] > 0. {
        -1.
    } else if reduced[0] == reduced[1] {
        -(outer + reduced[0])
    } else {
        let radii = reduced.map(|v| (radius - v).max(0.));
        (cc[0] / radii[0]).hypot(cc[1] / radii[1]).mul_add(1., -1.) * (radii[0] + radii[1]) * -0.5
    };
    let mut color = background;
    if inner.max(outer) < 0.5 {
        let mut border_color = rgba(q.border_color);
        if q.border_style == BorderStyle::Dashed {
            border_color[3] *= perimeter_dash(q, point, c, cc, radius, rounded, unrounded);
        }
        color = mix(
            background,
            over(background, border_color),
            saturate(0.5 - inner),
        );
    }
    color[3] *= saturate(0.5 - outer);
    color
}
fn perimeter_dash(
    q: &Quad,
    point: [f32; 2],
    c: [f32; 2],
    cc: [f32; 2],
    radius: f32,
    rounded: bool,
    unrounded: bool,
) -> f32 {
    let b = Rect::from(q.bounds);
    let r = q.corner_radii;
    let w = q.border_widths;
    let (t, mut max_t, velocity) = if unrounded {
        let horizontal = cc[0] < cc[1];
        let width = if horizontal {
            w.bottom.0.max(w.top.0)
        } else {
            w.right.0.max(w.left.0)
        };
        if width <= 0. {
            return 0.;
        }
        let velocity = 1. / (3. * width);
        (
            if horizontal { point[0] } else { point[1] } * velocity,
            if horizontal { b.width } else { b.height } * velocity,
            velocity,
        )
    } else {
        let velocity = |width: f32| if width <= 0. { 0. } else { 1. / (3. * width) };
        let dt = velocity(w.top.0);
        let dr = velocity(w.right.0);
        let db = velocity(w.bottom.0);
        let dl = velocity(w.left.0);
        let tr = corner_dash_velocity(dt, dr);
        let br = corner_dash_velocity(db, dr);
        let bl = corner_dash_velocity(db, dl);
        let tl = corner_dash_velocity(dt, dl);
        let upto_tr = (b.width - r.top_left.0 - r.top_right.0) * dt;
        let upto_r = upto_tr + r.top_right.0 * std::f32::consts::FRAC_PI_2 * tr;
        let upto_br = upto_r + (b.height - r.top_right.0 - r.bottom_right.0) * dr;
        let upto_b = upto_br + r.bottom_right.0 * std::f32::consts::FRAC_PI_2 * br;
        let upto_bl = upto_b + (b.width - r.bottom_right.0 - r.bottom_left.0) * db;
        let upto_l = upto_bl + r.bottom_left.0 * std::f32::consts::FRAC_PI_2 * bl;
        let upto_tl = upto_l + (b.height - r.bottom_left.0 - r.top_left.0) * dl;
        let max_t = upto_tl + r.top_left.0 * std::f32::consts::FRAC_PI_2 * tl;
        let (t, v) = if rounded {
            let ct = cc[1].atan2(cc[0]) * radius;
            if c[0] >= 0. {
                if c[1] < 0. {
                    (upto_r - ct * tr, tr)
                } else {
                    (upto_br + ct * br, br)
                }
            } else if c[1] >= 0. {
                (upto_l - ct * bl, bl)
            } else {
                (upto_tl + ct * tl, tl)
            }
        } else if cc[0] < cc[1] {
            if c[1] < 0. {
                ((point[0] - r.top_left.0) * dt, dt)
            } else {
                (upto_bl - (point[0] - r.bottom_left.0) * db, db)
            }
        } else if c[0] < 0. {
            (upto_tl - (point[1] - r.top_left.0) * dl, dl)
        } else {
            (upto_r + (point[1] - r.top_right.0) * dr, dr)
        };
        (t, max_t, v)
    };
    let length = 2. / 3.;
    max_t -= if unrounded { length } else { 0. };
    if max_t >= 1. {
        dash_alpha(t, max_t / max_t.floor(), length, velocity)
    } else if unrounded && max_t - length > 0. {
        dash_alpha(t, max_t, length, velocity)
    } else {
        1.
    }
}

/// Gaussian rounded-rectangle shadow, including the clipped inset complement.
pub fn shadow(s: &Shadow, p: [f32; 2]) -> Color {
    let b = Rect::from(s.bounds);
    let c = b.center_to(p);
    let radius = corner_radius(c, s.corner_radii);
    let sigma = s.blur_radius.0;
    let mut alpha = if sigma == 0. {
        saturate(0.5 - quad_distance(p, b, s.corner_radii))
    } else {
        let low = c[1] - b.height * 0.5;
        let high = c[1] + b.height * 0.5;
        let start = (-3. * sigma).clamp(low, high);
        let end = (3. * sigma).clamp(low, high);
        let step = (end - start) / 4.;
        (0..4)
            .map(|i| {
                let y = start + step * (i as f32 + 0.5);
                blur_x(
                    c[0],
                    c[1] - y,
                    sigma,
                    radius,
                    [b.width * 0.5, b.height * 0.5],
                ) * (-y * y / (2. * sigma * sigma)).exp()
                    / ((2. * std::f32::consts::PI).sqrt() * sigma)
                    * step
            })
            .sum()
    };
    if s.inset != 0 {
        alpha = (1. - alpha)
            * saturate(0.5 - quad_distance(p, s.element_bounds.into(), s.element_corner_radii));
    }
    let mut color = rgba(s.color);
    color[3] *= alpha;
    color
}
fn erf(x: f32) -> f32 {
    let a = x.abs();
    let r = 1. + (0.278393 + (0.230389 + (0.000972 + 0.078108 * a) * a) * a) * a;
    x.signum() * (1. - 1. / r.powi(4))
}
fn blur_x(x: f32, y: f32, sigma: f32, corner: f32, half: [f32; 2]) -> f32 {
    let delta = (half[1] - corner - y.abs()).min(0.);
    let curved = half[0] - corner + (corner * corner - delta * delta).max(0.).sqrt();
    let scale = std::f32::consts::FRAC_1_SQRT_2 / sigma;
    0.5 * (erf((x + curved) * scale) - erf((x - curved) * scale))
}

/// Straight or sinusoidal underline, preserving shader thickness/phase.
pub fn underline(u: &Underline, p: [f32; 2]) -> Color {
    let mut color = rgba(u.color);
    if u.wavy.get() {
        let b = Rect::from(u.bounds);
        let st = [(p[0] - b.x) / b.height, (p[1] - b.y) / b.height - 0.5];
        let frequency = std::f32::consts::PI * 2. * u.thickness.0 / b.height;
        let amplitude = u.thickness.0 * 0.8 / b.height;
        let sine = (st[0] * frequency).sin() * amplitude;
        let derivative = (st[0] * frequency).cos() * amplitude * frequency;
        let distance = (st[1] - sine) / (1. + derivative * derivative).sqrt() * b.height;
        color[3] *=
            saturate(0.5 - (distance - u.thickness.0 * 0.5).max(-distance - u.thickness.0 * 0.5));
    }
    color
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{Bounds, ContentMask, Corners, Edges, ScaledPixels, black, point, size, white};
    fn bounds() -> Bounds<ScaledPixels> {
        Bounds::new(
            point(ScaledPixels(0.), ScaledPixels(0.)),
            size(ScaledPixels(40.), ScaledPixels(30.)),
        )
    }
    #[test]
    fn asymmetric_rounded_and_dashed_borders_preserve_fill_and_clear_corners() {
        let mut q = Quad {
            bounds: bounds(),
            content_mask: ContentMask::default(),
            background: white().into(),
            border_color: black(),
            corner_radii: Corners::all(ScaledPixels(8.)),
            border_widths: Edges {
                top: ScaledPixels(2.),
                right: ScaledPixels(4.),
                bottom: ScaledPixels(3.),
                left: ScaledPixels(0.),
            },
            ..Default::default()
        };
        let f = Fill::new(q.background);
        assert_eq!(quad(&q, [20., 15.], f), [1.; 4]);
        assert_eq!(quad(&q, [0.5, 0.5], f)[3], 0.);
        assert!(quad(&q, [39.5, 15.], f)[0] < 0.1);
        assert!(quad(&q, [0.5, 15.], f)[0] > 0.9);
        q.border_style = BorderStyle::Dashed;
        let colors: Vec<_> = (8..32)
            .map(|x| quad(&q, [x as f32 + 0.5, 0.5], f)[0])
            .collect();
        assert!(colors.iter().any(|x| *x > 0.9));
        assert!(colors.iter().any(|x| *x < 0.1));
        for y in 0..30 {
            for x in 0..40 {
                assert!(
                    quad(&q, [x as f32 + 0.5, y as f32 + 0.5], f)
                        .iter()
                        .all(|v| v.is_finite())
                );
            }
        }
    }
    #[test]
    fn blur_inset_complement_and_wavy_underline_have_real_coverage() {
        let mut s = Shadow {
            order: 0,
            blur_radius: ScaledPixels(2.),
            bounds: bounds(),
            corner_radii: Corners::all(ScaledPixels(4.)),
            content_mask: ContentMask::default(),
            color: black(),
            element_bounds: bounds(),
            element_corner_radii: Corners::all(ScaledPixels(4.)),
            inset: 0,
            pad: 0,
        };
        assert!(shadow(&s, [20., 15.])[3] > 0.99);
        assert!(shadow(&s, [-4., 15.])[3] > 0. && shadow(&s, [-4., 15.])[3] < 0.2);
        s.inset = 1;
        assert!(shadow(&s, [-4., 15.])[3] == 0.);
        assert!(shadow(&s, [20., 15.])[3] < 0.01);
        let u = Underline {
            order: 0,
            pad: 0,
            bounds: bounds(),
            content_mask: ContentMask::default(),
            color: black(),
            thickness: ScaledPixels(2.),
            wavy: true.into(),
        };
        assert!(underline(&u, [0., 15.])[3] > 0.9);
        assert!(underline(&u, [0., 5.])[3] == 0.);
    }
}
