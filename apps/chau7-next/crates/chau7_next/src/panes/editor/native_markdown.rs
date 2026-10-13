//! Real AppKit source layout; raw text, selection and undo belong to NSTextView.
//! The NSScrollView is attached only while its GPUI source element is mounted.
#[cfg(feature = "native-parity-fixture")]
pub(super) mod fixture;

mod editing;
mod host;
mod styles;

use super::{EditorPane, SaveEditor, ToggleMarkdownMode};
use chau7_next_core::editor::{config::EditorConfig, live_markdown::Document, text as edtext};
use futures::{StreamExt, channel::mpsc};
use gpui::{
    AnyElement, App, Bounds, Context, Element, ElementId, GlobalElementId, InspectorElementId,
    IntoElement, LayoutId, Pixels, Window,
};
use gpui_kit::{base::Root, component::WindowExt};
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send,
    rc::{Retained, Weak},
    runtime::AnyObject,
    sel,
};
use objc2_app_kit::{
    NSApplication, NSAutoresizingMaskOptions, NSClipView, NSColor, NSEvent, NSEventModifierFlags,
    NSFont, NSFontAttributeName, NSForegroundColorAttributeName, NSMenuItem, NSRulerOrientation,
    NSRulerView, NSScrollView, NSStringDrawing, NSTextInputClient, NSTextView, NSView,
};
#[cfg(feature = "native-parity-fixture")]
use objc2_app_kit::{
    NSSelectionAffinity, NSTextInputContext, NSTextStorage,
    NSTextStorageDidProcessEditingNotification, NSWindow,
};
#[cfg(feature = "native-parity-fixture")]
use objc2_foundation::{NSArray, NSNotification, NSNotificationCenter, NSValue};
use objc2_foundation::{
    NSDictionary, NSObjectProtocol, NSPoint, NSRange, NSRect, NSSize, NSString, NSUndoManager,
};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

#[derive(Clone, Copy)]
enum Action {
    Save,
    Toggle,
    Jump,
}
#[derive(Default)]
pub(super) struct Pending {
    text: Option<String>,
    selection: Option<NSRange>,
    focused: bool,
    actions: Vec<Action>,
}
impl Pending {
    fn is_empty(&self) -> bool {
        self.text.is_none() && self.selection.is_none() && !self.focused && self.actions.is_empty()
    }
    pub(super) fn clear_for_load(&mut self) {
        *self = Self::default();
    }
    pub(super) fn text(&self) -> Option<&str> {
        self.text.as_deref()
    }
    /// Drain only edits; the already-enqueued signal still owns actions/focus.
    pub(super) fn take_edits(
        &mut self,
        mirrored: &str,
    ) -> (Option<String>, Option<std::ops::Range<usize>>) {
        let text = self.text.take();
        let current = text.as_deref().unwrap_or(mirrored);
        let selection = self.selection.take().map(|selection| {
            let start = utf16_to_byte(current, selection.location);
            let end = utf16_to_byte(current, selection.location + selection.length);
            start..end
        });
        (text, selection)
    }
    #[cfg(test)]
    pub(super) fn typed(&mut self, text: &str, selection: NSRange) {
        self.text = Some(text.to_string());
        self.selection = Some(selection);
    }
}

#[derive(Clone, Copy)]
pub(super) enum MenuCommand {
    Cut,
    Copy,
    Paste,
    SelectAll,
    Find,
    FindNext,
    FindPrevious,
    UseSelectionForFind,
}
#[cfg(feature = "native-parity-fixture")]
#[derive(Default)]
struct FixtureTrace {
    enabled: Cell<bool>,
    sequence: Cell<u64>,
    started_at: Cell<Option<std::time::Instant>>,
    last_marked: Cell<Option<bool>>,
    transition_stack: RefCell<Option<String>>,
    events: RefCell<Vec<serde_json::Value>>,
}
#[cfg(feature = "native-parity-fixture")]
impl FixtureTrace {
    const CAPACITY: usize = 96;

    fn begin(&self, view: &SourceTextView, site: &'static str) {
        self.events.borrow_mut().clear();
        self.sequence.set(0);
        self.started_at.set(Some(std::time::Instant::now()));
        self.last_marked.set(None);
        *self.transition_stack.borrow_mut() = None;
        self.enabled.set(true);
        self.record(view, site, None);
    }

