//! Owned, optional native backend proof. The window and menu belong only to
//! this isolated process; no global clipboard, OS setting or user window is used.
use core_foundation::{
    base::{CFGetTypeID, CFTypeRef, TCFType},
    data::{CFData, CFDataRef},
};
use gpui::{
    AppContext, AsyncApp, Context, Render, Window, WindowOptions, div, prelude::*, px, rgb, size,
};
use objc2::{MainThreadMarker, msg_send, rc::Retained, runtime::AnyObject};
use objc2_app_kit::{NSApplication, NSColorSpace, NSView};
use objc2_foundation::NSSize;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use serde_json::{Value, json};
use std::{
    ffi::c_void,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};

gpui::actions!(backend_native_fixture, [MenuProbe]);
struct SurfaceProbe;
impl Render for SurfaceProbe {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(div().w_full().flex_1().bg(rgb(0xff0000)))
            .child(div().w_full().flex_1().bg(rgb(0x0000ff)))
    }
}
#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGImageGetTypeID() -> usize;
    fn CGImageGetWidth(image: *const c_void) -> usize;
    fn CGImageGetHeight(image: *const c_void) -> usize;
    fn CGImageGetBytesPerRow(image: *const c_void) -> usize;
    fn CGImageGetDataProvider(image: *const c_void) -> *const c_void;
    fn CGDataProviderCopyData(provider: *const c_void) -> CFDataRef;
}
fn raw_view(window: &Window) -> Result<Retained<NSView>, String> {
    let handle = HasWindowHandle::window_handle(window).map_err(|error| error.to_string())?;
    let RawWindowHandle::AppKit(raw) = handle.as_raw() else {
        return Err("owned backend surface is not AppKit".into());
    };
    unsafe { Retained::retain(raw.ns_view.cast::<NSView>().as_ptr()) }
        .ok_or("owned backend view missing".into())
}
fn inspect(window: &Window) -> Result<Value, String> {
    let diagnostics = window
        .renderer_diagnostics()
        .ok_or("owned renderer diagnostics missing")?;
    let view = raw_view(window)?;
    let layer: *mut AnyObject = unsafe { msg_send![&*view, layer] };
    if layer.is_null() {
        return Err("owned backend view has no actual backing layer".into());
    }
    let software = diagnostics.backend == "software";
    let dimensions = if software {
        if unsafe { &*layer }
            .class()
            .name()
            .to_str()
            .map_err(|error| error.to_string())?
            != "CALayer"
        {
            return Err("software selected but actual owned layer is not ordinary CALayer".into());
        }
        let contents: *const c_void = unsafe { msg_send![&*layer, contents] };
        if contents.is_null()
            || unsafe { CFGetTypeID(contents as CFTypeRef) } != unsafe { CGImageGetTypeID() }
        {
            return Err("ordinary backing layer has no actual software CGImage".into());
        }
        let (width, height, stride) = unsafe {
            (
                CGImageGetWidth(contents),
                CGImageGetHeight(contents),
                CGImageGetBytesPerRow(contents),
            )
        };
        let provider = unsafe { CGImageGetDataProvider(contents) };
        if provider.is_null() {
            return Err("owned image provider missing".into());
        }
        let bytes = unsafe { CGDataProviderCopyData(provider) };
        if bytes.is_null() {
            return Err("owned image readback allocation failed".into());
        }
        let bytes = unsafe { CFData::wrap_under_create_rule(bytes) };
        if width < 4 || height < 4 || stride < width * 4 || bytes.len() < (stride * height) as isize
        {
            return Err("owned software image dimensions invalid".into());
        }
        let pixel = |x: usize, y: usize| &bytes.bytes()[y * stride + x * 4..y * stride + x * 4 + 4];
        let top = pixel(width / 2, height / 4);
        let bottom = pixel(width / 2, height * 3 / 4);
        if !(top[2] > 240 && top[0] < 10 && bottom[0] > 240 && bottom[2] < 10) {
            return Err(format!(
                "actual backing image orientation/color mismatch: top{top:?} bottom{bottom:?}"
            ));
        }
        if diagnostics.submitted_frames.unwrap_or(0) == 0
            || diagnostics.software_image_pixel_bytes != Some(width * height * 4)
        {
            return Err("actual backing image submission/storage counters mismatch".into());
        }
        // Cache the actual AppKit view composition, not merely a rerasterized
        // Scene or the source CGImage. This uses only the owned view and does
        // not need Screen Recording, global screen capture or TCC automation.
        let bounds = view.bounds();
        let bitmap = view
            .bitmapImageRepForCachingDisplayInRect(bounds)
            .ok_or("owned view bitmap allocation failed")?;
        view.cacheDisplayInRect_toBitmapImageRep(bounds, &bitmap);
        let sample = |y: isize| -> Result<[f64; 4], String> {
            let color = bitmap
                .colorAtX_y(bitmap.pixelsWide() / 2, y)
                .and_then(|color| color.colorUsingColorSpace(&NSColorSpace::sRGBColorSpace()))
                .ok_or("owned view composition sample missing")?;
            Ok([
                color.redComponent(),
                color.greenComponent(),
                color.blueComponent(),
                color.alphaComponent(),
            ])
        };
        let composed_top = sample(bitmap.pixelsHigh() / 4)?;
        let composed_bottom = sample(bitmap.pixelsHigh() * 3 / 4)?;
        if !(composed_top[0] > 0.9
            && composed_top[2] < 0.1
            && composed_bottom[2] > 0.9
            && composed_bottom[0] < 0.1)
        {
            return Err(format!(
                "actual owned NSView composition orientation/color mismatch: top{composed_top:?} bottom{composed_bottom:?}"
            ));
        }
        json!({"width":width,"height":height,"actual_layer":"CALayer","top_bgra":top,"bottom_bgra":bottom,"source_image_pixel_bytes":width*height*4,"actual_nsview_top_srgba":composed_top,"actual_nsview_bottom_srgba":composed_bottom})
    } else {
        Value::Null
    };
    Ok(
        json!({"actual_backend":diagnostics.backend,"software_image":dimensions,"display_completion":Value::Null}),
    )
}

