//! The Dock icon (`AppIcon.swift`). A bundled app shows the bundle's icon
//! (`bundle-macos.sh` copies `AppDockIcon.icns`). Run outside the bundle
//! (`cargo run`), the icon comes from `resources/AppDockIcon.png` above the
//! build folder, else a generated bell (`chau7_next_core::app_icon`).

use std::path::PathBuf;

use chau7_next_core::app_icon::{FALLBACK_ICON_SIZE, fallback_icon_rgba};

use crate::platform::attention;

/// Set the Dock icon when running unbundled. Main thread.
pub fn apply() {
    match attention::set_unbundled_app_icon(load_png) {
        Ok(true) => log::info!("Dock icon set (running outside the app bundle)."),
        Ok(false) => {}
        Err(err) => log::debug!("Dock icon: {err}"),
    }
}

fn load_png() -> Option<Vec<u8>> {
    if let Some(bytes) = icon_file().and_then(|path| std::fs::read(path).ok()) {
        log::info!("Loaded dock icon from file.");
        return Some(bytes);
    }
    fallback_png()
}

/// `AppDockIcon.png` of the checkout the executable was built in
/// (`apps/chau7-next/target/<profile>/chau7-next` below
/// `apps/chau7-next/resources`).
fn icon_file() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    exe.ancestors()
        .skip(1)
        .take(5)
        .map(|dir| dir.join("resources").join("AppDockIcon.png"))
        .find(|path| path.is_file())
}

/// The generated bell (`generateFallback`), as PNG.
fn fallback_png() -> Option<Vec<u8>> {
    let image =
        image::RgbaImage::from_raw(FALLBACK_ICON_SIZE, FALLBACK_ICON_SIZE, fallback_icon_rgba())?;
    let mut out = std::io::Cursor::new(Vec::new());
    image.write_to(&mut out, image::ImageFormat::Png).ok()?;
    Some(out.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_is_a_png() {
        let png = fallback_png().unwrap();
        assert_eq!(&png[1..4], b"PNG");
        let decoded = image::load_from_memory(&png).unwrap();
        assert_eq!(decoded.width(), FALLBACK_ICON_SIZE);
    }
}
