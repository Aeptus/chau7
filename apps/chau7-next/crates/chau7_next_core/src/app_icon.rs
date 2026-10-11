//! The fallback app icon (`AppIcon.generateFallback`): a white bell on a
//! teal rounded square over a near-black background, drawn when the app runs
//! outside its bundle and no `AppDockIcon` file is found.

/// Side of the generated icon, in pixels.
pub const FALLBACK_ICON_SIZE: u32 = 256;

/// RGBA pixels (row-major, top row first) of the fallback icon, 256 x 256.
pub fn fallback_icon_rgba() -> Vec<u8> {
    let size = FALLBACK_ICON_SIZE as f32;
    let background = [15u8, 15, 15, 255]; // calibratedWhite 0.06
    let teal = [26u8, 138, 158, 255]; // (0.10, 0.54, 0.62)
    let white = [255u8, 255, 255, 255];
    // Shapes in AppKit coordinates (origin at the bottom left), as Swift draws them.
    let tile = RoundedRect::new(24.0, 24.0, 208.0, 208.0, 48.0);
    let bell = RoundedRect::new(72.0, 86.0, 112.0, 104.0, 28.0);
    let base = RoundedRect::new(96.0, 72.0, 64.0, 12.0, 6.0);
    let clapper = (128.0f32, 76.0f32, 16.0f32); // oval in (112, 60, 32, 32)

    let n = FALLBACK_ICON_SIZE as usize;
    let mut pixels = Vec::with_capacity(n * n * 4);
    for row in 0..n {
        // Pixel centers, flipped to AppKit's y axis.
        let y = size - (row as f32 + 0.5);
        for col in 0..n {
            let x = col as f32 + 0.5;
            let in_clapper = {
                let (cx, cy, r) = clapper;
                (x - cx).powi(2) + (y - cy).powi(2) <= r * r
            };
            let color = if bell.contains(x, y) || base.contains(x, y) || in_clapper {
                white
            } else if tile.contains(x, y) {
                teal
            } else {
                background
            };
            pixels.extend_from_slice(&color);
        }
    }
    pixels
}

struct RoundedRect {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
}

impl RoundedRect {
    fn new(x: f32, y: f32, w: f32, h: f32, r: f32) -> Self {
        Self { x, y, w, h, r }
    }

    fn contains(&self, px: f32, py: f32) -> bool {
        if px < self.x || px > self.x + self.w || py < self.y || py > self.y + self.h {
            return false;
        }
        // Distance to the nearest corner circle center, when in a corner zone.
        let cx = px.clamp(self.x + self.r, self.x + self.w - self.r);
        let cy = py.clamp(self.y + self.r, self.y + self.h - self.r);
        (px - cx).powi(2) + (py - cy).powi(2) <= self.r * self.r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pixel(pixels: &[u8], col: usize, row: usize) -> [u8; 4] {
        let i = (row * FALLBACK_ICON_SIZE as usize + col) * 4;
        [pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]]
    }

    #[test]
    fn draws_background_tile_and_bell() {
        let p = fallback_icon_rgba();
        assert_eq!(p.len(), 256 * 256 * 4);
        // Corner: background; tile corner is rounded off.
        assert_eq!(pixel(&p, 0, 0), [15, 15, 15, 255]);
        assert_eq!(pixel(&p, 25, 25), [15, 15, 15, 255]);
        // Inside the tile, away from the bell.
        assert_eq!(pixel(&p, 40, 128), [26, 138, 158, 255]);
        // Bell body (AppKit y 138 is row 117).
        assert_eq!(pixel(&p, 128, 117), [255, 255, 255, 255]);
        // Clapper below the bell (AppKit y 66 is row 189).
        assert_eq!(pixel(&p, 128, 189), [255, 255, 255, 255]);
    }
}
