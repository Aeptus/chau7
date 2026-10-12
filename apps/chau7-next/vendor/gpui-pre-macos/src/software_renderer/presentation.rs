//! Ordinary CoreAnimation image presentation. This module never creates or
//! queries a Metal device, library, pipeline, texture, drawable or command queue.
//! All nullable CoreGraphics/CF allocations are checked before Rust ownership.
use super::{atlas::SoftwareAtlas, canvas::Canvas, scene};
use anyhow::{Result, anyhow, ensure};
use core_foundation::{
    base::{TCFType, kCFAllocatorDefault},
    data::{CFData, CFDataCreate, CFDataRef},
};
use core_graphics::{
    base::{CGFloat, kCGBitmapByteOrder32Little, kCGImageAlphaPremultipliedFirst},
    color_space::{CGColorSpace, kCGColorSpaceSRGB},
    data_provider::CGDataProvider,
    image::CGImage,
};
use foreign_types::ForeignType;
use gpui::{DevicePixels, PlatformAtlas, Scene, Size};
use objc2::{rc::Retained, runtime::AnyObject};
use std::{cell::RefCell, ptr, sync::Arc, time::Instant};

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGDataProviderCreateWithCFData(data: CFDataRef) -> core_graphics::sys::CGDataProviderRef;
    fn CGImageCreate(
        width: usize,
        height: usize,
        bits_per_component: usize,
        bits_per_pixel: usize,
        bytes_per_row: usize,
        color_space: core_graphics::sys::CGColorSpaceRef,
        bitmap_info: u32,
        provider: core_graphics::sys::CGDataProviderRef,
        decode: *const CGFloat,
        interpolate: bool,
        intent: u32,
    ) -> core_graphics::sys::CGImageRef;
}
fn image(canvas: &Canvas) -> Result<CGImage> {
    let bytes = canvas.bgra();
    let (width, height) = canvas.dimensions();
    let data_length = bytes
        .len()
        .try_into()
        .map_err(|_| anyhow!("software image data length overflow"))?;
    let data = unsafe { CFDataCreate(kCFAllocatorDefault, bytes.as_ptr(), data_length) };
    ensure!(!data.is_null(), "software image data allocation failed");
    let data = unsafe { CFData::wrap_under_create_rule(data) };
    let provider = unsafe { CGDataProviderCreateWithCFData(data.as_concrete_TypeRef()) };
    ensure!(
        !provider.is_null(),
        "software image provider allocation failed"
    );
    let provider = unsafe { CGDataProvider::from_ptr(provider) };
    // Scene shaders produce sRGB values. DeviceRGB is display-dependent and
    // visibly changes primary colors when AppKit color-manages a wide-gamut
    // view; attach the explicit matching profile with nullable-safe ownership.
    let color_space = CGColorSpace::create_with_name(unsafe { kCGColorSpaceSRGB })
        .ok_or_else(|| anyhow!("software image color space allocation failed"))?;
    let image = unsafe {
        CGImageCreate(
            width,
            height,
            8,
            32,
            width * 4,
            color_space.as_ptr(),
            kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
            provider.as_ptr(),
            ptr::null(),
            false,
            0,
        )
    };
    ensure!(!image.is_null(), "software image allocation failed");
    Ok(unsafe { CGImage::from_ptr(image) })
}
struct Transaction;
impl Transaction {
    fn begin() -> Self {
        unsafe {
            let class = objc2::class!(CATransaction);
            let _: () = objc2::msg_send![class, begin];
            let _: () = objc2::msg_send![class,setDisableActions:true];
        }
        Self
    }
}
impl Drop for Transaction {
    fn drop(&mut self) {
        unsafe {
            let _: () = objc2::msg_send![objc2::class!(CATransaction), commit];
        }
    }
}

/// Actual software rendering and owned-pixel counters. No GPU completion or
/// compositor backing-store allocation is inferred from these measurements.
#[derive(Clone, Debug, Default)]
pub struct SoftwareMetrics {
    /// Successfully constructed images submitted through CALayer contents.
    /// This does not measure compositor or physical display completion.
    pub submitted_frames: u64,
    /// Failed raster/image attempts, excluding zero-size suspended surfaces.
    pub failed_frames: u64,
    /// Actual retained source image pixel length (CFData); compositor memory unknown.
    pub owned_image_pixel_bytes: usize,
    /// Bytes retained by live CPU atlas keys.
    pub atlas_pixel_bytes: usize,
    /// Primitive counts from the last completed image.
    pub last_primitive_counts: Option<[u64; 8]>,
    /// Last completed frame's measured cached batches with retired atlas data.
    pub last_retired_sprite_batches: Option<u64>,
    /// Measured CPU raster+image construction+submission time, never GPU duration.
    pub last_cpu_submit_microseconds: Option<u64>,
}