pub(super) async fn verify(cx: &mut AsyncApp) -> Result<Value, String> {
    let menu_calls = Arc::new(AtomicUsize::new(0));
    let calls = menu_calls.clone();
    let handle = cx
        .update(|cx| {
            cx.on_action(move |_: &MenuProbe, _| {
                calls.fetch_add(1, Ordering::Relaxed);
            });
            cx.set_menus(vec![
                gpui::Menu::new("Owned Backend Fixture")
                    .items([gpui::MenuItem::action("Owned Menu Probe", MenuProbe)]),
            ]);
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(gpui::WindowBounds::Windowed(gpui::Bounds::new(
                        gpui::point(px(80.), px(80.)),
                        size(px(320.), px(200.)),
                    ))),
                    show: true,
                    focus: false,
                    ..Default::default()
                },
                |_, cx| cx.new(|_| SurfaceProbe),
            )
        })
        .map_err(|error| error.to_string())?;
    crate::native_parity_fixture::next_frame(handle.into(), cx).await?;
    let initial = cx
        .update_window(handle.into(), |_, window, _| inspect(window))
        .map_err(|error| error.to_string())??;
    // The real native setContentSize produces the normal GPUI resize callback.
    let native = cx
        .update_window(handle.into(), |_, window, _| {
            raw_view(window)?
                .window()
                .ok_or_else(|| "owned backend NSWindow missing".to_string())
        })
        .map_err(|error| error.to_string())??;
    // setContentSize synchronously calls GPUI's resize callback. Like the
    // NSMenu action below, it must run after the App borrow has ended.
    cx.foreground_executor()
        .spawn(async move {
            native.setContentSize(NSSize::new(420., 260.));
        })
        .await;
    crate::native_parity_fixture::next_frame(handle.into(), cx).await?;
    let resized = cx
        .update_window(handle.into(), |_, window, _| {
            let content = window.viewport_size();
            if (f32::from(content.width) - 420.).abs() > 1.
                || (f32::from(content.height) - 260.).abs() > 1.
            {
                return Err("native resize did not reach the actual GPUI viewport".into());
            }
            inspect(window)
        })
        .map_err(|error| error.to_string())??;
    if initial["actual_backend"] == "software"
        && initial["software_image"]["width"] == resized["software_image"]["width"]
    {
        return Err("owned native resize did not update the software image".into());
    }
    // Native menu callbacks run outside App::update, exactly as an AppKit
    // action does; synchronous reentry while the GPUI App is borrowed is invalid.
    cx.foreground_executor()
        .spawn(async move {
            let marker = MainThreadMarker::new().ok_or("owned menu not on main thread")?;
            let app = NSApplication::sharedApplication(marker);
            let menu = app
                .mainMenu()
                .ok_or("owned actual application menu missing")?;
            let submenu = menu
                .itemAtIndex(0)
                .and_then(|item| item.submenu())
                .ok_or("owned menu submenu missing")?;
            if submenu.itemAtIndex(0).is_none() {
                return Err::<(), String>("owned menu action missing".into());
            }
            submenu.performActionForItemAtIndex(0);
            Ok::<(), String>(())
        })
        .await?;
    if menu_calls.load(Ordering::Relaxed) != 1 {
        return Err("actual native NSMenu action did not reach GPUI".into());
    }
    cx.update_window(handle.into(), |_, window, _| window.remove_window())
        .map_err(|error| error.to_string())?;
    Ok(
        json!({"native_layer_image":initial,"native_resize":resized,"native_menu_action_count":1,"window_closed":true,"display_completion":Value::Null}),
    )
}
