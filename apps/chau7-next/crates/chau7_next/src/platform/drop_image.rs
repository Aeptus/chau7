//! Raw image data dropped on a terminal window (RBK-051): a PNG or TIFF
//! dragged from a browser, Preview or a screenshot thumbnail, with no file
//! behind it. Swift reads it in `performDragOperation` and pastes a
//! markdown data URI for AI CLIs (`pasteImageData`).
//!
//! GPUI only accepts drags that carry file names: it registers the window
//! for file names alone and refuses anything else. [`install`] registers the
//! terminal windows for PNG and TIFF too, and wraps GPUI's dragging methods
//! on its window class so a drag with image data and no files is accepted
//! and its bytes are queued here; drags with files still go to GPUI (the
//! terminal pastes their paths). The app drains the queue on its timer and
//! pastes into the focused terminal of that window. Main thread only.

use super::EventQueue;

/// Image bytes dropped on a window.
#[derive(Debug, Clone)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub struct ImageDrop {
    /// [`window_key`] of the window.
    pub window: usize,
    /// Drop point in window coordinates (top-left origin, points).
    pub x: f32,
    pub y: f32,
    /// PNG or TIFF bytes.
    pub data: Vec<u8>,
}

static EVENTS: EventQueue<ImageDrop> = EventQueue::new();

/// Accept image data dropped on this window. Safe to call more than once.
pub fn install(window: &gpui::Window) {
    imp::install(window)
}

/// Stop accepting image drops and discard pending drops before removing this
/// native terminal window. Queue ownership is a raw NSWindow pointer, so it
/// must be retired before that pointer can identify another window.
pub fn uninstall(window: &gpui::Window) {
    if let Some(key) = window_key(window) {
        discard_events_for_window(&EVENTS, key);
        imp::uninstall(window);
    }
}

fn discard_events_for_window(queue: &EventQueue<ImageDrop>, window: usize) {
    queue.retain(|event| event.window != window);
}

/// A key identifying a window in [`ImageDrop::window`].
pub fn window_key(window: &gpui::Window) -> Option<usize> {
    imp::window_key(window)
}

/// Every image dropped since the last call.
pub fn drain_events() -> Vec<ImageDrop> {
    EVENTS.drain()
}