/// One ordinary layer-backed software window renderer.
pub struct SoftwareRenderer {
    layer: Retained<AnyObject>,
    atlas: Arc<SoftwareAtlas>,
    viewport: Size<DevicePixels>,
    transparent: bool,
    last_image: RefCell<Option<CGImage>>,
    metrics: RefCell<SoftwareMetrics>,
}
impl SoftwareRenderer {
    /// Allocates a CALayer and checks framebuffer capacity before a window or
    /// atlas is exposed. This branch does not invoke any Metal API.
    pub fn new(viewport: Size<DevicePixels>, transparent: bool) -> Result<Self> {
        ensure!(
            viewport.width.0 > 0 && viewport.height.0 > 0,
            "software initial viewport must be positive"
        );
        let capacity = Canvas::new(
            viewport.width.0 as usize,
            viewport.height.0 as usize,
            transparent,
        )?;
        let initial_image = image(&capacity)?;
        let initial_pixel_bytes = capacity.bgra().len();
        let raw: *mut AnyObject = unsafe { objc2::msg_send![objc2::class!(CALayer), new] };
        let layer = unsafe { Retained::from_raw(raw) }
            .ok_or_else(|| anyhow!("software layer allocation failed"))?;
        unsafe {
            let _: () = objc2::msg_send![&*layer,setOpaque:!transparent];
            let _: () = objc2::msg_send![&*layer,setContentsScale:1_f64];
        }
        {
            let _transaction = Transaction::begin();
            unsafe {
                let _: () = objc2::msg_send![&*layer, setContents:initial_image.as_ptr().cast::<AnyObject>()];
            }
        }
        Ok(Self {
            layer,
            atlas: Arc::new(SoftwareAtlas::default()),
            viewport,
            transparent,
            last_image: RefCell::new(Some(initial_image)),
            metrics: RefCell::new(SoftwareMetrics {
                owned_image_pixel_bytes: initial_pixel_bytes,
                ..Default::default()
            }),
        })
    }
    /// The same backing-layer pointer returned by the native NSView subclass.
    pub fn layer_ptr(&self) -> *mut AnyObject {
        Retained::as_ptr(&self.layer).cast_mut()
    }
    /// Atlas used by this real window, with pixels retained for its scenes.
    pub fn sprite_atlas(&self) -> Arc<dyn PlatformAtlas> {
        self.atlas.clone()
    }
    /// Actual device-pixel viewport; zero sizes suspend drawing until a resize.
    pub fn update_drawable_size(&mut self, size: Size<DevicePixels>) {
        self.viewport = size;
    }
    /// Ordinary CALayer backing scale, separate from the device-space raster.
    pub fn set_contents_scale(&self, scale: f64) {
        if scale.is_finite() && scale > 0. {
            unsafe {
                let _: () = objc2::msg_send![&*self.layer,setContentsScale:scale];
            }
        }
    }
    /// Keeps native layer opacity in agreement with software clear alpha.
    pub fn update_transparency(&mut self, transparent: bool) {
        self.transparent = transparent;
        unsafe {
            let _: () = objc2::msg_send![&*self.layer,setOpaque:!transparent];
        }
    }
    /// Presents a complete image or leaves the previous valid image intact.
    pub fn draw(&mut self, scene: &Scene) -> Result<()> {
        if self.viewport.width.0 <= 0 || self.viewport.height.0 <= 0 {
            return Ok(());
        }
        let started = Instant::now();
        let result = (|| {
            let frame = scene::render(
                scene,
                &self.atlas,
                self.viewport.width.0 as usize,
                self.viewport.height.0 as usize,
                self.transparent,
            )?;
            let pixels = frame.canvas.bgra().len();
            let image = image(&frame.canvas)?;
            {
                let _transaction = Transaction::begin();
                unsafe {
                    let _: () = objc2::msg_send![&*self.layer,setContents:image.as_ptr().cast::<AnyObject>()];
                }
            }
            *self.last_image.get_mut() = Some(image);
            let metrics = self.metrics.get_mut();
            metrics.submitted_frames = metrics.submitted_frames.saturating_add(1);
            metrics.owned_image_pixel_bytes = pixels;
            metrics.atlas_pixel_bytes = self.atlas.retained_bytes();
            metrics.last_primitive_counts = Some(frame.primitive_counts);
            metrics.last_retired_sprite_batches = Some(frame.retired_sprite_batches);
            metrics.last_cpu_submit_microseconds =
                Some(started.elapsed().as_micros().min(u64::MAX as u128) as u64);
            Ok(())
        })();
        if result.is_err() {
            let metrics = self.metrics.get_mut();
            metrics.failed_frames = metrics.failed_frames.saturating_add(1);
        }
        result
    }
    /// Drops owned image contents without retaining any NSView/window.
    pub fn destroy(&self) {
        {
            let _transaction = Transaction::begin();
            unsafe {
                let _: () = objc2::msg_send![&*self.layer,setContents:ptr::null::<AnyObject>()];
            }
        }
        self.last_image.borrow_mut().take();
        self.metrics.borrow_mut().owned_image_pixel_bytes = 0;
    }
    /// Reads bounded measurements from this real renderer.
    pub fn metrics(&self) -> SoftwareMetrics {
        let mut metrics = self.metrics.borrow().clone();
        metrics.atlas_pixel_bytes = self.atlas.retained_bytes();
        metrics
    }
    /// Renders the current complete scene for GPUI's existing capture contract.
    #[cfg(any(test, feature = "test-support"))]
    pub fn render_to_image(&self, scene: &Scene) -> Result<image::RgbaImage> {
        let frame = scene::render(
            scene,
            &self.atlas,
            self.viewport.width.0 as usize,
            self.viewport.height.0 as usize,
            self.transparent,
        )?;
        image::RgbaImage::from_raw(
            self.viewport.width.0 as u32,
            self.viewport.height.0 as u32,
            frame.canvas.rgba()?,
        )
        .ok_or_else(|| anyhow!("software capture dimensions do not match image bytes"))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ordinary_layer_preflights_image_resources_and_reports_real_frame_lifetime() {
        let mut renderer =
            SoftwareRenderer::new(gpui::size(DevicePixels(8), DevicePixels(4)), false).unwrap();
        assert!(!renderer.layer_ptr().is_null());
        let initial = renderer.metrics();
        assert_eq!(initial.owned_image_pixel_bytes, 8 * 4 * 4);
        assert_eq!(initial.submitted_frames, 0);
        assert_eq!(initial.last_primitive_counts, None);
        assert_eq!(initial.last_cpu_submit_microseconds, None);
        renderer.set_contents_scale(2.);
        renderer.draw(&Scene::default()).unwrap();
        let completed = renderer.metrics();
        assert_eq!(completed.submitted_frames, 1);
        assert_eq!(completed.last_primitive_counts, Some([0; 8]));
        assert!(completed.last_cpu_submit_microseconds.is_some());
        renderer.update_drawable_size(gpui::size(DevicePixels(0), DevicePixels(0)));
        renderer.draw(&Scene::default()).unwrap();
        assert_eq!(renderer.metrics().submitted_frames, 1);
        renderer.destroy();
        assert_eq!(renderer.metrics().owned_image_pixel_bytes, 0);
        assert!(renderer.last_image.borrow().is_none());
        let contents: *const AnyObject = unsafe { objc2::msg_send![&*renderer.layer, contents] };
        assert!(contents.is_null());
    }
    #[test]
    fn actual_image_owns_bgra_pixels_after_framebuffer_release() {
        let mut canvas = Canvas::new(2, 1, true).unwrap();
        canvas.blend(0, 0, [1., 0., 0., 1.], false);
        canvas.blend(1, 0, [0., 0., 1., 0.5], false);
        let cg = image(&canvas).unwrap();
        drop(canvas);
        assert_eq!((cg.width(), cg.height()), (2, 1));
        assert_eq!(cg.bytes_per_row(), 8);
        assert_eq!(cg.data().bytes(), &[0, 0, 255, 255, 128, 0, 0, 128]);
        // Inspect the actual owned image profile, not merely the requested name.
        unsafe extern "C" {
            fn CGColorSpaceCopyName(space: core_graphics::sys::CGColorSpaceRef) -> core_foundation::string::CFStringRef;
        }
        let name = unsafe { CGColorSpaceCopyName(cg.color_space().as_ptr()) };
        assert!(!name.is_null());
        let name = unsafe { core_foundation::string::CFString::wrap_under_create_rule(name) };
        let expected = unsafe { core_foundation::string::CFString::wrap_under_get_rule(kCGColorSpaceSRGB) };
        assert_eq!(name, expected);
    }
}