    fn record(&self, view: &SourceTextView, site: &'static str, responder_result: Option<bool>) {
        if !self.enabled.get() {
            return;
        }
        let marked = view.markedRange();
        let selected = view.selectedRange();
        let has_marked_text = view.hasMarkedText();
        let previous_marked = self.last_marked.replace(Some(has_marked_text));
        let transition_stack = if previous_marked == Some(true) && !has_marked_text {
            let mut saved_stack = self.transition_stack.borrow_mut();
            if saved_stack.is_none() {
                let stack = std::backtrace::Backtrace::force_capture()
                    .to_string()
                    .lines()
                    .take(16)
                    .collect::<Vec<_>>()
                    .join("\n")
                    .chars()
                    .take(2048)
                    .collect::<String>();
                *saved_stack = Some(stack.clone());
                Some(stack)
            } else {
                None
            }
        } else {
            None
        };
        let elapsed_micros = self
            .started_at
            .get()
            .map(|started| u64::try_from(started.elapsed().as_micros()).unwrap_or(u64::MAX));
        let current_event = MainThreadMarker::new()
            .and_then(|mtm| NSApplication::sharedApplication(mtm).currentEvent());
        let appkit_event_type = current_event.as_ref().map(|event| event.r#type().0);
        let appkit_event_timestamp = current_event.as_ref().map(|event| event.timestamp());
        let appkit_event_window_number = current_event.as_ref().map(|event| event.windowNumber());
        let window = view.window();
        let source_window_identity = window
            .as_ref()
            .map(|window| (&**window as *const NSWindow) as usize);
        let source_window_number = window.as_ref().map(|window| window.windowNumber());
        let window_key = window.as_ref().is_some_and(|window| window.isKeyWindow());
        let first_responder = window.as_ref().and_then(|window| window.firstResponder());
        let first_responder_identity = first_responder
            .as_ref()
            .map(|responder| (&**responder as *const _) as usize);
        let source_first_responder = first_responder
            .and_then(|responder| responder.downcast::<SourceTextView>().ok())
            .is_some_and(|source| std::ptr::eq(&*source, view));
        let application_active = MainThreadMarker::new()
            .is_some_and(|mtm| NSApplication::sharedApplication(mtm).isActive());
        let source_context_id = view
            .inputContext()
            .map(|context| (&*context as *const NSTextInputContext) as usize);
        let current_context_id = MainThreadMarker::new()
            .and_then(NSTextInputContext::currentInputContext)
            .map(|context| (&*context as *const NSTextInputContext) as usize);
        let sequence = self.sequence.get().saturating_add(1);
        self.sequence.set(sequence);
        let event = serde_json::json!({
            "sequence": sequence,
            "elapsed_micros": elapsed_micros,
            "site": site,
            "has_marked_text": has_marked_text,
            "marked_location": marked.location,
            "marked_length": marked.length,
            "selection_location": selected.location,
            "selection_length": selected.length,
            "appkit_event_type": appkit_event_type,
            "appkit_event_timestamp_seconds": appkit_event_timestamp,
            "appkit_event_window_number": appkit_event_window_number,
            "source_window_identity": source_window_identity,
            "source_window_number": source_window_number,
            "window_key": window_key,
            "first_responder_identity": first_responder_identity,
            "source_first_responder": source_first_responder,
            "application_active": application_active,
            "source_input_context_id": source_context_id,
            "current_input_context_id": current_context_id,
            "source_context_is_current": source_context_id.is_some() && source_context_id == current_context_id,
            "responder_result": responder_result,
            "first_observed_marked_to_unmarked_stack": transition_stack,
        });
        let mut events = self.events.borrow_mut();
        if events.len() == Self::CAPACITY {
            events.remove(0);
        }
        events.push(event);
    }

    fn record_details(
        &self,
        view: &SourceTextView,
        site: &'static str,
        details: serde_json::Value,
    ) {
        self.record(view, site, None);
        if !self.enabled.get() {
            return;
        }
        if let Some(event) = self.events.borrow_mut().last_mut() {
            event["details"] = details;
        }
    }

    fn finish(&self, failed: bool) {
        if !self.enabled.replace(false) || !failed {
            return;
        }
        let events = self.events.borrow().clone();
        let transition_stack = self.transition_stack.borrow().clone();
        eprintln!(
            "native_editor_marked_trace={}",
            serde_json::json!({
                "capacity": Self::CAPACITY,
                "events": events,
                "first_observed_marked_to_unmarked_stack": transition_stack,
            })
        );
    }
}

#[cfg(feature = "native-parity-fixture")]
#[derive(Clone, Copy)]
struct FixtureAttachDecision {
    bounds: [f32; 4],
    actual_scroll_frame: [f64; 4],
    needs_reparent: bool,
    scroll_frame_set: bool,
    text_frame_set: bool,
    hidden_set: bool,
    text_target_width: Option<f64>,
    text_actual_width: Option<f64>,
}

struct Shared {
    document: RefCell<Document>,
    theme: RefCell<styles::Theme>,
    config: RefCell<EditorConfig>,
    pending: Rc<RefCell<Pending>>,
    queued: Rc<Cell<bool>>,
    sender: mpsc::UnboundedSender<()>,
    line_starts: RefCell<Vec<usize>>,
    ruler: RefCell<Option<Weak<LineRuler>>>,
    mirroring: Cell<bool>,
    deferred_style: Cell<bool>,
    host: host::SourceHost,
    #[cfg(feature = "native-parity-fixture")]
    fixture_trace: Rc<FixtureTrace>,
}
impl Shared {
    fn signal(&self) {
        if !self.queued.replace(true) && self.sender.unbounded_send(()).is_err() {
            self.queued.set(false);
        }
    }
    fn changed(&self, view: &SourceTextView, text_changed: bool) {
        #[cfg(feature = "native-parity-fixture")]
        self.fixture_trace
            .record(view, "Shared::changed.enter", None);
        if self.mirroring.get() {
            #[cfg(feature = "native-parity-fixture")]
            self.fixture_trace
                .record(view, "Shared::changed.skip_mirroring", None);
            return;
        }
        if text_changed {
            let text = view.string().to_string();
            let mut doc = self.document.borrow_mut();
            doc.update(&text);
            *self.line_starts.borrow_mut() = line_starts(&text);
            if let Some(ruler) = self.ruler.borrow().as_ref().and_then(Weak::load) {
                ruler.resize(self.line_starts.borrow().len());
                ruler.setNeedsDisplay(true);
            }
            if view.hasMarkedText() {
                // NSTextInputClient owns both the marked range and its
                // attributes until composition commits. Replacing paragraph
                // attributes here can remove AppKit's marked-text metadata.
                #[cfg(feature = "native-parity-fixture")]
                self.fixture_trace
                    .record(view, "Shared::changed.defer_style_marked", None);
                self.deferred_style.set(true);
            } else if let Some(storage) = unsafe { view.textStorage() } {
                let range = if self.deferred_style.replace(false) {
                    0..text.len()
                } else {
                    doc.restyled_range()
                };
                #[cfg(feature = "native-parity-fixture")]
                self.fixture_trace
                    .record(view, "Shared::changed.theme_apply.before", None);
                self.theme.borrow().apply(&storage, &doc, range);
                #[cfg(feature = "native-parity-fixture")]
                self.fixture_trace
                    .record(view, "Shared::changed.theme_apply.after", None);
            }
            self.pending.borrow_mut().text = Some(text);
        }
        let mut pending = self.pending.borrow_mut();
        pending.selection = Some(view.selectedRange());
        drop(pending);
        self.signal();
        #[cfg(feature = "native-parity-fixture")]
        self.fixture_trace
            .record(view, "Shared::changed.exit", None);
    }
}
/// Use the entity's current window, with no ownership of its original host.
/// Failed updates leave the complete queue intact until the next actual mount.
fn start_delivery(
    pending: Rc<RefCell<Pending>>,
    queued: Rc<Cell<bool>>,
    mut receiver: mpsc::UnboundedReceiver<()>,
    cx: &Context<EditorPane>,
    #[cfg(feature = "native-parity-fixture")] fixture_trace: Option<Rc<FixtureTrace>>,
) {
    cx.spawn(async move |this, cx| {
        while receiver.next().await.is_some() {
            queued.set(false);
            if this.upgrade().is_none() {
                break;
            }
            let _ = this.update_in(cx, |this, window, cx| {
                let mut pending = std::mem::take(&mut *pending.borrow_mut());
                #[cfg(feature = "native-parity-fixture")]
                let pending_text = pending.text.is_some();
                #[cfg(feature = "native-parity-fixture")]
                let pending_selection = pending.selection.is_some();
                #[cfg(feature = "native-parity-fixture")]
                let pending_focused = pending.focused;
                #[cfg(feature = "native-parity-fixture")]
                let pending_actions = pending.actions.len();
                #[cfg(feature = "native-parity-fixture")]
                if let (Some(trace), Some(native)) =
                    (fixture_trace.as_ref(), this.native_markdown.as_ref())
                {
                    trace.record_details(&native.text, "EditorPane::delivery.before_take_edits", serde_json::json!({
                        "pending_text": pending_text, "pending_selection": pending_selection,
                        "pending_focused": pending_focused, "pending_action_count": pending_actions,
                        "gpui_focus_handle_focused": this.focus_handle.is_focused(window),
                    }));
                }
                let (text, selection) = pending.take_edits(&this.state.read(cx).value());
                #[cfg(feature = "native-parity-fixture")]
                if let (Some(trace), Some(native)) =
                    (fixture_trace.as_ref(), this.native_markdown.as_ref())
                {
                    trace.record_details(&native.text, "EditorPane::delivery.after_take_edits", serde_json::json!({
                        "taken_text": text.is_some(), "taken_selection": selection.is_some(),
                        "gpui_focus_handle_focused": this.focus_handle.is_focused(window),
                    }));
                }
                if this.mirror_native_edits(text, selection, window, cx) {
                    this.schedule_autosave(cx);
                }
                #[cfg(feature = "native-parity-fixture")]
                if let (Some(trace), Some(native)) =
                    (fixture_trace.as_ref(), this.native_markdown.as_ref())
                {
                    trace.record_details(&native.text, "EditorPane::delivery.after_mirror", serde_json::json!({
                        "pending_text": pending_text, "pending_selection": pending_selection,
                        "pending_focused": pending_focused, "pending_action_count": pending_actions,
                        "gpui_focus_handle_focused": this.focus_handle.is_focused(window),
                    }));
                }
                if pending.focused {
                    #[cfg(feature = "native-parity-fixture")]
                    if let (Some(trace), Some(native)) =
                        (fixture_trace.as_ref(), this.native_markdown.as_ref())
                    {
                        trace.record_details(&native.text, "EditorPane::delivery.before_window_focus", serde_json::json!({
                            "pending_focused": pending_focused,
                        }));
                    }
                    window.focus(&this.focus_handle, cx);
                    #[cfg(feature = "native-parity-fixture")]
                    if let (Some(trace), Some(native)) =
                        (fixture_trace.as_ref(), this.native_markdown.as_ref())
                    {
                        trace.record_details(&native.text, "EditorPane::delivery.after_window_focus", serde_json::json!({
                            "pending_focused": pending_focused,
                        }));
                    }
                    cx.emit(super::SidePaneEvent::Focused);
                } else {
                    #[cfg(feature = "native-parity-fixture")]
                    if let (Some(trace), Some(native)) =
                        (fixture_trace.as_ref(), this.native_markdown.as_ref())
                    {
                        trace.record_details(&native.text, "EditorPane::delivery.window_focus_skipped", serde_json::json!({
                            "pending_focused": pending_focused,
                        }));
                    }
                }
                for action in pending.actions {
                    match action {
                        Action::Save => window.dispatch_action(Box::new(SaveEditor), cx),
                        Action::Toggle => window.dispatch_action(Box::new(ToggleMarkdownMode), cx),
                        Action::Jump => {
                            if let Some(native) = &this.native_markdown {
                                native.jump();
                            }
                        }
                    }
                }
                cx.notify();
            });
        }
    })
    .detach();
}
struct SourceIvars {
    shared: Rc<Shared>,
    history: editing::SourceHistory,
}
define_class!(
    #[unsafe(super = NSTextView)]
    #[name = "Chau7NextMarkdownSourceTextView"]
    #[thread_kind = MainThreadOnly]
    #[ivars = SourceIvars]
    struct SourceTextView;
    unsafe impl NSObjectProtocol for SourceTextView {}
    impl SourceTextView {
        #[unsafe(method_id(undoManager))]
        fn source_undo_manager(&self) -> Option<Retained<NSUndoManager>> {
            Some(self.ivars().history.manager())
        }
        #[unsafe(method(didChangeText))]
        fn changed(&self) {
            #[cfg(feature = "native-parity-fixture")]
            self.ivars().shared.fixture_trace.record(self, "SourceTextView::didChangeText.before_super", None);
            // SAFETY: exact NSTextView superclass selector and signature.
            unsafe { let _: ()=msg_send![super(self),didChangeText]; }
            #[cfg(feature = "native-parity-fixture")]
            self.ivars().shared.fixture_trace.record(self, "SourceTextView::didChangeText.after_super", None);
            self.ivars().shared.changed(self,true);
            #[cfg(feature = "native-parity-fixture")]
            self.ivars().shared.fixture_trace.record(self, "SourceTextView::didChangeText.after_changed", None);
        }
        #[unsafe(method(setSelectedRange:))]
        fn selected(&self, range:NSRange) {
            #[cfg(feature = "native-parity-fixture")]
            self.ivars().shared.fixture_trace.record(self, "SourceTextView::setSelectedRange.before_super", None);
            unsafe { let _: ()=msg_send![super(self),setSelectedRange:range]; }
            #[cfg(feature = "native-parity-fixture")]
            self.ivars().shared.fixture_trace.record(self, "SourceTextView::setSelectedRange.after_super", None);
            self.ivars().shared.changed(self,false);
        }
        #[cfg(feature = "native-parity-fixture")]
        #[unsafe(method(insertText:replacementRange:))]
        fn fixture_insert_text(&self, string: &AnyObject, replacement_range: NSRange) {
            self.ivars().shared.fixture_trace.record(
                self,
                "AppKit::insertText.before_super",
                None,
            );
            // SAFETY: preserve NSTextInputClient's implementation exactly once.
            unsafe {
                let _: () = msg_send![super(self), insertText: string, replacementRange: replacement_range];
            }
            self.ivars().shared.fixture_trace.record(
                self,
                "AppKit::insertText.after_super",
                None,
            );
        }
        #[cfg(feature = "native-parity-fixture")]
        #[unsafe(method(setMarkedText:selectedRange:replacementRange:))]
        fn fixture_set_marked_text(
            &self,
            string: &AnyObject,
            selected_range: NSRange,
            replacement_range: NSRange,
        ) {
            self.ivars().shared.fixture_trace.record(
                self,
                "AppKit::setMarkedText.before_super",
                None,
            );
            // SAFETY: preserve NSTextInputClient's implementation exactly once.
            unsafe {
                let _: () = msg_send![super(self), setMarkedText: string, selectedRange: selected_range, replacementRange: replacement_range];
            }
            self.ivars().shared.fixture_trace.record(
                self,
                "AppKit::setMarkedText.after_super",
                None,
            );
        }
        #[cfg(feature = "native-parity-fixture")]
        #[unsafe(method(unmarkText))]
        fn fixture_unmark_text(&self) {
            self.ivars().shared.fixture_trace.record(self, "AppKit::unmarkText.before_super", None);
            // SAFETY: preserve NSTextView's implementation exactly once.
            unsafe { let _: () = msg_send![super(self), unmarkText]; }
            self.ivars().shared.fixture_trace.record(self, "AppKit::unmarkText.after_super", None);
        }
        #[cfg(feature = "native-parity-fixture")]
        #[unsafe(method(setSelectedRange:affinity:stillSelecting:))]
        fn fixture_selected_affinity(
            &self,
            range: NSRange,
            affinity: NSSelectionAffinity,
            still_selecting: bool,
        ) {
            self.ivars().shared.fixture_trace.record(
                self,
                "SourceTextView::setSelectedRange_affinity.before_super",
                None,
            );
            // SAFETY: preserve NSTextView's exact selector and arguments once.
            unsafe {
                let _: () = msg_send![super(self), setSelectedRange: range, affinity: affinity, stillSelecting: still_selecting];
            }
            self.ivars().shared.fixture_trace.record(
                self,
                "SourceTextView::setSelectedRange_affinity.after_super",
                None,
            );
        }
        #[cfg(feature = "native-parity-fixture")]
        #[unsafe(method(setSelectedRanges:affinity:stillSelecting:))]
        fn fixture_selected_ranges_affinity(
            &self,
            ranges: &NSArray<NSValue>,
            affinity: NSSelectionAffinity,
            still_selecting: bool,
        ) {
            self.ivars().shared.fixture_trace.record(
                self,
                "SourceTextView::setSelectedRanges_affinity.before_super",
                None,
            );
            // SAFETY: preserve NSTextView's exact selector and arguments once.
            unsafe {
                let _: () = msg_send![super(self), setSelectedRanges: ranges, affinity: affinity, stillSelecting: still_selecting];
            }
            self.ivars().shared.fixture_trace.record(
                self,
                "SourceTextView::setSelectedRanges_affinity.after_super",
                None,
            );
        }
        #[cfg(feature = "native-parity-fixture")]
        #[unsafe(method(fixtureTextStorageDidProcessEditing:))]
        fn fixture_text_storage_did_process_editing(&self, notification: &NSNotification) {
            let Some(storage) = notification
                .object()
                .and_then(|object| object.downcast::<NSTextStorage>().ok())
            else {
                return;
            };
            let range = storage.editedRange();
            let edited_mask = storage.editedMask().0;
            let has_marked_text = self.hasMarkedText();
            let marked_range = self.markedRange();
            let attribute_edit_stack = if edited_mask == 1 && has_marked_text {
                let stack = format!("{:?}", std::backtrace::Backtrace::force_capture());
                Some(
                    stack
                        .lines()
                        .take(96)
                        .collect::<Vec<_>>()
                        .join("\n")
                        .chars()
                        .take(16 * 1024)
                        .collect::<String>(),
                )
            } else {
                None
            };
            self.ivars().shared.fixture_trace.record_details(
                self,
                "NSTextStorage::didProcessEditing",
                serde_json::json!({
                    "edited_mask": edited_mask,
                    "edited_range_location": range.location,
                    "edited_range_length": range.length,
                    "change_in_length": storage.changeInLength(),
                    "has_marked_text": has_marked_text,
                    "marked_range_location": marked_range.location,
                    "marked_range_length": marked_range.length,
                    "attribute_edit_stack": attribute_edit_stack,
                }),
            );
        }
        #[cfg(feature = "native-parity-fixture")]
        #[unsafe(method(becomeFirstResponder))]
        fn fixture_become_first_responder(&self) -> bool {
            self.ivars().shared.fixture_trace.record(self, "AppKit::becomeFirstResponder.before_super", None);
            // SAFETY: preserve NSResponder's implementation and return value.
            let result: bool = unsafe { msg_send![super(self), becomeFirstResponder] };
            self.ivars().shared.fixture_trace.record(
                self,
                "AppKit::becomeFirstResponder.after_super",
                Some(result),
            );
            result
        }
        #[cfg(feature = "native-parity-fixture")]
        #[unsafe(method(resignFirstResponder))]
        fn fixture_resign_first_responder(&self) -> bool {
            self.ivars().shared.fixture_trace.record(self, "AppKit::resignFirstResponder.before_super", None);
            // SAFETY: preserve NSResponder's implementation and return value.
            let result: bool = unsafe { msg_send![super(self), resignFirstResponder] };
            self.ivars().shared.fixture_trace.record(
                self,
                "AppKit::resignFirstResponder.after_super",
                Some(result),
            );
            result
        }
        #[unsafe(method(mouseDown:))]
        fn mouse_down(&self,event:&NSEvent) {
            self.ivars().shared.pending.borrow_mut().focused=true;
            self.ivars().shared.signal();
            if self.toggle_checkbox(event) {return;}
            unsafe { let _: ()=msg_send![super(self),mouseDown:event]; }
            self.ivars().shared.changed(self,false);
            self.highlight_bracket();
        }
        #[unsafe(method(keyDown:))]
        fn key_down(&self,event:&NSEvent) {
            unsafe {let _: ()=msg_send![super(self),keyDown:event];}
            self.ivars().shared.changed(self,false);
            self.highlight_bracket();
        }
        #[unsafe(method(insertTab:))]
        fn tab(&self,_sender:Option<&AnyObject>) { self.insert(&self.ivars().shared.config.borrow().tab_string(),self.selectedRange()); }
        #[unsafe(method(insertBacktab:))]
        fn backtab(&self,_sender:Option<&AnyObject>) {
            let text=self.string().to_string();let selected=self.selectedRange();let byte=utf16_to_byte(&text,selected.location);
            let tab=self.ivars().shared.config.borrow().tab_string();
            if let Some((start,len))=edtext::outdent(&text,byte,&tab) {
                self.insert("",bytes_to_range(&text,start..start+len));
                let shift=|n:usize| if n>=start+len {n-len} else {n.min(start)};
                let end=utf16_to_byte(&text,selected.location+selected.length);
                let now=self.string().to_string();self.setSelectedRange(bytes_to_range(&now,shift(byte)..shift(end)));
            }
        }
        #[unsafe(method(insertNewline:))]
        fn newline(&self,_sender:Option<&AnyObject>) {
            let text=self.string().to_string();let selected=self.selectedRange();
            let insert=if self.ivars().shared.config.borrow().auto_indent {edtext::newline_with_indent(&text,utf16_to_byte(&text,selected.location))} else {"\n".into()};
            self.insert(&insert,selected);
        }
        #[unsafe(method(performKeyEquivalent:))]
        fn equivalent(&self,event:&NSEvent)->bool {
            self.handle_equivalent(event)
        }
    }
);

#[cfg(feature = "native-parity-fixture")]
struct FixtureStorageObserver {
    center: Retained<NSNotificationCenter>,
    view: Retained<SourceTextView>,
    storage: Retained<NSTextStorage>,
}

#[cfg(feature = "native-parity-fixture")]
impl FixtureStorageObserver {
    fn register(view: &Retained<SourceTextView>) -> Result<Self, String> {
        let _mtm = MainThreadMarker::new()
            .ok_or("text-storage observer registration left the AppKit main thread")?;
        let storage = unsafe { view.textStorage() }
            .ok_or("native source view has no text storage for fixture observer")?;
        let center = NSNotificationCenter::defaultCenter();
        let observer: &AnyObject = view.as_ref();
        let observed_storage: &AnyObject = storage.as_ref();
        // SAFETY: the observer class declares this exact selector/signature,
        // and the notification object is the live storage owned by this view.
        unsafe {
            center.addObserver_selector_name_object(
                observer,
                sel!(fixtureTextStorageDidProcessEditing:),
                Some(NSTextStorageDidProcessEditingNotification),
                Some(observed_storage),
            );
        }
        Ok(Self {
            center,
            view: view.clone(),
            storage,
        })
    }
}

#[cfg(feature = "native-parity-fixture")]
impl Drop for FixtureStorageObserver {
    fn drop(&mut self) {
        let observer: &AnyObject = self.view.as_ref();
        let storage: &AnyObject = self.storage.as_ref();
        // SAFETY: remove only the exact name/object pair registered above.
        unsafe {
            self.center.removeObserver_name_object(
                observer,
                Some(NSTextStorageDidProcessEditingNotification),
                Some(storage),
            );
        }
    }
}

impl SourceTextView {
    fn handle_equivalent(&self, event: &NSEvent) -> bool {
        let flags = event.modifierFlags();
        let key = event
            .charactersIgnoringModifiers()
            .map(|s| s.to_string())
            .unwrap_or_default();
        if flags.contains(NSEventModifierFlags::Command) {
            let shift = flags.contains(NSEventModifierFlags::Shift);
            // GPUI's application Edit menu targets its own editor model. Native
            // source editing must consume these shortcuts with NSTextView's undo.
            match key.to_lowercase().as_str() {
                "z" => {
                    if let Some(undo) = self.undoManager() {
                        if shift {
                            undo.redo();
                        } else {
                            undo.undo();
                        }
                    }
                    return true;
                }
                "c" if !shift => {
                    unsafe {
                        self.copy(None);
                    }
                    return true;
                }
                "x" if !shift => {
                    unsafe {
                        self.cut(None);
                    }
                    return true;
                }
                "v" if !shift => {
                    unsafe {
                        self.paste(None);
                    }
                    return true;
                }
                "a" if !shift => {
                    unsafe {
                        self.selectAll(None);
                    }
                    self.ivars().shared.changed(self, false);
                    return true;
                }
                "g" => {
                    let item = NSMenuItem::new(self.mtm());
                    item.setTag(if shift { 3 } else { 2 });
                    unsafe {
                        self.performFindPanelAction(Some(&item));
                    }
                    return true;
                }
                _ => {}
            }

            let action = match (key.to_lowercase().as_str(), shift) {
                ("s", false) => Some(Action::Save),
                ("p", true) => Some(Action::Toggle),
                ("\\", true) => Some(Action::Jump),
                _ => None,
            };
            if let Some(action) = action {
                self.ivars()
                    .shared
                    .pending
                    .borrow_mut()
                    .actions
                    .push(action);
                self.ivars().shared.signal();
                return true;
            }
            if key.eq_ignore_ascii_case("f") && !shift {
                let item = NSMenuItem::new(self.mtm());
                item.setTag(1);
                unsafe {
                    self.performFindPanelAction(Some(&item));
                }
                return true;
            }
        }
        let handled: bool = unsafe { msg_send![super(self),performKeyEquivalent:event] };
        if handled {
            return true;
        }
        // Unhandled application shortcuts retain GPUI's normal dispatch path.
        self.ivars()
            .shared
            .host
            .view()
            .is_some_and(|v| v.performKeyEquivalent(event))
    }

