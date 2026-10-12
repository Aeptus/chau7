//! Read-only, scoped CoreVideo plane leases. The CPU path accepts exactly the
//! full-range bi-planar YCbCr format accepted by the locked Metal surface path.
use super::{
    canvas::Canvas,
    fills::{Color, Rect},
};
use anyhow::{Result, ensure};
use core_video::pixel_buffer::{
    CVPixelBuffer, kCVPixelBufferLock_ReadOnly, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
};
use gpui::PaintSurface;

struct Lock<'a>(&'a CVPixelBuffer);
impl<'a> Lock<'a> {
    fn new(buffer: &'a CVPixelBuffer) -> Result<Self> {
        ensure!(
            buffer.lock_base_address(kCVPixelBufferLock_ReadOnly) == 0,
            "CoreVideo surface read lock failed"
        );
        Ok(Self(buffer))
    }
    fn plane(&self, index: usize, channels: usize) -> Result<Plane<'_>> {
        let width = self.0.get_width_of_plane(index);
        let height = self.0.get_height_of_plane(index);
        let stride = self.0.get_bytes_per_row_of_plane(index);
        let len = stride
            .checked_mul(height)
            .filter(|n| *n <= isize::MAX as usize)
            .ok_or_else(|| anyhow::anyhow!("CoreVideo plane byte size overflow"))?;
        let pointer = unsafe { self.0.get_base_address_of_plane(index) };
        ensure!(
            !pointer.is_null(),
            "CoreVideo surface has no readable plane"
        );
        // CoreVideo owns this allocation; the successful read lock pins its
        // base address and stride for the lifetime of this borrow.
        let bytes = unsafe { std::slice::from_raw_parts(pointer.cast::<u8>(), len) };
        Plane::new(bytes, width, height, stride, channels)
    }
}
impl Drop for Lock<'_> {
    fn drop(&mut self) {
        self.0.unlock_base_address(kCVPixelBufferLock_ReadOnly);
    }
}
struct Plane<'a> {
    bytes: &'a [u8],
    width: usize,
    height: usize,
    stride: usize,
    channels: usize,
}
impl<'a> Plane<'a> {
    fn new(
        bytes: &'a [u8],
        width: usize,
        height: usize,
        stride: usize,
        channels: usize,
    ) -> Result<Self> {
        ensure!(
            width > 0 && height > 0 && (channels == 1 || channels == 2),
            "invalid CoreVideo plane dimensions"
        );
        let row = width
            .checked_mul(channels)
            .ok_or_else(|| anyhow::anyhow!("CoreVideo plane row overflow"))?;
        ensure!(
            stride >= row && stride.checked_mul(height).is_some_and(|n| n <= bytes.len()),
            "invalid CoreVideo plane stride or byte length"
        );
        Ok(Self {
            bytes,
            width,
            height,
            stride,
            channels,
        })
    }
    fn sample(&self, uv: [f32; 2], channel: usize) -> f32 {
        let x = uv[0] * self.width as f32 - 0.5;
        let y = uv[1] * self.height as f32 - 0.5;
        let ix = x.floor();
        let iy = y.floor();
        let tx = x - ix;
        let ty = y - iy;
        [
            (0., 0., (1. - tx) * (1. - ty)),
            (1., 0., tx * (1. - ty)),
            (0., 1., (1. - tx) * ty),
            (1., 1., tx * ty),
        ]
        .into_iter()
        .map(|(dx, dy, w)| {
            let x = (ix + dx).clamp(0., self.width as f32 - 1.) as usize;
            let y = (iy + dy).clamp(0., self.height as f32 - 1.) as usize;
            self.bytes[y * self.stride + x * self.channels + channel] as f32 / 255. * w
        })
        .sum()
    }
}
fn convert(y: f32, cb: f32, cr: f32) -> Color {
    [
        y + 1.402 * cr - 0.701,
        y - 0.3441 * cb - 0.7141 * cr + 0.5291,
        y + 1.772 * cb - 0.886,
        1.,
    ]
}
fn planes(
    canvas: &mut Canvas,
    bounds: Rect,
    clip: Rect,
    y_plane: &Plane<'_>,
    chroma: &Plane<'_>,
) -> Result<()> {
    let (xs, ys) = canvas.region(bounds.intersect(clip))?;
    for y in ys {
        for x in xs.clone() {
            let uv = [
                (x as f32 + 0.5 - bounds.x) / bounds.width,
                (y as f32 + 0.5 - bounds.y) / bounds.height,
            ];
            let color = convert(
                y_plane.sample(uv, 0),
                chroma.sample(uv, 0),
                chroma.sample(uv, 1),
            );
            canvas.blend(x, y, color, false);
        }
    }
    Ok(())
}
/// Locks, validates, samples, and unlocks the actual image buffer on every exit.
pub fn draw(canvas: &mut Canvas, surface: &PaintSurface) -> Result<()> {
    let buffer = &surface.image_buffer;
    ensure!(
        buffer.get_pixel_format() == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            && buffer.is_planar()
            && buffer.get_plane_count() == 2,
        "unsupported software CoreVideo surface format"
    );
    let lease = Lock::new(buffer)?;
    let y = lease.plane(0, 1)?;
    let chroma = lease.plane(1, 2)?;
    planes(
        canvas,
        surface.bounds.into(),
        surface.content_mask.bounds.into(),
        &y,
        &chroma,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn padded_biplanar_strides_bilinear_sampling_and_full_range_conversion() {
        let y = Plane::new(&[0, 255, 9, 9, 128, 128, 9, 9], 2, 2, 4, 1).unwrap();
        let cbcr = Plane::new(&[128, 128, 9, 9], 1, 1, 4, 2).unwrap();
        assert_eq!(y.sample([0.5, 0.25], 0), 0.5);
        assert_eq!(y.sample([0., 0.], 0), 0.);
        let mut c = Canvas::new(2, 2, false).unwrap();
        let b = Rect {
            x: 0.,
            y: 0.,
            width: 2.,
            height: 2.,
        };
        planes(&mut c, b, b, &y, &cbcr).unwrap();
        assert!(c.bytes[0] <= 1 && c.bytes[1] <= 1 && c.bytes[2] <= 1);
        assert!(c.bytes[4] >= 254 && c.bytes[5] >= 254 && c.bytes[6] >= 254);
        assert!(Plane::new(&[], 2, 2, 4, 1).is_err());
        assert!(Plane::new(&[0; 8], 2, 2, 1, 2).is_err());
    }
    #[test]
    fn actual_pixel_buffer_lock_is_released_after_invalid_plane_and_normal_drop() {
        let buffer =
            CVPixelBuffer::new(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 4, 4, None).unwrap();
        {
            let lease = Lock::new(&buffer).unwrap();
            assert!(lease.plane(0, 1).is_ok());
            assert!(lease.plane(1, 2).is_ok());
            assert!(lease.plane(0, 3).is_err());
        }
        // A second actual write lease succeeds after the scoped read lease.
        assert_eq!(buffer.lock_base_address(0), 0);
        assert_eq!(buffer.unlock_base_address(0), 0);
        let _lease = Lock::new(&buffer).unwrap();
    }
}
