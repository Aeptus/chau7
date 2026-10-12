//! Immutable, fallible per-platform startup backend selection. Preparation is
//! completed before the first NSWindow or shared atlas is exposed. A failure on
//! a later Metal window returns an error rather than changing atlas semantics.
use crate::software_renderer::presentation::{SoftwareMetrics, SoftwareRenderer};
use anyhow::{Result, anyhow};
use gpui::{DevicePixels, PlatformAtlas, Scene, Size};
use gpui_apple::metal_renderer::{InstanceBufferPool, MetalRenderer, RendererInitStage};
use parking_lot::Mutex;
use std::sync::Arc;

/// Startup policy, fixed at platform construction.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum BackendPolicy {
    /// Attempt Metal and fall back to software on a recoverable startup error.
    #[default]
    Auto,
    /// Require Metal; a startup failure is returned to the caller.
    Metal,
    /// Ordinary CALayer presentation without invoking Metal initialization.
    Software,
}
/// Actual selected whole-window backend, separate from terminal grid settings.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowBackend {
    Metal,
    Software,
}
/// Bounded startup state. None means no window has been prepared yet.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BackendStatus {
    pub policy: BackendPolicy,
    pub selected: Option<WindowBackend>,
    pub startup_failure: Option<RendererInitStage>,
    pub injected_failure: bool,
}
struct State {
    status: BackendStatus,
    metal_pool: Option<Arc<Mutex<InstanceBufferPool>>>,
    #[cfg(any(test, feature = "test-support"))]
    inject_device_failure: bool,
}
#[derive(Clone)]
pub struct Context(Arc<Mutex<State>>);
impl Default for Context {
    fn default() -> Self {
        Self::new(BackendPolicy::Auto)
    }
}
impl Context {
    pub fn new(policy: BackendPolicy) -> Self {
        Self(Arc::new(Mutex::new(State {
            status: BackendStatus {
                policy,
                selected: None,
                startup_failure: None,
                injected_failure: false,
            },
            metal_pool: None,
            #[cfg(any(test, feature = "test-support"))]
            inject_device_failure: false,
        })))
    }
    /// Test-only failure is decided before any Metal API is invoked.
    #[cfg(any(test, feature = "test-support"))]
    pub fn with_injected_device_failure(policy: BackendPolicy) -> Self {
        let context = Self::new(policy);
        context.0.lock().inject_device_failure = true;
        context
    }
    pub fn status(&self) -> BackendStatus {
        self.0.lock().status
    }
    pub fn prepare(&self, viewport: Size<DevicePixels>, transparent: bool) -> Result<Renderer> {
        let mut state = self.0.lock();
        let selected = state.status.selected;
        if selected == Some(WindowBackend::Software)
            || (selected.is_none() && state.status.policy == BackendPolicy::Software)
        {
            let renderer = SoftwareRenderer::new(viewport, transparent)?;
            state.status.selected = Some(WindowBackend::Software);
            return Ok(Renderer::Software(Box::new(renderer)));
        }
        // The candidate pool is not retained by the context unless the full
        // viewport, atlas and initial resources succeed.
        let pool = state.metal_pool.clone().unwrap_or_default();
        #[cfg(any(test, feature = "test-support"))]
        let injected = state.inject_device_failure;
        #[cfg(not(any(test, feature = "test-support")))]
        let injected = false;
        let metal = if injected {
            Err((
                RendererInitStage::Device,
                anyhow!("injected Metal device failure"),
            ))
        } else {
            MetalRenderer::try_new(pool.clone(), transparent)
                .and_then(|mut renderer| {
                    renderer.try_prepare_startup(viewport)?;
                    Ok(renderer)
                })
                .map_err(|error| (error.stage(), anyhow!(error)))
        };
        match metal {
            Ok(renderer) => {
                state.status.selected = Some(WindowBackend::Metal);
                state.metal_pool = Some(pool);
                Ok(Renderer::Metal(Box::new(renderer)))
            }
            Err((stage, error)) => {
                // The first successful choice is immutable even if a later
                // Metal window cannot allocate its resources.
                if selected.is_some() || state.status.policy == BackendPolicy::Metal {
                    return Err(error);
                }
                drop(pool);
                let renderer = SoftwareRenderer::new(viewport, transparent)?;
                state.status.selected = Some(WindowBackend::Software);
                state.status.startup_failure = Some(stage);
                state.status.injected_failure = injected;
                Ok(Renderer::Software(Box::new(renderer)))
            }
        }
    }
}