    fn new(mtm: MainThreadMarker, shared: Rc<Shared>) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(SourceIvars {
            shared,
            history: editing::SourceHistory::new(mtm),
        });
        unsafe {
            msg_send![super(this),initWithFrame:NSRect::new(NSPoint::new(0.,0.),NSSize::new(400.,400.))]
        }
    }
    fn toggle_checkbox(&self, event: &NSEvent) -> bool {
        let Some(layout) = (unsafe { self.layoutManager() }) else {
            return false;
        };
        let Some(container) = (unsafe { self.textContainer() }) else {
            return false;
        };
        let origin = self.textContainerOrigin();
        let local = self.convertPoint_fromView(event.locationInWindow(), None);
        let point = NSPoint::new(local.x - origin.x, local.y - origin.y);
        let range = {
            let doc = self.ivars().shared.document.borrow();
            doc.runs()
                .iter()
                .filter(|r| {
                    matches!(
                        r.kind,
                        chau7_next_core::editor::live_markdown::Kind::TaskCheckbox(_)
                    )
                })
                .find_map(|r| {
                    let range = bytes_to_range(doc.text(), r.range.clone());
                    let glyphs = unsafe {
                        layout.glyphRangeForCharacterRange_actualCharacterRange(
                            range,
                            std::ptr::null_mut(),
                        )
                    };
                    let rect = layout.boundingRectForGlyphRange_inTextContainer(glyphs, &container);
                    (point.x >= rect.origin.x
                        && point.x < rect.origin.x + rect.size.width
                        && point.y >= rect.origin.y
                        && point.y < rect.origin.y + rect.size.height)
                        .then_some(range)
                })
        };
        let Some(range) = range else {
            return false;
        };
        let text = self.string().to_string();
        let byte = utf16_to_byte(&text, range.location);
        let checked = text
            .get(byte..)
            .is_some_and(|s| s.starts_with("[x]") || s.starts_with("[X]"));
        let selected = self.selectedRange();
        self.insert(if checked { "[ ]" } else { "[x]" }, range);
        self.setSelectedRange(selected);
        true
    }
    fn highlight_bracket(&self) {
        if !self.ivars().shared.config.borrow().bracket_matching {
            return;
        }
        let text = self.string().to_string();
        let cursor = utf16_to_byte(&text, self.selectedRange().location);
        if let Some(target) = edtext::matching_bracket(&text, cursor)
            && let Some(c) = text[target..].chars().next()
        {
            self.showFindIndicatorForRange(bytes_to_range(&text, target..target + c.len_utf8()));
        }
    }
    fn insert(&self, text: &str, range: NSRange) {
        // Actual user insertion API registers native undo and preserves IME semantics.
        unsafe {
            self.insertText_replacementRange(&NSString::from_str(text), range);
        }
    }
}