#[cfg(target_os = "macos")]
mod imp {
    use std::sync::{Once, OnceLock};

    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, Bool, Imp, Sel};
    use objc2::{msg_send, sel};
    use objc2_app_kit::{NSView, NSWindow};
    use objc2_foundation::{NSArray, NSData, NSPoint, NSString};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    use super::{EVENTS, ImageDrop};

    type DragFn = unsafe extern "C-unwind" fn(&AnyObject, Sel, *mut AnyObject) -> usize;
    type PerformFn = unsafe extern "C-unwind" fn(&AnyObject, Sel, *mut AnyObject) -> Bool;

    static ENTERED: OnceLock<DragFn> = OnceLock::new();
    static UPDATED: OnceLock<DragFn> = OnceLock::new();
    static PERFORM: OnceLock<PerformFn> = OnceLock::new();
    static SWIZZLE: Once = Once::new();

    const DRAG_NONE: usize = 0;
    const DRAG_COPY: usize = 1;

    fn ns_window(window: &gpui::Window) -> Option<Retained<NSWindow>> {
        let handle = HasWindowHandle::window_handle(window).ok()?;
        let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
            return None;
        };
        // SAFETY: GPUI's AppKit handle points to the window's content NSView,
        // alive while `window` is borrowed; called on the main thread.
        let view: &NSView = unsafe { appkit.ns_view.cast::<NSView>().as_ref() };
        view.window()
    }

    pub fn window_key(window: &gpui::Window) -> Option<usize> {
        ns_window(window).map(|w| Retained::as_ptr(&w) as usize)
    }

    fn pasteboard(info: *mut AnyObject) -> Option<Retained<AnyObject>> {
        if info.is_null() {
            return None;
        }
        // SAFETY: `info` is the NSDraggingInfo AppKit passed to the method.
        unsafe { msg_send![&*info, draggingPasteboard] }
    }

    fn has_type(pasteboard: &AnyObject, uti: &str) -> bool {
        let types = NSArray::from_retained_slice(&[NSString::from_str(uti)]);
        // SAFETY: `availableTypeFromArray:` takes an array of type strings.
        let found: Option<Retained<NSString>> =
            unsafe { msg_send![pasteboard, availableTypeFromArray: &*types] };
        found.is_some()
    }

    fn has_files(pasteboard: &AnyObject) -> bool {
        has_type(pasteboard, "public.file-url") || has_type(pasteboard, "NSFilenamesPboardType")
    }

    /// PNG first, then TIFF (Swift: `data(forType: .png) ?? data(forType: .tiff)`).
    fn image_data(pasteboard: &AnyObject) -> Option<Vec<u8>> {
        ["public.png", "public.tiff"].iter().find_map(|uti| {
            let kind = NSString::from_str(uti);
            // SAFETY: `dataForType:` takes a type string and returns NSData or nil.
            let data: Option<Retained<NSData>> =
                unsafe { msg_send![pasteboard, dataForType: &*kind] };
            data.map(|d| d.to_vec())
        })
    }

    /// Image data and no files: GPUI would refuse it, Chau7 Next takes it.
    fn image_only(info: *mut AnyObject) -> bool {
        pasteboard(info).is_some_and(|pb| {
            !has_files(&pb) && (has_type(&pb, "public.png") || has_type(&pb, "public.tiff"))
        })
    }

    unsafe extern "C-unwind" fn dragging_entered(
        this: &AnyObject,
        cmd: Sel,
        info: *mut AnyObject,
    ) -> usize {
        // SAFETY: the original GPUI method, same arguments.
        let original = ENTERED
            .get()
            .map(|f| unsafe { f(this, cmd, info) })
            .unwrap_or(DRAG_NONE);
        if original == DRAG_NONE && image_only(info) {
            DRAG_COPY
        } else {
            original
        }
    }

    unsafe extern "C-unwind" fn dragging_updated(
        this: &AnyObject,
        cmd: Sel,
        info: *mut AnyObject,
    ) -> usize {
        // SAFETY: the original GPUI method, same arguments.
        let original = UPDATED
            .get()
            .map(|f| unsafe { f(this, cmd, info) })
            .unwrap_or(DRAG_NONE);
        if original == DRAG_NONE && image_only(info) {
            DRAG_COPY
        } else {
            original
        }
    }

    unsafe extern "C-unwind" fn perform_drag_operation(
        this: &AnyObject,
        cmd: Sel,
        info: *mut AnyObject,
    ) -> Bool {
        if image_only(info)
            && let Some(data) = pasteboard(info).and_then(|pb| image_data(&pb))
        {
            // SAFETY: `info` is the NSDraggingInfo; `this` is the NSWindow.
            let point: NSPoint = unsafe { msg_send![&*info, draggingLocation] };
            let content: Option<Retained<NSView>> = unsafe { msg_send![this, contentView] };
            let height = content.map(|v| v.frame().size.height).unwrap_or(0.0);
            EVENTS.push(ImageDrop {
                window: this as *const AnyObject as usize,
                x: point.x as f32,
                y: (height - point.y) as f32,
                data,
            });
            return Bool::YES;
        }
        // SAFETY: the original GPUI method, same arguments.
        PERFORM
            .get()
            .map(|f| unsafe { f(this, cmd, info) })
            .unwrap_or(Bool::NO)
    }

    pub fn uninstall(window: &gpui::Window) {
        if let Some(ns_window) = ns_window(window) {
            // SAFETY: this retires the drag destination registrations from
            // the exact NSWindow being removed, after queued drops were
            // purged and before GPUI releases the native window.
            ns_window.unregisterDraggedTypes();
        }
    }

    pub fn install(window: &gpui::Window) {
        let Some(ns_window) = ns_window(window) else {
            return;
        };
        let types = NSArray::from_retained_slice(&[
            NSString::from_str("NSFilenamesPboardType"),
            NSString::from_str("public.file-url"),
            NSString::from_str("public.png"),
            NSString::from_str("public.tiff"),
        ]);
        let object: &AnyObject = &ns_window;
        // SAFETY: `registerForDraggedTypes:` takes an array of type strings.
        let _: () = unsafe { msg_send![object, registerForDraggedTypes: &*types] };
        let class = object.class();
        // Only GPUI's own window classes, which define these methods
        // themselves (never NSWindow, which every window shares).
        if !class.name().to_bytes().starts_with(b"GPUI") {
            return;
        }
        SWIZZLE.call_once(|| {
            // SAFETY: each replacement has the signature of the method it
            // replaces (`draggingEntered:`, `draggingUpdated:` return
            // NSDragOperation, `performDragOperation:` returns BOOL), and the
            // originals are kept to be called first.
            unsafe {
                if let Some(method) = class.instance_method(sel!(draggingEntered:)) {
                    let new = std::mem::transmute::<DragFn, Imp>(dragging_entered);
                    let old = method.set_implementation(new);
                    let _ = ENTERED.set(std::mem::transmute::<Imp, DragFn>(old));
                }
                if let Some(method) = class.instance_method(sel!(draggingUpdated:)) {
                    let new = std::mem::transmute::<DragFn, Imp>(dragging_updated);
                    let old = method.set_implementation(new);
                    let _ = UPDATED.set(std::mem::transmute::<Imp, DragFn>(old));
                }
                if let Some(method) = class.instance_method(sel!(performDragOperation:)) {
                    let new = std::mem::transmute::<PerformFn, Imp>(perform_drag_operation);
                    let old = method.set_implementation(new);
                    let _ = PERFORM.set(std::mem::transmute::<Imp, PerformFn>(old));
                }
            }
        });
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    /// GPUI on Linux and Windows delivers dropped files only.
    pub fn install(_window: &gpui::Window) {
        crate::platform::log_unsupported_once("dropping image data");
    }

    pub fn window_key(_window: &gpui::Window) -> Option<usize> {
        None
    }

    pub fn uninstall(_window: &gpui::Window) {}
}

#[cfg(test)]
mod tests {
    use super::{EventQueue, ImageDrop, discard_events_for_window};

    #[test]
    fn retiring_a_window_purges_only_its_queued_image_drops() {
        let queue = EventQueue::new();
        queue.push(ImageDrop {
            window: 7,
            x: 1.0,
            y: 2.0,
            data: vec![1],
        });
        queue.push(ImageDrop {
            window: 8,
            x: 3.0,
            y: 4.0,
            data: vec![2],
        });
        discard_events_for_window(&queue, 7);
        let remaining = queue.drain();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].window, 8);
        assert_eq!(remaining[0].data, vec![2]);
    }
}
