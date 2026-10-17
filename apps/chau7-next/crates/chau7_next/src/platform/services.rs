//! macOS Services for Chau7 Next (a Next-only extension): the focused
//! terminal can offer its own selection to text services, and text returned
//! by a service is routed back to that window.
//!
//! GPUI's view class has none of these methods, so [`install`] adds them to
//! it (`GPUIView`) and registers the text type with the Services menu. They
//! answer only in terminal windows: the selection comes from
//! [`set_selection`] (the focused terminal keeps it current) and returned
//! text is queued for the app, which pastes it into the focused terminal of
//! that window ([`drain_returned_text`]). Main thread only.

#[cfg(any(target_os = "macos", test))]
use std::collections::HashSet;
use std::sync::Mutex;

use gpui::EntityId;

use super::EventQueue;

/// Text a service sent back, for the window with this
/// [`super::drop_image::window_key`].
#[derive(Debug, Clone)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub struct ReturnedText {
    pub window: usize,
    pub text: String,
}

/// The native windows currently eligible to participate in Services.
#[cfg(any(target_os = "macos", test))]
#[derive(Debug, Default)]
struct TerminalWindows(HashSet<usize>);

#[cfg(any(target_os = "macos", test))]
impl TerminalWindows {
    fn insert(&mut self, window: usize) {
        self.0.insert(window);
    }

    fn remove(&mut self, window: usize) -> bool {
        self.0.remove(&window)
    }