define_class!(
    #[unsafe(super = NSScrollView)]
    #[name = "Chau7NextMarkdownSourceScrollView"]
    #[thread_kind = MainThreadOnly]
    struct SourceScrollView;
    impl SourceScrollView {
        #[unsafe(method(reflectScrolledClipView:))]
        fn scrolled(&self,clip:&NSClipView) {
            unsafe {let _: ()=msg_send![super(self),reflectScrolledClipView:clip];}
            if let Some(ruler)=self.verticalRulerView() {ruler.setNeedsDisplay(true);}
        }
    }
);
impl SourceScrollView {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        unsafe {
            msg_send![super(Self::alloc(mtm).set_ivars(())),initWithFrame:NSRect::new(NSPoint::new(0.,0.),NSSize::new(400.,400.))]
        }
    }
}
struct RulerIvars {
    text: Weak<SourceTextView>,
    shared: Rc<Shared>,
}
define_class!(
    #[unsafe(super = NSRulerView)]
    #[name = "Chau7NextMarkdownLineRuler"]
    #[thread_kind = MainThreadOnly]
    #[ivars = RulerIvars]
    struct LineRuler;
    impl LineRuler {
        #[unsafe(method(drawHashMarksAndLabelsInRect:))]
        fn draw_numbers(&self,_rect:NSRect) {self.draw_lines();}
    }
);
impl LineRuler {
    fn new(
        mtm: MainThreadMarker,
        scroll: &NSScrollView,
        text: &SourceTextView,
        shared: Rc<Shared>,
    ) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(RulerIvars {
            text: Weak::new(text),
            shared,
        });
        let this: Retained<Self> = unsafe {
            msg_send![super(this),initWithScrollView:scroll,orientation:NSRulerOrientation::VerticalRuler]
        };
        this.setClientView(Some(text));
        this.setRuleThickness(40.);
        this
    }
    fn resize(&self, lines: usize) {
        let width = (lines.max(1).to_string().len().max(3) as f64) * 8. + 16.;
        if self.ruleThickness() != width {
            self.setRuleThickness(width);
            if let Some(scroll) = self.scrollView() {
                scroll.tile();
            }
        }
    }
    fn draw_lines(&self) {
        let Some(text) = self.ivars().text.load() else {
            return;
        };
        let Some(layout) = (unsafe { text.layoutManager() }) else {
            return;
        };
        let Some(container) = (unsafe { text.textContainer() }) else {
            return;
        };
        NSColor::controlBackgroundColor().setFill();
        objc2_app_kit::NSRectFill(self.bounds());
        let visible =
            layout.glyphRangeForBoundingRect_inTextContainer(text.visibleRect(), &container);
        let chars = unsafe {
            layout.characterRangeForGlyphRange_actualGlyphRange(visible, std::ptr::null_mut())
        };
        let font = NSFont::monospacedSystemFontOfSize_weight(11., 0.);
        let color = NSColor::secondaryLabelColor();
        let attrs = unsafe {
            NSDictionary::<NSString, AnyObject>::from_slices(
                &[NSFontAttributeName, NSForegroundColorAttributeName],
                &[&*font, &*color],
            )
        };
        let starts = self.ivars().shared.line_starts.borrow();
        let first = starts
            .partition_point(|s| *s < chars.location)
            .saturating_sub(1);
        let end = starts.partition_point(|s| *s <= chars.location + chars.length);
        let source = text.string();
        for (i, char_start) in starts[first..end].iter().enumerate() {
            if !ruler_start_valid(&source, *char_start) {
                continue;
            }
            let glyph = layout.glyphIndexForCharacterAtIndex(*char_start);
            let mut rect = unsafe {
                layout.lineFragmentRectForGlyphAtIndex_effectiveRange(glyph, std::ptr::null_mut())
            };
            let origin = text.textContainerOrigin();
            rect.origin.x += origin.x;
            rect.origin.y += origin.y;
            let rect = self.convertRect_fromView(rect, Some(&text));
            let label = NSString::from_str(&(first + i + 1).to_string());
            let size = unsafe { label.sizeWithAttributes(Some(&attrs)) };
            unsafe {
                label.drawAtPoint_withAttributes(
                    NSPoint::new(
                        self.ruleThickness() - size.width - 8.,
                        rect.origin.y + (rect.size.height - size.height) * 0.5,
                    ),
                    Some(&attrs),
                );
            }
        }
    }
}
// NSLayoutManager character indices and cached starts are UTF-16 units.
// NSString::len counts UTF-8 bytes and would admit an out-of-range final line
// after non-ASCII text, producing an invalid glyph-index lookup.
fn ruler_start_valid(text: &NSString, index: usize) -> bool {
    index < text.len_utf16()
}

