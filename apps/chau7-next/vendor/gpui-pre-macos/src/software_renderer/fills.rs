//! CPU equivalents of the locked shaders' fill and signed-distance functions.
//! Keep their coordinate, percentage, packed-pattern and gamma conventions.

use gpui::{Background, BackgroundDescription, Bounds, ColorSpace, Corners, Hsla, ScaledPixels};

pub type Color = [f32; 4];

/// Device-space rectangle; neither conversion nor sampling allocates.
#[derive(Clone, Copy, Debug, Default)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}
impl From<Bounds<ScaledPixels>> for Rect {
    fn from(b: Bounds<ScaledPixels>) -> Self {
        Self {
            x: b.origin.x.0,
            y: b.origin.y.0,
            width: b.size.width.0,
            height: b.size.height.0,
        }
    }
}
impl Rect {
    pub fn finite(self) -> bool {
        [self.x, self.y, self.width, self.height]
            .iter()
            .all(|v| v.is_finite())
    }
    pub fn contains(self, p: [f32; 2]) -> bool {
        p[0] >= self.x
            && p[1] >= self.y
            && p[0] < self.x + self.width
            && p[1] < self.y + self.height
    }
    pub fn center_to(self, p: [f32; 2]) -> [f32; 2] {
        [
            p[0] - self.x - self.width * 0.5,
            p[1] - self.y - self.height * 0.5,
        ]
    }
    pub fn intersect(self, other: Self) -> Self {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        Self {
            x,
            y,
            width: (self.x + self.width).min(other.x + other.width) - x,
            height: (self.y + self.height).min(other.y + other.height) - y,
        }
    }
    pub fn expand(self, margin: f32) -> Self {
        Self {
            x: self.x - margin,
            y: self.y - margin,
            width: self.width + 2. * margin,
            height: self.height + 2. * margin,
        }
    }
}

pub fn rgba(hsla: Hsla) -> Color {
    let c = hsla.to_rgb();
    [c.r, c.g, c.b, c.a]
}
pub fn saturate(v: f32) -> f32 {
    if v.is_nan() { 0. } else { v.clamp(0., 1.) }
}
pub fn mix(a: Color, b: Color, t: f32) -> Color {
    std::array::from_fn(|c| a[c] * (1. - t) + b[c] * t)
}
pub fn over(below: Color, above: Color) -> Color {
    let alpha = above[3] + below[3] * (1. - above[3]);
    if alpha <= 0. {
        return [0.; 4];
    }
    [
        (above[0] * above[3] + below[0] * below[3] * (1. - above[3])) / alpha,
        (above[1] * above[3] + below[1] * below[3] * (1. - above[3])) / alpha,
        (above[2] * above[3] + below[2] * below[3] * (1. - above[3])) / alpha,
        alpha,
    ]
}

