use crate::{
    BoolExt, MacDisplay, NSRange, NSStringExt, TISCopyCurrentKeyboardInputSource,
    TISGetInputSourceProperty, WindowFrameSource,
    events::{native_window_point_to_gpui, platform_input_from_native},
    kTISPropertyInputSourceIsASCIICapable, kTISPropertyInputSourceType, kTISTypeKeyboardInputMode,
    ns_string, renderer,
};
#[cfg(any(test, feature = "test-support"))]
use anyhow::Result;
use block2::RcBlock;
use cocoa::{
    appkit::{
        NSApplication, NSBackingStoreBuffered, NSColor, NSEvent, NSEventModifierFlags, NSEventType,
        NSFilenamesPboardType, NSPasteboard, NSRequestUserAttentionType, NSScreen, NSView,
        NSViewHeightSizable, NSViewWidthSizable, NSVisualEffectBlendingMode,
        NSVisualEffectMaterial, NSVisualEffectState, NSVisualEffectView, NSWindow,
        NSWindowCollectionBehavior, NSWindowOcclusionState, NSWindowOrderingMode,
        NSWindowStyleMask, NSWindowTitleVisibility,
    },
    base::{id, nil},
    foundation::{
        NSArray, NSAutoreleasePool, NSData, NSDictionary, NSFastEnumeration, NSInteger, NSNotFound,
        NSOperatingSystemVersion, NSPoint, NSProcessInfo, NSRect, NSSize, NSString, NSUInteger,
        NSUserDefaults,
    },
};
use dispatch2::DispatchQueue;
use gpui::{
    AnyWindowHandle, BackgroundExecutor, Bounds, Capslock, CursorStyle, ExternalDragPayload,
    ExternalPaths, FileDropEvent, ForegroundExecutor, FrameRequestSource, KeyDownEvent, Keystroke,
    Modifiers, ModifiersChangedEvent, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent,
    Pixels, PlatformAtlas, PlatformDisplay, PlatformFrameSignal, PlatformInput,
    PlatformInputHandler, PlatformWindow, Point, PromptButton, PromptLevel, RequestFrameOptions,
    SharedString, Size, SystemWindowTab, WindowAppearance, WindowBackgroundAppearance,
    WindowBounds, WindowControlArea, WindowKind, WindowParams, WindowVisibility, point, px, size,
};
#[cfg(any(test, feature = "test-support"))]
use image::RgbaImage;