fn line_starts(text: &str) -> Vec<usize> {
    let mut starts = vec![0];
    let mut units = 0;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        units += c.len_utf16();
        if c == '\r' && chars.peek() == Some(&'\n') {
            chars.next();
            units += 1;
            starts.push(units);
        } else if matches!(c, '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}') {
            starts.push(units);
        }
    }
    starts
}

pub(super) struct NativeMarkdown {
    scroll: Retained<SourceScrollView>,
    text: Retained<SourceTextView>,
    shared: Rc<Shared>,
    mount_generation: Cell<u64>,
    #[cfg(feature = "native-parity-fixture")]
    fixture_attach_decision: Cell<Option<FixtureAttachDecision>>,
}
impl NativeMarkdown {
    pub(super) fn create(
        window: &mut Window,
        cx: &mut Context<EditorPane>,
        pending: Rc<RefCell<Pending>>,
    ) -> Option<Rc<Self>> {
        let mtm = MainThreadMarker::new()?;
        let raw = raw_view(window)?;
        let (sender, receiver) = mpsc::unbounded();
        let config = Settings::get(cx).editor.config.clone();
        let shared = Rc::new(Shared {
            document: RefCell::new(Document::default()),
            theme: RefCell::new(styles::Theme::new(config.font_size as f64, mtm)),
            config: RefCell::new(config),
            pending,
            queued: Rc::new(Cell::new(false)),
            sender,
            line_starts: RefCell::new(vec![0]),
            ruler: RefCell::new(None),
            mirroring: Cell::new(false),
            deferred_style: Cell::new(false),
            host: host::SourceHost::new(&raw),
            #[cfg(feature = "native-parity-fixture")]
            fixture_trace: Rc::new(FixtureTrace::default()),
        });
        let text = SourceTextView::new(mtm, shared.clone());
        text.setFont(Some(&NSFont::systemFontOfSize(
            shared.config.borrow().font_size as f64,
        )));
        text.setEditable(true);
        text.setSelectable(true);
        text.setRichText(false);
        text.setAllowsUndo(true);
        text.setUsesFindBar(true);
        text.setIncrementalSearchingEnabled(true);
        text.setAutomaticQuoteSubstitutionEnabled(false);
        text.setAutomaticDashSubstitutionEnabled(false);
        text.setAutomaticTextReplacementEnabled(false);
        text.setAutomaticSpellingCorrectionEnabled(false);
        text.setTextContainerInset(NSSize::new(8., 8.));
        text.setVerticallyResizable(true);
        text.setMinSize(NSSize::new(0., 0.));
        text.setMaxSize(NSSize::new(f64::MAX, f64::MAX));
        let scroll = SourceScrollView::new(mtm);
        scroll.setDocumentView(Some(&text));
        scroll.setHasVerticalScroller(true);
        scroll.setAutohidesScrollers(true);
        let ruler = LineRuler::new(mtm, &scroll, &text, shared.clone());
        scroll.setVerticalRulerView(Some(&ruler));
        *shared.ruler.borrow_mut() = Some(Weak::new(&ruler));
        let result = Rc::new(Self {
            scroll,
            text,
            shared: shared.clone(),
            mount_generation: Cell::new(0),
            #[cfg(feature = "native-parity-fixture")]
            fixture_attach_decision: Cell::new(None),
        });
        #[cfg(feature = "native-parity-fixture")]
        start_delivery(
            shared.pending.clone(),
            shared.queued.clone(),
            receiver,
            cx,
            Some(shared.fixture_trace.clone()),
        );
        #[cfg(not(feature = "native-parity-fixture"))]
        start_delivery(shared.pending.clone(), shared.queued.clone(), receiver, cx);
        Some(result)
    }
    #[cfg(feature = "native-parity-fixture")]
    pub(super) fn fixture_record(&self, site: &'static str) {
        self.shared.fixture_trace.record(&self.text, site, None);
    }
    #[cfg(feature = "native-parity-fixture")]
    pub(super) fn fixture_record_details(&self, site: &'static str, details: serde_json::Value) {
        self.shared
            .fixture_trace
            .record_details(&self.text, site, details);
    }