/// Prepared once per primitive, including conversion of Oklab endpoints.
#[derive(Clone, Copy)]
pub enum Fill {
    Solid(Color),
    Linear {
        angle: f32,
        colors: [Color; 2],
        stops: [f32; 2],
        oklab: bool,
    },
    Slash {
        color: Color,
        encoded: f32,
    },
    Checker {
        color: Color,
        size: f32,
    },
}
impl Fill {
    pub fn new(background: Background) -> Self {
        match background.description() {
            BackgroundDescription::Solid(c) => Self::Solid(rgba(c)),
            BackgroundDescription::LinearGradient {
                color_space,
                angle,
                colors,
            } => {
                let oklab = color_space == ColorSpace::Oklab;
                let colors_rgba = colors.map(|stop| {
                    if oklab {
                        srgb_to_oklab(rgba(stop.color))
                    } else {
                        rgba(stop.color)
                    }
                });
                Self::Linear {
                    angle,
                    colors: colors_rgba,
                    stops: colors.map(|stop| stop.percentage),
                    oklab,
                }
            }
            BackgroundDescription::PatternSlash {
                color,
                encoded_width_interval,
            } => Self::Slash {
                color: rgba(color),
                encoded: encoded_width_interval,
            },
            BackgroundDescription::Checkerboard { color, size } => Self::Checker {
                color: rgba(color),
                size,
            },
        }
    }
    pub fn sample(self, p: [f32; 2], b: Rect) -> Color {
        match self {
            Self::Solid(c) => c,
            Self::Linear {
                angle,
                colors,
                stops,
                oklab,
            } => {
                let radians = ((angle % 360.) - 90.).to_radians();
                let mut direction = [radians.cos(), radians.sin()];
                if b.width > b.height {
                    direction[1] *= b.height / b.width;
                } else {
                    direction[0] *= b.width / b.height;
                }
                let q = b.center_to(p);
                let length = direction[0].hypot(direction[1]);
                let distance = (q[0] * direction[0] + q[1] * direction[1]) / length;
                let mut t = if direction[0].abs() > direction[1].abs() {
                    (distance + b.width * 0.5) / b.width
                } else {
                    (distance + b.height * 0.5) / b.height
                };
                t = saturate((t - stops[0]) / (stops[1] - stops[0]));
                let mut c = mix(colors[0], colors[1], t);
                if oklab {
                    c = oklab_to_srgb(c);
                }
                let seed = [p[0] * 0.618_034, p[1] * 0.618_034];
                let fract = |v: f32| v - v.floor();
                let r1 = fract((seed[0] * 12.9898 + seed[1] * 78.233).sin() * 43_758.547);
                let r2 = fract((seed[0] * 39.346 + seed[1] * 11.135).sin() * 24_634.635);
                let tri = r1 + r2 - 1.;
                for channel in &mut c[..3] {
                    *channel += tri * 2. / 255.;
                }
                c[3] += tri * 3. / 255.;
                c
            }
            Self::Slash { mut color, encoded } => {
                let width = (encoded / 65535.) / 255.;
                let interval = (encoded % 65535.) / 255.;
                let height = width + interval;
                let period = height * std::f32::consts::FRAC_1_SQRT_2;
                // MSL column-major float2x2(c,-s,s,c): x'=c*x+s*y.
                let rotated = ((p[0] - b.x) + (p[1] - b.y)) * std::f32::consts::FRAC_1_SQRT_2;
                let pattern = rotated % period;
                let distance = pattern.min(period - pattern) - period * (width / height) * 0.5;
                color[3] *= saturate(0.5 - distance);
                color
            }
            Self::Checker { mut color, size } => {
                let x = ((p[0] - b.x) / size).floor();
                let y = ((p[1] - b.y) / size).floor();
                color[3] *= saturate((x + y) % 2.);
                color
            }
        }
    }
}

fn srgb_to_oklab(c: Color) -> Color {
    let [r, g, b] = [c[0].powf(2.2), c[1].powf(2.2), c[2].powf(2.2)];
    let l = (0.412_221_46 * r + 0.536_332_55 * g + 0.051_445_995 * b).powf(1. / 3.);
    let m = (0.211_903_5 * r + 0.680_699_5 * g + 0.107_396_96 * b).powf(1. / 3.);
    let s = (0.088_302_46 * r + 0.281_718_85 * g + 0.629_978_7 * b).powf(1. / 3.);
    [
        0.210_454_26 * l + 0.793_617_8 * m - 0.004_072_047 * s,
        1.977_998_5 * l - 2.428_592_2 * m + 0.450_593_72 * s,
        0.025_904_037 * l + 0.782_771_77 * m - 0.808_675_77 * s,
        c[3],
    ]
}
fn oklab_to_srgb(c: Color) -> Color {
    let l = (c[0] + 0.396_337_78 * c[1] + 0.215_803_76 * c[2]).powi(3);
    let m = (c[0] - 0.105_561_346 * c[1] - 0.063_854_17 * c[2]).powi(3);
    let s = (c[0] - 0.089_484_18 * c[1] - 1.291_485_5 * c[2]).powi(3);
    [
        (4.076_741_7 * l - 3.307_711_6 * m + 0.230_969_94 * s)
            .max(0.)
            .powf(1. / 2.2),
        (-1.268_438 * l + 2.609_757_4 * m - 0.341_319_4 * s)
            .max(0.)
            .powf(1. / 2.2),
        (-0.004_196_086_3 * l - 0.703_418_6 * m + 1.707_614_7 * s)
            .max(0.)
            .powf(1. / 2.2),
        c[3],
    ]
}