use core_foundation::base::{CFRelease, CFTypeRef};
use core_foundation_sys::base::CFEqual;
use core_foundation_sys::number::{CFBooleanGetValue, CFBooleanRef};
use core_graphics::display::CGDirectDisplayID;
use ctor::ctor;
use futures::channel::oneshot;
use gpui_util::ResultExt;
use objc::{
    class,
    declare::ClassDecl,
    msg_send,
    runtime::{BOOL, Class, NO, Object, Protocol, Sel, YES},
    sel, sel_impl,
};
use objc2::{
    AnyThread, MainThreadMarker, MainThreadOnly,
    rc::Retained,
    runtime::{AnyObject as Objc2Object, ProtocolObject},
};
#[cfg(test)]
use objc2_app_kit::NSApplicationPresentationOptions as Objc2NSApplicationPresentationOptions;
use objc2_app_kit::{
    NSAlert, NSAlertStyle, NSAutoresizingMaskOptions, NSBeep, NSButton as Objc2NSButton,
    NSColor as Objc2NSColor, NSDraggingImageComponent, NSDraggingImageComponentIconKey,
    NSDraggingItem, NSPasteboardWriting, NSTrackingArea, NSTrackingAreaOptions,
    NSView as Objc2NSView, NSWindow as Objc2NSWindow, NSWindowButton as Objc2NSWindowButton,
    NSWindowStyleMask as Objc2NSWindowStyleMask, NSWorkspace,
};
use objc2_foundation::{
    NSPoint as Objc2NSPoint, NSRect as Objc2NSRect, NSSize as Objc2NSSize, NSURL,
};
use parking_lot::Mutex;
use raw_window_handle as rwh;
use smallvec::SmallVec;
use std::{
    cell::Cell,
    collections::HashMap,
    ffi::{CStr, CString, c_void},
    mem,
    ops::Range,
    os::unix::ffi::OsStrExt,
    path::PathBuf,
    ptr::{self, NonNull},
    rc::Rc,
    sync::{
        Arc, Once, OnceLock, Weak,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

const WINDOW_STATE_IVAR: &str = "windowState";
static CONTENT_LAYOUT_RECT_OBSERVER_CONTEXT: u8 = 0;
static FULLSCREEN_TOOLBAR_UPDATES_PENDING: OnceLock<Mutex<HashMap<usize, Option<usize>>>> =
    OnceLock::new();

static RESTORES_WORKSPACE_AT_LAUNCH_DEFAULT: Once = Once::new();

static mut WINDOW_CLASS: *const Class = ptr::null();
static mut PANEL_CLASS: *const Class = ptr::null();
static mut VIEW_CLASS: *const Class = ptr::null();
static mut BLURRED_VIEW_CLASS: *const Class = ptr::null();
static mut WINDOW_STATE_ARCHIVER_DELEGATE_CLASS: *const Class = ptr::null();
static mut WINDOW_STATE_UNARCHIVER_CLASS: *const Class = ptr::null();

#[allow(non_upper_case_globals)]
const NSWindowStyleMaskNonactivatingPanel: NSWindowStyleMask =
    NSWindowStyleMask::from_bits_retain(1 << 7);
// WindowLevel const value ref: https://docs.rs/core-graphics2/0.4.1/src/core_graphics2/window_level.rs.html
#[allow(non_upper_case_globals)]
const NSNormalWindowLevel: NSInteger = 0;
#[allow(non_upper_case_globals)]
const NSFloatingWindowLevel: NSInteger = 3;
#[allow(non_upper_case_globals)]
const NSPopUpWindowLevel: NSInteger = 101;
#[allow(non_upper_case_globals)]
const NSWindowAnimationBehaviorUtilityWindow: NSInteger = 4;
#[allow(non_upper_case_globals)]
const NSViewLayerContentsRedrawDuringViewResize: NSInteger = 2;
// https://developer.apple.com/documentation/appkit/nsdragoperation
type NSDragOperation = NSUInteger;
#[allow(non_upper_case_globals)]
const NSDragOperationNone: NSDragOperation = 0;
#[allow(non_upper_case_globals)]
const NSDragOperationCopy: NSDragOperation = 1;
#[allow(non_upper_case_globals)]
const NSDragOperationMove: NSDragOperation = 16;
const NSDRAGGING_CONTEXT_OUTSIDE_APPLICATION: NSInteger = 0;
const NSDRAGGING_CONTEXT_WITHIN_APPLICATION: NSInteger = 1;
#[derive(PartialEq)]
pub enum UserTabbingPreference {
    Never,
    Always,
    InFullScreen,
}

#[ctor(unsafe)]
unsafe fn build_classes() {
    unsafe {
        WINDOW_CLASS = build_window_class("GPUIWindow", class!(NSWindow));
        PANEL_CLASS = build_window_class("GPUIPanel", class!(NSPanel));
        VIEW_CLASS = {
            let mut decl = ClassDecl::new("GPUIView", class!(NSView)).unwrap();
            decl.add_ivar::<*mut c_void>(WINDOW_STATE_IVAR);
            decl.add_method(sel!(dealloc), dealloc_view as extern "C" fn(&Object, Sel));

            decl.add_method(
                sel!(performKeyEquivalent:),
                handle_key_equivalent as extern "C" fn(&Object, Sel, id) -> BOOL,
            );
            decl.add_method(
                sel!(keyDown:),
                handle_key_down as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(keyUp:),
                handle_key_up as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(mouseDown:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(mouseUp:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(rightMouseDown:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(rightMouseUp:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(otherMouseDown:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(otherMouseUp:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(mouseMoved:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(resetCursorRects),
                reset_cursor_rects as extern "C" fn(&Object, Sel),
            );
            decl.add_method(
                sel!(pressureChangeWithEvent:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(mouseExited:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(magnifyWithEvent:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(mouseDragged:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(rightMouseDragged:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(otherMouseDragged:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(scrollWheel:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(swipeWithEvent:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );
            decl.add_method(
                sel!(flagsChanged:),
                handle_view_event as extern "C" fn(&Object, Sel, id),
            );

            decl.add_method(
                sel!(makeBackingLayer),
                make_backing_layer as extern "C" fn(&Object, Sel) -> id,
            );

            decl.add_protocol(Protocol::get("CALayerDelegate").unwrap());
            decl.add_method(
                sel!(viewDidChangeBackingProperties),
                view_did_change_backing_properties as extern "C" fn(&Object, Sel),
            );
            decl.add_method(
                sel!(setFrameSize:),
                set_frame_size as extern "C" fn(&Object, Sel, NSSize),
            );
            decl.add_method(
                sel!(displayLayer:),
                display_layer as extern "C" fn(&Object, Sel, id),
            );

            decl.add_protocol(Protocol::get("NSTextInputClient").unwrap());
            decl.add_method(
                sel!(validAttributesForMarkedText),
                valid_attributes_for_marked_text as extern "C" fn(&Object, Sel) -> id,
            );
            decl.add_method(
                sel!(hasMarkedText),
                has_marked_text as extern "C" fn(&Object, Sel) -> BOOL,
            );
            decl.add_method(
                sel!(markedRange),
                marked_range as extern "C" fn(&Object, Sel) -> NSRange,
            );
            decl.add_method(
                sel!(selectedRange),
                selected_range as extern "C" fn(&Object, Sel) -> NSRange,
            );
            decl.add_method(
                sel!(firstRectForCharacterRange:actualRange:),
                first_rect_for_character_range
                    as extern "C" fn(&Object, Sel, NSRange, id) -> NSRect,
            );
            decl.add_method(
                sel!(insertText:replacementRange:),
                insert_text as extern "C" fn(&Object, Sel, id, NSRange),
            );
            decl.add_method(
                sel!(setMarkedText:selectedRange:replacementRange:),
                set_marked_text as extern "C" fn(&Object, Sel, id, NSRange, NSRange),
            );
            decl.add_method(sel!(unmarkText), unmark_text as extern "C" fn(&Object, Sel));
            decl.add_method(
                sel!(attributedSubstringForProposedRange:actualRange:),
                attributed_substring_for_proposed_range
                    as extern "C" fn(&Object, Sel, NSRange, *mut c_void) -> id,
            );
            decl.add_method(
                sel!(viewDidChangeEffectiveAppearance),
                view_did_change_effective_appearance as extern "C" fn(&Object, Sel),
            );

            // Suppress beep on keystrokes with modifier keys.
            decl.add_method(
                sel!(doCommandBySelector:),
                do_command_by_selector as extern "C" fn(&Object, Sel, Sel),
            );

            decl.add_method(
                sel!(acceptsFirstMouse:),
                accepts_first_mouse as extern "C" fn(&Object, Sel, id) -> BOOL,
            );

            decl.add_method(
                sel!(_opaqueRectForWindowMoveWhenInTitlebar),
                opaque_rect_for_window_move_when_in_titlebar
                    as extern "C" fn(&Object, Sel) -> NSRect,
            );

            decl.add_method(
                sel!(characterIndexForPoint:),
                character_index_for_point as extern "C" fn(&Object, Sel, NSPoint) -> u64,
            );
            decl.register()
        };
        BLURRED_VIEW_CLASS = {
            let mut decl = ClassDecl::new("BlurredView", class!(NSVisualEffectView)).unwrap();
            decl.add_method(
                sel!(initWithFrame:),
                blurred_view_init_with_frame as extern "C" fn(&Object, Sel, NSRect) -> id,
            );
            decl.add_method(
                sel!(updateLayer),
                blurred_view_update_layer as extern "C" fn(&Object, Sel),
            );
            decl.register()
        };
        WINDOW_STATE_ARCHIVER_DELEGATE_CLASS = {
            let mut decl =
                ClassDecl::new("GPUIWindowStateArchiverDelegate", class!(NSObject)).unwrap();
            decl.add_method(
                sel!(archiver:willEncodeObject:),
                window_state_archiver_will_encode_object
                    as extern "C" fn(&Object, Sel, id, id) -> id,
            );
            decl.register()
        };
        WINDOW_STATE_UNARCHIVER_CLASS = {
            let mut decl =
                ClassDecl::new("GPUIWindowStateKeyedUnarchiver", class!(NSKeyedUnarchiver))
                    .unwrap();
            decl.add_method(
                sel!(_windowRestorationOptions),
                window_state_unarchiver_restoration_options as extern "C" fn(&Object, Sel) -> id,
            );
            decl.register()
        };
    }
}

// NSKeyedArchiverDelegate callback that skips objects which don't adopt `NSSecureCoding`
// (the window itself and its NSView hierarchy), so encoding the window's restorable state
// succeeds. AppKit still encodes the window frame and its persistent window-management
// identifier, which is what the Space restoration on relaunch keys off.
extern "C" fn window_state_archiver_will_encode_object(
    _this: &Object,
    _sel: Sel,
    _archiver: id,
    object: id,
) -> id {
    // SAFETY: `object` is whatever AppKit hands the delegate during archiving; we only send it
    // `isKindOfClass:` with valid class arguments, which is safe for any Objective-C object.
    unsafe {
        if object.is_null() {
            return object;
        }
        let is_view: BOOL = msg_send![object, isKindOfClass: class!(NSView)];
        let is_window: BOOL = msg_send![object, isKindOfClass: class!(NSWindow)];
        if is_view == YES || is_window == YES {
            nil
        } else {
            object
        }
    }
}

// Override of the private `_windowRestorationOptions` on our NSKeyedUnarchiver subclass.
// Returning a default-initialized `NSWindowRestorationOptions` tells AppKit to restore the
// window to its original Space. This is the macOS 15+ path (FB15644170: the
// `NSWindowRestoresWorkspaceAtLaunch` user default no longer works there).
extern "C" fn window_state_unarchiver_restoration_options(_this: &Object, _sel: Sel) -> id {
    if !is_macos_version_at_least(NSOperatingSystemVersion::new(15, 0, 0)) {
        return nil;
    }
    // SAFETY: we look the class up by name and only send it `alloc`/`init`/`autorelease`, all of
    // which have the standard `-> id` signature. Returning `nil` when the class is absent is valid.
    unsafe {
        match Class::get("NSWindowRestorationOptions") {
            Some(class) => {
                let options: id = msg_send![class, alloc];
                let options: id = msg_send![options, init];
                msg_send![options, autorelease]
            }
            None => nil,
        }
    }
}

pub(crate) fn convert_mouse_position(
    position: NSPoint,
    native_view: id,
    view_height: Pixels,
) -> Point<Pixels> {
    unsafe { native_window_point_to_gpui(native_view, position, view_height) }
}

/// Stores the cursor style on the active GPUI window and invalidates its cursor rects.
///
/// # Safety
///
/// This function is not thread safe. Callers must ensure this is called on the AppKit main
/// thread because it reads the active AppKit window and updates GPUI window state associated
/// with Objective-C objects.
pub(crate) unsafe fn set_active_window_cursor_style(style: CursorStyle) {
    // SAFETY: The caller guarantees AppKit main-thread access. `is_gpui_window` ensures the
    // window has our WINDOW_STATE_IVAR before reading it.
    unsafe {
        let app = NSApplication::sharedApplication(nil);
        let key_window: id = msg_send![app, keyWindow];
        let main_window: id = msg_send![app, mainWindow];
        let active_window = if !key_window.is_null() && is_gpui_window(key_window) {
            Some(key_window)
        } else if !main_window.is_null() && is_gpui_window(main_window) {
            Some(main_window)
        } else {
            None
        };

        let Some(active_window) = active_window else {
            return;
        };

        let window_state = get_window_state(&*active_window);
        let mut window_state = window_state.lock();
        if window_state.cursor_style != style {
            window_state.cursor_style = style;
            let _: () = msg_send![
                window_state.native_window,
                invalidateCursorRectsForView: window_state.native_view.as_ptr()
            ];
        }
    }
}

unsafe fn build_window_class(name: &'static str, superclass: &Class) -> *const Class {
    unsafe {
        let mut decl = ClassDecl::new(name, superclass).unwrap();
        decl.add_ivar::<*mut c_void>(WINDOW_STATE_IVAR);
        decl.add_method(sel!(dealloc), dealloc_window as extern "C" fn(&Object, Sel));

        decl.add_method(
            sel!(canBecomeMainWindow),
            yes as extern "C" fn(&Object, Sel) -> BOOL,
        );
        decl.add_method(
            sel!(canBecomeKeyWindow),
            yes as extern "C" fn(&Object, Sel) -> BOOL,
        );
        decl.add_method(
            sel!(windowDidResize:),
            window_did_resize as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowDidChangeOcclusionState:),
            window_did_change_occlusion_state as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(fullscreenToolbarWindowDidChange:),
            fullscreen_toolbar_window_did_change as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowWillEnterFullScreen:),
            window_will_enter_fullscreen as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowDidEnterFullScreen:),
            window_did_enter_fullscreen as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowDidFailToEnterFullScreen:),
            window_did_fail_to_enter_fullscreen as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowWillExitFullScreen:),
            window_will_exit_fullscreen as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowDidFailToExitFullScreen:),
            window_did_fail_to_exit_fullscreen as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowDidExitFullScreen:),
            window_did_exit_fullscreen as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowDidMove:),
            window_did_move as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowDidChangeScreen:),
            window_did_change_screen as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowDidBecomeKey:),
            window_did_change_key_status as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowDidResignKey:),
            window_did_change_key_status as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(windowShouldClose:),
            window_should_close as extern "C" fn(&Object, Sel, id) -> BOOL,
        );
        decl.add_method(
            sel!(window:willUseFullScreenPresentationOptions:),
            window_will_use_full_screen_presentation_options
                as extern "C" fn(&Object, Sel, id, NSUInteger) -> NSUInteger,
        );
        decl.add_method(
            sel!(observeValueForKeyPath:ofObject:change:context:),
            observe_value_for_key_path as extern "C" fn(&Object, Sel, id, id, id, *mut c_void),
        );

        decl.add_method(sel!(close), close_window as extern "C" fn(&Object, Sel));

        decl.add_method(
            sel!(draggingEntered:),
            dragging_entered as extern "C" fn(&Object, Sel, id) -> NSDragOperation,
        );
        decl.add_method(
            sel!(draggingUpdated:),
            dragging_updated as extern "C" fn(&Object, Sel, id) -> NSDragOperation,
        );
        decl.add_method(
            sel!(draggingExited:),
            dragging_exited as extern "C" fn(&Object, Sel, id),
        );
        decl.add_method(
            sel!(performDragOperation:),
            perform_drag_operation as extern "C" fn(&Object, Sel, id) -> BOOL,
        );
        decl.add_method(
            sel!(concludeDragOperation:),
            conclude_drag_operation as extern "C" fn(&Object, Sel, id),
        );

        decl.add_protocol(Protocol::get("NSDraggingSource").unwrap());
        decl.add_method(
            sel!(draggingSession:sourceOperationMaskForDraggingContext:),
            dragging_session_source_operation_mask
                as extern "C" fn(&Object, Sel, id, NSInteger) -> NSDragOperation,
        );
        decl.add_method(
            sel!(draggingSession:endedAtPoint:operation:),
            dragging_session_ended as extern "C" fn(&Object, Sel, id, NSPoint, NSDragOperation),
        );

        decl.add_method(
            sel!(addTitlebarAccessoryViewController:),
            add_titlebar_accessory_view_controller as extern "C" fn(&Object, Sel, id),
        );

        decl.add_method(
            sel!(moveTabToNewWindow:),
            move_tab_to_new_window as extern "C" fn(&Object, Sel, id),
        );

        decl.add_method(
            sel!(mergeAllWindows:),
            merge_all_windows as extern "C" fn(&Object, Sel, id),
        );

        decl.add_method(
            sel!(selectNextTab:),
            select_next_tab as extern "C" fn(&Object, Sel, id),
        );

        decl.add_method(
            sel!(selectPreviousTab:),
            select_previous_tab as extern "C" fn(&Object, Sel, id),
        );

        decl.add_method(
            sel!(toggleTabBar:),
            toggle_tab_bar as extern "C" fn(&Object, Sel, id),
        );

        decl.register()
    }
}

#[derive(Clone, Copy)]
struct TrafficLightFrames {
    titlebar: Objc2NSRect,
    close: Objc2NSRect,
    minimize: Objc2NSRect,
    zoom: Objc2NSRect,
}

struct TrafficLightButtons {
    close: Retained<Objc2NSButton>,
    minimize: Retained<Objc2NSButton>,
    zoom: Retained<Objc2NSButton>,
}

struct FullscreenAuxiliaryChromeSnapshot {
    window: Retained<Objc2NSWindow>,
    titlebar_container: Retained<Objc2NSView>,
    is_opaque: bool,
    background_color: Retained<Objc2NSColor>,
    titlebar_appears_transparent: Option<bool>,
    has_shadow: bool,
    ignores_mouse_events: bool,
    titlebar_container_is_hidden: bool,
}

impl FullscreenAuxiliaryChromeSnapshot {
    fn new(
        window: Retained<Objc2NSWindow>,
        titlebar_container: Retained<Objc2NSView>,
    ) -> Self {
        Self {
            is_opaque: window.isOpaque(),
            background_color: window.backgroundColor(),
            // AppKit's fullscreen auxiliary window can be borderless. Only
            // titled windows support titlebar-specific state.
            titlebar_appears_transparent: window
                .styleMask()
                .contains(Objc2NSWindowStyleMask::Titled)
                .then(|| window.titlebarAppearsTransparent()),
            has_shadow: window.hasShadow(),
            ignores_mouse_events: window.ignoresMouseEvents(),
            titlebar_container_is_hidden: titlebar_container.isHidden(),
            window,
            titlebar_container,
        }
    }

    fn apply_and_verify(&self) -> bool {
        if self.is_applied() {
            return true;
        }

        let clear = Objc2NSColor::clearColor();
        if self.window.isOpaque() {
            self.window.setOpaque(false);
        }
        if self.window.backgroundColor() != clear {
            self.window.setBackgroundColor(Some(&clear));
        }
        if self.titlebar_appears_transparent.is_some()
            && self.window.styleMask().contains(Objc2NSWindowStyleMask::Titled)
            && !self.window.titlebarAppearsTransparent()
        {
            self.window.setTitlebarAppearsTransparent(true);
        }
        if self.window.hasShadow() {
            self.window.setHasShadow(false);
        }
        if !self.window.ignoresMouseEvents() {
            self.window.setIgnoresMouseEvents(true);
        }
        if !self.titlebar_container.isHidden() {
            self.titlebar_container.setHidden(true);
        }
        self.is_applied()
    }

    fn is_applied(&self) -> bool {
        !self.window.isOpaque()
            && self.window.backgroundColor() == Objc2NSColor::clearColor()
            && (self.titlebar_appears_transparent.is_none()
                || !self.window.styleMask().contains(Objc2NSWindowStyleMask::Titled)
                || self.window.titlebarAppearsTransparent())
            && !self.window.hasShadow()
            && self.window.ignoresMouseEvents()
            && self.titlebar_container.isHidden()
    }

    fn restore(&self) {
        self.window
            .setBackgroundColor(Some(&self.background_color));
        if let Some(transparent) = self.titlebar_appears_transparent
            && self.window.styleMask().contains(Objc2NSWindowStyleMask::Titled)
        {
            self.window.setTitlebarAppearsTransparent(transparent);
        }
        self.window.setOpaque(self.is_opaque);
        self.window.setHasShadow(self.has_shadow);
        self.window
            .setIgnoresMouseEvents(self.ignores_mouse_events);
        self.titlebar_container
            .setHidden(self.titlebar_container_is_hidden);
    }
}

struct FullscreenTrafficLightOverlay {
    button_container: Retained<Objc2NSView>,
    titlebar_container: Retained<Objc2NSView>,
    toolbar_window: Option<Retained<Objc2NSWindow>>,
    suppressed_auxiliary_chrome: Option<FullscreenAuxiliaryChromeSnapshot>,
    closed_toolbar_window: Option<usize>,
    host_view: Retained<Objc2NSView>,
    buttons: TrafficLightButtons,
    frames: TrafficLightFrames,
    button_padding: f64,
}

#[derive(Clone, Copy)]
struct FullscreenTrafficLightLayout {
    host_frame: Objc2NSRect,
    close_origin: Objc2NSPoint,
    minimize_origin: Objc2NSPoint,
    zoom_origin: Objc2NSPoint,
}

fn fullscreen_traffic_light_layout(
    bounds: Objc2NSRect,
    bounds_is_flipped: bool,
    host_is_flipped: bool,
    frames: TrafficLightFrames,
    button_padding: f64,
    padding_x: f64,
    padding_y: f64,
) -> Option<FullscreenTrafficLightLayout> {
    let button_frames = [frames.close, frames.minimize, frames.zoom];
    let button_width = frames.close.size.width;
    let button_height = frames.close.size.height;
    if !button_width.is_finite()
        || button_width <= 0.0
        || !button_height.is_finite()
        || button_height <= 0.0
        || !button_padding.is_finite()
        || button_padding <= 0.0
        || !padding_x.is_finite()
        || padding_x < 0.0
        || !padding_y.is_finite()
        || padding_y < 0.0
        || button_frames.iter().any(|frame| {
            !frame.origin.x.is_finite()
                || !frame.origin.y.is_finite()
                || !frame.size.width.is_finite()
                || frame.size.width <= 0.0
                || !frame.size.height.is_finite()
                || frame.size.height <= 0.0
        })
    {
        return None;
    }

    let close_x = padding_x;
    let minimize_x = close_x + button_width + button_padding;
    let zoom_x = minimize_x + button_width + button_padding;
    let row_width = zoom_x + button_width + padding_x;
    let original_right = button_frames
        .iter()
        .map(|frame| frame.origin.x + frame.size.width)
        .fold(0.0_f64, f64::max);
    let host_width = row_width.max(original_right + padding_x);

    // AppKit may restore a standard button's original titlebar-local frame after
    // reparenting. Give that small native row enough room to stay near the top
    // when the content view resizes, rather than parenting the buttons directly
    // to the full-height content view.
    let original_bottom = button_frames
        .iter()
        .map(|frame| frame.origin.y + frame.size.height)
        .fold(0.0_f64, f64::max);
    let host_height = (button_height + padding_y * 2.0).max(original_bottom + padding_y);

    let host_origin_y = if bounds_is_flipped {
        bounds.origin.y
    } else {
        bounds.origin.y + bounds.size.height - host_height
    };
    let button_y = if host_is_flipped {
        padding_y
    } else {
        host_height - button_height - padding_y
    };

    let values = [
        bounds.origin.x,
        host_origin_y,
        host_width,
        host_height,
        close_x,
        minimize_x,
        zoom_x,
        button_y,
    ];
    if values.iter().any(|value| !value.is_finite()) || host_width <= 0.0 || host_height <= 0.0 {
        return None;
    }

    Some(FullscreenTrafficLightLayout {
        host_frame: Objc2NSRect::new(
            Objc2NSPoint::new(bounds.origin.x, host_origin_y),
            Objc2NSSize::new(host_width, host_height),
        ),
        close_origin: Objc2NSPoint::new(close_x, button_y),
        minimize_origin: Objc2NSPoint::new(minimize_x, button_y),
        zoom_origin: Objc2NSPoint::new(zoom_x, button_y),
    })
}

// `NSApplicationPresentationOptions` bits (see `NSApplication.PresentationOptions`).
const NS_APPLICATION_PRESENTATION_AUTO_HIDE_DOCK: NSUInteger = 1 << 0;
const NS_APPLICATION_PRESENTATION_AUTO_HIDE_MENU_BAR: NSUInteger = 1 << 2;

// State captured when entering simple (borderless) fullscreen, used to restore
// the window on exit.
struct SimpleFullscreenState {
    frame: NSRect,
    bounds: Bounds<Pixels>,
    style_mask: NSWindowStyleMask,
}

enum SimpleFullscreenPlan {
    Enter { screen_frame: NSRect },
    Exit(SimpleFullscreenState),
}

struct SimpleFullscreenAppState {
    window_count: usize,
    saved_presentation_options: NSUInteger,
}

static SIMPLE_FULLSCREEN_APP_STATE: Mutex<Option<SimpleFullscreenAppState>> = Mutex::new(None);

unsafe fn push_simple_fullscreen_presentation_options() {
    let mut app_state = SIMPLE_FULLSCREEN_APP_STATE.lock();
    match app_state.as_mut() {
        Some(app_state) => app_state.window_count += 1,
        None => unsafe {
            let app = NSApplication::sharedApplication(nil);
            let saved_presentation_options: NSUInteger = msg_send![app, presentationOptions];
            let _: () = msg_send![
                app,
                setPresentationOptions: NS_APPLICATION_PRESENTATION_AUTO_HIDE_DOCK
                    | NS_APPLICATION_PRESENTATION_AUTO_HIDE_MENU_BAR
            ];
            *app_state = Some(SimpleFullscreenAppState {
                window_count: 1,
                saved_presentation_options,
            });
        },
    }
}

unsafe fn pop_simple_fullscreen_presentation_options() {
    let mut app_state = SIMPLE_FULLSCREEN_APP_STATE.lock();
    if let Some(state) = app_state.as_mut() {
        state.window_count = state.window_count.saturating_sub(1);
        if state.window_count == 0 {
            unsafe {
                let app = NSApplication::sharedApplication(nil);
                let _: () = msg_send![
                    app,
                    setPresentationOptions: state.saved_presentation_options
                ];
            }
            *app_state = None;
        }
    }
}

unsafe fn apply_simple_fullscreen_plan(
    native_window: id,
    native_view: id,
    plan: SimpleFullscreenPlan,
) {
    unsafe {
        match plan {
            SimpleFullscreenPlan::Exit(saved) => {
                pop_simple_fullscreen_presentation_options();
                native_window.setStyleMask_(saved.style_mask);
                native_window.setFrame_display_(saved.frame, YES);
            }
            SimpleFullscreenPlan::Enter { screen_frame } => {
                push_simple_fullscreen_presentation_options();
                native_window.setStyleMask_(NSWindowStyleMask::NSBorderlessWindowMask);
                native_window.setFrame_display_(screen_frame, YES);
            }
        }

        // Changing the style mask makes AppKit resign the window's key status and
        // first responder, so keyboard input stops reaching the editor. Re-make the
        // window key and restore the GPUI view as first responder.
        native_window.makeKeyAndOrderFront_(nil);
        native_window.makeFirstResponder_(native_view);
    }
}

type ResizeCallback = Box<dyn FnMut(Size<Pixels>, f32)>;

struct MacWindowState {
    handle: AnyWindowHandle,
    foreground_executor: ForegroundExecutor,
    background_executor: BackgroundExecutor,
    native_window: id,
    native_view: NonNull<Object>,
    blurred_view: Option<id>,
    background_appearance: WindowBackgroundAppearance,
    cursor_style: CursorStyle,
    cursor_visible: Arc<AtomicBool>,
    frame_source: Option<WindowFrameSource>,
    renderer: renderer::Renderer,
    request_frame_callback: Option<Box<dyn FnMut(RequestFrameOptions)>>,
    event_callback: Option<Box<dyn FnMut(PlatformInput) -> gpui::DispatchEventResult>>,
    activate_callback: Option<Box<dyn FnMut(bool)>>,
    visibility_callback: Option<Box<dyn FnMut(WindowVisibility)>>,
    // `None` until a callback is registered, so notifications during
    // construction are not queued for delivery to a callback registered later.
    last_visibility: Option<WindowVisibility>,
    resize_callback: Option<ResizeCallback>,
    moved_callback: Option<Box<dyn FnMut()>>,
    display_changed_callback: Option<Box<dyn FnMut()>>,
    should_close_callback: Option<Box<dyn FnMut() -> bool>>,
    close_callback: Option<Box<dyn FnOnce()>>,
    appearance_changed_callback: Option<Box<dyn FnMut()>>,
    input_handler: Option<PlatformInputHandler>,
    last_key_equivalent: Option<KeyDownEvent>,
    last_left_mouse_down_event: Option<Retained<Objc2Object>>,
    synthetic_drag_counter: usize,
    traffic_light_position: Option<Point<Pixels>>,
    traffic_light_frames: Option<TrafficLightFrames>,
    pre_fullscreen_traffic_light_frames: Option<TrafficLightFrames>,
    fullscreen_traffic_light_overlay: Option<FullscreenTrafficLightOverlay>,
    fullscreen_controls_active: bool,
    content_layout_rect_observer_registered: bool,
    transparent_titlebar: bool,
    previous_modifiers_changed_event: Option<PlatformInput>,
    keystroke_for_do_command: Option<Keystroke>,
    do_command_handled: Option<bool>,
    external_files_dragged: bool,
    // Whether the next left-mouse click is also the focusing click.
    first_mouse: bool,
    // When true, the whole content view is reported as app-owned titlebar content via
    // `_opaqueRectForWindowMoveWhenInTitlebar`, so AppKit does not drag the window from
    // the titlebar or delay titlebar clicks (a delay first observed on macOS 27). Such
    // windows draw their own titlebar and move the window via `start_window_move`.
    app_owns_titlebar_drag: bool,
    fullscreen_restore_bounds: Bounds<Pixels>,
    is_exiting_fullscreen: bool,
    simple_fullscreen_state: Option<SimpleFullscreenState>,
    move_tab_to_new_window_callback: Option<Box<dyn FnMut()>>,
    merge_all_windows_callback: Option<Box<dyn FnMut()>>,
    select_next_tab_callback: Option<Box<dyn FnMut()>>,
    select_previous_tab_callback: Option<Box<dyn FnMut()>>,
    toggle_tab_bar_callback: Option<Box<dyn FnMut()>>,
    activated_least_once: bool,
    closed: Arc<AtomicBool>,
    accesskit_adapter: Option<accesskit_macos::SubclassingAdapter>,
    // The parent window if this window is a sheet (Dialog kind)
    sheet_parent: Option<id>,
}

impl MacWindowState {
    fn move_traffic_light(&mut self) {
        if let Some(traffic_light_position) = self.traffic_light_position {
            if self.fullscreen_controls_active {
                self.update_fullscreen_traffic_lights();
                return;
            }

            if self.is_fullscreen() && !self.is_exiting_fullscreen {
                self.restore_traffic_light();
                return;
            }

            if self.traffic_light_frames.is_none() {
                self.traffic_light_frames = self.capture_traffic_light_frames();
            }

            if self.traffic_light_frames.is_some() {
                // AppKit can recreate standard buttons, so fetch the live views for each layout pass.
                let Some(buttons) = self.traffic_light_buttons() else {
                    return;
                };
                let Some(titlebar_container) = Self::titlebar_container(&buttons.close) else {
                    return;
                };
                // The titlebar container is positioned in its superview's
                // coordinate space, which can have a different height from
                // the outer NSWindow frame after zooming or display changes.
                let Some(titlebar_superview) = (unsafe { titlebar_container.superview() }) else {
                    return;
                };

                let close_frame = buttons.close.frame();
                let minimize_frame = buttons.minimize.frame();
                let button_width = Pixels::from(close_frame.size.width);
                let button_height = Pixels::from(close_frame.size.height);
                let button_padding = Pixels::from(
                    minimize_frame.origin.x - close_frame.origin.x - close_frame.size.width,
                );
                let container_height =
                    button_height + traffic_light_position.y + traffic_light_position.y;

                let mut titlebar_frame = titlebar_container.frame();
                titlebar_frame.size.height = container_height.to_f64();
                let superview_bounds = titlebar_superview.bounds();
                titlebar_frame.origin.y = if titlebar_superview.isFlipped() {
                    superview_bounds.origin.y
                } else {
                    superview_bounds.origin.y + superview_bounds.size.height
                        - container_height.to_f64()
                };

                let minimize_x = traffic_light_position.x + button_width + button_padding;
                let zoom_x = minimize_x + button_width + button_padding;

                titlebar_container.setFrame(titlebar_frame);
                buttons.close.setFrameOrigin(Objc2NSPoint::new(
                    traffic_light_position.x.to_f64(),
                    traffic_light_position.y.to_f64(),
                ));
                buttons.minimize.setFrameOrigin(Objc2NSPoint::new(
                    minimize_x.to_f64(),
                    traffic_light_position.y.to_f64(),
                ));
                buttons.zoom.setFrameOrigin(Objc2NSPoint::new(
                    zoom_x.to_f64(),
                    traffic_light_position.y.to_f64(),
                ));

                titlebar_container.updateTrackingAreas();
                buttons.close.updateTrackingAreas();
                buttons.minimize.updateTrackingAreas();
                buttons.zoom.updateTrackingAreas();
            }
        }
    }

    fn capture_traffic_light_frames(&self) -> Option<TrafficLightFrames> {
        let buttons = self.traffic_light_buttons()?;
        let titlebar_container = Self::titlebar_container(&buttons.close)?;

        Some(TrafficLightFrames {
            titlebar: titlebar_container.frame(),
            close: buttons.close.frame(),
            minimize: buttons.minimize.frame(),
            zoom: buttons.zoom.frame(),
        })
    }

    fn native_window(&self) -> &Objc2NSWindow {
        // SAFETY: `MacWindow::new` initializes `self.native_window` with the AppKit
        // window for this state. It is either `NSWindow` or `NSPanel`, so borrowing it
        // as `Objc2NSWindow` is valid here.
        unsafe { &*self.native_window.cast::<Objc2NSWindow>() }
    }

    fn traffic_light_buttons(&self) -> Option<TrafficLightButtons> {
        let window = self.native_window();
        Some(TrafficLightButtons {
            close: window.standardWindowButton(Objc2NSWindowButton::CloseButton)?,
            minimize: window.standardWindowButton(Objc2NSWindowButton::MiniaturizeButton)?,
            zoom: window.standardWindowButton(Objc2NSWindowButton::ZoomButton)?,
        })
    }

    fn titlebar_container(close_button: &Objc2NSButton) -> Option<Retained<Objc2NSView>> {
        // SAFETY: `close_button` comes from AppKit's `standardWindowButton(_:)`.
        // Although `superview` is unsafe, objc2 returns each result as `Retained<NSView>`.
        unsafe {
            let button_container = close_button.superview()?;
            button_container.superview()
        }
    }

    fn restore_traffic_light(&mut self) {
        if let Some(frames) = self.traffic_light_frames.take() {
            let Some(buttons) = self.traffic_light_buttons() else {
                return;
            };
            let Some(titlebar_container) = Self::titlebar_container(&buttons.close) else {
                return;
            };

            buttons.close.setFrame(frames.close);
            buttons.minimize.setFrame(frames.minimize);
            buttons.zoom.setFrame(frames.zoom);
            titlebar_container.setFrame(frames.titlebar);

            titlebar_container.updateTrackingAreas();
            buttons.close.updateTrackingAreas();
            buttons.minimize.updateTrackingAreas();
            buttons.zoom.updateTrackingAreas();
        }
    }

    fn update_fullscreen_traffic_lights(&mut self) {
        // Windows without the custom titlebar keep AppKit's native hierarchy and layout.
        if self.traffic_light_position.is_none() {
            return;
        }

        let live_buttons = self.traffic_light_buttons();
        let replace_overlay = self
            .fullscreen_traffic_light_overlay
            .as_ref()
            .zip(live_buttons.as_ref())
            .is_some_and(|(overlay, buttons)| {
                Retained::as_ptr(&overlay.buttons.close) != Retained::as_ptr(&buttons.close)
                    || Retained::as_ptr(&overlay.buttons.minimize)
                        != Retained::as_ptr(&buttons.minimize)
                    || Retained::as_ptr(&overlay.buttons.zoom) != Retained::as_ptr(&buttons.zoom)
            });

        if replace_overlay {
            self.discard_fullscreen_traffic_light_overlay();
        }

        if self.fullscreen_traffic_light_overlay.is_none() {
            let Some(buttons) = live_buttons else {
                return;
            };
            self.install_fullscreen_traffic_light_overlay(buttons);
        }

        self.position_fullscreen_traffic_lights();
    }

    fn install_fullscreen_traffic_light_overlay(&mut self, buttons: TrafficLightButtons) {
        let Some(button_container) = (unsafe { buttons.close.superview() }) else {
            return;
        };
        let Some(titlebar_container) = (unsafe { button_container.superview() }) else {
            return;
        };

        let frames = TrafficLightFrames {
            titlebar: titlebar_container.frame(),
            close: buttons.close.frame(),
            minimize: buttons.minimize.frame(),
            zoom: buttons.zoom.frame(),
        };
        let button_width = frames.close.size.width;
        let button_height = frames.close.size.height;
        let button_padding = frames.minimize.origin.x - frames.close.origin.x - button_width;
        let button_frames_are_valid = [&frames.close, &frames.minimize, &frames.zoom]
            .into_iter()
            .all(|frame| {
                frame.origin.x.is_finite()
                    && frame.origin.y.is_finite()
                    && frame.size.width.is_finite()
                    && frame.size.width > 0.0
                    && frame.size.height.is_finite()
                    && frame.size.height > 0.0
            });
        if !button_frames_are_valid || !button_padding.is_finite() || button_padding <= 0.0 {
            // AppKit can report zero-sized controls before the first native layout pass.
            return;
        }

        let Some(content_view) = (unsafe { self.native_window().contentView() }) else {
            return;
        };
        let Some(position) = self.traffic_light_position else {
            return;
        };
        // The renderer view is inset below AppKit's auxiliary fullscreen
        // toolbar while visible. Keep the native controls on that same row.
        let bounds: Objc2NSRect = unsafe { msg_send![self.native_view.as_ptr() as id, frame] };
        // A plain AppKit NSView uses an unflipped local coordinate system.
        let initial_layout = fullscreen_traffic_light_layout(
            bounds,
            content_view.isFlipped(),
            false,
            frames,
            button_padding,
            position.x.to_f64(),
            position.y.to_f64(),
        );
        let Some(initial_layout) = initial_layout else {
            return;
        };

        // The host is deliberately only a small traffic-light row. AppKit may
        // restore the buttons' titlebar-local y coordinates after a focus or
        // fullscreen layout pass; within this row those coordinates remain at
        // the top edge instead of becoming bottom-edge coordinates in the
        // full-height content view.
        // SAFETY: fullscreen overlay installation is only called from AppKit's
        // main-thread window callbacks.
        let main_thread = unsafe { MainThreadMarker::new_unchecked() };
        let host_view =
            Objc2NSView::initWithFrame(Objc2NSView::alloc(main_thread), initial_layout.host_frame);
        let flexible_bottom_margin = if content_view.isFlipped() {
            NSAutoresizingMaskOptions::ViewMaxYMargin
        } else {
            NSAutoresizingMaskOptions::ViewMinYMargin
        };
        host_view.setAutoresizingMask(
            NSAutoresizingMaskOptions::ViewMaxXMargin | flexible_bottom_margin,
        );

        self.fullscreen_traffic_light_overlay = Some(FullscreenTrafficLightOverlay {
            button_container,
            titlebar_container,
            toolbar_window: None,
            suppressed_auxiliary_chrome: None,
            closed_toolbar_window: None,
            host_view,
            buttons,
            frames,
            button_padding,
        });

        let overlay = self.fullscreen_traffic_light_overlay.as_ref().unwrap();
        let host = Retained::as_ptr(&overlay.host_view) as id;
        let native_view = self.native_view.as_ptr() as id;
        unsafe {
            let _: () = msg_send![
                Retained::as_ptr(&content_view) as id,
                addSubview: host
                positioned: NSWindowOrderingMode::NSWindowAbove
                relativeTo: native_view
            ];
            for button in [
                Retained::as_ptr(&overlay.buttons.close) as id,
                Retained::as_ptr(&overlay.buttons.minimize) as id,
                Retained::as_ptr(&overlay.buttons.zoom) as id,
            ] {
                let _: () = msg_send![button, removeFromSuperview];
                let _: () = msg_send![
                    host,
                    addSubview: button
                    positioned: NSWindowOrderingMode::NSWindowAbove
                    relativeTo: nil
                ];
                let _: () = msg_send![button, setHidden: NO];
                let _: () = msg_send![button, setAlphaValue: 1.0f64];
            }
        }
    }

    fn position_fullscreen_traffic_lights(&self) {
        let Some(position) = self.traffic_light_position else {
            return;
        };
        let Some(overlay) = self.fullscreen_traffic_light_overlay.as_ref() else {
            return;
        };

        let Some(content_view) = (unsafe { self.native_window().contentView() }) else {
            return;
        };
        let host = Retained::as_ptr(&overlay.host_view) as id;
        let host_is_in_content_view =
            unsafe { overlay.host_view.superview() }.is_some_and(|superview| {
                Retained::as_ptr(&superview) == Retained::as_ptr(&content_view)
            });
        if !host_is_in_content_view {
            unsafe {
                let _: () = msg_send![host, removeFromSuperview];
                let _: () = msg_send![
                    Retained::as_ptr(&content_view) as id,
                    addSubview: host
                    positioned: NSWindowOrderingMode::NSWindowAbove
                    relativeTo: self.native_view.as_ptr() as id
                ];
            }
        }

        for button in [
            &overlay.buttons.close,
            &overlay.buttons.minimize,
            &overlay.buttons.zoom,
        ] {
            let already_in_host = unsafe { button.superview() }.is_some_and(|superview| {
                Retained::as_ptr(&superview) == Retained::as_ptr(&overlay.host_view)
            });
            if !already_in_host {
                let button = Retained::as_ptr(button) as id;
                unsafe {
                    let _: () = msg_send![button, removeFromSuperview];
                    let _: () = msg_send![
                        host,
                        addSubview: button
                        positioned: NSWindowOrderingMode::NSWindowAbove
                        relativeTo: nil
                    ];
                }
            }
        }
        let Some(layout) = fullscreen_traffic_light_layout(
            // The host is a content-view child, so use the renderer's frame in
            // content-view coordinates rather than the full content bounds.
            unsafe { msg_send![self.native_view.as_ptr() as id, frame] },
            content_view.isFlipped(),
            overlay.host_view.isFlipped(),
            overlay.frames,
            overlay.button_padding,
            position.x.to_f64(),
            position.y.to_f64(),
        ) else {
            return;
        };
        overlay.host_view.setFrame(layout.host_frame);
        overlay.host_view.setAutoresizingMask(
            NSAutoresizingMaskOptions::ViewMaxXMargin
                | if content_view.isFlipped() {
                    NSAutoresizingMaskOptions::ViewMaxYMargin
                } else {
                    NSAutoresizingMaskOptions::ViewMinYMargin
                },
        );

        overlay.buttons.close.setFrameOrigin(layout.close_origin);
        overlay
            .buttons
            .minimize
            .setFrameOrigin(layout.minimize_origin);
        overlay.buttons.zoom.setFrameOrigin(layout.zoom_origin);

        unsafe {
            for button in [
                Retained::as_ptr(&overlay.buttons.close) as id,
                Retained::as_ptr(&overlay.buttons.minimize) as id,
                Retained::as_ptr(&overlay.buttons.zoom) as id,
            ] {
                let _: () = msg_send![button, setHidden: NO];
                let _: () = msg_send![button, setAlphaValue: 1.0f64];
            }
        }
        overlay.host_view.updateTrackingAreas();
        overlay.buttons.close.updateTrackingAreas();
        overlay.buttons.minimize.updateTrackingAreas();
        overlay.buttons.zoom.updateTrackingAreas();
    }

    fn discard_fullscreen_traffic_light_overlay(&mut self) {
        self.remove_fullscreen_toolbar_window_observer();
        let Some(overlay) = self.fullscreen_traffic_light_overlay.take() else {
            return;
        };
        unsafe {
            for button in [
                Retained::as_ptr(&overlay.buttons.close) as id,
                Retained::as_ptr(&overlay.buttons.minimize) as id,
                Retained::as_ptr(&overlay.buttons.zoom) as id,
            ] {
                let _: () = msg_send![button, removeFromSuperview];
            }
            let _: () = msg_send![
                Retained::as_ptr(&overlay.host_view) as id,
                removeFromSuperview
            ];
        }
    }

    fn restore_fullscreen_traffic_lights(&mut self) {
        self.remove_fullscreen_toolbar_window_observer();
        let Some(overlay) = self.fullscreen_traffic_light_overlay.take() else {
            return;
        };

        let button_container = Retained::as_ptr(&overlay.button_container) as id;
        unsafe {
            for button in [
                Retained::as_ptr(&overlay.buttons.close) as id,
                Retained::as_ptr(&overlay.buttons.minimize) as id,
                Retained::as_ptr(&overlay.buttons.zoom) as id,
            ] {
                let _: () = msg_send![button, removeFromSuperview];
                let _: () = msg_send![
                    button_container,
                    addSubview: button
                    positioned: NSWindowOrderingMode::NSWindowAbove
                    relativeTo: nil
                ];
                let _: () = msg_send![button, setHidden: NO];
                let _: () = msg_send![button, setAlphaValue: 1.0f64];
            }
            let _: () = msg_send![
                Retained::as_ptr(&overlay.host_view) as id,
                removeFromSuperview
            ];
        }

        overlay.buttons.close.setFrame(overlay.frames.close);
        overlay.buttons.minimize.setFrame(overlay.frames.minimize);
        overlay.buttons.zoom.setFrame(overlay.frames.zoom);
        overlay.titlebar_container.setFrame(overlay.frames.titlebar);

        overlay.titlebar_container.updateTrackingAreas();
        overlay.button_container.updateTrackingAreas();
        overlay.buttons.close.updateTrackingAreas();
        overlay.buttons.minimize.updateTrackingAreas();
        overlay.buttons.zoom.updateTrackingAreas();
    }

    fn refresh_fullscreen_toolbar_window_observer(&mut self) {
        let (candidate, current_ptr, closed_toolbar_window) = {
            let Some(overlay) = self.fullscreen_traffic_light_overlay.as_ref() else {
                return;
            };
            let candidate = overlay.titlebar_container.window();
            let candidate =
                candidate.filter(|window| Retained::as_ptr(window) as id != self.native_window);
            let current_ptr = overlay
                .toolbar_window
                .as_ref()
                .map(|window| Retained::as_ptr(window));
            (candidate, current_ptr, overlay.closed_toolbar_window)
        };
        let candidate_ptr = candidate.as_ref().map(|window| Retained::as_ptr(window));
        if candidate_ptr.is_none() {
            if let Some(overlay) = self.fullscreen_traffic_light_overlay.as_mut() {
                overlay.closed_toolbar_window = None;
            }
        }
        if current_ptr == candidate_ptr {
            if let Some(candidate) = candidate.as_ref() {
                self.reconcile_fullscreen_auxiliary_chrome(candidate);
            } else {
                self.restore_suppressed_fullscreen_auxiliary_chrome();
            }
            return;
        }

        if candidate_ptr.map(|pointer| pointer as usize) == closed_toolbar_window {
            return;
        }
        if let Some(overlay) = self.fullscreen_traffic_light_overlay.as_mut() {
            overlay.closed_toolbar_window = None;
        }

        self.remove_fullscreen_toolbar_window_observer();
        let Some(candidate) = candidate else {
            return;
        };

        unsafe {
            let center: id = msg_send![class!(NSNotificationCenter), defaultCenter];
            let observer = self.native_window;
            let toolbar_window = Retained::as_ptr(&candidate) as id;
            for name in [
                "NSWindowDidMoveNotification",
                "NSWindowDidResizeNotification",
                "NSWindowDidChangeOcclusionStateNotification",
                "NSWindowWillCloseNotification",
            ] {
                let name = ns_string(name);
                let _: () = msg_send![
                    center,
                    addObserver: observer
                    selector: sel!(fullscreenToolbarWindowDidChange:)
                    name: name
                    object: toolbar_window
                ];
            }
        }
        // This observes the public AppKit geometry/lifetime notifications. We
        // sample visibility and alpha with each update; alpha-only Reduce Motion
        // transitions without a corresponding notification remain unverified.
        if let Some(overlay) = self.fullscreen_traffic_light_overlay.as_mut() {
            overlay.toolbar_window = Some(candidate);
        }
        if let Some(candidate) = self
            .fullscreen_traffic_light_overlay
            .as_ref()
            .and_then(|overlay| overlay.toolbar_window.as_ref())
            .cloned()
        {
            self.reconcile_fullscreen_auxiliary_chrome(&candidate);
        }
    }

    fn mark_fullscreen_toolbar_window_closed(&mut self, closed_window: usize) {
        let matches_observed_window = self
            .fullscreen_traffic_light_overlay
            .as_ref()
            .and_then(|overlay| overlay.toolbar_window.as_ref())
            .map(|window| Retained::as_ptr(window) as usize == closed_window)
            .unwrap_or(false);
        if !matches_observed_window {
            return;
        }

        self.remove_fullscreen_toolbar_window_observer();
        if let Some(overlay) = self.fullscreen_traffic_light_overlay.as_mut() {
            overlay.closed_toolbar_window = Some(closed_window);
        }
    }

    fn remove_fullscreen_toolbar_window_observer(&mut self) {
        self.restore_suppressed_fullscreen_auxiliary_chrome();
        let Some(window) = self
            .fullscreen_traffic_light_overlay
            .as_mut()
            .and_then(|overlay| overlay.toolbar_window.take())
        else {
            return;
        };

        unsafe {
            let center: id = msg_send![class!(NSNotificationCenter), defaultCenter];
            let observer = self.native_window;
            let toolbar_window = Retained::as_ptr(&window) as id;
            for name in [
                "NSWindowDidMoveNotification",
                "NSWindowDidResizeNotification",
                "NSWindowDidChangeOcclusionStateNotification",
                "NSWindowWillCloseNotification",
            ] {
                let name = ns_string(name);
                let _: () = msg_send![
                    center,
                    removeObserver: observer
                    name: name
                    object: toolbar_window
                ];
            }
        }
    }

    fn reconcile_fullscreen_auxiliary_chrome(&mut self, candidate: &Retained<Objc2NSWindow>) {
        let eligible = self
            .fullscreen_traffic_light_overlay
            .as_ref()
            .is_some_and(|overlay| self.fullscreen_auxiliary_chrome_is_eligible(candidate, overlay));
        if !eligible {
            self.restore_suppressed_fullscreen_auxiliary_chrome();
            return;
        }

        let candidate_ptr = Retained::as_ptr(candidate);
        let snapshot_ptr = self
            .fullscreen_traffic_light_overlay
            .as_ref()
            .and_then(|overlay| overlay.suppressed_auxiliary_chrome.as_ref())
            .map(|snapshot| Retained::as_ptr(&snapshot.window));
        if snapshot_ptr.is_some_and(|pointer| pointer != candidate_ptr) {
            self.restore_suppressed_fullscreen_auxiliary_chrome();
        }

        if let Some(overlay) = self.fullscreen_traffic_light_overlay.as_mut()
            && overlay.suppressed_auxiliary_chrome.is_none()
        {
            overlay.suppressed_auxiliary_chrome = Some(FullscreenAuxiliaryChromeSnapshot::new(
                candidate.clone(),
                overlay.titlebar_container.clone(),
            ));
        }

        let applied = self
            .fullscreen_traffic_light_overlay
            .as_ref()
            .and_then(|overlay| overlay.suppressed_auxiliary_chrome.as_ref())
            .is_some_and(FullscreenAuxiliaryChromeSnapshot::apply_and_verify);
        if !applied {
            self.restore_suppressed_fullscreen_auxiliary_chrome();
        }
    }

    fn fullscreen_auxiliary_chrome_is_eligible(
        &self,
        candidate: &Retained<Objc2NSWindow>,
        overlay: &FullscreenTrafficLightOverlay,
    ) -> bool {
        let candidate_id = Retained::as_ptr(candidate) as id;
        let main_window_id = self.native_window;
        let Some(content_view) = self.native_window().contentView() else {
            return false;
        };
        let host_is_in_content_view = unsafe { overlay.host_view.superview() }.is_some_and(|view| {
            Retained::as_ptr(&view) == Retained::as_ptr(&content_view)
        });
        let buttons_are_hosted = host_is_in_content_view
            && !overlay.host_view.isHidden()
            && overlay.host_view.alphaValue() > 0.0
            && [&overlay.buttons.close, &overlay.buttons.minimize, &overlay.buttons.zoom]
                .into_iter()
                .all(|button| {
                    unsafe { button.superview() }.is_some_and(|view| {
                        Retained::as_ptr(&view) == Retained::as_ptr(&overlay.host_view)
                    }) && !button.isHidden()
                        && button.alphaValue() > 0.0
                });
        let titlebar_belongs_to_candidate = overlay
            .titlebar_container
            .window()
            .is_some_and(|window| Retained::as_ptr(&window) == Retained::as_ptr(candidate));
        let button_container_belongs_to_titlebar = unsafe {
            overlay.button_container.superview()
        }
        .is_some_and(|view| Retained::as_ptr(&view) == Retained::as_ptr(&overlay.titlebar_container));
        let saved_titlebar_hidden = overlay
            .suppressed_auxiliary_chrome
            .as_ref()
            .filter(|snapshot| Retained::as_ptr(&snapshot.window) == Retained::as_ptr(candidate))
            .map(|snapshot| snapshot.titlebar_container_is_hidden);
        let titlebar_container_is_visible = fullscreen_auxiliary_titlebar_container_is_eligible(
            overlay.titlebar_container.isHidden(),
            saved_titlebar_hidden,
        );

        let style_mask: NSWindowStyleMask = unsafe { msg_send![main_window_id, styleMask] };
        let custom_transparent_fullsize_titlebar = self.traffic_light_position.is_some()
            && self.transparent_titlebar
            && style_mask.contains(NSWindowStyleMask::NSTitledWindowMask)
            && style_mask.contains(NSWindowStyleMask::NSFullSizeContentViewWindowMask);
        // Do not query titlebar properties on unsupported main-window styles.
        if !custom_transparent_fullsize_titlebar {
            return false;
        }
        let no_native_toolbar_or_accessories = unsafe {
            !window_has_native_toolbar_or_accessories(main_window_id)
                && !window_has_native_toolbar_or_accessories(candidate_id)
        };
        // This is GPUI's explicitly custom titlebar. Keep any native title or
        // subtitle visible instead of treating it as empty auxiliary chrome.
        let no_native_title_or_subtitle = unsafe {
            let title_visibility: NSWindowTitleVisibility =
                msg_send![main_window_id, titleVisibility];
            let subtitle: id = msg_send![main_window_id, subtitle];
            let subtitle_length: NSUInteger = if subtitle.is_null() {
                0
            } else {
                msg_send![subtitle, length]
            };
            title_visibility == NSWindowTitleVisibility::NSWindowTitleHidden
                && subtitle_length == 0
        };
        fullscreen_empty_auxiliary_chrome_suppression_eligible(
            custom_transparent_fullsize_titlebar,
            candidate_id != main_window_id && titlebar_belongs_to_candidate,
            no_native_toolbar_or_accessories,
            no_native_title_or_subtitle,
            buttons_are_hosted && button_container_belongs_to_titlebar,
            titlebar_container_is_visible && !overlay.button_container.isHidden(),
        )
    }

    fn restore_suppressed_fullscreen_auxiliary_chrome(&mut self) {
        let snapshot = self
            .fullscreen_traffic_light_overlay
            .as_mut()
            .and_then(|overlay| overlay.suppressed_auxiliary_chrome.take());
        if let Some(snapshot) = snapshot {
            snapshot.restore();
        }
    }

    fn start_display_link(&mut self) {
        self.stop_display_link();
        // Software requests actual AppKit layer updates only on demand. It
        // must not require CoreVideo display-link availability or an idle tick.
        if self.renderer.backend() == renderer::WindowBackend::Software {
            return;
        }
        unsafe {
            if !self
                .native_window
                .occlusionState()
                .contains(NSWindowOcclusionState::NSWindowOcclusionStateVisible)
            {
                return;
            }
        }
        let Some(display_id) = display_id_for_screen(unsafe { self.native_window.screen() }) else {
            // AppKit can temporarily report no screen while displays are being reconfigured.
            return;
        };
        let data = self.native_view.as_ptr() as *mut c_void;
        self.frame_source
            .get_or_insert_with(|| WindowFrameSource::new(data, step))
            .start(display_id)
            .log_err();
    }

    fn stop_display_link(&mut self) {
        if let Some(frame_source) = self.frame_source.as_mut() {
            frame_source.stop();
        }
    }

    fn is_maximized(&self) -> bool {
        fn rect_to_size(rect: NSRect) -> Size<Pixels> {
            let NSSize { width, height } = rect.size;
            size(width.into(), height.into())
        }

        unsafe {
            let bounds = self.bounds();
            let screen_size = rect_to_size(self.native_window.screen().visibleFrame());
            bounds.size == screen_size
        }
    }

    fn is_fullscreen(&self) -> bool {
        unsafe {
            let style_mask = self.native_window.styleMask();
            style_mask.contains(NSWindowStyleMask::NSFullScreenWindowMask)
        }
    }

    fn toggle_simple_fullscreen(&mut self) -> Option<SimpleFullscreenPlan> {
        // If the window is in native fullscreen, simple fullscreen would conflict
        // with AppKit's own fullscreen handling, so ignore the request.
        if self.is_fullscreen() {
            return None;
        }

        if let Some(saved) = self.simple_fullscreen_state.take() {
            Some(SimpleFullscreenPlan::Exit(saved))
        } else {
            let screen = unsafe { self.native_window.screen() };
            if screen == nil {
                return None;
            }
            let screen_frame = unsafe { NSScreen::frame(screen) };
            let bounds = self.bounds();

            self.simple_fullscreen_state = Some(SimpleFullscreenState {
                frame: unsafe { NSWindow::frame(self.native_window) },
                bounds,
                style_mask: unsafe { self.native_window.styleMask() },
            });

            Some(SimpleFullscreenPlan::Enter { screen_frame })
        }
    }

    fn bounds(&self) -> Bounds<Pixels> {
        let mut window_frame = unsafe { NSWindow::frame(self.native_window) };
        let screen = unsafe { NSWindow::screen(self.native_window) };
        if screen == nil {
            return Bounds::new(point(px(0.), px(0.)), gpui::DEFAULT_WINDOW_SIZE);
        }
        let screen_frame = unsafe { NSScreen::frame(screen) };

        // Flip the y coordinate to be top-left origin
        window_frame.origin.y =
            screen_frame.size.height - window_frame.origin.y - window_frame.size.height;

        Bounds::new(
            point(
                px((window_frame.origin.x - screen_frame.origin.x) as f32),
                px((window_frame.origin.y + screen_frame.origin.y) as f32),
            ),
            size(
                px(window_frame.size.width as f32),
                px(window_frame.size.height as f32),
            ),
        )
    }

    fn content_size(&self) -> Size<Pixels> {
        let NSSize { width, height, .. } =
            unsafe { NSView::frame(self.native_view.as_ptr() as id) }.size;
        size(px(width as f32), px(height as f32))
    }

    fn scale_factor(&self) -> f32 {
        get_scale_factor(self.native_window)
    }

    fn window_bounds(&self) -> WindowBounds {
        if self.is_fullscreen() {
            WindowBounds::Fullscreen(self.fullscreen_restore_bounds)
        } else if let Some(state) = &self.simple_fullscreen_state {
            WindowBounds::Windowed(state.bounds)
        } else {
            WindowBounds::Windowed(self.bounds())
        }
    }
}

unsafe impl Send for MacWindowState {}

pub(crate) struct MacWindow(Arc<Mutex<MacWindowState>>, MainThreadMarker);

impl MacWindow {
    pub fn open(
        handle: AnyWindowHandle,
        WindowParams {
            bounds,
            titlebar,
            kind,
            is_movable,
            app_owns_titlebar_drag,
            is_resizable,
            is_minimizable,
            focus,
            show,
            display_id,
            window_min_size,
            tabbing_identifier,
            ..
        }: WindowParams,
        cursor_visible: Arc<AtomicBool>,
        foreground_executor: ForegroundExecutor,
        background_executor: BackgroundExecutor,
        renderer: renderer::Renderer,
        marker: MainThreadMarker,
    ) -> Self {
        unsafe {
            let pool = NSAutoreleasePool::new(nil);

            let allows_automatic_window_tabbing = tabbing_identifier.is_some();
            if allows_automatic_window_tabbing {
                let () = msg_send![class!(NSWindow), setAllowsAutomaticWindowTabbing: YES];
            } else {
                let () = msg_send![class!(NSWindow), setAllowsAutomaticWindowTabbing: NO];
            }

            let mut style_mask;
            if let Some(titlebar) = titlebar.as_ref() {
                style_mask =
                    NSWindowStyleMask::NSClosableWindowMask | NSWindowStyleMask::NSTitledWindowMask;

                if is_resizable {
                    style_mask |= NSWindowStyleMask::NSResizableWindowMask;
                }

                if is_minimizable {
                    style_mask |= NSWindowStyleMask::NSMiniaturizableWindowMask;
                }

                if titlebar.appears_transparent {
                    style_mask |= NSWindowStyleMask::NSFullSizeContentViewWindowMask;
                }
            } else {
                style_mask = NSWindowStyleMask::NSTitledWindowMask
                    | NSWindowStyleMask::NSFullSizeContentViewWindowMask;
            }

            let native_window: id = match kind {
                WindowKind::Normal => {
                    msg_send![WINDOW_CLASS, alloc]
                }
                // `AnchoredPopup` is rejected in `MacPlatform::open_window`, grouped here only
                // for exhaustiveness.
                WindowKind::PopUp | WindowKind::AnchoredPopup(_) => {
                    style_mask |= NSWindowStyleMaskNonactivatingPanel;
                    msg_send![PANEL_CLASS, alloc]
                }
                WindowKind::Floating | WindowKind::Dialog => {
                    msg_send![PANEL_CLASS, alloc]
                }
            };

            let display = display_id
                .and_then(MacDisplay::find_by_id)
                .unwrap_or_else(MacDisplay::primary);

            let mut target_screen = nil;
            let mut screen_frame = None;

            let screens = NSScreen::screens(nil);
            let count: u64 = cocoa::foundation::NSArray::count(screens);
            for i in 0..count {
                let screen = cocoa::foundation::NSArray::objectAtIndex(screens, i);
                let Some(display_id) = display_id_for_screen(screen) else {
                    continue;
                };
                let frame = NSScreen::frame(screen);
                if display_id == display.0 {
                    screen_frame = Some(frame);
                    target_screen = screen;
                }
            }

            let screen_frame = screen_frame.unwrap_or_else(|| {
                let screen = NSScreen::mainScreen(nil);
                target_screen = screen;
                NSScreen::frame(screen)
            });

            let window_rect = NSRect::new(
                NSPoint::new(
                    screen_frame.origin.x + bounds.origin.x.as_f32() as f64,
                    screen_frame.origin.y
                        + (display.bounds().size.height - bounds.origin.y).as_f32() as f64,
                ),
                NSSize::new(
                    bounds.size.width.as_f32() as f64,
                    bounds.size.height.as_f32() as f64,
                ),
            );

            let native_window = native_window.initWithContentRect_styleMask_backing_defer_screen_(
                window_rect,
                style_mask,
                NSBackingStoreBuffered,
                NO,
                target_screen,
            );
            assert!(!native_window.is_null());
            let () = msg_send![
                native_window,
                registerForDraggedTypes:
                    NSArray::arrayWithObject(nil, NSFilenamesPboardType)
            ];
            let () = msg_send![
                native_window,
                setReleasedWhenClosed: NO
            ];

            let content_view = native_window.contentView();
            let native_view: id = msg_send![VIEW_CLASS, alloc];
            let native_view = NSView::initWithFrame_(native_view, NSView::bounds(content_view));
            assert!(!native_view.is_null());

            let state = Arc::new(Mutex::new(MacWindowState {
                handle,
                foreground_executor,
                background_executor,
                native_window,
                native_view: NonNull::new_unchecked(native_view),
                blurred_view: None,
                background_appearance: WindowBackgroundAppearance::Opaque,
                cursor_style: CursorStyle::Arrow,
                cursor_visible,
                frame_source: None,
                renderer,
                request_frame_callback: None,
                event_callback: None,
                activate_callback: None,
                visibility_callback: None,
                last_visibility: None,
                resize_callback: None,
                moved_callback: None,
                display_changed_callback: None,
                should_close_callback: None,
                close_callback: None,
                appearance_changed_callback: None,
                input_handler: None,
                last_key_equivalent: None,
                last_left_mouse_down_event: None,
                synthetic_drag_counter: 0,
                traffic_light_position: titlebar
                    .as_ref()
                    .and_then(|titlebar| titlebar.traffic_light_position),
                traffic_light_frames: None,
                pre_fullscreen_traffic_light_frames: None,
                fullscreen_traffic_light_overlay: None,
                fullscreen_controls_active: false,
                content_layout_rect_observer_registered: false,
                transparent_titlebar: titlebar
                    .as_ref()
                    .is_none_or(|titlebar| titlebar.appears_transparent),
                previous_modifiers_changed_event: None,
                keystroke_for_do_command: None,
                do_command_handled: None,
                external_files_dragged: false,
                first_mouse: false,
                app_owns_titlebar_drag,
                fullscreen_restore_bounds: Bounds::default(),
                is_exiting_fullscreen: false,
                simple_fullscreen_state: None,
                move_tab_to_new_window_callback: None,
                merge_all_windows_callback: None,
                select_next_tab_callback: None,
                select_previous_tab_callback: None,
                toggle_tab_bar_callback: None,
                activated_least_once: false,
                closed: Arc::new(AtomicBool::new(false)),
                accesskit_adapter: None,
                sheet_parent: None,
            }));
            let mut window = Self(state, marker);

            (*native_window).set_ivar(
                WINDOW_STATE_IVAR,
                Arc::into_raw(window.0.clone()) as *const c_void,
            );
            native_window.setDelegate_(native_window);
            (*native_view).set_ivar(
                WINDOW_STATE_IVAR,
                Arc::into_raw(window.0.clone()) as *const c_void,
            );

            if let Some(title) = titlebar
                .as_ref()
                .and_then(|t| t.title.as_ref().map(AsRef::as_ref))
            {
                window.set_title(title);
            }

            native_window.setMovable_(is_movable as BOOL);

            if let Some(window_min_size) = window_min_size {
                native_window.setContentMinSize_(NSSize {
                    width: window_min_size.width.to_f64(),
                    height: window_min_size.height.to_f64(),
                });
            }

            if titlebar.is_none_or(|titlebar| titlebar.appears_transparent) {
                native_window.setTitlebarAppearsTransparent_(YES);
                native_window.setTitleVisibility_(NSWindowTitleVisibility::NSWindowTitleHidden);
            }

            native_view.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable);
            native_view.setWantsBestResolutionOpenGLSurface_(YES);

            // From winit crate: On Mojave, views automatically become layer-backed shortly after
            // being added to a native_window. Changing the layer-backedness of a view breaks the
            // association between the view and its associated OpenGL context. To work around this,
            // on we explicitly make the view layer-backed up front so that AppKit doesn't do it
            // itself and break the association with its context.
            native_view.setWantsLayer(YES);
            let _: () = msg_send![
            native_view,
            setLayerContentsRedrawPolicy: NSViewLayerContentsRedrawDuringViewResize
            ];

            content_view.addSubview_(native_view.autorelease());
            native_window.makeFirstResponder_(native_view);

            let key_path = ns_string("contentLayoutRect");
            let observer_context = content_layout_rect_observer_context();
            let _: () = msg_send![
                native_window,
                addObserver: native_window
                forKeyPath: key_path
                options: 0 as NSUInteger
                context: observer_context
            ];
            window.0.lock().content_layout_rect_observer_registered = true;
            synchronize_fullscreen_content_view_frame(&window.0);

            let app: id = NSApplication::sharedApplication(nil);
            let main_window: id = msg_send![app, mainWindow];
            let mut sheet_parent = None;

            // SAFETY: This is the live GPUIView (an NSView subclass) added to the
            // content view above, and window creation runs on the main thread.
            let tracking_view = &*native_view.cast::<Objc2NSView>();

            match kind {
                WindowKind::Normal | WindowKind::Floating => {
                    if kind == WindowKind::Floating {
                        // Let the window float keep above normal windows.
                        native_window.setLevel_(NSFloatingWindowLevel);
                        native_window.setAcceptsMouseMovedEvents_(YES);
                    } else {
                        native_window.setLevel_(NSNormalWindowLevel);
                        native_window.setAcceptsMouseMovedEvents_(NO);
                        add_mouse_tracking_area(tracking_view);
                    }

                    if let Some(tabbing_identifier) = tabbing_identifier {
                        let tabbing_id = ns_string(tabbing_identifier.as_str());
                        let _: () = msg_send![native_window, setTabbingIdentifier: tabbing_id];
                    } else {
                        let _: () = msg_send![native_window, setTabbingIdentifier:nil];
                    }
                }
                // `AnchoredPopup` is rejected in `MacPlatform::open_window`, grouped here only
                // for exhaustiveness.
                WindowKind::PopUp | WindowKind::AnchoredPopup(_) => {
                    add_mouse_tracking_area(tracking_view);

                    native_window.setLevel_(NSPopUpWindowLevel);
                    let _: () = msg_send![
                        native_window,
                        setAnimationBehavior: NSWindowAnimationBehaviorUtilityWindow
                    ];
                    native_window.setCollectionBehavior_(
                        NSWindowCollectionBehavior::NSWindowCollectionBehaviorCanJoinAllSpaces |
                        NSWindowCollectionBehavior::NSWindowCollectionBehaviorFullScreenAuxiliary
                    );
                }
                WindowKind::Dialog => {
                    if !main_window.is_null() {
                        let parent = {
                            let active_sheet: id = msg_send![main_window, attachedSheet];
                            if active_sheet.is_null() {
                                main_window
                            } else {
                                active_sheet
                            }
                        };
                        let _: () =
                            msg_send![parent, beginSheet: native_window completionHandler: nil];
                        sheet_parent = Some(parent);
                    }
                }
            }

            if allows_automatic_window_tabbing
                && !main_window.is_null()
                && main_window != native_window
            {
                let main_window_is_fullscreen = main_window
                    .styleMask()
                    .contains(NSWindowStyleMask::NSFullScreenWindowMask);
                let user_tabbing_preference = Self::get_user_tabbing_preference()
                    .unwrap_or(UserTabbingPreference::InFullScreen);
                let should_add_as_tab = user_tabbing_preference == UserTabbingPreference::Always
                    || user_tabbing_preference == UserTabbingPreference::InFullScreen
                        && main_window_is_fullscreen;

                if should_add_as_tab {
                    let main_window_can_tab: BOOL =
                        msg_send![main_window, respondsToSelector: sel!(addTabbedWindow:ordered:)];
                    let main_window_visible: BOOL = msg_send![main_window, isVisible];

                    if main_window_can_tab == YES && main_window_visible == YES {
                        let _: () = msg_send![main_window, addTabbedWindow: native_window ordered: NSWindowOrderingMode::NSWindowAbove];

                        // Ensure the window is visible immediately after adding the tab, since the tab bar is updated with a new entry at this point.
                        // Note: Calling orderFront here can break fullscreen mode (makes fullscreen windows exit fullscreen), so only do this if the main window is not fullscreen.
                        if !main_window_is_fullscreen {
                            let _: () = msg_send![native_window, orderFront: nil];
                        }
                    }
                }
            }

            if focus && show {
                native_window.makeKeyAndOrderFront_(nil);
            } else if show {
                native_window.orderFront_(nil);
            }

            // Set the initial position of the window to the specified origin.
            // Although we already specified the position using `initWithContentRect_styleMask_backing_defer_screen_`,
            // the window position might be incorrect if the main screen (the screen that contains the window that has focus)
            //  is different from the primary screen.
            NSWindow::setFrameTopLeftPoint_(native_window, window_rect.origin);
            {
                let mut window_state = window.0.lock();
                window_state.move_traffic_light();
                window_state.sheet_parent = sheet_parent;
            }

            pool.drain();

            window
        }
    }

    pub fn active_window() -> Option<AnyWindowHandle> {
        unsafe {
            let app = NSApplication::sharedApplication(nil);
            let main_window: id = msg_send![app, mainWindow];
            if main_window.is_null() {
                return None;
            }

            if msg_send![main_window, isKindOfClass: WINDOW_CLASS] {
                let handle = get_window_state(&*main_window).lock().handle;
                Some(handle)
            } else {
                None
            }
        }
    }

    pub fn ordered_windows() -> Vec<AnyWindowHandle> {
        unsafe {
            let app = NSApplication::sharedApplication(nil);
            let windows: id = msg_send![app, orderedWindows];
            let count: NSUInteger = msg_send![windows, count];

            let mut window_handles = Vec::new();
            for i in 0..count {
                let window: id = msg_send![windows, objectAtIndex:i];
                if msg_send![window, isKindOfClass: WINDOW_CLASS] {
                    let handle = get_window_state(&*window).lock().handle;
                    window_handles.push(handle);
                }
            }

            window_handles
        }
    }

    pub fn get_user_tabbing_preference() -> Option<UserTabbingPreference> {
        unsafe {
            let defaults: id = NSUserDefaults::standardUserDefaults();
            let domain = ns_string("NSGlobalDomain");
            let key = ns_string("AppleWindowTabbingMode");

            let dict: id = msg_send![defaults, persistentDomainForName: domain];
            let value: id = if !dict.is_null() {
                msg_send![dict, objectForKey: key]
            } else {
                nil
            };

            let value_str = if !value.is_null() {
                CStr::from_ptr(NSString::UTF8String(value)).to_string_lossy()
            } else {
                "".into()
            };

            match value_str.as_ref() {
                "manual" => Some(UserTabbingPreference::Never),
                "always" => Some(UserTabbingPreference::Always),
                _ => Some(UserTabbingPreference::InFullScreen),
            }
        }
    }
}

impl Drop for MacWindow {
    fn drop(&mut self) {
        let mut this = self.0.lock();
        if this.renderer.backend() == renderer::WindowBackend::Software {
            this.closed.store(true, Ordering::Release);
        }
        // The AccessKit adapter strong-retains the GPUI view, which carries an
        // `Arc<Mutex<MacWindowState>>` in its `windowState` ivar. That forms
        // `MacWindowState -> adapter -> GPUIView -> MacWindowState`, a cycle
        // the delegate/`frame_source` teardown below cannot break. Drop the
        // adapter here so the native view, its `CAMetalLayer` and the renderer's
        // command queue are actually released with the window.
        drop(this.accesskit_adapter.take());
        this.renderer.destroy();
        let window = this.native_window;
        let sheet_parent = this.sheet_parent.take();
        this.frame_source.take();
        unsafe {
            this.native_window.setDelegate_(nil);
        }
        this.input_handler.take();
        // A delivery task queued by `report_visibility` may still run after the
        // GPUI window is gone; without a callback it has nothing to notify.
        this.visibility_callback.take();
        this.foreground_executor
            .spawn(async move {
                unsafe {
                    if let Some(parent) = sheet_parent {
                        let _: () = msg_send![parent, endSheet: window];
                    }
                    window.close();
                    window.autorelease();
                }
            })
            .detach();
    }
}

/// Calls `f` if the window is not closed.
///
/// This should be used when spawning foreground tasks interacting with the
/// window, as some messages will end hard faulting if dispatched to no longer
/// valid window handles.
fn if_window_not_closed(closed: Arc<AtomicBool>, f: impl FnOnce()) {
    if !closed.load(Ordering::Acquire) {
        f();
    }
}

impl PlatformWindow for MacWindow {
    fn frame_waker(&self) -> Option<Rc<dyn Fn()>> {
        let state = self.0.lock();
        if state.renderer.backend() != renderer::WindowBackend::Software {
            return None;
        }
        let foreground = state.foreground_executor.clone();
        let background = state.background_executor.clone();
        let closed = state.closed.clone();
        drop(state);
        let weak = Arc::downgrade(&self.0);
        let clock = Rc::new(std::cell::RefCell::new(
            crate::software_renderer::frame_clock::DemandClock::default(),
        ));
        Some(Rc::new(move || {
            if closed.load(Ordering::Acquire) || weak.strong_count() == 0 {
                return;
            }
            let Some(delay) = clock.borrow_mut().request(std::time::Instant::now()) else {
                return;
            };
            let clock = clock.clone();
            let weak = weak.clone();
            let closed = closed.clone();
            let background = background.clone();
            foreground
                .spawn(async move {
                    // Even a zero-delay wake is deferred beyond the App borrow
                    // invoking the invalidator. There is only one queued task.
                    if !delay.is_zero() {
                        background.timer(delay).await;
                    }
                    clock.borrow_mut().delivered(std::time::Instant::now());
                    if closed.load(Ordering::Acquire) {
                        return;
                    }
                    let Some(state) = weak.upgrade() else {
                        return;
                    };
                    let layer = {
                        let state = state.lock();
                        if state.closed.load(Ordering::Acquire) {
                            return;
                        }
                        state.renderer.layer_ptr()
                    };
                    // SAFETY: this is the live renderer's ordinary CALayer;
                    // the main-thread task has no await between obtaining it
                    // and retaining it. No App or window-state borrow remains.
                    let Some(layer) = (unsafe { Retained::retain(layer) }) else {
                        return;
                    };
                    unsafe {
                        let _: () = objc2::msg_send![&*layer, setNeedsDisplay];
                        // Actual CALayerDelegate delivery is needed even when
                        // AppKit doesn't traverse an inactive/occluded window.
                        // A skipped GPUI throttle re-arms this same bounded
                        // demand clock; idle windows schedule nothing.
                        let _: () = objc2::msg_send![&*layer, displayIfNeeded];
                    }
                })
                .detach();
        }))
    }

    fn bounds(&self) -> Bounds<Pixels> {
        self.0.as_ref().lock().bounds()
    }

    fn window_bounds(&self) -> WindowBounds {
        self.0.as_ref().lock().window_bounds()
    }

    fn is_maximized(&self) -> bool {
        self.0.as_ref().lock().is_maximized()
    }

    fn content_size(&self) -> Size<Pixels> {
        self.0.as_ref().lock().content_size()
    }

    fn resize(&mut self, size: Size<Pixels>) {
        let this = self.0.lock();
        let window = this.native_window;
        let closed = this.closed.clone();
        this.foreground_executor
            .spawn(async move {
                if_window_not_closed(closed, || unsafe {
                    window.setContentSize_(NSSize {
                        width: size.width.as_f32() as f64,
                        height: size.height.as_f32() as f64,
                    });
                })
            })
            .detach();
    }

    fn merge_all_windows(&self) {
        let native_window = self.0.lock().native_window;
        extern "C" fn merge_windows_async(context: *mut std::ffi::c_void) {
            unsafe {
                let native_window = context as id;
                let _: () = msg_send![native_window, mergeAllWindows:nil];
            }
        }

        unsafe {
            DispatchQueue::main()
                .exec_async_f(native_window as *mut std::ffi::c_void, merge_windows_async);
        }
    }

    fn move_tab_to_new_window(&self) {
        let native_window = self.0.lock().native_window;
        extern "C" fn move_tab_async(context: *mut std::ffi::c_void) {
            unsafe {
                let native_window = context as id;
                let _: () = msg_send![native_window, moveTabToNewWindow:nil];
                let _: () = msg_send![native_window, makeKeyAndOrderFront: nil];
            }
        }

        unsafe {
            DispatchQueue::main()
                .exec_async_f(native_window as *mut std::ffi::c_void, move_tab_async);
        }
    }

    fn toggle_window_tab_overview(&self) {
        let native_window = self.0.lock().native_window;
        unsafe {
            let _: () = msg_send![native_window, toggleTabOverview:nil];
        }
    }

    fn set_tabbing_identifier(&self, tabbing_identifier: Option<String>) {
        let native_window = self.0.lock().native_window;
        unsafe {
            let allows_automatic_window_tabbing = tabbing_identifier.is_some();
            if allows_automatic_window_tabbing {
                let () = msg_send![class!(NSWindow), setAllowsAutomaticWindowTabbing: YES];
            } else {
                let () = msg_send![class!(NSWindow), setAllowsAutomaticWindowTabbing: NO];
            }

            if let Some(tabbing_identifier) = tabbing_identifier {
                let tabbing_id = ns_string(tabbing_identifier.as_str());
                let _: () = msg_send![native_window, setTabbingIdentifier: tabbing_id];
            } else {
                let _: () = msg_send![native_window, setTabbingIdentifier:nil];
            }
        }
    }

    fn native_window_state(&self) -> Option<Vec<u8>> {
        let native_window = {
            let state = self.0.lock();
            if state.is_fullscreen() || state.simple_fullscreen_state.is_some() {
                return None;
            }
            state.native_window
        };
        // SAFETY: `native_window` is a live `NSWindow` retained by this window's state, and the
        // selectors below are AppKit/Foundation methods sent with their documented signatures. The
        // archived bytes are copied into an owned `Vec` before the objects we allocated are
        // released, so no pointer into Objective-C memory escapes this block.
        unsafe {
            let archiver: id = msg_send![class!(NSKeyedArchiver), alloc];
            let archiver: id = msg_send![archiver, initRequiringSecureCoding: YES];
            if archiver.is_null() {
                log::warn!("failed to create an archiver for the native window state");
                return None;
            }
            let delegate: id = msg_send![WINDOW_STATE_ARCHIVER_DELEGATE_CLASS, new];
            let _: () = msg_send![archiver, setDelegate: delegate];
            let _: () = msg_send![native_window, encodeRestorableStateWithCoder: archiver];
            let _: () = msg_send![archiver, finishEncoding];
            // The archiver holds a weak reference to its delegate; clear it before the delegate
            // is released below.
            let _: () = msg_send![archiver, setDelegate: nil];

            let data: id = msg_send![archiver, encodedData];
            let bytes = if data.is_null() {
                ptr::null()
            } else {
                data.bytes() as *const u8
            };
            let state = if bytes.is_null() {
                log::warn!("the archiver produced no data for the native window state");
                None
            } else {
                Some(std::slice::from_raw_parts(bytes, data.length() as usize).to_vec())
            };

            let _: () = msg_send![delegate, release];
            let _: () = msg_send![archiver, release];
            state
        }
    }

    fn restore_native_window_state(&self, state: &[u8]) {
        if state.is_empty() {
            return;
        }
        let native_window = self.0.lock().native_window;
        // SAFETY: `native_window` is a live `NSWindow` retained by this window's state. The NSData,
        // NSKeyedUnarchiver and `restoreStateWithCoder:` selectors are sent with their documented
        // signatures, and the `NSData` only borrows `state` for the duration of this synchronous
        // call (it is consumed before `state` could be freed).
        unsafe {
            let data = NSData::dataWithBytes_length_(
                nil,
                state.as_ptr() as *const c_void,
                state.len() as u64,
            );
            if data.is_null() {
                log::warn!(
                    "failed to wrap {} bytes of native window state",
                    state.len()
                );
                return;
            }

            // On macOS < 15 the `NSWindowRestoresWorkspaceAtLaunch` user default controls whether
            // the window is restored to its original Space. On macOS 15+ that default is broken
            // (FB15644170), and the `_windowRestorationOptions` override on our unarchiver subclass
            // handles it instead.
            if !is_macos_version_at_least(NSOperatingSystemVersion::new(15, 0, 0)) {
                RESTORES_WORKSPACE_AT_LAUNCH_DEFAULT.call_once(|| {
                    let defaults: id = NSUserDefaults::standardUserDefaults();
                    let key = ns_string("NSWindowRestoresWorkspaceAtLaunch");
                    let yes_value: id = msg_send![class!(NSNumber), numberWithBool: YES];
                    let dict: id = msg_send![
                        class!(NSDictionary),
                        dictionaryWithObject: yes_value
                        forKey: key
                    ];
                    let _: () = msg_send![defaults, registerDefaults: dict];
                });
            }

            let unarchiver: id = msg_send![WINDOW_STATE_UNARCHIVER_CLASS, alloc];
            let mut error: id = nil;
            let unarchiver: id =
                msg_send![unarchiver, initForReadingFromData: data error: &mut error];
            if unarchiver.is_null() {
                log::warn!(
                    "failed to unarchive the native window state: {}",
                    ns_error_description(error)
                );
                return;
            }
            let _: () = msg_send![native_window, restoreStateWithCoder: unarchiver];
            let error: id = msg_send![unarchiver, error];
            if !error.is_null() {
                log::warn!(
                    "failed to restore the native window state: {}",
                    ns_error_description(error)
                );
            }
            let _: () = msg_send![unarchiver, release];
        }
    }

    fn set_traffic_light_position(&self, position: Point<Pixels>) {
        let mut state = self.0.lock();
        state.traffic_light_position = Some(position);
        state.move_traffic_light();
    }

    fn scale_factor(&self) -> f32 {
        self.0.as_ref().lock().scale_factor()
    }

    fn appearance(&self) -> WindowAppearance {
        unsafe {
            let appearance: id = msg_send![self.0.lock().native_window, effectiveAppearance];
            crate::window_appearance::window_appearance_from_native(appearance)
        }
    }

    fn display(&self) -> Option<Rc<dyn PlatformDisplay>> {
        unsafe {
            let screen = self.0.lock().native_window.screen();
            if screen.is_null() {
                return None;
            }
            let device_description: id = msg_send![screen, deviceDescription];
            let screen_number: id =
                NSDictionary::valueForKey_(device_description, ns_string("NSScreenNumber"));

            let screen_number: u32 = msg_send![screen_number, unsignedIntValue];

            Some(Rc::new(MacDisplay(screen_number)))
        }
    }

    fn mouse_position(&self) -> Point<Pixels> {
        let (position, native_view, view_height) = {
            let state = self.0.lock();
            let position = unsafe { state.native_window.mouseLocationOutsideOfEventStream() };
            (
                position,
                state.native_view.as_ptr() as id,
                state.content_size().height,
            )
        };
        convert_mouse_position(position, native_view, view_height)
    }

    fn modifiers(&self) -> Modifiers {
        unsafe {
            let modifiers: NSEventModifierFlags = msg_send![class!(NSEvent), modifierFlags];

            let control = modifiers.contains(NSEventModifierFlags::NSControlKeyMask);
            let alt = modifiers.contains(NSEventModifierFlags::NSAlternateKeyMask);
            let shift = modifiers.contains(NSEventModifierFlags::NSShiftKeyMask);
            let command = modifiers.contains(NSEventModifierFlags::NSCommandKeyMask);
            let function = modifiers.contains(NSEventModifierFlags::NSFunctionKeyMask);

            Modifiers {
                control,
                alt,
                shift,
                platform: command,
                function,
            }
        }
    }

    fn capslock(&self) -> Capslock {
        unsafe {
            let modifiers: NSEventModifierFlags = msg_send![class!(NSEvent), modifierFlags];

            Capslock {
                on: modifiers.contains(NSEventModifierFlags::NSAlphaShiftKeyMask),
            }
        }
    }

    fn set_input_handler(&mut self, input_handler: PlatformInputHandler) {
        self.0.as_ref().lock().input_handler = Some(input_handler);
    }

    fn take_input_handler(&mut self) -> Option<PlatformInputHandler> {
        self.0.as_ref().lock().input_handler.take()
    }

    fn prompt(
        &self,
        level: PromptLevel,
        msg: &str,
        detail: Option<&str>,
        answers: &[PromptButton],
    ) -> Option<oneshot::Receiver<usize>> {
        use objc2_foundation::{NSInteger, NSString};

        // NSAlert's first button keeps Return and Cancel keeps Escape, but the keyboard
        // focus (and therefore Space) defaults to Cancel, leaving the middle button of
        // prompts like "Save / Don't Save / Cancel" unreachable from the keyboard. Move
        // the initial focus onto the last non-cancel, non-default button instead.
        let initial_focus_ix = answers
            .iter()
            .enumerate()
            .rev()
            .find(|(_, label)| !label.is_cancel())
            .map(|(ix, _)| ix)
            .filter(|&ix| ix > 0);

        let alert = NSAlert::new(self.1);
        alert.setAlertStyle(match level {
            PromptLevel::Critical => NSAlertStyle::Critical,
            PromptLevel::Warning => NSAlertStyle::Warning,
            PromptLevel::Info => NSAlertStyle::Informational,
        });
        let message = NSString::from_str(msg);
        alert.setMessageText(message.as_ref());

        if let Some(detail) = detail {
            let detail_text = NSString::from_str(detail);
            alert.setInformativeText(detail_text.as_ref());
        }

        let mut initial_focus_button: Option<Retained<Objc2NSButton>> = None;
        for (ix, answer) in answers.iter().enumerate() {
            let title = NSString::from_str(answer.label());
            let button = alert.addButtonWithTitle(&title);
            button.setTag(ix as NSInteger);

            if answer.is_cancel() {
                if let Some(key) = core::char::from_u32(crate::events::ESCAPE_KEY as u32) {
                    let key = NSString::from_str(&key.to_string());
                    button.setKeyEquivalent(&key);
                }
            } else if Some(ix) == initial_focus_ix {
                initial_focus_button = Some(button);
            }
        }

        if let Some(button) = initial_focus_button {
            alert.window().setInitialFirstResponder(Some(&button));
        }

        let (done_tx, done_rx) = oneshot::channel();
        let done_tx = Cell::new(Some(done_tx));

        let block = RcBlock::new(move |answer: NSInteger| {
            if let Some(done_tx) = done_tx.take() {
                let _ = done_tx.send(answer.try_into().unwrap());
            }
        });

        let lock = self.0.lock();
        let native_window = lock.native_window;
        let closed = lock.closed.clone();
        let executor = lock.foreground_executor.clone();
        executor
            .spawn(async move {
                if !closed.load(Ordering::Acquire) {
                    // SAFETY: `native_window` is an Objective-C `NSWindow` pointer
                    // owned by the platform window; bridge it into objc2.
                    let sheet_window: &Objc2NSWindow =
                        unsafe { &*(native_window as *const Objc2NSWindow) };

                    alert.beginSheetModalForWindow_completionHandler(sheet_window, Some(&block));
                }
            })
            .detach();

        Some(done_rx)
    }

    fn activate(&self) {
        let lock = self.0.lock();
        let window = lock.native_window;
        let view = lock.native_view.as_ptr();
        let closed = lock.closed.clone();
        let executor = lock.foreground_executor.clone();
        executor
            .spawn(async move {
                if !closed.load(Ordering::Acquire) {
                    let window = unsafe { &*window.cast::<Objc2NSWindow>() };
                    if !window.isVisible() {
                        let view = unsafe { &*view.cast::<Objc2NSView>() };
                        view.setNeedsDisplay(true);
                    }
                    window.makeKeyAndOrderFront(None);
                }
            })
            .detach();
    }

    fn request_attention(&self) {
        if self.is_active() {
            return;
        }

        let executor = self.0.lock().foreground_executor.clone();
        executor
            .spawn(async move {
                unsafe {
                    let app = NSApplication::sharedApplication(nil);
                    app.requestUserAttention_(NSRequestUserAttentionType::NSInformationalRequest);
                }
            })
            .detach();
    }

    fn is_active(&self) -> bool {
        unsafe { self.0.lock().native_window.isKeyWindow() == YES }
    }

    fn visibility(&self) -> WindowVisibility {
        visibility(&self.0.lock())
    }

    // is_hovered is unused on macOS. See Window::is_window_hovered.
    fn is_hovered(&self) -> bool {
        false
    }

    fn set_title(&mut self, title: &str) {
        unsafe {
            let app = NSApplication::sharedApplication(nil);
            let window = self.0.lock().native_window;
            let title = ns_string(title);
            let _: () = msg_send![app, changeWindowsItem:window title:title filename:false];
            let _: () = msg_send![window, setTitle: title];
            self.0.lock().move_traffic_light();
        }
    }

    fn get_title(&self) -> String {
        unsafe {
            let title: id = msg_send![self.0.lock().native_window, title];
            if title.is_null() {
                "".to_string()
            } else {
                title.to_str().to_string()
            }
        }
    }

    fn set_app_id(&mut self, _app_id: &str) {}

    fn set_background_appearance(&self, background_appearance: WindowBackgroundAppearance) {
        let mut this = self.0.as_ref().lock();
        this.background_appearance = background_appearance;

        let opaque = background_appearance == WindowBackgroundAppearance::Opaque;
        this.renderer.update_transparency(!opaque);

        unsafe {
            this.native_window.setOpaque_(opaque as BOOL);
            let background_color = if opaque {
                NSColor::colorWithSRGBRed_green_blue_alpha_(nil, 0f64, 0f64, 0f64, 1f64)
            } else {
                // Not using `+[NSColor clearColor]` to avoid broken shadow.
                NSColor::colorWithSRGBRed_green_blue_alpha_(nil, 0f64, 0f64, 0f64, 0.0001)
            };
            this.native_window.setBackgroundColor_(background_color);

            if background_appearance != WindowBackgroundAppearance::Blurred {
                if let Some(blur_view) = this.blurred_view {
                    NSView::removeFromSuperview(blur_view);
                    this.blurred_view = None;
                }
            } else if this.blurred_view.is_none() {
                let content_view = this.native_window.contentView();
                let frame = NSView::bounds(content_view);
                let mut blur_view: id = msg_send![BLURRED_VIEW_CLASS, alloc];
                blur_view = NSView::initWithFrame_(blur_view, frame);
                blur_view.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable);

                let _: () = msg_send![
                    content_view,
                    addSubview: blur_view
                    positioned: NSWindowOrderingMode::NSWindowBelow
                    relativeTo: nil
                ];
                this.blurred_view = Some(blur_view.autorelease());
            }
        }
    }

    fn background_appearance(&self) -> WindowBackgroundAppearance {
        self.0.as_ref().lock().background_appearance
    }

    fn is_subpixel_rendering_supported(&self) -> bool {
        false
    }

    fn set_edited(&mut self, edited: bool) {
        unsafe {
            let window = self.0.lock().native_window;
            msg_send![window, setDocumentEdited: edited as BOOL]
        }

        // Changing the document edited state resets the traffic light position,
        // so we have to move it again.
        self.0.lock().move_traffic_light();
    }

    fn set_document_path(&self, path: Option<&std::path::Path>) {
        unsafe {
            let window = self.0.lock().native_window;
            let filename = path.map_or(ns_string(""), |p| ns_string(&p.to_string_lossy()));
            let _: () = msg_send![window, setRepresentedFilename: filename];
        }

        // Changing the document path state resets the traffic light position,
        // so we have to move it again.
        self.0.lock().move_traffic_light();
    }

    fn show_character_palette(&self) {
        let this = self.0.lock();
        let window = this.native_window;
        this.foreground_executor
            .spawn(async move {
                unsafe {
                    let app = NSApplication::sharedApplication(nil);
                    let _: () = msg_send![app, orderFrontCharacterPalette: window];
                }
            })
            .detach();
    }

    fn minimize(&self) {
        let window = self.0.lock().native_window;
        unsafe {
            window.miniaturize_(nil);
        }
    }

    fn zoom(&self) {
        let this = self.0.lock();
        let window = this.native_window;
        let closed = this.closed.clone();
        this.foreground_executor
            .spawn(async move {
                if_window_not_closed(closed, || unsafe {
                    window.zoom_(nil);
                })
            })
            .detach();
    }

    fn toggle_fullscreen(&self) {
        let this = self.0.lock();
        let window = this.native_window;
        let closed = this.closed.clone();
        this.foreground_executor
            .spawn(async move {
                if_window_not_closed(closed, || unsafe {
                    window.toggleFullScreen_(nil);
                })
            })
            .detach();
    }

    fn toggle_simple_fullscreen(&self) {
        let state = self.0.clone();
        let (foreground_executor, closed) = {
            let this = self.0.lock();
            (this.foreground_executor.clone(), this.closed.clone())
        };
        foreground_executor
            .spawn(async move {
                if_window_not_closed(closed, move || {
                    let (native_window, native_view, plan) = {
                        let mut lock = state.lock();
                        (
                            lock.native_window,
                            lock.native_view.as_ptr() as id,
                            lock.toggle_simple_fullscreen(),
                        )
                    };
                    if let Some(plan) = plan {
                        unsafe { apply_simple_fullscreen_plan(native_window, native_view, plan) };
                    }
                })
            })
            .detach();
    }

    fn is_simple_fullscreen(&self) -> bool {
        self.0.lock().simple_fullscreen_state.is_some()
    }

    fn is_fullscreen(&self) -> bool {
        let this = self.0.lock();
        let window = this.native_window;

        unsafe {
            window
                .styleMask()
                .contains(NSWindowStyleMask::NSFullScreenWindowMask)
        }
    }

    fn on_request_frame(&self, callback: Box<dyn FnMut(RequestFrameOptions)>) {
        self.0.as_ref().lock().request_frame_callback = Some(callback);
    }

    fn on_input(&self, callback: Box<dyn FnMut(PlatformInput) -> gpui::DispatchEventResult>) {
        self.0.as_ref().lock().event_callback = Some(callback);
    }

    fn on_active_status_change(&self, callback: Box<dyn FnMut(bool)>) {
        self.0.as_ref().lock().activate_callback = Some(callback);
    }

    fn on_visibility_change(&self, callback: Box<dyn FnMut(WindowVisibility)>) {
        let mut state = self.0.lock();
        state.last_visibility = Some(visibility(&state));
        state.visibility_callback = Some(callback);
    }

    fn on_hover_status_change(&self, _: Box<dyn FnMut(bool)>) {}

    fn on_resize(&self, callback: Box<dyn FnMut(Size<Pixels>, f32)>) {
        self.0.as_ref().lock().resize_callback = Some(callback);
    }

    fn on_display_changed(&self, callback: Box<dyn FnMut()>) {
        self.0.as_ref().lock().display_changed_callback = Some(callback);
    }

    fn on_moved(&self, callback: Box<dyn FnMut()>) {
        self.0.as_ref().lock().moved_callback = Some(callback);
    }

    fn on_should_close(&self, callback: Box<dyn FnMut() -> bool>) {
        self.0.as_ref().lock().should_close_callback = Some(callback);
    }

    fn on_close(&self, callback: Box<dyn FnOnce()>) {
        self.0.as_ref().lock().close_callback = Some(callback);
    }

    fn on_hit_test_window_control(&self, _callback: Box<dyn FnMut() -> Option<WindowControlArea>>) {
    }

    fn on_appearance_changed(&self, callback: Box<dyn FnMut()>) {
        self.0.lock().appearance_changed_callback = Some(callback);
    }

    fn tabbed_windows(&self) -> Option<Vec<SystemWindowTab>> {
        unsafe {
            let windows: id = msg_send![self.0.lock().native_window, tabbedWindows];
            if windows.is_null() {
                return None;
            }

            let count: NSUInteger = msg_send![windows, count];
            let mut result = Vec::new();
            for i in 0..count {
                let window: id = msg_send![windows, objectAtIndex:i];
                if msg_send![window, isKindOfClass: WINDOW_CLASS] {
                    let handle = get_window_state(&*window).lock().handle;
                    let title: id = msg_send![window, title];
                    let title = SharedString::from(title.to_str().to_string());

                    result.push(SystemWindowTab::new(title, handle));
                }
            }

            Some(result)
        }
    }

    fn tab_bar_visible(&self) -> bool {
        unsafe {
            let tab_group: id = msg_send![self.0.lock().native_window, tabGroup];
            if tab_group.is_null() {
                false
            } else {
                let tab_bar_visible: BOOL = msg_send![tab_group, isTabBarVisible];
                tab_bar_visible == YES
            }
        }
    }

    fn on_move_tab_to_new_window(&self, callback: Box<dyn FnMut()>) {
        self.0.as_ref().lock().move_tab_to_new_window_callback = Some(callback);
    }

    fn on_merge_all_windows(&self, callback: Box<dyn FnMut()>) {
        self.0.as_ref().lock().merge_all_windows_callback = Some(callback);
    }

    fn on_select_next_tab(&self, callback: Box<dyn FnMut()>) {
        self.0.as_ref().lock().select_next_tab_callback = Some(callback);
    }

    fn on_select_previous_tab(&self, callback: Box<dyn FnMut()>) {
        self.0.as_ref().lock().select_previous_tab_callback = Some(callback);
    }

    fn on_toggle_tab_bar(&self, callback: Box<dyn FnMut()>) {
        self.0.as_ref().lock().toggle_tab_bar_callback = Some(callback);
    }

    fn draw(&self, scene: &gpui::Scene) {
        let mut this = self.0.lock();
        this.renderer.draw(scene);
    }

    fn sprite_atlas(&self) -> Arc<dyn PlatformAtlas> {
        self.0.lock().renderer.sprite_atlas().clone()
    }

    fn renderer_diagnostics(&self) -> Option<gpui::WindowRendererDiagnostics> {
        let state = self.0.lock();
        let metrics = state.renderer.software_metrics();
        Some(gpui::WindowRendererDiagnostics {
            backend: match state.renderer.backend() {
                renderer::WindowBackend::Metal => "metal",
                renderer::WindowBackend::Software => "software",
            },
            submitted_frames: metrics.as_ref().map(|m| m.submitted_frames),
            failed_frames: metrics.as_ref().map(|m| m.failed_frames),
            software_image_pixel_bytes: metrics.as_ref().map(|m| m.owned_image_pixel_bytes),
            software_live_atlas_pixel_bytes: metrics.as_ref().map(|m| m.atlas_pixel_bytes),
            last_primitive_counts: metrics.as_ref().and_then(|m| m.last_primitive_counts),
            last_retired_sprite_batches: metrics
                .as_ref()
                .and_then(|m| m.last_retired_sprite_batches),
            last_cpu_submit_microseconds: metrics
                .as_ref()
                .and_then(|m| m.last_cpu_submit_microseconds),
        })
    }

    fn gpu_specs(&self) -> Option<gpui::GpuSpecs> {
        None
    }

    fn update_ime_position(&self, _bounds: Bounds<Pixels>) {
        let executor = self.0.lock().foreground_executor.clone();
        executor
            .spawn(async move {
                unsafe {
                    let input_context: id =
                        msg_send![class!(NSTextInputContext), currentInputContext];
                    if input_context.is_null() {
                        return;
                    }
                    let _: () = msg_send![input_context, invalidateCharacterCoordinates];
                }
            })
            .detach()
    }

    fn titlebar_double_click(&self, is_resizable: bool, is_minimizable: bool) {
        let this = self.0.lock();
        if this.simple_fullscreen_state.is_some() {
            return;
        }
        let window = this.native_window;
        let closed = this.closed.clone();
        this.foreground_executor
            .spawn(async move {
                if_window_not_closed(closed, || {
                    unsafe {
                        let defaults: id = NSUserDefaults::standardUserDefaults();
                        let domain = ns_string("NSGlobalDomain");
                        let key = ns_string("AppleActionOnDoubleClick");

                        let dict: id = msg_send![defaults, persistentDomainForName: domain];
                        let action: id = if !dict.is_null() {
                            msg_send![dict, objectForKey: key]
                        } else {
                            nil
                        };

                        let action_str = if !action.is_null() {
                            CStr::from_ptr(NSString::UTF8String(action)).to_string_lossy()
                        } else {
                            "".into()
                        };

                        match action_str.as_ref() {
                            "None" => {
                                // "Do Nothing" selected, so do no action
                            }
                            "Minimize" => {
                                if is_minimizable {
                                    window.miniaturize_(nil);
                                }
                            }
                            "Maximize" => {
                                if is_resizable {
                                    window.zoom_(nil);
                                }
                            }
                            "Fill" => {
                                if is_resizable {
                                    // Unlike `zoom:`, AppKit's private Fill action honors the system's
                                    // "Tiled windows have margins" setting.
                                    let responds_to_zoom_fill: BOOL =
                                        msg_send![window, respondsToSelector: sel!(_zoomFill:)];
                                    if responds_to_zoom_fill == YES {
                                        let _: () = msg_send![window, _zoomFill: nil];
                                    } else {
                                        window.zoom_(nil);
                                    }
                                }
                            }
                            _ => {
                                if is_resizable {
                                    window.zoom_(nil);
                                }
                            }
                        }
                    }
                })
            })
            .detach();
    }

    fn start_window_move(&self) {
        let this = self.0.lock();
        if this.simple_fullscreen_state.is_some() {
            return;
        }
        let window = this.native_window;

        unsafe {
            let app = NSApplication::sharedApplication(nil);
            let event: id = msg_send![app, currentEvent];
            let _: () = msg_send![window, performWindowDragWithEvent: event];
        }
    }

    fn can_start_external_drag(&self) -> bool {
        true
    }

    fn start_external_drag(&self, payload: &ExternalDragPayload) -> bool {
        use objc2_foundation::{NSArray, NSPoint, NSRect, NSSize, NSString};

        let ExternalDragPayload::Files(paths) = payload;
        if paths.entries().is_empty() {
            log::warn!("start_external_drag declined: no paths");
            return false;
        }

        let (native_view, native_window, last_left_mouse_down_event) = {
            let state = self.0.lock();
            (
                state.native_view.as_ptr(),
                state.native_window,
                state.last_left_mouse_down_event.clone(),
            )
        };

        let Some(last_left_mouse_down_event) = last_left_mouse_down_event else {
            log::warn!("start_external_drag declined: no retained left mouse down event");
            return false;
        };

        // SAFETY: This method runs on the AppKit/foreground path during drag initiation. The
        // native view/window are retained by MacWindowState, copied out under a short lock above,
        // and all pointers passed to Objective-C remain valid for their respective calls.
        unsafe {
            let event: id = Retained::as_ptr(&last_left_mouse_down_event)
                .cast_mut()
                .cast();
            let dragging_items: id = msg_send![class!(NSMutableArray), array];
            // AppKit keeps this frame's distance from the event's location as the drag image's
            // offset from the cursor, so it has to stay anchored on `event`.
            let location: cocoa::foundation::NSPoint = msg_send![event, locationInWindow];
            let frame = NSRect::new(
                NSPoint::new(location.x - 16., location.y - 16.),
                NSSize::new(32., 32.),
            );

            for (path, is_directory) in paths.entries() {
                // Preserve non-UTF-8 paths
                let Ok(path_bytes) = CString::new(path.as_os_str().as_bytes()) else {
                    log::warn!("start_external_drag skipped path containing an interior nul byte");
                    continue;
                };

                let path_bytes = NonNull::new_unchecked(path_bytes.as_ptr().cast_mut());
                let url = NSURL::fileURLWithFileSystemRepresentation_isDirectory_relativeToURL(
                    path_bytes,
                    *is_directory,
                    None,
                );

                let pasteboard_writer = ProtocolObject::<dyn NSPasteboardWriting>::from_ref(&*url);
                let item = NSDraggingItem::initWithPasteboardWriter(
                    NSDraggingItem::alloc(),
                    pasteboard_writer,
                );

                // Resolve drag images lazily via `imageComponentsProvider` (Apple's
                // recommendation for large item counts), and by file *type* rather than
                // `iconForFile:`, which can synchronously hit LaunchServices, network
                // mounts, or iCloud for every selected path and beachball drag startup.
                // `iconForFileType:` is deprecated in favor of `iconForContentType:`,
                // but the replacement requires macOS 11 and we target 10.15.
                let file_type = if *is_directory {
                    "public.folder".to_string()
                } else {
                    path.extension()
                        .and_then(|extension| extension.to_str())
                        .map(|extension| extension.to_string())
                        .unwrap_or_else(|| "public.data".to_string())
                };
                let provider = RcBlock::new(move || {
                    let component = NSDraggingImageComponent::draggingImageComponentWithKey(
                        NSDraggingImageComponentIconKey,
                    );
                    let workspace = NSWorkspace::sharedWorkspace();
                    let file_type = NSString::from_str(&file_type);
                    // TODO: Replace with `iconForContentType` once Zed no longer supports MacOS 10.15
                    #[expect(deprecated, reason = "Support for MacOS 10.15")]
                    let icon = workspace.iconForFileType(&file_type);
                    component.setContents(Some(&icon));
                    // Component frames are relative to the item's dragging frame.
                    component.setFrame(NSRect::new(NSPoint::new(0., 0.), NSSize::new(32., 32.)));
                    let components = NSArray::from_slice(&[&*component]);
                    NonNull::new_unchecked(Retained::autorelease_return(components))
                });
                item.setDraggingFrame(frame);
                item.setImageComponentsProvider(Some(&provider));
                let _: () = msg_send![dragging_items, addObject: Retained::as_ptr(&item)];
            }

            let count: NSUInteger = msg_send![dragging_items, count];
            if count == 0 {
                log::warn!("start_external_drag declined: no dragging items");
                return false;
            }

            let session: id = msg_send![
                native_view,
                beginDraggingSessionWithItems: dragging_items
                event: event
                source: native_window
            ];

            let started = !session.is_null();
            if started {
                self.0.lock().synthetic_drag_counter += 1;
            }
            log::debug!(
                "start_external_drag completed: started={}, item_count={}",
                started,
                count
            );
            started
        }
    }

    fn play_system_bell(&self) {
        NSBeep()
    }

    #[cfg(any(test, feature = "test-support"))]
    fn render_to_image(&self, scene: &gpui::Scene) -> Result<RgbaImage> {
        let mut this = self.0.lock();
        this.renderer.render_to_image(scene)
    }

    fn a11y_init(&self, callbacks: gpui::A11yCallbacks) {
        let mut lock = self.0.lock();

        let activation_handler = A11yActivationHandler {
            callback: callbacks.activation,
        };
        let action_handler = A11yActionHandler(callbacks.action);

        let adapter = unsafe {
            accesskit_macos::SubclassingAdapter::new(
                lock.native_view.as_ptr() as *mut c_void,
                activation_handler,
                action_handler,
            )
        };

        lock.accesskit_adapter = Some(adapter);
    }

    fn a11y_tree_update(&self, tree_update: accesskit::TreeUpdate) {
        let events = {
            let mut lock = self.0.lock();
            lock.accesskit_adapter
                .as_mut()
                .and_then(|adapter| adapter.update_if_active(|| tree_update))
        };
        if let Some(events) = events {
            events.raise();
        }
    }

    fn a11y_update_window_bounds(&self) {
        // macOS handles window bounds tracking automatically via NSAccessibility.
    }
}

struct A11yActivationHandler {
    callback: Box<dyn Fn() -> Option<accesskit::TreeUpdate> + Send + 'static>,
}

impl accesskit::ActivationHandler for A11yActivationHandler {
    fn request_initial_tree(&mut self) -> Option<accesskit::TreeUpdate> {
        (self.callback)()
    }
}

struct A11yActionHandler(Box<dyn Fn(accesskit::ActionRequest) + Send + 'static>);

impl accesskit::ActionHandler for A11yActionHandler {
    fn do_action(&mut self, request: accesskit::ActionRequest) {
        (self.0)(request);
    }
}

impl rwh::HasWindowHandle for MacWindow {
    fn window_handle(&self) -> Result<rwh::WindowHandle<'_>, rwh::HandleError> {
        // SAFETY: The AppKitWindowHandle is a wrapper around a pointer to an NSView
        unsafe {
            Ok(rwh::WindowHandle::borrow_raw(rwh::RawWindowHandle::AppKit(
                rwh::AppKitWindowHandle::new(self.0.lock().native_view.cast()),
            )))
        }
    }
}

impl rwh::HasDisplayHandle for MacWindow {
    fn display_handle(&self) -> Result<rwh::DisplayHandle<'_>, rwh::HandleError> {
        Ok(rwh::DisplayHandle::appkit())
    }
}

fn get_scale_factor(native_window: id) -> f32 {
    let factor = unsafe {
        let screen: id = msg_send![native_window, screen];
        if screen.is_null() {
            return 2.0;
        }
        NSScreen::backingScaleFactor(screen) as f32
    };

    // We are not certain what triggers this, but it seems that sometimes
    // this method would return 0 (https://github.com/zed-industries/zed/issues/6412)
    // It seems most likely that this would happen if the window has no screen
    // (if it is off-screen), though we'd expect to see viewDidChangeBackingProperties before
    // it was rendered for real.
    // Regardless, attempt to avoid the issue here.
    if factor == 0.0 { 2. } else { factor }
}

/// Returns whether `window` is one of GPUI's managed windows.
unsafe fn is_gpui_window(window: id) -> bool {
    unsafe {
        msg_send![window, isKindOfClass: WINDOW_CLASS]
            || msg_send![window, isKindOfClass: PANEL_CLASS]
    }
}

unsafe fn get_window_state(object: &Object) -> Arc<Mutex<MacWindowState>> {
    unsafe {
        let raw: *mut c_void = *object.get_ivar(WINDOW_STATE_IVAR);
        let rc1 = Arc::from_raw(raw as *mut Mutex<MacWindowState>);
        let rc2 = rc1.clone();
        mem::forget(rc1);
        rc2
    }
}

unsafe fn drop_window_state(object: &Object) {
    unsafe {
        let raw: *mut c_void = *object.get_ivar(WINDOW_STATE_IVAR);
        Arc::from_raw(raw as *mut Mutex<MacWindowState>);
    }
}

extern "C" fn yes(_: &Object, _: Sel) -> BOOL {
    YES
}

extern "C" fn dealloc_window(this: &Object, _: Sel) {
    unsafe {
        let window_state = get_window_state(this);
        let (observer_registered, native_window) = {
            let mut state = window_state.lock();
            state.closed.store(true, Ordering::Release);
            state.remove_fullscreen_toolbar_window_observer();
            (
                state.content_layout_rect_observer_registered,
                state.native_window,
            )
        };
        clear_pending_fullscreen_toolbar_update(native_window);
        if observer_registered {
            let key_path = ns_string("contentLayoutRect");
            let observer_context = content_layout_rect_observer_context();
            let _: () = msg_send![
                this,
                removeObserver: this
                forKeyPath: key_path
                context: observer_context
            ];
        }
        drop(window_state);
        drop_window_state(this);
        let _: () = msg_send![super(this, class!(NSWindow)), dealloc];
    }
}

extern "C" fn dealloc_view(this: &Object, _: Sel) {
    unsafe {
        drop_window_state(this);
        let _: () = msg_send![super(this, class!(NSView)), dealloc];
    }
}

fn add_mouse_tracking_area(native_view: &Objc2NSView) {
    let options = NSTrackingAreaOptions::MouseEnteredAndExited
        | NSTrackingAreaOptions::MouseMoved
        // Track even when another application is active so visible
        // windows can respond to hover without being focused.
        | NSTrackingAreaOptions::ActiveAlways
        | NSTrackingAreaOptions::InVisibleRect;

    // SAFETY: NSView provides the tracking-event callbacks, and the owner is
    // the same view that retains the tracking area. No user info is supplied.
    let tracking_area = unsafe {
        NSTrackingArea::initWithRect_options_owner_userInfo(
            NSTrackingArea::alloc(),
            Objc2NSRect::ZERO,
            options,
            Some(native_view),
            None,
        )
    };
    native_view.addTrackingArea(&tracking_area);
}

extern "C" fn reset_cursor_rects(this: &Object, _: Sel) {
    // SAFETY: AppKit invokes cursor-rect updates on the main thread for GPUIView instances,
    // whose WINDOW_STATE_IVAR is initialized when the view is created. The cursor registered
    // below is a valid NSCursor.
    unsafe {
        let _: () = msg_send![super(this, class!(NSView)), resetCursorRects];

        let window_state = get_window_state(this);
        let cursor_style = window_state.lock().cursor_style;

        let cursor: id = match cursor_style {
            CursorStyle::Arrow => msg_send![class!(NSCursor), arrowCursor],
            CursorStyle::IBeam => msg_send![class!(NSCursor), IBeamCursor],
            CursorStyle::Crosshair => msg_send![class!(NSCursor), crosshairCursor],
            CursorStyle::ClosedHand => msg_send![class!(NSCursor), closedHandCursor],
            CursorStyle::OpenHand => msg_send![class!(NSCursor), openHandCursor],
            CursorStyle::PointingHand => msg_send![class!(NSCursor), pointingHandCursor],
            CursorStyle::ResizeLeftRight => msg_send![class!(NSCursor), resizeLeftRightCursor],
            CursorStyle::ResizeUpDown => msg_send![class!(NSCursor), resizeUpDownCursor],
            CursorStyle::ResizeLeft => msg_send![class!(NSCursor), resizeLeftCursor],
            CursorStyle::ResizeRight => msg_send![class!(NSCursor), resizeRightCursor],
            CursorStyle::ResizeColumn => msg_send![class!(NSCursor), resizeLeftRightCursor],
            CursorStyle::ResizeRow => msg_send![class!(NSCursor), resizeUpDownCursor],
            CursorStyle::ResizeUp => msg_send![class!(NSCursor), resizeUpCursor],
            CursorStyle::ResizeDown => msg_send![class!(NSCursor), resizeDownCursor],

            // Undocumented, private class methods:
            // https://stackoverflow.com/questions/27242353/cocoa-predefined-resize-mouse-cursor
            CursorStyle::ResizeUpLeftDownRight => {
                msg_send![class!(NSCursor), _windowResizeNorthWestSouthEastCursor]
            }
            CursorStyle::ResizeUpRightDownLeft => {
                msg_send![class!(NSCursor), _windowResizeNorthEastSouthWestCursor]
            }

            CursorStyle::IBeamCursorForVerticalLayout => {
                msg_send![class!(NSCursor), IBeamCursorForVerticalLayout]
            }
            CursorStyle::OperationNotAllowed => {
                msg_send![class!(NSCursor), operationNotAllowedCursor]
            }
            CursorStyle::DragLink => msg_send![class!(NSCursor), dragLinkCursor],
            CursorStyle::DragCopy => msg_send![class!(NSCursor), dragCopyCursor],
            CursorStyle::ContextualMenu => msg_send![class!(NSCursor), contextualMenuCursor],
        };

        let bounds = NSView::bounds(this as *const Object as id);
        let _: () = msg_send![this, addCursorRect: bounds cursor: cursor];
    }
}

extern "C" fn handle_key_equivalent(this: &Object, _: Sel, native_event: id) -> BOOL {
    handle_key_event(this, native_event, true)
}

extern "C" fn handle_key_down(this: &Object, _: Sel, native_event: id) {
    handle_key_event(this, native_event, false);
}

extern "C" fn handle_key_up(this: &Object, _: Sel, native_event: id) {
    handle_key_event(this, native_event, false);
}

// Things to test if you're modifying this method:
//  U.S. layout:
//   - The IME consumes characters like 'j' and 'k', which makes paging through `less` in
//     the terminal behave incorrectly by default. This behavior should be patched by our
//     IME integration
//   - `alt-t` should open the tasks menu
//   - In vim mode, this keybinding should work:
//     ```
//        {
//          "context": "Editor && vim_mode == insert",
//          "bindings": {"j j": "vim::NormalBefore"}
//        }
//     ```
//     and typing 'j k' in insert mode with this keybinding should insert the two characters
//  Brazilian layout:
//   - `" space` should create an unmarked quote
//   - `" backspace` should delete the marked quote
//   - `" "`should create an unmarked quote and a second marked quote
//   - `" up` should insert a quote, unmark it, and move up one line
//   - `" cmd-down` should insert a quote, unmark it, and move to the end of the file
//   - `cmd-ctrl-space` and clicking on an emoji should type it
//  Czech (QWERTY) layout:
//   - in vim mode `option-4`  should go to end of line (same as $)
//  Japanese (Romaji) layout:
//   - type `a i left down up enter enter` should create an unmarked text "愛"
//   - In vim mode with `jj` bound to `vim::NormalBefore` in insert mode, typing 'j i' with
//     Japanese IME should produce "じ" (ji), not "jい"

/// Returns true if the current keyboard input source is a composition-based IME
/// (e.g. Japanese Hiragana, Korean, Chinese Pinyin) that produces non-ASCII output.
///
/// This checks two properties:
/// 1. The source type is `kTISTypeKeyboardInputMode` (an IME input mode, not a plain
///    keyboard layout). This excludes non-ASCII layouts like Armenian and Ukrainian
///    that map keys directly without composition.
/// 2. The source is not ASCII-capable, which excludes modes like Japanese Romaji that
///    produce ASCII characters and should allow multi-stroke keybindings like `jj`.
unsafe fn is_ime_input_source_active() -> bool {
    unsafe {
        let source = TISCopyCurrentKeyboardInputSource();
        if source.is_null() {
            return false;
        }

        let source_type =
            TISGetInputSourceProperty(source, kTISPropertyInputSourceType as *const c_void);
        let is_input_mode = !source_type.is_null()
            && CFEqual(
                source_type as CFTypeRef,
                kTISTypeKeyboardInputMode as CFTypeRef,
            ) != 0;

        let is_ascii = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceIsASCIICapable as *const c_void,
        );
        let is_ascii_capable = !is_ascii.is_null() && CFBooleanGetValue(is_ascii as CFBooleanRef);

        CFRelease(source as CFTypeRef);

        is_input_mode && !is_ascii_capable
    }
}

extern "C" fn handle_key_event(this: &Object, native_event: id, key_equivalent: bool) -> BOOL {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();

    let window_height = lock.content_size().height;
    let native_view = lock.native_view.as_ptr() as id;
    let event =
        unsafe { platform_input_from_native(native_event, native_view, Some(window_height)) };

    let Some(event) = event else {
        return NO;
    };

    let run_callback = |event: PlatformInput| -> BOOL {
        let mut callback = window_state.as_ref().lock().event_callback.take();
        let handled: BOOL = if let Some(callback) = callback.as_mut() {
            !callback(event).propagate as BOOL
        } else {
            NO
        };
        window_state.as_ref().lock().event_callback = callback;
        handled
    };

    match event {
        PlatformInput::KeyDown(key_down_event) => {
            // For certain keystrokes, macOS will first dispatch a "key equivalent" event.
            // If that event isn't handled, it will then dispatch a "key down" event. GPUI
            // makes no distinction between these two types of events, so we need to ignore
            // the "key down" event if we've already just processed its "key equivalent" version.
            if key_equivalent {
                lock.last_key_equivalent = Some(key_down_event.clone());
            } else if lock.last_key_equivalent.take().as_ref() == Some(&key_down_event) {
                return NO;
            }

            drop(lock);

            let is_composing =
                with_input_handler(this, |input_handler| input_handler.marked_text_range())
                    .flatten()
                    .is_some();

            // If we're composing, send the key to the input handler first;
            // otherwise we only send to the input handler if we don't have a matching binding.
            // The input handler may call `do_command_by_selector` if it doesn't know how to handle
            // a key. If it does so, it will return YES so we won't send the key twice.
            // We also do this for non-printing keys (like arrow keys and escape) as the IME menu
            // may need them even if there is no marked text;
            // however we skip keys with control or the input handler adds control-characters to the buffer.
            // and keys with function, as the input handler swallows them.
            // and keys with platform (Cmd), so that Cmd+key events (e.g. Cmd+`) are not
            // consumed by the IME on non-QWERTY / dead-key layouts.
            // We also send printable keys to the IME first when an IME input source (e.g. Japanese,
            // Korean, Chinese) is active and the input handler accepts text input. This prevents
            // multi-stroke keybindings like `jj` from intercepting keys that the IME should compose
            // (e.g. typing 'ji' should produce 'じ', not 'jい'). If the IME doesn't handle the key,
            // it calls `doCommandBySelector:` which routes it back to keybinding matching.
            let is_ime_printable_key = !is_composing
                && key_down_event
                    .keystroke
                    .key_char
                    .as_ref()
                    .is_some_and(|key_char| key_char.chars().all(|c| !c.is_control()))
                && !key_down_event.keystroke.modifiers.control
                && !key_down_event.keystroke.modifiers.function
                && !key_down_event.keystroke.modifiers.platform
                && unsafe { is_ime_input_source_active() }
                && with_input_handler(this, |input_handler| {
                    input_handler.query_prefers_ime_for_printable_keys()
                })
                .unwrap_or(false);

            if is_composing
                || is_ime_printable_key
                || (key_down_event.keystroke.key_char.is_none()
                    && !key_down_event.keystroke.modifiers.control
                    && !key_down_event.keystroke.modifiers.function
                    && !key_down_event.keystroke.modifiers.platform)
            {
                {
                    let mut lock = window_state.as_ref().lock();
                    lock.keystroke_for_do_command = Some(key_down_event.keystroke.clone());
                    lock.do_command_handled.take();
                    drop(lock);
                }

                let handled: BOOL = unsafe {
                    let input_context: id = msg_send![this, inputContext];
                    msg_send![input_context, handleEvent: native_event]
                };
                window_state.as_ref().lock().keystroke_for_do_command.take();
                if let Some(handled) = window_state.as_ref().lock().do_command_handled.take() {
                    return handled as BOOL;
                } else if handled == YES {
                    return YES;
                }

                let handled = run_callback(PlatformInput::KeyDown(key_down_event));
                return handled;
            }

            let handled = run_callback(PlatformInput::KeyDown(key_down_event.clone()));
            if handled == YES {
                return YES;
            }

            if key_down_event.is_held
                && let Some(key_char) = key_down_event.keystroke.key_char.as_ref()
            {
                let handled = with_input_handler(this, |input_handler| {
                    if !input_handler.apple_press_and_hold_enabled() {
                        input_handler.replace_text_in_range(None, key_char);
                        return YES;
                    }
                    NO
                });
                if handled == Some(YES) {
                    return YES;
                }
            }

            // Don't send key equivalents to the input handler if there are key modifiers other
            // than Function key, or macOS shortcuts like cmd-` will stop working.
            if key_equivalent && key_down_event.keystroke.modifiers != Modifiers::function() {
                return NO;
            }

            unsafe {
                let input_context: id = msg_send![this, inputContext];
                msg_send![input_context, handleEvent: native_event]
            }
        }

        PlatformInput::KeyUp(_) => {
            drop(lock);
            run_callback(event)
        }

        _ => NO,
    }
}

extern "C" fn handle_view_event(this: &Object, _: Sel, native_event: id) {
    let window_state = unsafe { get_window_state(this) };
    let weak_window_state = Arc::downgrade(&window_state);
    let mut lock = window_state.as_ref().lock();
    let window_height = lock.content_size().height;
    let native_event_type = unsafe { native_event.eventType() };
    match native_event_type {
        NSEventType::NSLeftMouseDown => {
            // AppKit owns `native_event` for the callback; retain it so the drag session can still
            // be started later, once the pointer leaves the window.
            lock.last_left_mouse_down_event =
                unsafe { Retained::retain(native_event.cast::<Objc2Object>()) };
        }
        NSEventType::NSLeftMouseUp => {
            lock.last_left_mouse_down_event = None;
        }
        _ => {}
    }
    let native_view = lock.native_view.as_ptr() as id;
    let event =
        unsafe { platform_input_from_native(native_event, native_view, Some(window_height)) };

    if let Some(mut event) = event {
        // AppKit unhides the cursor on the next mouse movement; mirror that here.
        if matches!(
            event,
            PlatformInput::MouseMove(_)
                | PlatformInput::MouseDown(_)
                | PlatformInput::MouseUp(_)
                | PlatformInput::MousePressure(_)
                | PlatformInput::MouseExited(_)
                | PlatformInput::ScrollWheel(_)
                | PlatformInput::Pinch(_)
        ) {
            lock.cursor_visible.store(true, Ordering::Relaxed);
        }

        match &mut event {
            PlatformInput::MouseDown(
                event @ MouseDownEvent {
                    button: MouseButton::Left,
                    modifiers: Modifiers { control: true, .. },
                    ..
                },
            ) => {
                // On mac, a ctrl-left click should be handled as a right click.
                *event = MouseDownEvent {
                    button: MouseButton::Right,
                    modifiers: Modifiers {
                        control: false,
                        ..event.modifiers
                    },
                    click_count: 1,
                    ..*event
                };
            }

            // Handles focusing click.
            PlatformInput::MouseDown(
                event @ MouseDownEvent {
                    button: MouseButton::Left,
                    ..
                },
            ) if (lock.first_mouse) => {
                *event = MouseDownEvent {
                    first_mouse: true,
                    ..*event
                };
                lock.first_mouse = false;
            }

            // Because we map a ctrl-left_down to a right_down -> right_up let's ignore
            // the ctrl-left_up to avoid having a mismatch in button down/up events if the
            // user is still holding ctrl when releasing the left mouse button
            PlatformInput::MouseUp(
                event @ MouseUpEvent {
                    button: MouseButton::Left,
                    modifiers: Modifiers { control: true, .. },
                    ..
                },
            ) => {
                *event = MouseUpEvent {
                    button: MouseButton::Right,
                    modifiers: Modifiers {
                        control: false,
                        ..event.modifiers
                    },
                    click_count: 1,
                    ..*event
                };
            }

            _ => {}
        };

        match &event {
            PlatformInput::MouseDown(_) => {
                drop(lock);
                unsafe {
                    let input_context: id = msg_send![this, inputContext];
                    msg_send![input_context, handleEvent: native_event]
                }
                lock = window_state.as_ref().lock();
            }
            PlatformInput::MouseMove(
                event @ MouseMoveEvent {
                    pressed_button: Some(_),
                    ..
                },
            ) => {
                // Synthetic drag is used for selecting long buffer contents while buffer is being scrolled.
                // External file drag and drop is able to emit its own synthetic mouse events which will conflict
                // with these ones.
                if !lock.external_files_dragged {
                    lock.synthetic_drag_counter += 1;
                    let executor = lock.foreground_executor.clone();
                    executor
                        .spawn(synthetic_drag(
                            weak_window_state,
                            lock.synthetic_drag_counter,
                            event.clone(),
                            lock.background_executor.clone(),
                        ))
                        .detach();
                }
            }

            PlatformInput::MouseUp(MouseUpEvent { .. }) => {
                lock.synthetic_drag_counter += 1;
            }

            PlatformInput::ModifiersChanged(ModifiersChangedEvent {
                modifiers,
                capslock,
            }) => {
                // Only raise modifiers changed event when they have actually changed
                if let Some(PlatformInput::ModifiersChanged(ModifiersChangedEvent {
                    modifiers: prev_modifiers,
                    capslock: prev_capslock,
                })) = &lock.previous_modifiers_changed_event
                    && prev_modifiers == modifiers
                    && prev_capslock == capslock
                {
                    return;
                }

                lock.previous_modifiers_changed_event = Some(event.clone());
            }

            _ => {}
        }

        if let Some(mut callback) = lock.event_callback.take() {
            drop(lock);
            callback(event);
            window_state.lock().event_callback = Some(callback);
        }
    }
}

fn visibility(state: &MacWindowState) -> WindowVisibility {
    let is_visible = unsafe {
        state
            .native_window
            .occlusionState()
            .contains(NSWindowOcclusionState::NSWindowOcclusionStateVisible)
    };
    if is_visible {
        WindowVisibility::Visible
    } else {
        WindowVisibility::Hidden
    }
}

fn report_visibility(window_state: &Arc<Mutex<MacWindowState>>) {
    let state = window_state.lock();
    if state.last_visibility.is_none() {
        return;
    }
    let executor = state.foreground_executor.clone();
    drop(state);

    // AppKit can notify while GPUI is updating a window. Deliver observers
    // after that update completes, as activation notifications do. The state
    // is read at delivery rather than captured here so a burst of
    // notifications collapses to the final value.
    executor
        .spawn({
            let window_state = window_state.clone();
            async move {
                let mut state = window_state.lock();
                let visibility = visibility(&state);
                if state.last_visibility == Some(visibility) {
                    return;
                }
                state.last_visibility = Some(visibility);
                if let Some(mut callback) = state.visibility_callback.take() {
                    drop(state);
                    callback(visibility);
                    window_state.lock().visibility_callback = Some(callback);
                }
            }
        })
        .detach();
}

extern "C" fn window_did_change_occlusion_state(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.lock();
    unsafe {
        if lock
            .native_window
            .occlusionState()
            .contains(NSWindowOcclusionState::NSWindowOcclusionStateVisible)
        {
            lock.move_traffic_light();
            lock.start_display_link();
        } else {
            lock.stop_display_link();
        }
    }
    drop(lock);
    // The only visibility source: AppKit posts this for covering, minimizing,
    // hiding, Space switches, and display sleep alike.
    report_visibility(&window_state);
}

extern "C" fn window_did_resize(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    window_state.as_ref().lock().move_traffic_light();
    synchronize_fullscreen_content_view_frame(&window_state);
}

extern "C" fn window_will_enter_fullscreen(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    lock.restore_fullscreen_traffic_lights();
    lock.fullscreen_controls_active = true;
    lock.fullscreen_restore_bounds = lock.bounds();
    lock.is_exiting_fullscreen = false;
    lock.pre_fullscreen_traffic_light_frames = lock.traffic_light_frames;
    lock.restore_traffic_light();
    apply_fullscreen_titlebar_appearance(&lock);

    // Move the real AppKit buttons into the content hierarchy before AppKit
    // removes the titlebar while entering fullscreen.
    lock.update_fullscreen_traffic_lights();
    drop(lock);
    synchronize_fullscreen_content_view_frame(&window_state);
}

extern "C" fn window_did_fail_to_enter_fullscreen(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    apply_fullscreen_titlebar_appearance(&lock);
    lock.fullscreen_controls_active = false;
    lock.restore_fullscreen_traffic_lights();
    lock.traffic_light_frames = lock.pre_fullscreen_traffic_light_frames.take();
    lock.move_traffic_light();
    drop(lock);
    synchronize_fullscreen_content_view_frame(&window_state);
}

extern "C" fn window_did_enter_fullscreen(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    apply_fullscreen_titlebar_appearance(&lock);
    lock.fullscreen_controls_active = true;
    lock.update_fullscreen_traffic_lights();
    drop(lock);
    synchronize_fullscreen_content_view_frame(&window_state);
}

extern "C" fn window_will_exit_fullscreen(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    lock.is_exiting_fullscreen = true;
    lock.fullscreen_controls_active = false;

    apply_fullscreen_titlebar_appearance(&lock);

    lock.restore_fullscreen_traffic_lights();
    lock.move_traffic_light();
    drop(lock);
    synchronize_fullscreen_content_view_frame(&window_state);
}

extern "C" fn window_did_fail_to_exit_fullscreen(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    apply_fullscreen_titlebar_appearance(&lock);
    lock.is_exiting_fullscreen = false;
    lock.restore_traffic_light();
    lock.fullscreen_controls_active = true;
    lock.update_fullscreen_traffic_lights();
    drop(lock);
    synchronize_fullscreen_content_view_frame(&window_state);
}

extern "C" fn window_did_exit_fullscreen(this: &Object, _: Sel, _: id) {
    // SAFETY: This method is registered only on GPUI window classes, which initialize
    // WINDOW_STATE_IVAR with an Arc<Mutex<MacWindowState>> during window creation.
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    apply_fullscreen_titlebar_appearance(&lock);
    lock.is_exiting_fullscreen = false;
    lock.fullscreen_controls_active = false;
    lock.restore_fullscreen_traffic_lights();
    // Moving the buttons during the transition captures their fullscreen frames.
    // Keep using the native windowed frames when restoring them on the next entry.
    lock.traffic_light_frames = lock.pre_fullscreen_traffic_light_frames.take();
    lock.move_traffic_light();
    drop(lock);
    synchronize_fullscreen_content_view_frame(&window_state);
}

fn fullscreen_titlebar_appearance_update(
    titlebar_is_transparent: bool,
    macos_15_3_or_later: bool,
) -> Option<bool> {
    macos_15_3_or_later.then_some(titlebar_is_transparent)
}

fn apply_fullscreen_titlebar_appearance(window_state: &MacWindowState) {
    let macos_15_3_or_later = is_macos_version_at_least(NSOperatingSystemVersion::new(15, 3, 0));
    if let Some(titlebar_is_transparent) = fullscreen_titlebar_appearance_update(
        window_state.transparent_titlebar,
        macos_15_3_or_later,
    ) {
        // An opaque native titlebar can cover custom content in the full-size
        // content view when the auto-hidden menu bar is revealed.
        let desired_appearance = if titlebar_is_transparent { YES } else { NO };
        let current_appearance: BOOL =
            unsafe { msg_send![window_state.native_window, titlebarAppearsTransparent] };
        if current_appearance != desired_appearance {
            unsafe {
                window_state
                    .native_window
                    .setTitlebarAppearsTransparent_(desired_appearance);
            }
        }
    }
}

pub(crate) fn is_macos_version_at_least(version: NSOperatingSystemVersion) -> bool {
    unsafe { NSProcessInfo::processInfo(nil).isOperatingSystemAtLeastVersion(version) }
}

fn ns_error_description(error: id) -> String {
    if error.is_null() {
        return "unknown error".to_owned();
    }
    unsafe {
        let description: id = msg_send![error, localizedDescription];
        description.to_str().to_owned()
    }
}

extern "C" fn window_did_move(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    if let Some(mut callback) = lock.moved_callback.take() {
        drop(lock);
        callback();
        window_state.lock().moved_callback = Some(callback);
    }
}

// Update the window scale factor and drawable size, and call the resize callback if any.
fn update_window_scale_factor(window_state: &Arc<Mutex<MacWindowState>>) {
    let mut lock = window_state.as_ref().lock();
    let scale_factor = lock.scale_factor();
    let size = lock.content_size();
    let drawable_size = size.to_device_pixels(scale_factor);
    lock.renderer.set_contents_scale(scale_factor as f64);

    lock.renderer.update_drawable_size(drawable_size);

    if let Some(mut callback) = lock.resize_callback.take() {
        let content_size = lock.content_size();
        let scale_factor = lock.scale_factor();
        drop(lock);
        callback(content_size, scale_factor);
        window_state.as_ref().lock().resize_callback = Some(callback);
    };
}

extern "C" fn window_did_change_screen(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    lock.start_display_link();
    drop(lock);
    update_window_scale_factor(&window_state);
    report_display_change(&window_state);
}

fn report_display_change(window_state: &Arc<Mutex<MacWindowState>>) {
    let executor = window_state.lock().foreground_executor.clone();
    // AppKit can post screen changes while GPUI is updating a window, e.g.
    // from `setFrame:`, so deliver after that update completes.
    executor
        .spawn({
            let window_state = window_state.clone();
            async move {
                let callback = window_state.lock().display_changed_callback.take();
                if let Some(mut callback) = callback {
                    callback();
                    window_state.lock().display_changed_callback = Some(callback);
                }
            }
        })
        .detach();
}

extern "C" fn window_did_change_key_status(this: &Object, selector: Sel, _: id) {
    let signal_at = PlatformFrameSignal::capture(scheduler::Instant::now);
    let window_state = unsafe { get_window_state(this) };
    let lock = window_state.lock();
    let is_active = unsafe { lock.native_window.isKeyWindow() == YES };

    // AppKit also unhides the cursor on activation changes, so mirror that here.
    lock.cursor_visible.store(true, Ordering::Relaxed);

    // When opening a pop-up while the application isn't active, Cocoa sends a spurious
    // `windowDidBecomeKey` message to the previous key window even though that window
    // isn't actually key. This causes a bug if the application is later activated while
    // the pop-up is still open, making it impossible to activate the previous key window
    // even if the pop-up gets closed. The only way to activate it again is to de-activate
    // the app and re-activate it, which is a pretty bad UX.
    // The following code detects the spurious event and invokes `resignKeyWindow`:
    // in theory, we're not supposed to invoke this method manually but it balances out
    // the spurious `becomeKeyWindow` event and helps us work around that bug.
    if selector == sel!(windowDidBecomeKey:) && !is_active {
        let native_window = lock.native_window;
        drop(lock);
        unsafe {
            let _: () = msg_send![native_window, resignKeyWindow];
        }
        return;
    }

    let executor = lock.foreground_executor.clone();
    drop(lock);

    let a11y_events = {
        let mut lock = window_state.lock();
        lock.accesskit_adapter
            .as_mut()
            .and_then(|adapter| adapter.update_view_focus_state(is_active))
    };
    if let Some(events) = a11y_events {
        events.raise();
    }

    // When a window becomes active, trigger an immediate synchronous frame request to prevent
    // tab flicker when switching between windows in native tabs mode.
    //
    // This is only done on subsequent activations (not the first) to ensure the initial focus
    // path is properly established. Without this guard, the focus state would remain unset until
    // the first mouse click, causing keybindings to be non-functional.
    if selector == sel!(windowDidBecomeKey:) && is_active {
        let window_state = unsafe { get_window_state(this) };
        let mut lock = window_state.lock();

        if lock.activated_least_once {
            if let Some(mut callback) = lock.request_frame_callback.take() {
                lock.renderer.set_presents_with_transaction(true);
                lock.stop_display_link();
                drop(lock);
                callback(RequestFrameOptions {
                    signal_at,
                    signal_source: FrameRequestSource::NativeCallback,
                    ..Default::default()
                });

                let mut lock = window_state.lock();
                lock.request_frame_callback = Some(callback);
                lock.renderer.set_presents_with_transaction(false);
                lock.start_display_link();
            }
        } else {
            lock.activated_least_once = true;
        }
    }

    executor
        .spawn(async move {
            let mut lock = window_state.as_ref().lock();
            // AppKit can reposition or reparent standard controls when a fullscreen
            // window resigns key as well as when it becomes active again.
            if is_active || lock.fullscreen_controls_active {
                lock.move_traffic_light();
            }

            if let Some(mut callback) = lock.activate_callback.take() {
                drop(lock);
                callback(is_active);
                window_state.lock().activate_callback = Some(callback);
            };
        })
        .detach();
}

extern "C" fn window_should_close(this: &Object, _: Sel, _: id) -> BOOL {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    if let Some(mut callback) = lock.should_close_callback.take() {
        drop(lock);
        let should_close = callback();
        window_state.lock().should_close_callback = Some(callback);
        should_close as BOOL
    } else {
        YES
    }
}

extern "C" fn window_will_use_full_screen_presentation_options(
    _this: &Object,
    _: Sel,
    _: id,
    proposed_options: NSUInteger,
) -> NSUInteger {
    fullscreen_presentation_options_update(proposed_options)
}

extern "C" fn observe_value_for_key_path(
    this: &Object,
    _: Sel,
    key_path: id,
    object: id,
    change: id,
    context: *mut c_void,
) {
    if context == content_layout_rect_observer_context()
        && !key_path.is_null()
        && unsafe { key_path.to_str() } == "contentLayoutRect"
    {
        unsafe {
            // contentLayoutRect can change reentrantly while a window callback holds
            // MacWindowState's mutex. Defer the read and frame update until AppKit's
            // current layout transaction has returned, retaining the window meanwhile.
            let retained_window: id = msg_send![this, retain];
            DispatchQueue::main().exec_async_f(
                retained_window as *mut c_void,
                synchronize_fullscreen_content_view_frame_deferred,
            );
        }
        return;
    }

    unsafe {
        let is_panel: BOOL = msg_send![this, isKindOfClass: PANEL_CLASS];
        if is_panel == YES {
            let _: () = msg_send![
                super(this, class!(NSPanel)),
                observeValueForKeyPath: key_path
                ofObject: object
                change: change
                context: context
            ];
        } else {
            let _: () = msg_send![
                super(this, class!(NSWindow)),
                observeValueForKeyPath: key_path
                ofObject: object
                change: change
                context: context
            ];
        }
    }
}

extern "C" fn fullscreen_toolbar_window_did_change(this: &Object, _: Sel, notification: id) {
    let window_pointer = this as *const Object as usize;
    let is_closing = unsafe {
        let name: id = msg_send![notification, name];
        !name.is_null() && name.to_str() == "NSWindowWillCloseNotification"
    };
    let closing_toolbar_window = if is_closing {
        let toolbar_window: id = unsafe { msg_send![notification, object] };
        (!toolbar_window.is_null()).then_some(toolbar_window as usize)
    } else {
        None
    };
    let should_dispatch = {
        let mut pending = FULLSCREEN_TOOLBAR_UPDATES_PENDING
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock();
        match pending.entry(window_pointer) {
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert(closing_toolbar_window);
                true
            }
            std::collections::hash_map::Entry::Occupied(mut entry) => {
                if closing_toolbar_window.is_some() {
                    entry.insert(closing_toolbar_window);
                }
                false
            }
        }
    };
    if !should_dispatch {
        return;
    }
    unsafe {
        // Auxiliary toolbar notifications can arrive synchronously while a GPUI
        // AppKit callback holds MacWindowState's mutex. Read the new geometry only
        // after that transaction returns. Collapse a burst into one main-queue sync.
        let retained_window: id = msg_send![this, retain];
        DispatchQueue::main().exec_async_f(
            retained_window as *mut c_void,
            synchronize_fullscreen_toolbar_frame_deferred,
        );
    }
}

extern "C" fn synchronize_fullscreen_toolbar_frame_deferred(context: *mut c_void) {
    let native_window = context as id;
    let closing_toolbar_window = FULLSCREEN_TOOLBAR_UPDATES_PENDING
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .remove(&(native_window as usize))
        .flatten();
    unsafe {
        let window_state = get_window_state(&*native_window);
        if let Some(closing_toolbar_window) = closing_toolbar_window {
            let mut state = window_state.lock();
            state.mark_fullscreen_toolbar_window_closed(closing_toolbar_window);
        }
        synchronize_fullscreen_content_view_frame(&window_state);
        let _: () = msg_send![native_window, release];
    }
}

extern "C" fn synchronize_fullscreen_content_view_frame_deferred(context: *mut c_void) {
    let native_window = context as id;
    unsafe {
        let window_state = get_window_state(&*native_window);
        synchronize_fullscreen_content_view_frame(&window_state);
        let _: () = msg_send![native_window, release];
    }
}

fn content_layout_rect_observer_context() -> *mut c_void {
    ptr::addr_of!(CONTENT_LAYOUT_RECT_OBSERVER_CONTEXT) as *mut c_void
}

fn clear_pending_fullscreen_toolbar_update(native_window: id) {
    if let Some(pending) = FULLSCREEN_TOOLBAR_UPDATES_PENDING.get() {
        pending.lock().remove(&(native_window as usize));
    }
}

fn fullscreen_presentation_options_update(proposed_options: NSUInteger) -> NSUInteger {
    // Let AppKit auto-hide the native fullscreen toolbar with the menu bar. GPUI
    // follows the auxiliary window's visible frame because contentLayoutRect does
    // not change during the toolbar reveal on the observed macOS version.
    proposed_options
}

fn fullscreen_content_view_frame(
    is_fullscreen: bool,
    is_exiting_fullscreen: bool,
    uses_full_size_content_view: bool,
    content_view_bounds: NSRect,
    content_layout_rect: NSRect,
) -> NSRect {
    if is_fullscreen && !is_exiting_fullscreen && uses_full_size_content_view {
        content_layout_rect
    } else {
        content_view_bounds
    }
}

fn fullscreen_toolbar_occlusion_depth(
    renderer_frame: NSRect,
    toolbar_frame: NSRect,
    content_view_is_flipped: bool,
    toolbar_is_visible: bool,
    toolbar_alpha_value: f64,
) -> f64 {
    const EDGE_TOLERANCE: f64 = 0.5;
    if !toolbar_is_visible
        || !toolbar_alpha_value.is_finite()
        || toolbar_alpha_value <= 0.0
        || !renderer_frame.origin.x.is_finite()
        || !renderer_frame.origin.y.is_finite()
        || !renderer_frame.size.width.is_finite()
        || renderer_frame.size.width <= 0.0
        || !renderer_frame.size.height.is_finite()
        || renderer_frame.size.height <= 0.0
        || !toolbar_frame.origin.x.is_finite()
        || !toolbar_frame.origin.y.is_finite()
        || !toolbar_frame.size.width.is_finite()
        || toolbar_frame.size.width <= 0.0
        || !toolbar_frame.size.height.is_finite()
        || toolbar_frame.size.height <= 0.0
    {
        return 0.0;
    }

    let renderer_right = renderer_frame.origin.x + renderer_frame.size.width;
    let renderer_top = renderer_frame.origin.y + renderer_frame.size.height;
    let toolbar_right = toolbar_frame.origin.x + toolbar_frame.size.width;
    let toolbar_top = toolbar_frame.origin.y + toolbar_frame.size.height;
    let overlap_left = renderer_frame.origin.x.max(toolbar_frame.origin.x);
    let overlap_right = renderer_right.min(toolbar_right);
    let overlap_bottom = renderer_frame.origin.y.max(toolbar_frame.origin.y);
    let overlap_top = renderer_top.min(toolbar_top);
    let overlap_width = overlap_right - overlap_left;
    let overlap_height = overlap_top - overlap_bottom;

    // This view hosts the whole tab row. A narrow auxiliary panel elsewhere in
    // the content area must not create a full-width empty band.
    if overlap_width < renderer_frame.size.width - EDGE_TOLERANCE || overlap_height <= 0.0 {
        return 0.0;
    }

    let reaches_content_top = if content_view_is_flipped {
        toolbar_frame.origin.y <= renderer_frame.origin.y + EDGE_TOLERANCE
    } else {
        toolbar_top >= renderer_top - EDGE_TOLERANCE
    };
    if !reaches_content_top {
        return 0.0;
    }

    overlap_height.min(renderer_frame.size.height)
}

fn fullscreen_empty_auxiliary_chrome_suppression_eligible(
    custom_transparent_fullsize_titlebar: bool,
    owned_auxiliary_window: bool,
    no_native_toolbar_or_accessories: bool,
    no_native_title_or_subtitle: bool,
    all_standard_buttons_hosted: bool,
    titlebar_container_is_visible: bool,
) -> bool {
    custom_transparent_fullsize_titlebar
        && owned_auxiliary_window
        && no_native_toolbar_or_accessories
        && no_native_title_or_subtitle
        && all_standard_buttons_hosted
        && titlebar_container_is_visible
}

fn fullscreen_auxiliary_titlebar_container_is_eligible(
    currently_hidden: bool,
    original_hidden: Option<bool>,
) -> bool {
    !original_hidden.unwrap_or(currently_hidden)
}

#[cfg(any(test, feature = "test-support"))]
fn fullscreen_renderer_top_gap(base_frame: NSRect, renderer_frame: NSRect, flipped: bool) -> f64 {
    if flipped {
        (renderer_frame.origin.y - base_frame.origin.y).max(0.0)
    } else {
        (base_frame.origin.y + base_frame.size.height
            - renderer_frame.origin.y
            - renderer_frame.size.height)
            .max(0.0)
    }
}

fn native_toolbar_or_titlebar_accessories_present(
    has_toolbar: bool,
    supports_titlebar: bool,
    accessory_count: impl FnOnce() -> Option<usize>,
) -> bool {
    has_toolbar || (supports_titlebar && accessory_count().is_none_or(|count| count > 0))
}

unsafe fn window_has_native_toolbar_or_accessories(window: id) -> bool {
    unsafe {
        let toolbar: id = msg_send![window, toolbar];
        let style_mask: NSWindowStyleMask = msg_send![window, styleMask];
        native_toolbar_or_titlebar_accessories_present(
            !toolbar.is_null(),
            style_mask.contains(NSWindowStyleMask::NSTitledWindowMask),
            || {
                // The selector exists on borderless NSWindow too, but invoking
                // it raises an Objective-C exception. Check the style first.
                let accessories: id = msg_send![window, titlebarAccessoryViewControllers];
                if accessories.is_null() {
                    None
                } else {
                    let count: NSUInteger = msg_send![accessories, count];
                    Some(count as usize)
                }
            },
        )
    }
}

fn fullscreen_content_view_frame_avoiding_toolbar(
    renderer_frame: NSRect,
    content_view_is_flipped: bool,
    toolbar_frame: Option<NSRect>,
    toolbar_is_visible: bool,
    toolbar_alpha_value: f64,
) -> NSRect {
    let Some(toolbar_frame) = toolbar_frame else {
        return renderer_frame;
    };
    let inset = fullscreen_toolbar_occlusion_depth(
        renderer_frame,
        toolbar_frame,
        content_view_is_flipped,
        toolbar_is_visible,
        toolbar_alpha_value,
    );
    if inset <= 0.0 || inset >= renderer_frame.size.height {
        return renderer_frame;
    }

    let mut frame = renderer_frame;
    frame.size.height -= inset;
    if content_view_is_flipped {
        frame.origin.y += inset;
    }
    frame
}

#[derive(Clone, Copy)]
struct FullscreenToolbarGeometry {
    frame_in_content_view: Option<NSRect>,
    is_visible: bool,
    alpha_value: f64,
    #[cfg(feature = "test-support")]
    is_occlusion_visible: bool,
}

fn fullscreen_toolbar_geometry(
    native_window: id,
    content_view: id,
    toolbar_window: Option<&Objc2NSWindow>,
) -> FullscreenToolbarGeometry {
    let Some(toolbar_window) = toolbar_window else {
        return FullscreenToolbarGeometry {
            frame_in_content_view: None,
            is_visible: false,
            alpha_value: 0.0,
            #[cfg(feature = "test-support")]
            is_occlusion_visible: false,
        };
    };

    unsafe {
        let native_window_objc = &*(native_window as *const Objc2NSWindow);
        let content_view_objc = &*(content_view as *const Objc2NSView);
        let toolbar_frame_in_window =
            native_window_objc.convertRectFromScreen(toolbar_window.frame());
        let toolbar_frame_in_view =
            content_view_objc.convertRect_fromView(toolbar_frame_in_window, None);
        #[cfg(feature = "test-support")]
        let toolbar_occlusion_state: NSWindowOcclusionState = {
            let toolbar_window_id = toolbar_window as *const Objc2NSWindow as id;
            msg_send![toolbar_window_id, occlusionState]
        };

        FullscreenToolbarGeometry {
            frame_in_content_view: Some(NSRect::new(
                NSPoint::new(
                    toolbar_frame_in_view.origin.x,
                    toolbar_frame_in_view.origin.y,
                ),
                NSSize::new(
                    toolbar_frame_in_view.size.width,
                    toolbar_frame_in_view.size.height,
                ),
            )),
            is_visible: toolbar_window.isVisible(),
            alpha_value: toolbar_window.alphaValue(),
            #[cfg(feature = "test-support")]
            is_occlusion_visible: toolbar_occlusion_state
                .contains(NSWindowOcclusionState::NSWindowOcclusionStateVisible),
        }
    }
}

#[cfg(feature = "test-support")]
pub struct FullscreenToolbarRevealObservation {
    pub renderer_frame: Objc2NSRect,
    pub expected_renderer_frame: Objc2NSRect,
    pub toolbar_frame_in_content_view: Option<Objc2NSRect>,
    pub toolbar_window_present: bool,
    pub empty_toolbar_suppressed: bool,
    pub toolbar_is_visible: bool,
    pub toolbar_alpha_value: Option<f64>,
    pub toolbar_occlusion_state_visible: bool,
    /// Raw measured overlap, retained for diagnostics even when native chrome is suppressed.
    pub toolbar_occlusion_height: f64,
    /// Renderer inset applied after checking whether owned empty auxiliary chrome is suppressed.
    pub applied_toolbar_occlusion_height: f64,
    /// Distance between the content layout top edge and the actual renderer top edge.
    pub extra_renderer_top_gap: f64,
}

/// Reports the live AppKit auxiliary-toolbar overlap and GPUI renderer frame
/// for a native fullscreen fixture window.
#[cfg(feature = "test-support")]
pub fn fullscreen_toolbar_reveal_observation(
    native_window: &Objc2NSWindow,
) -> Option<FullscreenToolbarRevealObservation> {
    if MainThreadMarker::new().is_none() {
        return None;
    }

    let native_window_id = native_window as *const Objc2NSWindow as id;
    if !unsafe { is_gpui_window(native_window_id) } {
        return None;
    }
    let object = unsafe { &*(native_window_id as *const Object) };
    let window_state = unsafe { get_window_state(object) };
    let (native_window_id, native_view, toolbar_window, empty_toolbar_suppressed) = {
        let state = window_state.lock();
        if state.closed.load(Ordering::Acquire)
            || !state.is_fullscreen()
            || state.is_exiting_fullscreen
        {
            return None;
        }
        (
            state.native_window,
            state.native_view.as_ptr() as id,
            state
                .fullscreen_traffic_light_overlay
                .as_ref()
                .and_then(|overlay| overlay.toolbar_window.clone()),
            state
                .fullscreen_traffic_light_overlay
                .as_ref()
                .and_then(|overlay| overlay.suppressed_auxiliary_chrome.as_ref())
                .is_some_and(FullscreenAuxiliaryChromeSnapshot::is_applied),
        )
    };

    unsafe {
        let content_view: id = msg_send![native_window_id, contentView];
        if content_view.is_null() {
            return None;
        }
        let content_view_bounds: NSRect = msg_send![content_view, bounds];
        let content_layout_rect: NSRect = msg_send![native_window_id, contentLayoutRect];
        let content_layout_rect_in_content_view: NSRect = msg_send![
            content_view,
            convertRect: content_layout_rect
            fromView: nil
        ];
        let style_mask: NSWindowStyleMask = msg_send![native_window_id, styleMask];
        let base_frame = fullscreen_content_view_frame(
            true,
            false,
            style_mask.contains(NSWindowStyleMask::NSFullSizeContentViewWindowMask),
            content_view_bounds,
            content_layout_rect_in_content_view,
        );
        let toolbar_geometry = fullscreen_toolbar_geometry(
            native_window_id,
            content_view,
            toolbar_window.as_ref().map(|window| &**window),
        );
        let content_view_is_flipped: BOOL = msg_send![content_view, isFlipped];
        let expected_renderer_frame = fullscreen_content_view_frame_avoiding_toolbar(
            base_frame,
            content_view_is_flipped == YES,
            if empty_toolbar_suppressed {
                None
            } else {
                toolbar_geometry.frame_in_content_view
            },
            toolbar_geometry.is_visible,
            toolbar_geometry.alpha_value,
        );
        let renderer_frame: NSRect = msg_send![native_view, frame];
        let toolbar_occlusion_height = toolbar_geometry
            .frame_in_content_view
            .map(|toolbar_frame| {
                fullscreen_toolbar_occlusion_depth(
                    base_frame,
                    toolbar_frame,
                    content_view_is_flipped == YES,
                    toolbar_geometry.is_visible,
                    toolbar_geometry.alpha_value,
                )
            })
            .unwrap_or(0.0);
        let applied_toolbar_occlusion_height = fullscreen_renderer_top_gap(
            base_frame,
            expected_renderer_frame,
            content_view_is_flipped == YES,
        );
        let extra_renderer_top_gap = fullscreen_renderer_top_gap(
            base_frame,
            renderer_frame,
            content_view_is_flipped == YES,
        );
        let to_objc_rect = |rect: NSRect| {
            Objc2NSRect::new(
                Objc2NSPoint::new(rect.origin.x, rect.origin.y),
                Objc2NSSize::new(rect.size.width, rect.size.height),
            )
        };
        Some(FullscreenToolbarRevealObservation {
            renderer_frame: to_objc_rect(renderer_frame),
            expected_renderer_frame: to_objc_rect(expected_renderer_frame),
            toolbar_frame_in_content_view: toolbar_geometry.frame_in_content_view.map(to_objc_rect),
            toolbar_window_present: toolbar_window.is_some(),
            empty_toolbar_suppressed,
            toolbar_is_visible: toolbar_geometry.is_visible,
            toolbar_alpha_value: toolbar_window
                .as_ref()
                .map(|_| toolbar_geometry.alpha_value),
            toolbar_occlusion_state_visible: toolbar_geometry.is_occlusion_visible,
            toolbar_occlusion_height,
            applied_toolbar_occlusion_height,
            extra_renderer_top_gap,
        })
    }
}

fn synchronize_fullscreen_content_view_frame(window_state: &Arc<Mutex<MacWindowState>>) {
    let (
        native_window,
        native_view,
        is_fullscreen,
        is_exiting_fullscreen,
        toolbar_window,
        empty_toolbar_suppressed,
    ) = {
        let mut state = window_state.lock();
        if state.closed.load(Ordering::Acquire) {
            return;
        }
        let is_fullscreen = state.is_fullscreen();
        if is_fullscreen && !state.is_exiting_fullscreen {
            state.refresh_fullscreen_toolbar_window_observer();
        } else {
            state.remove_fullscreen_toolbar_window_observer();
        }
        (
            state.native_window,
            state.native_view.as_ptr() as id,
            is_fullscreen,
            state.is_exiting_fullscreen,
            state
                .fullscreen_traffic_light_overlay
                .as_ref()
                .and_then(|overlay| overlay.toolbar_window.clone()),
            state
                .fullscreen_traffic_light_overlay
                .as_ref()
                .and_then(|overlay| overlay.suppressed_auxiliary_chrome.as_ref())
                .is_some_and(FullscreenAuxiliaryChromeSnapshot::is_applied),
        )
    };

    unsafe {
        let content_view: id = msg_send![native_window, contentView];
        let content_view_bounds: NSRect = msg_send![content_view, bounds];
        let content_layout_rect: NSRect = msg_send![native_window, contentLayoutRect];
        let content_layout_rect_in_content_view: NSRect = msg_send![
            content_view,
            convertRect: content_layout_rect
            fromView: nil
        ];
        let style_mask: NSWindowStyleMask = msg_send![native_window, styleMask];
        let target_frame = fullscreen_content_view_frame(
            is_fullscreen,
            is_exiting_fullscreen,
            style_mask.contains(NSWindowStyleMask::NSFullSizeContentViewWindowMask),
            content_view_bounds,
            content_layout_rect_in_content_view,
        );
        let content_view_objc = &*(content_view as *const Objc2NSView);
        let toolbar_geometry = fullscreen_toolbar_geometry(
            native_window,
            content_view,
            toolbar_window.as_ref().map(|window| &**window),
        );
        let target_frame = fullscreen_content_view_frame_avoiding_toolbar(
            target_frame,
            content_view_objc.isFlipped(),
            if empty_toolbar_suppressed {
                None
            } else {
                toolbar_geometry.frame_in_content_view
            },
            toolbar_geometry.is_visible,
            toolbar_geometry.alpha_value,
        );
        let current_frame: NSRect = msg_send![native_view, frame];
        if current_frame.origin.x != target_frame.origin.x
            || current_frame.origin.y != target_frame.origin.y
            || current_frame.size.width != target_frame.size.width
            || current_frame.size.height != target_frame.size.height
        {
            let _: () = msg_send![native_view, setFrame: target_frame];
            let mut state = window_state.lock();
            if state.fullscreen_controls_active {
                state.update_fullscreen_traffic_lights();
            }
        }
    }
}

extern "C" fn close_window(this: &Object, _: Sel) {
    unsafe {
        let (close_callback, simple_fullscreen_state) = {
            let window_state = get_window_state(this);
            let mut lock = window_state.as_ref().lock();
            lock.closed.store(true, Ordering::Release);
            lock.remove_fullscreen_toolbar_window_observer();
            clear_pending_fullscreen_toolbar_update(lock.native_window);
            (
                lock.close_callback.take(),
                lock.simple_fullscreen_state.take(),
            )
        };

        if simple_fullscreen_state.is_some() {
            pop_simple_fullscreen_presentation_options();
        }

        if let Some(callback) = close_callback {
            callback();
        }

        let _: () = msg_send![super(this, class!(NSWindow)), close];
    }
}

extern "C" fn make_backing_layer(this: &Object, _: Sel) -> id {
    let window_state = unsafe { get_window_state(this) };
    let window_state = window_state.as_ref().lock();
    window_state.renderer.layer_ptr() as id
}

extern "C" fn view_did_change_backing_properties(this: &Object, _: Sel) {
    let window_state = unsafe { get_window_state(this) };
    update_window_scale_factor(&window_state);
}

extern "C" fn set_frame_size(this: &Object, _: Sel, size: NSSize) {
    fn convert(value: NSSize) -> Size<Pixels> {
        Size {
            width: px(value.width as f32),
            height: px(value.height as f32),
        }
    }

    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();

    let new_size = convert(size);
    let old_size = unsafe {
        let old_frame: NSRect = msg_send![this, frame];
        convert(old_frame.size)
    };

    if old_size == new_size {
        return;
    }

    unsafe {
        let _: () = msg_send![super(this, class!(NSView)), setFrameSize: size];
    }

    let scale_factor = lock.scale_factor();
    let drawable_size = new_size.to_device_pixels(scale_factor);
    lock.renderer.update_drawable_size(drawable_size);

    if let Some(mut callback) = lock.resize_callback.take() {
        let content_size = lock.content_size();
        let scale_factor = lock.scale_factor();
        drop(lock);
        callback(content_size, scale_factor);
        window_state.lock().resize_callback = Some(callback);
    };
}

extern "C" fn display_layer(this: &Object, _: Sel, _: id) {
    let signal_at = PlatformFrameSignal::capture(scheduler::Instant::now);
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.lock();
    if let Some(mut callback) = lock.request_frame_callback.take() {
        lock.renderer.set_presents_with_transaction(true);
        lock.stop_display_link();
        drop(lock);
        callback(RequestFrameOptions {
            signal_at,
            signal_source: FrameRequestSource::NativeCallback,
            ..Default::default()
        });

        let mut lock = window_state.lock();
        lock.request_frame_callback = Some(callback);
        lock.renderer.set_presents_with_transaction(false);
        lock.start_display_link();
    }
}

extern "C" fn step(view: *mut c_void) {
    let view = view as id;
    let window_state = unsafe { get_window_state(&*view) };
    let mut lock = window_state.lock();

    if let Some(mut callback) = lock.request_frame_callback.take() {
        let (signal_at, signal_source) = lock
            .frame_source
            .as_ref()
            .and_then(WindowFrameSource::take_signal)
            .map_or(
                (None, FrameRequestSource::NativeCallback),
                |(at, source)| (Some(at), source),
            );
        drop(lock);
        callback(RequestFrameOptions {
            signal_at,
            signal_source,
            ..Default::default()
        });
        window_state.lock().request_frame_callback = Some(callback);
    }
}

extern "C" fn valid_attributes_for_marked_text(_: &Object, _: Sel) -> id {
    unsafe { msg_send![class!(NSArray), array] }
}

extern "C" fn has_marked_text(this: &Object, _: Sel) -> BOOL {
    let has_marked_text_result =
        with_input_handler(this, |input_handler| input_handler.marked_text_range()).flatten();

    has_marked_text_result.is_some() as BOOL
}

extern "C" fn marked_range(this: &Object, _: Sel) -> NSRange {
    let marked_range_result =
        with_input_handler(this, |input_handler| input_handler.marked_text_range()).flatten();

    marked_range_result.map_or(NSRange::invalid(), |range| range.into())
}

extern "C" fn selected_range(this: &Object, _: Sel) -> NSRange {
    let selected_range_result = with_input_handler(this, |input_handler| {
        input_handler.selected_text_range(false)
    })
    .flatten();

    selected_range_result.map_or(NSRange::invalid(), |selection| selection.range.into())
}

extern "C" fn first_rect_for_character_range(
    this: &Object,
    _: Sel,
    range: NSRange,
    _: id,
) -> NSRect {
    let frame = get_frame(this);
    with_input_handler(this, |input_handler| {
        input_handler.bounds_for_range(range.to_range()?)
    })
    .flatten()
    .map_or(
        NSRect::new(NSPoint::new(0., 0.), NSSize::new(0., 0.)),
        |bounds| {
            NSRect::new(
                NSPoint::new(
                    frame.origin.x + bounds.origin.x.as_f32() as f64,
                    frame.origin.y + frame.size.height
                        - bounds.origin.y.as_f32() as f64
                        - bounds.size.height.as_f32() as f64,
                ),
                NSSize::new(
                    bounds.size.width.as_f32() as f64,
                    bounds.size.height.as_f32() as f64,
                ),
            )
        },
    )
}

fn get_frame(this: &Object) -> NSRect {
    unsafe {
        let state = get_window_state(this);
        let lock = state.lock();
        let native_view = lock.native_view.as_ptr() as id;
        let native_window = lock.native_window;
        let view_bounds: NSRect = msg_send![native_view, bounds];
        let view_frame_in_window: NSRect =
            msg_send![native_view, convertRect: view_bounds toView: nil];
        msg_send![native_window, convertRectToScreen: view_frame_in_window]
    }
}

extern "C" fn insert_text(this: &Object, _: Sel, text: id, replacement_range: NSRange) {
    unsafe {
        let is_attributed_string: BOOL =
            msg_send![text, isKindOfClass: [class!(NSAttributedString)]];
        let text: id = if is_attributed_string == YES {
            msg_send![text, string]
        } else {
            text
        };

        let text = text.to_str();
        let replacement_range = replacement_range.to_range();
        with_input_handler(this, |input_handler| {
            input_handler.replace_text_in_range(replacement_range, text)
        });
    }
}

extern "C" fn set_marked_text(
    this: &Object,
    _: Sel,
    text: id,
    selected_range: NSRange,
    replacement_range: NSRange,
) {
    unsafe {
        let is_attributed_string: BOOL =
            msg_send![text, isKindOfClass: [class!(NSAttributedString)]];
        let text: id = if is_attributed_string == YES {
            msg_send![text, string]
        } else {
            text
        };
        let selected_range = selected_range.to_range();
        let replacement_range = replacement_range.to_range();
        let text = text.to_str();
        with_input_handler(this, |input_handler| {
            input_handler.replace_and_mark_text_in_range(replacement_range, text, selected_range)
        });
    }
}
extern "C" fn unmark_text(this: &Object, _: Sel) {
    with_input_handler(this, |input_handler| input_handler.unmark_text());
}

extern "C" fn attributed_substring_for_proposed_range(
    this: &Object,
    _: Sel,
    range: NSRange,
    actual_range: *mut c_void,
) -> id {
    with_input_handler(this, |input_handler| {
        let range = range.to_range()?;
        if range.is_empty() {
            return None;
        }
        let mut adjusted: Option<Range<usize>> = None;

        let selected_text = input_handler.text_for_range(range.clone(), &mut adjusted)?;
        if let Some(adjusted) = adjusted
            && adjusted != range
        {
            unsafe { (actual_range as *mut NSRange).write(NSRange::from(adjusted)) };
        }
        unsafe {
            let string: id = msg_send![class!(NSAttributedString), alloc];
            let string: id = msg_send![string, initWithString: ns_string(&selected_text)];
            Some(string)
        }
    })
    .flatten()
    .unwrap_or(nil)
}

// We ignore which selector it asks us to do because the user may have
// bound the shortcut to something else.
extern "C" fn do_command_by_selector(this: &Object, _: Sel, _: Sel) {
    let state = unsafe { get_window_state(this) };
    let mut lock = state.as_ref().lock();
    let keystroke = lock.keystroke_for_do_command.take();
    let mut event_callback = lock.event_callback.take();
    drop(lock);

    if let Some((keystroke, callback)) = keystroke.zip(event_callback.as_mut()) {
        let handled = (callback)(PlatformInput::KeyDown(KeyDownEvent {
            keystroke,
            is_held: false,
            prefer_character_input: false,
        }));
        state.as_ref().lock().do_command_handled = Some(!handled.propagate);
    }

    state.as_ref().lock().event_callback = event_callback;
}

extern "C" fn view_did_change_effective_appearance(this: &Object, _: Sel) {
    unsafe {
        let state = get_window_state(this);
        let appearance_changed_callback = {
            let mut lock = state.as_ref().lock();
            lock.appearance_changed_callback.take()
        };

        if let Some(mut callback) = appearance_changed_callback {
            callback();
            state.lock().appearance_changed_callback = Some(callback);
        }

        // AppKit can relayout the standard traffic light buttons as part of
        // applying a new appearance, so reapply GPUI's custom position.
        state.lock().move_traffic_light();
    }
}

extern "C" fn accepts_first_mouse(this: &Object, _: Sel, _: id) -> BOOL {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    lock.first_mouse = true;
    YES
}

// Reports which region of the view AppKit should treat as app-owned titlebar content
// (rather than a system-owned window-move region). When `app_owns_titlebar_drag` is
// true, we claim the entire view so AppKit neither drags the window from the titlebar
// nor waits to disambiguate double-clicks before delivering titlebar clicks (the macOS
// 27 delay); such windows implement dragging themselves via [`Window::start_window_move`].
// Otherwise we return an empty rect so AppKit's native titlebar dragging keeps working.
// This is independent of `NSWindow.isMovable`, so the Window-menu tiling items stay
// enabled regardless.
extern "C" fn opaque_rect_for_window_move_when_in_titlebar(this: &Object, _: Sel) -> NSRect {
    let zero_rect = NSRect::new(NSPoint::new(0., 0.), NSSize::new(0., 0.));
    let window_state = unsafe { get_window_state(this) };
    let app_owns_titlebar_drag = window_state.as_ref().lock().app_owns_titlebar_drag;
    if app_owns_titlebar_drag {
        unsafe { msg_send![this, bounds] }
    } else {
        zero_rect
    }
}

extern "C" fn character_index_for_point(this: &Object, _: Sel, position: NSPoint) -> u64 {
    let position = screen_point_to_gpui_point(this, position);
    with_input_handler(this, |input_handler| {
        input_handler.character_index_for_point(position)
    })
    .flatten()
    .map(|index| index as u64)
    .unwrap_or(NSNotFound as u64)
}

fn screen_point_to_gpui_point(this: &Object, position: NSPoint) -> Point<Pixels> {
    let frame = get_frame(this);
    let window_x = position.x - frame.origin.x;
    let window_y = frame.size.height - (position.y - frame.origin.y);

    point(px(window_x as f32), px(window_y as f32))
}

fn is_drag_from_this_window(this: &Object, dragging_info: id) -> bool {
    let source: id = unsafe { msg_send![dragging_info, draggingSource] };
    std::ptr::eq(source as *const Object, this as *const Object)
}

extern "C" fn dragging_entered(this: &Object, _: Sel, dragging_info: id) -> NSDragOperation {
    let is_source_window = is_drag_from_this_window(this, dragging_info);
    let window_state = unsafe { get_window_state(this) };
    let position = drag_event_position(&window_state, dragging_info);
    let paths = external_paths_from_event(dragging_info);
    if let Some(event) = paths.map(|paths| FileDropEvent::Entered { position, paths })
        && send_file_drop_event(window_state, event)
    {
        if is_source_window {
            return NSDragOperationMove;
        }
        return NSDragOperationCopy;
    }
    NSDragOperationNone
}

extern "C" fn dragging_updated(this: &Object, _: Sel, dragging_info: id) -> NSDragOperation {
    let is_source_window = is_drag_from_this_window(this, dragging_info);
    let window_state = unsafe { get_window_state(this) };
    let position = drag_event_position(&window_state, dragging_info);
    if send_file_drop_event(window_state, FileDropEvent::Pending { position }) {
        if is_source_window {
            NSDragOperationMove
        } else {
            NSDragOperationCopy
        }
    } else {
        NSDragOperationNone
    }
}

extern "C" fn dragging_exited(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    send_file_drop_event(window_state, FileDropEvent::Exited);
}

extern "C" fn perform_drag_operation(this: &Object, _: Sel, dragging_info: id) -> BOOL {
    let window_state = unsafe { get_window_state(this) };
    let position = drag_event_position(&window_state, dragging_info);
    send_file_drop_event(window_state, FileDropEvent::Submit { position }).to_objc()
}

fn external_paths_from_event(dragging_info: *mut Object) -> Option<ExternalPaths> {
    let mut paths = SmallVec::new();
    let pasteboard: id = unsafe { msg_send![dragging_info, draggingPasteboard] };
    let filenames = unsafe { NSPasteboard::propertyListForType(pasteboard, NSFilenamesPboardType) };
    if filenames == nil {
        return None;
    }
    for file in unsafe { filenames.iter() } {
        let path = unsafe {
            let f = NSString::UTF8String(file);
            CStr::from_ptr(f).to_string_lossy().into_owned()
        };
        paths.push(PathBuf::from(path))
    }
    Some(ExternalPaths(paths))
}

extern "C" fn conclude_drag_operation(this: &Object, _: Sel, _: id) {
    let window_state = unsafe { get_window_state(this) };
    send_file_drop_event(window_state, FileDropEvent::Exited);
}

extern "C" fn dragging_session_source_operation_mask(
    _: &Object,
    _: Sel,
    _: id,
    context: NSInteger,
) -> NSDragOperation {
    let operation = match context {
        NSDRAGGING_CONTEXT_OUTSIDE_APPLICATION => NSDragOperationCopy,
        NSDRAGGING_CONTEXT_WITHIN_APPLICATION => NSDragOperationCopy | NSDragOperationMove,
        _ => NSDragOperationCopy | NSDragOperationMove,
    };
    log::debug!(
        "dragging_session_source_operation_mask: context={}, operation={}",
        context,
        operation
    );
    operation
}

extern "C" fn dragging_session_ended(
    this: &Object,
    _: Sel,
    _: id,
    _: NSPoint,
    operation: NSDragOperation,
) {
    log::debug!("dragging_session_ended operation={operation}");
    // SAFETY: AppKit invokes this selector on the GPUIWindow instance registered in build_classes,
    // which always has WINDOW_STATE_IVAR initialized to the owning MacWindowState.
    let window_state = unsafe { get_window_state(this) };
    {
        let mut lock = window_state.lock();
        lock.synthetic_drag_counter += 1;
        lock.last_left_mouse_down_event = None;
    }
    send_file_drop_event(window_state, FileDropEvent::Ended);
}

fn synthetic_drag_button_is_pressed(button: Option<MouseButton>, pressed: NSUInteger) -> bool {
    let bit = match button {
        Some(MouseButton::Left) => 0,
        Some(MouseButton::Right) => 1,
        Some(MouseButton::Middle) => 2,
        Some(MouseButton::Navigate(gpui::NavigationDirection::Back)) => 3,
        Some(MouseButton::Navigate(gpui::NavigationDirection::Forward)) => 4,
        None => return false,
    };
    pressed & (1 << bit) != 0
}

async fn synthetic_drag(
    window_state: Weak<Mutex<MacWindowState>>,
    drag_id: usize,
    event: MouseMoveEvent,
    executor: BackgroundExecutor,
) {
    loop {
        executor.timer(Duration::from_millis(16)).await;
        let Some(window_state) = window_state.upgrade() else {
            break;
        };
        let mut lock = window_state.lock();
        if lock.synthetic_drag_counter != drag_id {
            break;
        }
        // Native menu tracking can consume mouse-up, leaving stale drag events replaying.
        // Check whether the original mouse button is still physically pressed before replaying.
        let pressed: NSUInteger = unsafe { msg_send![class!(NSEvent), pressedMouseButtons] };
        if !synthetic_drag_button_is_pressed(event.pressed_button, pressed) {
            lock.synthetic_drag_counter += 1;
            break;
        }
        if let Some(mut callback) = lock.event_callback.take() {
            drop(lock);
            callback(PlatformInput::MouseMove(event.clone()));
            window_state.lock().event_callback = Some(callback);
        }
    }
}

/// Sends the specified FileDropEvent using `PlatformInput::FileDrop` to the window
/// state and updates the window state according to the event passed.
fn send_file_drop_event(
    window_state: Arc<Mutex<MacWindowState>>,
    file_drop_event: FileDropEvent,
) -> bool {
    let external_files_dragged = match file_drop_event {
        FileDropEvent::Entered { .. } => Some(true),
        FileDropEvent::Exited | FileDropEvent::Ended => Some(false),
        _ => None,
    };

    let mut lock = window_state.lock();
    if let Some(mut callback) = lock.event_callback.take() {
        drop(lock);
        callback(PlatformInput::FileDrop(file_drop_event));
        let mut lock = window_state.lock();
        lock.event_callback = Some(callback);
        if let Some(external_files_dragged) = external_files_dragged {
            lock.external_files_dragged = external_files_dragged;
        }
        true
    } else {
        false
    }
}

fn drag_event_position(window_state: &Mutex<MacWindowState>, dragging_info: id) -> Point<Pixels> {
    let drag_location: NSPoint = unsafe { msg_send![dragging_info, draggingLocation] };
    let (native_view, view_height) = {
        let state = window_state.lock();
        (
            state.native_view.as_ptr() as id,
            state.content_size().height,
        )
    };
    convert_mouse_position(drag_location, native_view, view_height)
}

fn with_input_handler<F, R>(window: &Object, f: F) -> Option<R>
where
    F: FnOnce(&mut PlatformInputHandler) -> R,
{
    let window_state = unsafe { get_window_state(window) };
    let mut lock = window_state.as_ref().lock();
    if let Some(mut input_handler) = lock.input_handler.take() {
        drop(lock);
        let result = f(&mut input_handler);
        window_state.lock().input_handler = Some(input_handler);
        Some(result)
    } else {
        None
    }
}

fn display_id_for_screen(screen: id) -> Option<CGDirectDisplayID> {
    if screen.is_null() {
        return None;
    }

    unsafe {
        let device_description = NSScreen::deviceDescription(screen);
        let screen_number_key: id = ns_string("NSScreenNumber");
        let screen_number = device_description.objectForKey_(screen_number_key);
        let screen_number: NSUInteger = msg_send![screen_number, unsignedIntegerValue];
        Some(screen_number as CGDirectDisplayID)
    }
}

extern "C" fn blurred_view_init_with_frame(this: &Object, _: Sel, frame: NSRect) -> id {
    unsafe {
        let view = msg_send![super(this, class!(NSVisualEffectView)), initWithFrame: frame];
        // A window-background material, whose tint and extra saturation
        // `blurred_view_update_layer` strips, leaving only the blur. `Selection`, used before,
        // has no `CABackdropLayer` on macOS 27, so nothing behind the window was blurred. (Setting
        // a material also avoids the deprecated default, `AppearanceBased`.)
        NSVisualEffectView::setMaterial_(view, NSVisualEffectMaterial::UnderWindowBackground);
        // The default, but blurring what's behind the window is this view's whole purpose.
        NSVisualEffectView::setBlendingMode_(view, NSVisualEffectBlendingMode::BehindWindow);
        NSVisualEffectView::setState_(view, NSVisualEffectState::Active);
        view
    }
}

extern "C" fn blurred_view_update_layer(this: &Object, _: Sel) {
    unsafe {
        let _: () = msg_send![super(this, class!(NSVisualEffectView)), updateLayer];
        let layer: id = msg_send![this, layer];
        if !layer.is_null() {
            remove_layer_background(layer);
        }
    }
}

unsafe fn remove_layer_background(layer: id) {
    unsafe {
        let _: () = msg_send![layer, setBackgroundColor:nil];

        let class_name: id = msg_send![layer, className];
        if class_name.isEqualToString("CAChameleonLayer") {
            // Remove the desktop tinting effect.
            let _: () = msg_send![layer, setHidden: YES];
            return;
        }

        let filters: id = msg_send![layer, filters];
        if !filters.is_null() {
            // Remove the increased saturation.
            // The effect of a `CAFilter` or `CIFilter` is determined by its name, and the
            // `description` reflects its name and some parameters. Currently `NSVisualEffectView`
            // uses a `CAFilter` named "colorSaturate". If one day they switch to `CIFilter`, the
            // `description` will still contain "Saturat" ("... inputSaturation = ...").
            let test_string: id = ns_string("Saturat");
            let count = NSArray::count(filters);
            for i in 0..count {
                let description: id = msg_send![filters.objectAtIndex(i), description];
                let hit: BOOL = msg_send![description, containsString: test_string];
                if hit == NO {
                    continue;
                }

                let all_indices = NSRange {
                    location: 0,
                    length: count,
                };
                let indices: id = msg_send![class!(NSMutableIndexSet), indexSet];
                let _: () = msg_send![indices, addIndexesInRange: all_indices];
                let _: () = msg_send![indices, removeIndex:i];
                let filtered: id = msg_send![filters, objectsAtIndexes: indices];
                let _: () = msg_send![layer, setFilters: filtered];
                break;
            }
        }

        let sublayers: id = msg_send![layer, sublayers];
        if !sublayers.is_null() {
            let count = NSArray::count(sublayers);
            for i in 0..count {
                let sublayer = sublayers.objectAtIndex(i);
                remove_layer_background(sublayer);
            }
        }
    }
}

extern "C" fn add_titlebar_accessory_view_controller(this: &Object, _: Sel, view_controller: id) {
    unsafe {
        let _: () = msg_send![super(this, class!(NSWindow)), addTitlebarAccessoryViewController: view_controller];

        // Hide the native tab bar and set its height to 0, since we render our own.
        let accessory_view: id = msg_send![view_controller, view];
        let _: () = msg_send![accessory_view, setHidden: YES];
        let mut frame: NSRect = msg_send![accessory_view, frame];
        frame.size.height = 0.0;
        let _: () = msg_send![accessory_view, setFrame: frame];
    }
}

extern "C" fn move_tab_to_new_window(this: &Object, _: Sel, _: id) {
    unsafe {
        let _: () = msg_send![super(this, class!(NSWindow)), moveTabToNewWindow:nil];

        let window_state = get_window_state(this);
        let mut lock = window_state.as_ref().lock();
        if let Some(mut callback) = lock.move_tab_to_new_window_callback.take() {
            drop(lock);
            callback();
            window_state.lock().move_tab_to_new_window_callback = Some(callback);
        }
    }
}

extern "C" fn merge_all_windows(this: &Object, _: Sel, _: id) {
    unsafe {
        let _: () = msg_send![super(this, class!(NSWindow)), mergeAllWindows:nil];

        let window_state = get_window_state(this);
        let mut lock = window_state.as_ref().lock();
        if let Some(mut callback) = lock.merge_all_windows_callback.take() {
            drop(lock);
            callback();
            window_state.lock().merge_all_windows_callback = Some(callback);
        }
    }
}

extern "C" fn select_next_tab(this: &Object, _sel: Sel, _id: id) {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    if let Some(mut callback) = lock.select_next_tab_callback.take() {
        drop(lock);
        callback();
        window_state.lock().select_next_tab_callback = Some(callback);
    }
}

extern "C" fn select_previous_tab(this: &Object, _sel: Sel, _id: id) {
    let window_state = unsafe { get_window_state(this) };
    let mut lock = window_state.as_ref().lock();
    if let Some(mut callback) = lock.select_previous_tab_callback.take() {
        drop(lock);
        callback();
        window_state.lock().select_previous_tab_callback = Some(callback);
    }
}

extern "C" fn toggle_tab_bar(this: &Object, _sel: Sel, _id: id) {
    unsafe {
        let _: () = msg_send![super(this, class!(NSWindow)), toggleTabBar:nil];

        let window_state = get_window_state(this);
        let mut lock = window_state.as_ref().lock();
        lock.move_traffic_light();

        if let Some(mut callback) = lock.toggle_tab_bar_callback.take() {
            drop(lock);
            callback();
            window_state.lock().toggle_tab_bar_callback = Some(callback);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_native_rect_eq(left: NSRect, right: NSRect) {
        assert_eq!(left.origin.x, right.origin.x);
        assert_eq!(left.origin.y, right.origin.y);
        assert_eq!(left.size.width, right.size.width);
        assert_eq!(left.size.height, right.size.height);
    }

    #[test]
    fn fullscreen_content_layout_moves_renderer_only_while_obscured() {
        let content_bounds = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(1000.0, 700.0));
        let hidden_menu_layout = content_bounds;
        let revealed_menu_layout = NSRect::new(NSPoint::new(0.0, 17.0), NSSize::new(1000.0, 620.0));

        let hidden_frame =
            fullscreen_content_view_frame(true, false, true, content_bounds, hidden_menu_layout);
        assert_native_rect_eq(hidden_frame, content_bounds);

        let revealed_frame =
            fullscreen_content_view_frame(true, false, true, content_bounds, revealed_menu_layout);
        assert_native_rect_eq(revealed_frame, revealed_menu_layout);

        let exit_frame =
            fullscreen_content_view_frame(true, true, true, content_bounds, revealed_menu_layout);
        assert_native_rect_eq(exit_frame, content_bounds);

        let windowed_frame = fullscreen_content_view_frame(
            false,
            false,
            false,
            content_bounds,
            revealed_menu_layout,
        );
        assert_native_rect_eq(windowed_frame, content_bounds);

        let native_titlebar_frame =
            fullscreen_content_view_frame(true, false, false, content_bounds, revealed_menu_layout);
        assert_native_rect_eq(native_titlebar_frame, content_bounds);
    }

    #[test]
    fn fullscreen_toolbar_overlap_trims_only_visible_full_width_top_occlusion() {
        let content = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(1000.0, 700.0));
        let toolbar = NSRect::new(NSPoint::new(0.0, 668.0), NSSize::new(1000.0, 32.0));

        assert_eq!(
            fullscreen_toolbar_occlusion_depth(content, toolbar, false, true, 1.0),
            32.0
        );
        assert_eq!(
            fullscreen_toolbar_occlusion_depth(content, toolbar, false, false, 1.0),
            0.0
        );
        assert_eq!(
            fullscreen_toolbar_occlusion_depth(content, toolbar, false, true, 0.0),
            0.0
        );

        let partly_outside_top = NSRect::new(NSPoint::new(0.0, 684.0), NSSize::new(1000.0, 32.0));
        assert_eq!(
            fullscreen_toolbar_occlusion_depth(content, partly_outside_top, false, true, 1.0),
            16.0
        );

        let flipped_toolbar = NSRect::new(NSPoint::new(0.0, -16.0), NSSize::new(1000.0, 32.0));
        assert_eq!(
            fullscreen_toolbar_occlusion_depth(content, flipped_toolbar, true, true, 1.0),
            16.0
        );

        let narrow_toolbar = NSRect::new(NSPoint::new(0.0, 668.0), NSSize::new(900.0, 32.0));
        let away_from_top = NSRect::new(NSPoint::new(0.0, 100.0), NSSize::new(1000.0, 32.0));
        assert_eq!(
            fullscreen_toolbar_occlusion_depth(content, narrow_toolbar, false, true, 1.0),
            0.0
        );
        assert_eq!(
            fullscreen_toolbar_occlusion_depth(content, away_from_top, false, true, 1.0),
            0.0
        );
    }

    #[test]
    fn fullscreen_toolbar_frame_restores_when_auxiliary_toolbar_hides() {
        let content = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(1000.0, 700.0));
        let toolbar = NSRect::new(NSPoint::new(0.0, 668.0), NSSize::new(1000.0, 32.0));
        let unflipped = fullscreen_content_view_frame_avoiding_toolbar(
            content,
            false,
            Some(toolbar),
            true,
            1.0,
        );
        assert_native_rect_eq(
            unflipped,
            NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(1000.0, 668.0)),
        );

        let flipped = fullscreen_content_view_frame_avoiding_toolbar(
            content,
            true,
            Some(NSRect::new(
                NSPoint::new(0.0, 0.0),
                NSSize::new(1000.0, 32.0),
            )),
            true,
            1.0,
        );
        assert_native_rect_eq(
            flipped,
            NSRect::new(NSPoint::new(0.0, 32.0), NSSize::new(1000.0, 668.0)),
        );

        let hidden = fullscreen_content_view_frame_avoiding_toolbar(
            content,
            false,
            Some(toolbar),
            false,
            1.0,
        );
        assert_native_rect_eq(hidden, content);
        let missing_toolbar =
            fullscreen_content_view_frame_avoiding_toolbar(content, false, None, true, 1.0);
        assert_native_rect_eq(missing_toolbar, content);
    }

    #[test]
    fn borderless_auxiliary_window_never_queries_titlebar_accessories() {
        assert!(!native_toolbar_or_titlebar_accessories_present(false, false, || {
            panic!("borderless AppKit windows reject titlebar accessory queries")
        }));
    }

    #[test]
    fn native_toolbar_blocks_suppression_without_querying_accessories() {
        for supports_titlebar in [false, true] {
            assert!(native_toolbar_or_titlebar_accessories_present(true, supports_titlebar, || {
                panic!("a toolbar already prevents empty chrome suppression")
            }));
        }
    }

    #[test]
    fn titled_window_accessories_preserve_nonempty_and_unknown_chrome() {
        assert!(!native_toolbar_or_titlebar_accessories_present(false, true, || Some(0)));
        assert!(native_toolbar_or_titlebar_accessories_present(false, true, || Some(1)));
        assert!(native_toolbar_or_titlebar_accessories_present(false, true, || None));
    }

    #[test]
    fn fullscreen_empty_auxiliary_suppression_requires_every_safety_gate() {
        assert!(fullscreen_empty_auxiliary_chrome_suppression_eligible(
            true, true, true, true, true, true
        ));
        for failed_gate in 0..6 {
            let mut gates = [true; 6];
            gates[failed_gate] = false;
            assert!(!fullscreen_empty_auxiliary_chrome_suppression_eligible(
                gates[0], gates[1], gates[2], gates[3], gates[4], gates[5]
            ));
        }
    }

    #[test]
    fn fullscreen_empty_auxiliary_reconciliation_uses_saved_container_visibility() {
        assert!(!fullscreen_auxiliary_titlebar_container_is_eligible(true, None));
        assert!(fullscreen_auxiliary_titlebar_container_is_eligible(false, None));
        // The hidden container belongs to our active suppression; use its saved
        // visible state so a geometry notification can safely reapply settings.
        assert!(fullscreen_auxiliary_titlebar_container_is_eligible(true, Some(false)));
        assert!(!fullscreen_auxiliary_titlebar_container_is_eligible(false, Some(true)));
    }

    #[test]
    fn fullscreen_renderer_top_gap_reports_content_layout_delta() {
        let base = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(1000.0, 700.0));
        let inset_unflipped = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(1000.0, 668.0));
        let inset_flipped = NSRect::new(NSPoint::new(0.0, 32.0), NSSize::new(1000.0, 668.0));

        assert_eq!(fullscreen_renderer_top_gap(base, inset_unflipped, false), 32.0);
        assert_eq!(fullscreen_renderer_top_gap(base, inset_flipped, true), 32.0);
        assert_eq!(fullscreen_renderer_top_gap(base, base, false), 0.0);
        assert_eq!(fullscreen_renderer_top_gap(base, base, true), 0.0);
    }

    #[test]
    fn fullscreen_presentation_options_preserve_appkit_toolbar_behavior() {
        let proposed_options = (Objc2NSApplicationPresentationOptions::FullScreen
            | Objc2NSApplicationPresentationOptions::AutoHideMenuBar
            | Objc2NSApplicationPresentationOptions::AutoHideToolbar)
            .0 as NSUInteger;
        assert_eq!(
            fullscreen_presentation_options_update(proposed_options),
            proposed_options
        );
    }

    #[test]
    fn fullscreen_titlebar_appearance_preserves_configured_transparency() {
        assert_eq!(
            fullscreen_titlebar_appearance_update(true, true),
            Some(true)
        );
        assert_eq!(
            fullscreen_titlebar_appearance_update(false, true),
            Some(false)
        );
        assert_eq!(fullscreen_titlebar_appearance_update(true, false), None);
    }

    fn traffic_light_frames() -> TrafficLightFrames {
        TrafficLightFrames {
            titlebar: Objc2NSRect::new(Objc2NSPoint::new(0.0, 0.0), Objc2NSSize::new(300.0, 38.0)),
            close: Objc2NSRect::new(Objc2NSPoint::new(7.0, 16.0), Objc2NSSize::new(14.0, 14.0)),
            minimize: Objc2NSRect::new(Objc2NSPoint::new(27.0, 16.0), Objc2NSSize::new(14.0, 14.0)),
            zoom: Objc2NSRect::new(Objc2NSPoint::new(47.0, 16.0), Objc2NSSize::new(14.0, 14.0)),
        }
    }

    #[test]
    fn fullscreen_traffic_light_host_keeps_original_button_y_near_top() {
        let bounds = Objc2NSRect::new(Objc2NSPoint::new(5.0, 7.0), Objc2NSSize::new(900.0, 600.0));
        let layout = fullscreen_traffic_light_layout(
            bounds,
            false,
            false,
            traffic_light_frames(),
            6.0,
            9.0,
            9.0,
        )
        .unwrap();

        assert_eq!(layout.host_frame.origin, Objc2NSPoint::new(5.0, 568.0));
        assert_eq!(layout.host_frame.size, Objc2NSSize::new(72.0, 39.0));
        assert_eq!(layout.close_origin, Objc2NSPoint::new(9.0, 16.0));
        assert_eq!(layout.minimize_origin, Objc2NSPoint::new(29.0, 16.0));
        assert_eq!(layout.zoom_origin, Objc2NSPoint::new(49.0, 16.0));

        // If AppKit restores the source titlebar-local y=16 after reparenting,
        // the small host still keeps the control within the configured top inset.
        let restored_y = traffic_light_frames().close.origin.y;
        let top_inset = layout.host_frame.size.height - restored_y - 14.0;
        assert_eq!(top_inset, 9.0);
    }

    #[test]
    fn fullscreen_traffic_light_host_anchors_at_top_for_both_content_orientations() {
        let bounds = Objc2NSRect::new(Objc2NSPoint::new(-4.0, 5.0), Objc2NSSize::new(900.0, 600.0));
        let frames = traffic_light_frames();

        let unflipped =
            fullscreen_traffic_light_layout(bounds, false, false, frames, 6.0, 9.0, 9.0).unwrap();
        let flipped =
            fullscreen_traffic_light_layout(bounds, true, false, frames, 6.0, 9.0, 9.0).unwrap();
        let flipped_host =
            fullscreen_traffic_light_layout(bounds, false, true, frames, 6.0, 9.0, 9.0).unwrap();

        assert_eq!(unflipped.host_frame.origin.y, 566.0);
        assert_eq!(flipped.host_frame.origin.y, 5.0);
        assert_eq!(unflipped.host_frame.origin.x, -4.0);
        assert_eq!(flipped.host_frame.origin.x, -4.0);
        assert_eq!(flipped_host.close_origin.y, 9.0);
    }

    #[test]
    fn display_id_for_screen_returns_none_for_null_screen() {
        assert_eq!(display_id_for_screen(nil), None);
    }
}