    pub(super) fn has_pending_edits(&self) -> bool {
        self.shared.pending.borrow().text.is_some()
    }

    /// A completed explicit load supersedes queued input from the old document,
    /// even when the new file happens to contain identical text.
    pub(super) fn loaded(
        &self,
        text: &str,
        config: &EditorConfig,
        selection: std::ops::Range<usize>,
    ) {
        self.shared.pending.borrow_mut().clear_for_load();
        self.sync_inner(text, config, true);
        self.shared.mirroring.set(true);
        self.text.setSelectedRange(bytes_to_range(text, selection));
        self.text.scrollRangeToVisible(self.text.selectedRange());
        self.shared.mirroring.set(false);
    }

    pub(super) fn sync(&self, text: &str, config: &EditorConfig) {
        self.sync_inner(text, config, false);
    }
    fn sync_inner(&self, text: &str, config: &EditorConfig, loaded: bool) {
        #[cfg(feature = "native-parity-fixture")]
        self.shared
            .fixture_trace
            .record(&self.text, "NativeMarkdown::sync_inner.enter", None);
        if !loaded && self.text.hasMarkedText() {
            // A render/configuration pass must not overwrite an in-progress
            // native composition with its asynchronously delivered GPUI mirror.
            #[cfg(feature = "native-parity-fixture")]
            self.shared.fixture_trace.record(
                &self.text,
                "NativeMarkdown::sync_inner.marked_guard",
                None,
            );
            self.shared.deferred_style.set(true);
            return;
        }
        if !loaded && self.has_pending_edits() {
            #[cfg(feature = "native-parity-fixture")]
            self.shared.fixture_trace.record(
                &self.text,
                "NativeMarkdown::sync_inner.pending_guard",
                None,
            );
            return;
        }
        let size = config.font_size as f64;
        let size_changed = self.shared.theme.borrow().size() != size;
        if size_changed && let Some(mtm) = MainThreadMarker::new() {
            *self.shared.theme.borrow_mut() = styles::Theme::new(size, mtm);
        }
        *self.shared.config.borrow_mut() = config.clone();
        self.scroll.setHasVerticalRuler(config.show_line_numbers);
        self.scroll.setRulersVisible(config.show_line_numbers);
        let caret_color = if config.highlight_current_line {
            NSColor::controlAccentColor()
        } else {
            NSColor::textColor()
        };
        self.text.setInsertionPointColor(Some(&caret_color));
        self.text.setHorizontallyResizable(!config.word_wrap);
        self.text.setAutoresizingMask(if config.word_wrap {
            NSAutoresizingMaskOptions::ViewWidthSizable
        } else {
            NSAutoresizingMaskOptions::empty()
        });
        self.scroll.setHasHorizontalScroller(!config.word_wrap);
        if let Some(container) = unsafe { self.text.textContainer() } {
            container.setWidthTracksTextView(config.word_wrap);
            if !config.word_wrap {
                container.setContainerSize(NSSize::new(f64::MAX, f64::MAX));
            }
        }
        let same = self.shared.document.borrow().text() == text;
        if !same || loaded {
            #[cfg(feature = "native-parity-fixture")]
            self.shared.fixture_trace.record(
                &self.text,
                "NativeMarkdown::editing_replace.before",
                None,
            );
            *self.shared.line_starts.borrow_mut() = line_starts(text);
            if let Some(ruler) = self.shared.ruler.borrow().as_ref().and_then(Weak::load) {
                ruler.resize(self.shared.line_starts.borrow().len());
                ruler.setNeedsDisplay(true);
            }
            self.shared.mirroring.set(true);
            editing::replace(&self.text, text, loaded);
            self.shared.mirroring.set(false);
            #[cfg(feature = "native-parity-fixture")]
            self.shared.fixture_trace.record(
                &self.text,
                "NativeMarkdown::editing_replace.after",
                None,
            );
        }
        let mut doc = self.shared.document.borrow_mut();
        doc.update(text);
        let deferred_style = self.shared.deferred_style.replace(false);
        let range = if size_changed || loaded || deferred_style {
            0..text.len()
        } else {
            doc.restyled_range()
        };
        if let Some(storage) = unsafe { self.text.textStorage() } {
            #[cfg(feature = "native-parity-fixture")]
            self.shared.fixture_trace.record(
                &self.text,
                "NativeMarkdown::theme_apply.before",
                None,
            );
            self.shared.theme.borrow().apply(&storage, &doc, range);
            #[cfg(feature = "native-parity-fixture")]
            self.shared
                .fixture_trace
                .record(&self.text, "NativeMarkdown::theme_apply.after", None);
        }
    }
    pub(super) fn append(&self, expected: &str, addition: &str) -> bool {
        if !editing::append(&self.text, expected, addition) {
            return false;
        }
        // Capture the final string and restored selection before the synchronous
        // flush, regardless of how AppKit coalesces its change notifications.
        self.shared.changed(&self.text, true);
        true
    }

    /// GPUI application menu items use Chau7 actions rather than AppKit's
    /// responder selectors. Route them only when this native surface owns focus.
    pub(super) fn menu_command(&self, command: MenuCommand) -> bool {
        if self.scroll.isHidden() {
            return false;
        }
        let Some(responder) = self.scroll.window().and_then(|w| w.firstResponder()) else {
            return false;
        };
        if !responder
            .downcast_ref::<NSView>()
            .is_some_and(|v| v.isDescendantOf(&self.scroll))
        {
            return false;
        }
        let find_tag = match command {
            MenuCommand::Find => Some(1),
            MenuCommand::FindNext => Some(2),
            MenuCommand::FindPrevious => Some(3),
            MenuCommand::UseSelectionForFind => Some(7),
            _ => None,
        };
        if let Some(tag) = find_tag {
            let item = NSMenuItem::new(self.text.mtm());
            item.setTag(tag);
            unsafe {
                self.text.performFindPanelAction(Some(&item));
            }
            return true;
        }
        let selector = match command {
            MenuCommand::Cut => sel!(cut:),
            MenuCommand::Copy => sel!(copy:),
            MenuCommand::Paste => sel!(paste:),
            MenuCommand::SelectAll => sel!(selectAll:),
            _ => unreachable!(),
        };
        if !responder.respondsToSelector(selector) {
            return false;
        }
        // SAFETY: these are standard single-sender AppKit edit selectors and
        // the actual native first responder confirmed it implements the selector.
        unsafe {
            NSApplication::sharedApplication(self.text.mtm()).sendAction_to_from(
                selector,
                Some(&responder),
                None,
            )
        }
    }