pub fn corner_radius(center: [f32; 2], r: Corners<ScaledPixels>) -> f32 {
    if center[0] < 0. {
        if center[1] < 0. {
            r.top_left.0
        } else {
            r.bottom_left.0
        }
    } else if center[1] < 0. {
        r.top_right.0
    } else {
        r.bottom_right.0
    }
}
pub fn quad_distance(p: [f32; 2], b: Rect, r: Corners<ScaledPixels>) -> f32 {
    let q = b.center_to(p);
    let radius = corner_radius(q, r);
    sdf_impl(
        [
            q[0].abs() - b.width * 0.5 + radius,
            q[1].abs() - b.height * 0.5 + radius,
        ],
        radius,
    )
}
pub fn sdf_impl(q: [f32; 2], radius: f32) -> f32 {
    q[0].max(0.).hypot(q[1].max(0.)) + q[0].max(q[1]).min(0.) - radius
}
pub fn corner_dash_velocity(a: f32, b: f32) -> f32 {
    if a == 0. {
        b
    } else if b == 0. {
        a
    } else {
        a.min(b)
    }
}
pub fn dash_alpha(t: f32, period: f32, length: f32, velocity: f32) -> f32 {
    let centered = ((t + period * 0.5 - length * 0.5) % period) - period * 0.5;
    saturate(0.5 - (centered.abs() - length * 0.5) / velocity)
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{black, checkerboard, linear_color_stop, linear_gradient, pattern_slash, white};
    #[test]
    fn fills_preserve_css_angle_stop_percentages_and_checker_pattern() {
        let b = Rect {
            x: 0.,
            y: 0.,
            width: 100.,
            height: 50.,
        };
        let f = Fill::new(linear_gradient(
            90.,
            linear_color_stop(black(), 0.25),
            linear_color_stop(white(), 0.75),
        ));
        assert!(f.sample([10., 25.], b)[0].abs() < 0.01);
        assert!((f.sample([50., 25.], b)[0] - 0.5).abs() < 0.01);
        assert!((f.sample([90., 25.], b)[0] - 1.).abs() < 0.01);
        let checker = Fill::new(checkerboard(white(), 10.));
        assert_eq!(checker.sample([5., 5.], b)[3], 0.);
        assert_eq!(checker.sample([15., 5.], b)[3], 1.);
        let slash = Fill::new(pattern_slash(white(), 2., 3.));
        assert!(slash.sample([0., 0.], b)[3] > 0.9);
        assert!(slash.sample([1.25, 1.25], b)[3] < 0.01);
    }
    #[test]
    fn oklab_and_transparency_remain_finite_and_roundtrip_primary_colors() {
        for c in [
            [1., 0., 0., 0.3],
            [0., 1., 0., 0.7],
            [0., 0., 1., 1.],
            [0., 0., 0., 0.],
        ] {
            let out = oklab_to_srgb(srgb_to_oklab(c));
            for channel in 0..3 {
                assert!(
                    (out[channel] - c[channel]).abs() < 2. / 255.,
                    "f32 shader roundtrip: {c:?} -> {out:?}"
                );
            }
            assert_eq!(out[3], c[3]);
        }
        assert_eq!(over([0.; 4], [0.; 4]), [0.; 4]);
        assert_eq!(
            over([0., 0., 1., 1.], [1., 0., 0., 0.5]),
            [0.5, 0., 0.5, 1.]
        );
    }
}
