//! macOS Services for the terminal (RBK-042): the selection is offered to
//! services that take text (Services menu, right click, keyboard
//! shortcuts), and text a service returns is pasted
//! (`RustTerminalView.validRequestor`, `writeSelectionToPasteboard`,
//! `readSelectionFromPasteboard`).
//!
//! GPUI's view class has none of these methods, so [`install`] adds them to
//! it (`GPUIView`) and registers the text type with the Services menu. They
//! answer only in terminal windows: the selection comes from
//! [`set_selection`] (the focused terminal keeps it current) and returned
//! text is queued for the app, which pastes it into the focused terminal of
//! that window ([`drain_returned_text`]). Main thread only.

use std::sync::Mutex;

use super::EventQueue;

/// Text a service sent back, for the window with this
/// [`super::drop_image::window_key`].
#[derive(Debug, Clone)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub struct ReturnedText {
    pub window: usize,
    pub text: String,
}

static SELECTION: Mutex<Option<String>> = Mutex::new(None);
static RETURNED: EventQueue<ReturnedText> = EventQueue::new();

/// The focused terminal's selection (`None` when nothing is selected).
pub fn set_selection(text: Option<String>) {
    *SELECTION.lock().unwrap_or_else(|e| e.into_inner()) = text.filter(|t| !t.is_empty());
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn selection() -> Option<String> {
    SELECTION.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Offer this terminal window's selection to Services.
pub fn install(window: &gpui::Window) {
    imp::install(window)
}

/// Text returned by services since the last call.
pub fn drain_returned_text() -> Vec<ReturnedText> {
    RETURNED.drain()
}

#[cfg(target_os = "macos")]
mod imp {
    use std::collections::HashSet;
    use std::sync::{Mutex, Once};

    use objc2::rc::Retained;
    use objc2::runtime::{AnyClass, AnyObject, Bool, Imp, Sel};
    use objc2::{msg_send, sel};
    use objc2_app_kit::{NSApplication, NSView, NSWindow};
    use objc2_foundation::{NSArray, NSString};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    use super::{RETURNED, ReturnedText, selection};
    use crate::platform::main_thread;

    /// `public.utf8-plain-text` (`NSPasteboard.PasteboardType.string`).
    const TEXT_TYPE: &str = "public.utf8-plain-text";

    /// NSWindow pointers of the terminal windows.
    static TERMINAL_WINDOWS: Mutex<Option<HashSet<usize>>> = Mutex::new(None);
    static ADD_METHODS: Once = Once::new();

    type RequestorFn = unsafe extern "C-unwind" fn(
        &AnyObject,
        Sel,
        *mut AnyObject,
        *mut AnyObject,
    ) -> *mut AnyObject;
    type WriteFn =
        unsafe extern "C-unwind" fn(&AnyObject, Sel, *mut AnyObject, *mut AnyObject) -> Bool;
    type ReadFn = unsafe extern "C-unwind" fn(&AnyObject, Sel, *mut AnyObject) -> Bool;

    fn ns_view(window: &gpui::Window) -> Option<&NSView> {
        let handle = HasWindowHandle::window_handle(window).ok()?;
        let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
            return None;
        };
        // SAFETY: GPUI's AppKit handle points to the window's NSView, alive
        // while `window` is borrowed; called on the main thread.
        Some(unsafe { appkit.ns_view.cast::<NSView>().as_ref() })
    }

    /// The NSWindow of a view, as a key, when it is a terminal window.
    fn terminal_window_of(view: &AnyObject) -> Option<usize> {
        // SAFETY: every NSView answers `window`.
        let window: Option<Retained<NSWindow>> = unsafe { msg_send![view, window] };
        let key = Retained::as_ptr(&window?) as usize;
        let windows = TERMINAL_WINDOWS.lock().unwrap_or_else(|e| e.into_inner());
        windows.as_ref()?.contains(&key).then_some(key)
    }

    fn is_text_type(kind: *mut AnyObject) -> bool {
        if kind.is_null() {
            return false;
        }
        // SAFETY: pasteboard types are NSStrings.
        let kind: &NSString = unsafe { &*(kind as *const NSString) };
        kind.to_string() == TEXT_TYPE
    }

    /// `validRequestorForSendType:returnType:`: this view when it can send
    /// the selection or take text back, else what NSView answers.
    unsafe extern "C-unwind" fn valid_requestor(
        this: &AnyObject,
        cmd: Sel,
        send_type: *mut AnyObject,
        return_type: *mut AnyObject,
    ) -> *mut AnyObject {
        if terminal_window_of(this).is_some() {
            if is_text_type(send_type) && selection().is_some() {
                return this as *const AnyObject as *mut AnyObject;
            }
            if is_text_type(return_type) {
                return this as *const AnyObject as *mut AnyObject;
            }
        }
        let Some(method) = AnyClass::get(c"NSView").and_then(|c| c.instance_method(cmd)) else {
            return std::ptr::null_mut();
        };
        // SAFETY: NSView's (NSResponder's) implementation of the same method.
        unsafe {
            let original = std::mem::transmute::<Imp, RequestorFn>(method.implementation());
            original(this, cmd, send_type, return_type)
        }
    }

    /// `writeSelectionToPasteboard:types:`.
    unsafe extern "C-unwind" fn write_selection(
        this: &AnyObject,
        _cmd: Sel,
        pasteboard: *mut AnyObject,
        types: *mut AnyObject,
    ) -> Bool {
        let Some(text) = selection() else {
            return Bool::NO;
        };
        if pasteboard.is_null() || terminal_window_of(this).is_none() {
            return Bool::NO;
        }
        let kind = NSString::from_str(TEXT_TYPE);
        if !types.is_null() {
            // SAFETY: `types` is an NSArray of type strings.
            let wanted: Bool = unsafe { msg_send![&*types, containsObject: &*kind] };
            if !wanted.as_bool() {
                return Bool::NO;
            }
        }
        let value = NSString::from_str(&text);
        // SAFETY: `pasteboard` is the NSPasteboard AppKit passed in.
        unsafe {
            let pasteboard = &*pasteboard;
            let _: isize = msg_send![pasteboard, clearContents];
            msg_send![pasteboard, setString: &*value, forType: &*kind]
        }
    }

    /// `readSelectionFromPasteboard:`: paste what the service returned.
    unsafe extern "C-unwind" fn read_selection(
        this: &AnyObject,
        _cmd: Sel,
        pasteboard: *mut AnyObject,
    ) -> Bool {
        if pasteboard.is_null() {
            return Bool::NO;
        }
        let Some(window) = terminal_window_of(this) else {
            return Bool::NO;
        };
        let kind = NSString::from_str(TEXT_TYPE);
        // SAFETY: `pasteboard` is the NSPasteboard AppKit passed in.
        let text: Option<Retained<NSString>> =
            unsafe { msg_send![&*pasteboard, stringForType: &*kind] };
        match text.map(|t| t.to_string()).filter(|t| !t.is_empty()) {
            Some(text) => {
                RETURNED.push(ReturnedText { window, text });
                Bool::YES
            }
            None => Bool::NO,
        }
    }

    pub fn install(window: &gpui::Window) {
        let Some(view) = ns_view(window) else {
            return;
        };
        let Some(ns_window) = view.window() else {
            return;
        };
        TERMINAL_WINDOWS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_or_insert_with(HashSet::new)
            .insert(Retained::as_ptr(&ns_window) as usize);
        let object: &AnyObject = view;
        let class = object.class();
        ADD_METHODS.call_once(|| {
            if !class.name().to_bytes().starts_with(b"GPUI") {
                return;
            }
            let class_ptr = class as *const AnyClass as *mut AnyClass;
            // SAFETY: the methods are added to GPUI's own view class, which
            // does not define them, with their Objective-C signatures
            // (`@@:@@`, `c@:@@`, `c@:@`).
            unsafe {
                let _ = objc2::ffi::class_addMethod(
                    class_ptr,
                    sel!(validRequestorForSendType:returnType:),
                    std::mem::transmute::<RequestorFn, Imp>(valid_requestor),
                    c"@@:@@".as_ptr(),
                );
                let _ = objc2::ffi::class_addMethod(
                    class_ptr,
                    sel!(writeSelectionToPasteboard:types:),
                    std::mem::transmute::<WriteFn, Imp>(write_selection),
                    c"c@:@@".as_ptr(),
                );
                let _ = objc2::ffi::class_addMethod(
                    class_ptr,
                    sel!(readSelectionFromPasteboard:),
                    std::mem::transmute::<ReadFn, Imp>(read_selection),
                    c"c@:@".as_ptr(),
                );
            }
            if let Ok(mtm) = main_thread() {
                let app = NSApplication::sharedApplication(mtm);
                let types = NSArray::from_retained_slice(&[NSString::from_str(TEXT_TYPE)]);
                // SAFETY: both arguments are arrays of type strings.
                let _: () = unsafe {
                    msg_send![&*app, registerServicesMenuSendTypes: &*types, returnTypes: &*types]
                };
            }
        });
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    /// Only macOS has Services.
    pub fn install(_window: &gpui::Window) {}
}

#[cfg(test)]
mod tests {
    #[test]
    fn empty_selection_counts_as_none() {
        super::set_selection(Some(String::new()));
        assert_eq!(super::selection(), None);
        super::set_selection(Some("ls".into()));
        assert_eq!(super::selection().as_deref(), Some("ls"));
        super::set_selection(None);
        assert_eq!(super::selection(), None);
    }
}