pub enum Renderer {
    Metal(Box<MetalRenderer>),
    Software(Box<SoftwareRenderer>),
}
impl Renderer {
    pub fn backend(&self) -> WindowBackend {
        match self {
            Self::Metal(_) => WindowBackend::Metal,
            Self::Software(_) => WindowBackend::Software,
        }
    }
    pub fn software_metrics(&self) -> Option<SoftwareMetrics> {
        match self {
            Self::Metal(_) => None,
            Self::Software(renderer) => Some(renderer.metrics()),
        }
    }
    pub fn layer_ptr(&self) -> *mut objc2::runtime::AnyObject {
        match self {
            Self::Metal(renderer) => renderer.layer_ptr().cast(),
            Self::Software(renderer) => renderer.layer_ptr(),
        }
    }
    pub fn sprite_atlas(&self) -> Arc<dyn PlatformAtlas> {
        match self {
            Self::Metal(renderer) => renderer.sprite_atlas().clone(),
            Self::Software(renderer) => renderer.sprite_atlas(),
        }
    }
    pub fn draw(&mut self, scene: &Scene) {
        match self {
            Self::Metal(renderer) => renderer.draw(scene),
            Self::Software(renderer) => {
                if let Err(error) = renderer.draw(scene) {
                    log::error!("Software scene presentation failed: {error}");
                }
            }
        }
    }
    pub fn update_drawable_size(&mut self, size: Size<DevicePixels>) {
        match self {
            Self::Metal(renderer) => renderer.update_drawable_size(size),
            Self::Software(renderer) => renderer.update_drawable_size(size),
        }
    }
    pub fn set_contents_scale(&self, scale: f64) {
        if scale.is_finite() && scale > 0. {
            unsafe {
                let _: () = objc2::msg_send![&*self.layer_ptr(),setContentsScale:scale];
            }
        }
    }
    pub fn set_presents_with_transaction(&mut self, value: bool) {
        if let Self::Metal(renderer) = self {
            renderer.set_presents_with_transaction(value);
        }
    }
    pub fn update_transparency(&mut self, value: bool) {
        match self {
            Self::Metal(renderer) => renderer.update_transparency(value),
            Self::Software(renderer) => renderer.update_transparency(value),
        }
    }
    pub fn destroy(&self) {
        match self {
            Self::Metal(renderer) => renderer.destroy(),
            Self::Software(renderer) => renderer.destroy(),
        }
    }
    #[cfg(any(test, feature = "test-support"))]
    pub fn render_to_image(&mut self, scene: &Scene) -> Result<image::RgbaImage> {
        match self {
            Self::Metal(renderer) => renderer.render_to_image(scene),
            Self::Software(renderer) => renderer.render_to_image(scene),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn injected_device_failure_selects_software_once_before_any_metal_call() {
        objc2::rc::autoreleasepool(|_| {
            let context = Context::with_injected_device_failure(BackendPolicy::Auto);
            assert_eq!(context.status().selected, None);
            let renderer = context
                .prepare(gpui::size(DevicePixels(8), DevicePixels(4)), false)
                .unwrap();
            assert_eq!(renderer.backend(), WindowBackend::Software);
            assert_eq!(
                context.status().startup_failure,
                Some(RendererInitStage::Device)
            );
            assert!(context.status().injected_failure);
            let next = context
                .prepare(gpui::size(DevicePixels(4), DevicePixels(4)), true)
                .unwrap();
            assert_eq!(next.backend(), WindowBackend::Software);
            assert!(context.0.lock().metal_pool.is_none());
            assert_eq!(next.software_metrics().unwrap().owned_image_pixel_bytes, 64);
        });
    }
    #[test]
    fn successful_metal_preparation_keeps_backend_and_shared_pool() {
        objc2::rc::autoreleasepool(|_| {
            let context = Context::new(BackendPolicy::Auto);
            let renderer = context
                .prepare(gpui::size(DevicePixels(8), DevicePixels(4)), false)
                .unwrap();
            assert_eq!(renderer.backend(), WindowBackend::Metal);
            assert_eq!(context.status().startup_failure, None);
            assert!(renderer.software_metrics().is_none());
            let pool = context.0.lock().metal_pool.clone().unwrap();
            let next = context
                .prepare(gpui::size(DevicePixels(4), DevicePixels(4)), true)
                .unwrap();
            assert_eq!(next.backend(), WindowBackend::Metal);
            assert!(Arc::ptr_eq(
                &pool,
                context.0.lock().metal_pool.as_ref().unwrap()
            ));
        });
    }
    #[test]
    fn require_metal_failure_and_invalid_software_viewport_do_not_publish_backend() {
        objc2::rc::autoreleasepool(|_| {
            let context = Context::with_injected_device_failure(BackendPolicy::Metal);
            assert!(
                context
                    .prepare(gpui::size(DevicePixels(8), DevicePixels(4)), false)
                    .is_err()
            );
            assert_eq!(context.status().selected, None);
            let context = Context::new(BackendPolicy::Software);
            assert!(
                context
                    .prepare(gpui::size(DevicePixels(0), DevicePixels(4)), false)
                    .is_err()
            );
            assert_eq!(context.status().selected, None);
        });
    }
}
