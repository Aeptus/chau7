//! Public renderer prerequisites; no native device/window creation.

use gpui::{
    Background, BackgroundDescription, ColorSpace, black, checkerboard, hsla, linear_color_stop,
    linear_gradient, pattern_slash, solid_background, white,
};

#[test]
fn describes_all_fill_kinds_without_changing_shader_layout() {
    let color = hsla(0.25, 0.5, 0.75, 0.4);
    assert_eq!(
        solid_background(color).description(),
        BackgroundDescription::Solid(color)
    );
    let colors = [
        linear_color_stop(color, 0.2),
        linear_color_stop(white(), 0.8),
    ];
    assert_eq!(
        linear_gradient(42., colors[0], colors[1])
            .color_space(ColorSpace::Oklab)
            .description(),
        BackgroundDescription::LinearGradient {
            color_space: ColorSpace::Oklab,
            angle: 42.,
            colors
        }
    );
    assert_eq!(
        pattern_slash(color, 2., 3.).description(),
        BackgroundDescription::PatternSlash {
            color,
            encoded_width_interval: ((510u32 * 0xFFFF) + 765) as f32
        }
    );
    assert_eq!(
        checkerboard(color, 8.).description(),
        BackgroundDescription::Checkerboard { color, size: 8. }
    );
    assert_eq!(std::mem::size_of::<Background>(), 72);
}

#[test]
fn description_preserves_existing_opacity_and_serialization() {
    let fill = linear_gradient(
        90.,
        linear_color_stop(black(), 0.),
        linear_color_stop(white(), 1.),
    )
    .color_space(ColorSpace::Srgb)
    .opacity(0.3);
    let encoded = serde_json::to_string(&fill).unwrap();
    let restored: Background = serde_json::from_str(&encoded).unwrap();
    // Existing Hsla wire serialization quantizes alpha to an RGBA8 byte.
    // The new descriptor exposes the original value without changing that wire contract.
    assert_eq!(serde_json::to_string(&restored).unwrap(), encoded);
    if let BackgroundDescription::LinearGradient { colors, .. } = fill.description() {
        assert_eq!(colors[0].color.a, 0.3);
    } else {
        panic!("linear gradient description changed kind");
    }
    if let BackgroundDescription::LinearGradient { colors, .. } = restored.description() {
        assert_eq!(colors[0].color.a, 77. / 255.);
        assert_eq!(colors[1].color.a, 77. / 255.);
    } else {
        panic!("linear gradient description changed kind");
    }
}