    pub(super) fn jump(&self) {
        let text = self.text.string().to_string();
        let cursor = utf16_to_byte(&text, self.text.selectedRange().location);
        if let Some(target) = edtext::matching_bracket(&text, cursor) {
            self.text
                .setSelectedRange(bytes_to_range(&text, target..target));
            self.text.scrollRangeToVisible(self.text.selectedRange());
        }
    }
    fn attach(&self, window: &Window, bounds: Bounds<Pixels>) -> Option<u64> {
        if bounds.size.width <= gpui::px(0.) || bounds.size.height <= gpui::px(0.) {
            self.detach();
            return None;
        }
        let view = raw_view(window)?;
        let generation = self.mount_generation.get().wrapping_add(1);
        self.mount_generation.set(generation);
        self.shared.host.bind(&view);
        let needs_reparent = unsafe { self.scroll.superview() }
            .as_ref()
            .is_none_or(|v| !std::ptr::eq::<NSView>(&**v, &*view));
        let mut y = f64::from(f32::from(bounds.origin.y));
        let height = f64::from(f32::from(bounds.size.height));
        if !view.isFlipped() {
            y = view.bounds().size.height - y - height;
        }
        let frame = NSRect::new(
            NSPoint::new(f64::from(f32::from(bounds.origin.x)), y),
            NSSize::new(f64::from(f32::from(bounds.size.width)), height),
        );
        let previous_scroll_frame = self.scroll.frame();
        #[cfg(feature = "native-parity-fixture")]
        let previous_text_frame = self.text.frame();
        #[cfg(feature = "native-parity-fixture")]
        let old_parent_id = unsafe { self.scroll.superview() }
            .as_ref()
            .map(|parent| (&**parent as *const NSView) as usize);
        let scroll_frame_set = needs_reparent || previous_scroll_frame != frame;
        #[cfg(feature = "native-parity-fixture")]
        self.shared.fixture_trace.record(
            &self.text,
            "NativeMarkdown::attach.set_frame.before",
            None,
        );
        if scroll_frame_set {
            self.scroll.setFrame(frame);
        }
        #[cfg(feature = "native-parity-fixture")]
        self.shared.fixture_trace.record(
            &self.text,
            "NativeMarkdown::attach.set_frame.after",
            None,
        );
        if needs_reparent {
            #[cfg(feature = "native-parity-fixture")]
            self.shared.fixture_trace.record(
                &self.text,
                "NativeMarkdown::attach.add_subview.before",
                None,
            );
            view.addSubview(&self.scroll);
            #[cfg(feature = "native-parity-fixture")]
            self.shared.fixture_trace.record(
                &self.text,
                "NativeMarkdown::attach.add_subview.after",
                None,
            );
        }
        #[cfg(feature = "native-parity-fixture")]
        let mut text_frame_set = false;
        #[cfg(feature = "native-parity-fixture")]
        let mut text_target_width = None;
        if self.shared.config.borrow().word_wrap {
            let width = self.scroll.contentView().bounds().size.width;
            let mut frame = self.text.frame();
            #[cfg(feature = "native-parity-fixture")]
            {
                text_target_width = Some(width);
            }
            if frame.size.width != width {
                frame.size.width = width;
                #[cfg(feature = "native-parity-fixture")]
                self.shared.fixture_trace.record(
                    &self.text,
                    "NativeMarkdown::attach.text_frame.before",
                    None,
                );
                self.text.setFrame(frame);
                #[cfg(feature = "native-parity-fixture")]
                {
                    text_frame_set = true;
                    self.shared.fixture_trace.record(
                        &self.text,
                        "NativeMarkdown::attach.text_frame.after",
                        None,
                    );
                }
            }
        }
        let hidden_set = self.scroll.isHidden();
        if hidden_set {
            self.scroll.setHidden(false);
        }
        #[cfg(feature = "native-parity-fixture")]
        {
            let actual_scroll_frame = self.scroll.frame();
            let actual_text_frame = self.text.frame();
            let decision = FixtureAttachDecision {
                bounds: [
                    f32::from(bounds.origin.x),
                    f32::from(bounds.origin.y),
                    f32::from(bounds.size.width),
                    f32::from(bounds.size.height),
                ],
                actual_scroll_frame: [
                    actual_scroll_frame.origin.x,
                    actual_scroll_frame.origin.y,
                    actual_scroll_frame.size.width,
                    actual_scroll_frame.size.height,
                ],
                needs_reparent,
                scroll_frame_set,
                text_frame_set,
                hidden_set,
                text_target_width,
                text_actual_width: text_target_width.map(|_| actual_text_frame.size.width),
            };
            self.fixture_attach_decision.set(Some(decision));
            self.shared.fixture_trace.record_details(&self.text, "NativeMarkdown::attach.geometry", serde_json::json!({
                "needs_reparent": needs_reparent, "scroll_frame_set": scroll_frame_set,
                "text_frame_set": text_frame_set, "was_hidden": hidden_set,
                "is_hidden": self.scroll.isHidden(), "old_parent_id": old_parent_id,
                "host_view_id": (&*view as *const NSView) as usize,
                "previous_scroll_frame": [previous_scroll_frame.origin.x, previous_scroll_frame.origin.y,
                    previous_scroll_frame.size.width, previous_scroll_frame.size.height],
                "target_scroll_frame": [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height],
                "actual_scroll_frame": [actual_scroll_frame.origin.x, actual_scroll_frame.origin.y,
                    actual_scroll_frame.size.width, actual_scroll_frame.size.height],
                "previous_text_frame": [previous_text_frame.origin.x, previous_text_frame.origin.y,
                    previous_text_frame.size.width, previous_text_frame.size.height],
                "actual_text_frame": [actual_text_frame.origin.x, actual_text_frame.origin.y,
                    actual_text_frame.size.width, actual_text_frame.size.height],
                "text_target_width": text_target_width,
            }));
        }
        // A signal can arrive while a transferred pane has no mounted window.
        // Retry only on a real mount; never consume its edits/actions on failure.
        if !self.shared.pending.borrow().is_empty() {
            self.shared.signal();
        }
        Some(generation)
    }
    pub(super) fn detach(&self) {
        #[cfg(feature = "native-parity-fixture")]
        self.shared
            .fixture_trace
            .record(&self.text, "NativeMarkdown::detach.before", None);
        // Explicit modal/close/visibility teardown invalidates old frame guards.
        self.mount_generation
            .set(self.mount_generation.get().wrapping_add(1));
        self.shared.host.return_focus(&self.scroll);
        self.scroll.setHidden(true);
        self.scroll.removeFromSuperview();
        #[cfg(feature = "native-parity-fixture")]
        self.shared
            .fixture_trace
            .record(&self.text, "NativeMarkdown::detach.after", None);
    }
}
use crate::settings::Settings;
fn raw_view(window: &Window) -> Option<Retained<NSView>> {
    let handle = HasWindowHandle::window_handle(window).ok()?;
    let RawWindowHandle::AppKit(raw) = handle.as_raw() else {
        return None;
    };
    unsafe { Retained::retain(raw.ns_view.cast::<NSView>().as_ptr()) }
}
fn utf16_to_byte(text: &str, target: usize) -> usize {
    let mut units = 0;
    for (byte, c) in text.char_indices() {
        if units >= target {
            return byte;
        }
        units += c.len_utf16();
    }
    text.len()
}
fn bytes_to_range(text: &str, range: std::ops::Range<usize>) -> NSRange {
    let start = text[..range.start].encode_utf16().count();
    NSRange::new(start, text[range].encode_utf16().count())
}