    fn contains(&self, window: usize) -> bool {
        self.0.contains(&window)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SelectionOwner {
    window: usize,
    session_id: u64,
    view_id: EntityId,
}

#[derive(Debug, Default)]
struct SelectionState {
    owner: Option<SelectionOwner>,
    text: Option<String>,
}

impl SelectionState {
    fn focus(&mut self, owner: SelectionOwner, text: Option<String>) {
        self.owner = Some(owner);
        self.text = text.filter(|text| !text.is_empty());
    }

    fn blur(&mut self, owner: SelectionOwner) {
        if self.owner == Some(owner) {
            self.owner = None;
            self.text = None;
        }
    }

    fn set(&mut self, owner: SelectionOwner, text: Option<String>) {
        if self.owner == Some(owner) {
            self.text = text.filter(|text| !text.is_empty());
        }
    }

    // Input clears selection in the shared terminal emulator. Invalidate that
    // session's cached text even if another view currently owns focus, while
    // retaining the current owner; blur/release retire an exact view via `blur`.
    fn clear_session(&mut self, session_id: u64) {
        if self
            .owner
            .is_some_and(|owner| owner.session_id == session_id)
        {
            self.text = None;
        }
    }

    fn retire_window(&mut self, window: usize) {
        if self.owner.is_some_and(|owner| owner.window == window) {
            self.owner = None;
            self.text = None;
        }
    }

    fn selection_for_window(&self, window: usize) -> Option<String> {
        if self.owner.is_some_and(|owner| owner.window == window) {
            self.text.clone()
        } else {
            None
        }
    }
}

static SELECTION: Mutex<SelectionState> = Mutex::new(SelectionState {
    owner: None,
    text: None,
});
static RETURNED: EventQueue<ReturnedText> = EventQueue::new();

/// Track the focused terminal view within its window. A stale blur or release
/// from an older view instance cannot clear a newer selection, and Services
/// never cross window owners.
pub fn sync_focused_session(
    window: usize,
    session_id: u64,
    view_id: EntityId,
    focused: bool,
    text: Option<String>,
) {
    let owner = SelectionOwner {
        window,
        session_id,
        view_id,
    };
    let mut state = SELECTION.lock().unwrap_or_else(|e| e.into_inner());
    if focused {
        state.focus(owner, text);
    } else {
        state.blur(owner);
    }
}

/// Update the Services selection only when this exact terminal still owns focus.
pub fn set_selection(window: usize, session_id: u64, view_id: EntityId, text: Option<String>) {
    SELECTION.lock().unwrap_or_else(|e| e.into_inner()).set(
        SelectionOwner {
            window,
            session_id,
            view_id,
        },
        text,
    );
}

/// Clear this owner without disturbing a different focused terminal.
pub fn clear_selection(window: usize, session_id: u64, view_id: EntityId) {
    SELECTION
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .blur(SelectionOwner {
            window,
            session_id,
            view_id,
        });
}

/// Clear a session's selected text after terminal input while retaining its
/// focus ownership so later selections in the same session can be published.
/// Session IDs identify the terminal when a caller has no GPUI Window.
pub fn clear_selection_for_session(session_id: u64) {
    SELECTION
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear_session(session_id);
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn selection(window: usize) -> Option<String> {
    SELECTION
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .selection_for_window(window)
}

/// Offer this terminal window's selection to Services.
pub fn install(window: &gpui::Window) {
    imp::install(window)
}

/// Retire this terminal window's Services ownership before removing its
/// native window. This also discards service replies already queued for it,
/// so AppKit pointer reuse cannot route them into a later terminal window.
pub fn uninstall(window: &gpui::Window) {
    let Some(key) = imp::window_key(window) else {
        return;
    };
    SELECTION
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .retire_window(key);
    discard_returned_for_window(&RETURNED, key);
    imp::uninstall(key);
}

fn discard_returned_for_window(queue: &EventQueue<ReturnedText>, window: usize) {
    queue.retain(|returned| returned.window != window);
}

/// Text returned by services since the last call.
pub fn drain_returned_text() -> Vec<ReturnedText> {
    RETURNED.drain()
}

#[cfg(target_os = "macos")]
mod imp {
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

    /// NSWindow pointers of the terminal windows, retired before close.
    static TERMINAL_WINDOWS: Mutex<Option<super::TerminalWindows>> = Mutex::new(None);
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

    pub fn window_key(window: &gpui::Window) -> Option<usize> {
        let view = ns_view(window)?;
        let ns_window = view.window()?;
        Some(Retained::as_ptr(&ns_window) as usize)
    }

    pub fn uninstall(key: usize) {
        if let Some(windows) = TERMINAL_WINDOWS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_mut()
        {
            windows.remove(key);
        }
    }

    /// The NSWindow of a view, as a key, when it is a terminal window.
    fn terminal_window_of(view: &AnyObject) -> Option<usize> {
        // SAFETY: every NSView answers `window`.
        let window: Option<Retained<NSWindow>> = unsafe { msg_send![view, window] };
        let key = Retained::as_ptr(&window?) as usize;
        let windows = TERMINAL_WINDOWS.lock().unwrap_or_else(|e| e.into_inner());
        windows.as_ref()?.contains(key).then_some(key)
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
        if let Some(window) = terminal_window_of(this) {
            if is_text_type(send_type) && selection(window).is_some() {
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
        if pasteboard.is_null() {
            return Bool::NO;
        }
        let Some(window) = terminal_window_of(this) else {
            return Bool::NO;
        };
        let Some(text) = selection(window) else {
            return Bool::NO;
        };
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
            .get_or_insert_with(super::TerminalWindows::default)
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

    pub fn window_key(_window: &gpui::Window) -> Option<usize> {
        None
    }

    pub fn uninstall(_key: usize) {}
}

#[cfg(test)]
mod tests {
    use super::{
        EntityId, SelectionOwner, SelectionState, TerminalWindows, discard_returned_for_window,
    };
    use crate::platform::EventQueue;

    fn owner(window: usize, session_id: u64, view_id: u64) -> SelectionOwner {
        SelectionOwner {
            window,
            session_id,
            view_id: EntityId::from(view_id),
        }
    }

    #[test]
    fn empty_selection_counts_as_none() {
        let mut state = SelectionState::default();
        let owner = owner(1, 10, 1);
        state.focus(owner, Some(String::new()));
        assert_eq!(state.selection_for_window(1), None);
        state.set(owner, Some("ls".into()));
        assert_eq!(state.selection_for_window(1).as_deref(), Some("ls"));
        state.set(owner, None);
        assert_eq!(state.selection_for_window(1), None);
    }

    #[test]
    fn background_window_or_session_cannot_replace_or_clear_the_focused_selection() {
        let mut state = SelectionState::default();
        let focused = owner(1, 10, 2);
        let background = owner(2, 20, 3);
        state.focus(focused, Some("focused".into()));

        state.set(background, Some("background".into()));
        state.set(background, None);
        state.clear_session(background.session_id);
        assert_eq!(state.selection_for_window(1).as_deref(), Some("focused"));
        assert_eq!(state.selection_for_window(2), None);
    }

    #[test]
    fn background_terminal_in_the_same_window_cannot_clear_the_focused_selection() {
        let mut state = SelectionState::default();
        let focused = owner(1, 10, 4);
        let background = owner(1, 20, 5);
        state.focus(focused, Some("focused".into()));

        state.set(background, None);
        state.clear_session(background.session_id);
        assert_eq!(state.selection_for_window(1).as_deref(), Some("focused"));
    }

    #[test]
    fn clearing_selected_text_keeps_focus_ownership_for_later_selection() {
        let mut state = SelectionState::default();
        let owner = owner(1, 10, 6);
        state.focus(owner, Some("first".into()));

        state.clear_session(owner.session_id);
        assert_eq!(state.owner, Some(owner));
        assert_eq!(state.selection_for_window(1), None);
        state.set(owner, Some("second".into()));
        assert_eq!(state.selection_for_window(1).as_deref(), Some("second"));
    }

    #[test]
    fn input_on_shared_session_invalidates_text_but_keeps_replacement_view_owner() {
        let mut state = SelectionState::default();
        let old_view = owner(1, 10, 100);
        let replacement_view = owner(1, 10, 101);
        state.focus(old_view, Some("selected before remount".into()));
        state.focus(replacement_view, Some("selected before remount".into()));

        // Both view instances reference the same TerminalSession emulator, so
        // input from either clears its real selection and cached text. It does
        // not retire the replacement view's focus ownership.
        state.clear_session(old_view.session_id);
        assert_eq!(state.owner, Some(replacement_view));
        assert_eq!(state.selection_for_window(1), None);

        state.set(replacement_view, Some("selected after input".into()));
        assert_eq!(
            state.selection_for_window(1).as_deref(),
            Some("selected after input")
        );
    }

    #[test]
    fn selection_is_offered_only_to_its_owning_window() {
        let mut state = SelectionState::default();
        state.focus(owner(7, 42, 7), Some("selected".into()));

        assert_eq!(state.selection_for_window(7).as_deref(), Some("selected"));
        assert_eq!(state.selection_for_window(8), None);
    }

    #[test]
    fn stale_blur_cannot_clear_a_new_owner() {
        let mut state = SelectionState::default();
        let old = owner(1, 10, 8);
        let new = owner(2, 20, 9);
        state.focus(old, Some("first".into()));
        state.focus(new, Some("second".into()));
        state.blur(old);
        assert_eq!(state.owner, Some(new));
        assert_eq!(state.selection_for_window(2).as_deref(), Some("second"));
        state.blur(new);
        assert_eq!(state.owner, None);
        assert_eq!(state.selection_for_window(2), None);
    }

    #[test]
    fn stale_blur_or_release_from_remounted_view_cannot_clear_same_session_selection() {
        let mut state = SelectionState::default();
        let old_view = owner(1, 10, 100);
        let replacement_view = owner(1, 10, 101);
        state.focus(old_view, Some("old selection".into()));
        state.focus(replacement_view, Some("new selection".into()));

        // Focus-out and on_release both use the same owner-checked blur path.
        state.blur(old_view);
        assert_eq!(state.owner, Some(replacement_view));
        assert_eq!(
            state.selection_for_window(1).as_deref(),
            Some("new selection")
        );
        state.set(old_view, None);
        assert_eq!(
            state.selection_for_window(1).as_deref(),
            Some("new selection")
        );
    }

    #[test]
    fn retiring_a_window_clears_only_its_selection_and_allows_pointer_reuse() {
        let mut state = SelectionState::default();
        let old = owner(7, 42, 70);
        state.focus(old, Some("old selection".into()));
        state.retire_window(7);
        assert_eq!(state.owner, None);
        assert_eq!(state.selection_for_window(7), None);

        let reused = owner(7, 84, 71);
        state.focus(reused, Some("new selection".into()));
        assert_eq!(
            state.selection_for_window(7).as_deref(),
            Some("new selection")
        );
    }

    #[test]
    fn terminal_window_registry_retires_exact_ids_before_reuse() {
        let mut windows = TerminalWindows::default();
        windows.insert(7);
        windows.insert(8);
        assert!(windows.remove(7));
        assert!(!windows.contains(7));
        assert!(windows.contains(8));
        windows.insert(7);
        assert!(windows.contains(7));
    }

    #[test]
    fn retiring_a_window_purges_only_its_queued_service_reply() {
        let queue = EventQueue::new();
        queue.push(super::ReturnedText {
            window: 7,
            text: "old".into(),
        });
        queue.push(super::ReturnedText {
            window: 8,
            text: "keep".into(),
        });
        discard_returned_for_window(&queue, 7);
        let remaining = queue.drain();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].window, 8);
        assert_eq!(remaining[0].text, "keep");
    }
}