impl Drop for NativeMarkdown {
    fn drop(&mut self) {
        // Clear the owned manager even if the NSScrollView was already detached.
        // This neither depends on a live window nor clears a sibling's history.
        self.text.ivars().history.clear();
        self.detach();
    }
}

struct Attachment {
    native: Rc<NativeMarkdown>,
    generation: u64,
}
impl Attachment {
    fn for_mount(previous: Option<Self>, native: &Rc<NativeMarkdown>, generation: u64) -> Self {
        if let Some(mut previous) = previous
            && Rc::ptr_eq(&previous.native, native)
        {
            previous.generation = generation;
            previous
        } else {
            Self {
                native: native.clone(),
                generation,
            }
        }
    }
}
impl Drop for Attachment {
    fn drop(&mut self) {
        // A previous frame/window must not detach a newly mounted same source.
        if self.native.mount_generation.get() == self.generation {
            self.native.detach();
        }
    }
}
pub(super) struct NativeSource {
    native: Rc<NativeMarkdown>,
    child: AnyElement,
}
pub(super) fn element(native: Rc<NativeMarkdown>, child: impl IntoElement) -> NativeSource {
    NativeSource {
        native,
        child: child.into_any_element(),
    }
}
impl IntoElement for NativeSource {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}
impl Element for NativeSource {
    type RequestLayoutState = ();
    type PrepaintState = ();
    fn id(&self) -> Option<ElementId> {
        Some("native-markdown-source".into())
    }
    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }
    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        (self.child.request_layout(window, cx), ())
    }
    fn prepaint(
        &mut self,
        id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) {
        self.child.prepaint(window, cx);
        let allowed = !window.has_active_prompt()
            && !window
                .context_stack()
                .iter()
                .any(|c| c.contains("PopupMenu"))
            && !window.has_active_dialog(cx)
            && !window.has_active_sheet(cx)
            && Root::read(window, cx)
                .view()
                .clone()
                .downcast::<crate::workspace::Workspace>()
                .is_ok_and(|w| w.read(cx).native_editor_allowed(cx));
        if allowed {
            if let Some(generation) = self
                .native
                .attach(window, bounds.intersect(&window.content_mask().bounds))
                && let Some(id) = id
            {
                window.with_element_state(id, |previous: Option<Attachment>, _| {
                    (
                        (),
                        Attachment::for_mount(previous, &self.native, generation),
                    )
                });
            }
        } else {
            self.native.detach();
        }
    }
    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut (),
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) {
        self.child.paint(window, cx);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn edit_flush_preserves_coalesced_actions_and_focus() {
        let mut pending = Pending {
            text: Some("# café😀".into()),
            selection: Some(NSRange::new(2, 6)),
            focused: true,
            actions: vec![Action::Save, Action::Toggle],
        };
        let (text, selection) = pending.take_edits("old mirror");
        assert_eq!(text.as_deref(), Some("# café😀"));
        assert_eq!(selection, Some(2.."# café😀".len()));
        assert!(pending.focused);
        assert_eq!(pending.actions.len(), 2);
        assert!(matches!(pending.actions[0], Action::Save));
        assert!(matches!(pending.actions[1], Action::Toggle));
        assert_eq!(pending.take_edits("new mirror"), (None, None));
    }

    #[test]
    fn document_load_discards_old_queued_text_actions_and_selection() {
        let mut pending = Pending {
            text: Some("old file edit".into()),
            selection: Some(NSRange::new(4, 3)),
            focused: true,
            actions: vec![Action::Save],
        };
        pending.clear_for_load();
        // Draining the already queued notification cannot modify the new file.
        assert!(pending.text.is_none());
        assert!(pending.selection.is_none());
        assert!(!pending.focused);
        assert!(pending.actions.is_empty());
        // New input can coalesce into that notification without being lost.
        pending.text = Some("new file edit".into());
        pending.selection = Some(NSRange::new(13, 0));
        let drained = std::mem::take(&mut pending);
        assert_eq!(drained.text.as_deref(), Some("new file edit"));
        assert_eq!(drained.selection, Some(NSRange::new(13, 0)));
        assert!(pending.text.is_none());
    }

    #[test]
    fn ruler_bounds_reject_final_utf16_index_after_unicode() {
        for source in ["", "ascii\n", "# café😀\n", "e\u{301}\n", "漢字\n"] {
            let text = NSString::from_str(source);
            let units = source.encode_utf16().count();
            assert_eq!(text.len_utf16(), units);
            for start in line_starts(source) {
                assert_eq!(ruler_start_valid(&text, start), start < units);
            }
            assert!(!ruler_start_valid(&text, units));
        }
        let text = NSString::from_str("# café😀\n");
        assert_eq!(text.len_utf16(), 9);
        assert_eq!(text.len(), 12);
        assert!(!ruler_start_valid(&text, 9));
        assert!(ruler_start_valid(&text, 8));
    }

    #[test]
    fn native_indices_and_cached_line_starts_handle_surrogates_and_all_newlines() {
        let text = "é👩🏽‍💻\r\n漢\u{2028}z\n";
        for (byte, _) in text.char_indices() {
            let range = bytes_to_range(text, byte..byte);
            assert_eq!(utf16_to_byte(text, range.location), byte);
        }
        assert_eq!(line_starts(text), vec![0, 10, 12, 14]);
        assert_eq!(utf16_to_byte(text, usize::MAX), text.len());
    }
    #[gpui::test]
    fn queued_edits_and_actions_follow_transfer_after_source_closes(cx: &mut gpui::TestAppContext) {
        use gpui::{AppContext, WindowOptions};
        use gpui_kit::test::TestWindowExt;
        let (source, pane) = super::super::markdown_live_tests::editor(cx);
        cx.update_window(source.into(), |_, window, cx| window.render_frame(cx))
            .unwrap();
        let (sender, receiver) = mpsc::unbounded();
        let queued = Rc::new(Cell::new(true));
        let pending = cx.update(|cx| {
            pane.update(cx, |pane, cx| {
                let pending = pane.native_pending.clone();
                #[cfg(feature = "native-parity-fixture")]
                let fixture_trace = pane
                    .native_markdown
                    .as_ref()
                    .map(|native| native.shared.fixture_trace.clone());
                #[cfg(feature = "native-parity-fixture")]
                start_delivery(pending.clone(), queued.clone(), receiver, cx, fixture_trace);
                #[cfg(not(feature = "native-parity-fixture"))]
                start_delivery(pending.clone(), queued.clone(), receiver, cx);
                pending
            })
        });
        cx.update_window(source.into(), |_, window, _| window.remove_window())
            .unwrap();
        {
            let mut p = pending.borrow_mut();
            p.typed("# moved café😀", NSRange::new(2, 4));
            p.focused = true;
            p.actions.push(Action::Toggle);
        }
        sender.unbounded_send(()).unwrap();
        cx.run_until_parked();
        assert!(!queued.get());
        assert_eq!(pending.borrow().text(), Some("# moved café😀"));
        assert_eq!(pending.borrow().actions.len(), 1);
        let target = cx.update(|cx| {
            gpui_kit::open_window(WindowOptions::default(), cx, |_, _| pane.clone())
                .unwrap()
                .0
        });
        cx.update_window(target, |_, window, cx| window.render_frame(cx))
            .unwrap();
        // Actual native attachment re-signals the preserved queue on mount.
        queued.set(true);
        sender.unbounded_send(()).unwrap();
        cx.run_until_parked();
        cx.update_window(target, |_, window, cx| {
            pane.read_with(cx, |pane, cx| {
                assert_eq!(pane.window_handle, target);
                assert_eq!(pane.state.read(cx).value(), "# moved café😀");
                assert_eq!(pane.state.read(cx).selected_range(), 2..6);
                assert!(
                    pane.markdown_mode,
                    "Toggle was dispatched in the target window"
                );
                assert!(pane.focus_handle.is_focused(window));
            });
        })
        .unwrap();
        assert!(pending.borrow().is_empty());
        assert!(cx.update_window(source.into(), |_, _, _| ()).is_err());
        drop(sender);
        cx.run_until_parked();
    }
}
