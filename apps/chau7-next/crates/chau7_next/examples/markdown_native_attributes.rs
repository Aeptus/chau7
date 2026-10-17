//! Optional real AppKit verification, without activating or ordering a window.
//! Run: cargo run -p chau7_next --example markdown_native_attributes --release
//! Uses the production styler, not a duplicate font/layout implementation.
#[cfg(target_os = "macos")]
use chau7_next_core::editor::live_markdown::Document;
#[cfg(target_os = "macos")]
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send,
    rc::{Retained, Weak, autoreleasepool},
};
#[cfg(target_os = "macos")]
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSBackingStoreType, NSFont, NSFontAttributeName,
    NSParagraphStyle, NSParagraphStyleAttributeName, NSTextInputClient, NSTextView, NSView,
    NSWindow, NSWindowStyleMask,
};
#[cfg(target_os = "macos")]
use objc2_foundation::{
    NSDate, NSObjectProtocol, NSPoint, NSRange, NSRect, NSRunLoop, NSSize, NSString, NSUndoManager,
};
#[cfg(target_os = "macos")]
#[path = "../src/panes/editor/native_markdown/editing.rs"]
mod editing;
#[cfg(target_os = "macos")]
#[path = "../src/panes/editor/native_markdown/host.rs"]
mod host;
#[cfg(target_os = "macos")]
#[path = "../src/panes/editor/native_markdown/styles.rs"]
mod styles;
#[cfg(target_os = "macos")]
struct HistoryIvars {
    history: editing::SourceHistory,
}
#[cfg(target_os = "macos")]
define_class!(
    #[unsafe(super = NSTextView)]
    #[name = "Chau7NextMarkdownUndoFixtureTextView"]
    #[thread_kind = MainThreadOnly]
    #[ivars = HistoryIvars]
    struct HistoryView;
    unsafe impl NSObjectProtocol for HistoryView {}
    impl HistoryView {
        #[unsafe(method_id(undoManager))]
        fn source_undo_manager(&self) -> Option<Retained<NSUndoManager>> {
            Some(self.ivars().history.manager())
        }
    }
);
#[cfg(target_os = "macos")]
define_class!(
    #[unsafe(super = NSView)]
    #[name = "Chau7NextMarkdownHostFixtureView"]
    #[thread_kind = MainThreadOnly]
    struct HostView;
    unsafe impl NSObjectProtocol for HostView {}
    impl HostView {
        #[unsafe(method(acceptsFirstResponder))]
        fn accepts_first_responder(&self) -> bool { true }
    }
);
#[cfg(target_os = "macos")]
struct OwnedHistoryView(Retained<HistoryView>);
#[cfg(target_os = "macos")]
impl OwnedHistoryView {
    fn new(mtm: MainThreadMarker, text: &str) -> Self {
        let view = HistoryView::alloc(mtm).set_ivars(HistoryIvars {
            history: editing::SourceHistory::new(mtm),
        });
        let view: Retained<HistoryView> = unsafe {
            msg_send![super(view), initWithFrame:NSRect::new(NSPoint::new(0.,0.),NSSize::new(640.,480.))]
        };
        view.setEditable(true);
        view.setRichText(false);
        view.setAllowsUndo(true);
        view.setString(&NSString::from_str(text));
        Self(view)
    }
}
#[cfg(target_os = "macos")]
impl Drop for OwnedHistoryView {
    fn drop(&mut self) {
        // Same production cleanup API and ownership rule as NativeMarkdown.
        self.0.ivars().history.clear();
    }
}
#[cfg(target_os = "macos")]
fn verify_source_release(mtm: MainThreadMarker) {
    let (released, closed_manager, sibling) = autoreleasepool(|_| {
        let first = OwnedHistoryView::new(mtm, "# first");
        let second = OwnedHistoryView::new(mtm, "# second");
        let first_manager = first.0.undoManager().unwrap();
        let second_manager = second.0.undoManager().unwrap();
        assert!(!std::ptr::eq(&*first_manager, &*second_manager));
        for (view, manager, initial) in [
            (&first.0, &first_manager, "# first"),
            (&second.0, &second_manager, "# second"),
        ] {
            manager.setGroupsByEvent(false);
            manager.beginUndoGrouping();
            assert!(editing::append(view, initial, "!"));
            manager.endUndoGrouping();
            assert!(manager.canUndo());
        }
        let released = Weak::new(&*first.0);
        drop(first);
        assert!(!first_manager.canUndo());
        assert!(second_manager.canUndo());
        (released, first_manager, second)
    });
    drain_deferred_release(&released);
    assert!(!closed_manager.canUndo());
    let (released_sibling, sibling_manager) = autoreleasepool(|_| {
        let manager = sibling.0.undoManager().unwrap();
        assert!(manager.canUndo());
        manager.undo();
        assert_eq!(sibling.0.string().to_string(), "# second");
        assert!(manager.canRedo());
        let released = Weak::new(&*sibling.0);
        drop(sibling);
        assert!(!manager.canUndo());
        assert!(!manager.canRedo());
        (released, manager)
    });
    drain_deferred_release(&released_sibling);
    assert!(!sibling_manager.canUndo());
    assert!(!sibling_manager.canRedo());
}

#[cfg(target_os = "macos")]
fn drain_deferred_release(view: &Weak<HistoryView>) {
    // AppKit may temporarily retain text views through deferred notifications.
    // Drain only this fixture process's run loop; no window is ordered or activated.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while view.load().is_some() && std::time::Instant::now() < deadline {
        autoreleasepool(|_| {
            NSRunLoop::currentRunLoop().runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(0.01));
        });
    }
    assert!(
        view.load().is_none(),
        "closed source remained retained after deferred AppKit work"
    );
}

#[cfg(target_os = "macos")]
fn verify_cross_window_host(mtm: MainThreadMarker) {
    let frame = NSRect::new(NSPoint::new(0., 0.), NSSize::new(640., 480.));
    let make_window = || unsafe {
        NSWindow::initWithContentRect_styleMask_backing_defer(
            NSWindow::alloc(mtm),
            frame,
            NSWindowStyleMask::Titled,
            NSBackingStoreType::Buffered,
            false,
        )
    };
    // Both windows are owned, never ordered or activated, and accept no OS input.
    let source = make_window();
    let target = make_window();
    unsafe {
        source.setReleasedWhenClosed(false);
        target.setReleasedWhenClosed(false);
    }
    let original: Retained<HostView> =
        unsafe { msg_send![HostView::alloc(mtm), initWithFrame:frame] };
    let current: Retained<HostView> =
        unsafe { msg_send![HostView::alloc(mtm), initWithFrame:frame] };
    source.setContentView(Some(&original));
    target.setContentView(Some(&current));
    let routing = host::SourceHost::new(&original);
    let text = OwnedHistoryView::new(mtm, "# moved café😀");
    original.addSubview(&text.0);
    text.0.setSelectedRange(NSRange::new(2, 4));
    let manager = text.0.undoManager().unwrap();
    manager.setGroupsByEvent(false);
    manager.beginUndoGrouping();
    assert!(editing::append(&text.0, "# moved café😀", "!"));
    manager.endUndoGrouping();
    let selected = text.0.selectedRange();
    text.0.removeFromSuperview();
    current.addSubview(&text.0);
    routing.bind(&current);
    assert!(std::ptr::eq::<NSView>(
        &*routing.view().unwrap(),
        &**current
    ));
    source.close();
    drop(source);
    assert!(target.makeFirstResponder(Some(&text.0)));
    routing.return_focus(&text.0);
    assert!(
        target
            .firstResponder()
            .and_then(|r| r.downcast::<NSView>().ok())
            .is_some_and(|r| std::ptr::eq::<NSView>(&*r, &**current))
    );
    assert_eq!(text.0.string().to_string(), "# moved café😀!");
    assert_eq!(text.0.selectedRange(), selected);
    assert!(manager.canUndo());
    manager.undo();
    assert_eq!(text.0.string().to_string(), "# moved café😀");
    manager.redo();
    assert_eq!(text.0.string().to_string(), "# moved café😀!");
    text.0.setHidden(true);
    text.0.removeFromSuperview();
    assert!(text.0.window().is_none());
    target.close();
}

#[cfg(target_os = "macos")]
fn main() {
    let mtm = MainThreadMarker::new().unwrap();
    let app = NSApplication::sharedApplication(mtm);
    app.setActivationPolicy(NSApplicationActivationPolicy::Prohibited);
    let frame = NSRect::new(NSPoint::new(0., 0.), NSSize::new(640., 480.));
    let view = NSTextView::initWithFrame(NSTextView::alloc(mtm), frame);
    view.setEditable(true);
    view.setRichText(false);
    view.setAllowsUndo(true);
    let window = unsafe {
        NSWindow::initWithContentRect_styleMask_backing_defer(
            NSWindow::alloc(mtm),
            frame,
            NSWindowStyleMask::empty(),
            NSBackingStoreType::Buffered,
            false,
        )
    };
    unsafe {
        window.setReleasedWhenClosed(false);
    };
    window.setContentView(Some(&view));
    window.makeFirstResponder(Some(&view));
    let initial = "# hé👩🏽‍💻\n- [x] a long list body that wraps\n`code`\n";
    view.setString(&NSString::from_str(initial));
    let mut doc = Document::default();
    doc.update(initial);
    let styles = styles::Theme::new(13., mtm);
    assert_eq!(styles.size(), 13.);
    let storage = unsafe { view.textStorage() }.unwrap();
    let selection = NSRange::new(4, 2);
    view.setSelectedRange(selection);
    styles.apply(&storage, &doc, doc.restyled_range());
    assert_eq!(view.string().to_string(), initial);
    assert_eq!(view.selectedRange(), selection);
    let font = unsafe {
        storage.attribute_atIndex_effectiveRange(NSFontAttributeName, 2, std::ptr::null_mut())
    }
    .unwrap()
    .downcast::<NSFont>()
    .unwrap();
    assert!((font.pointSize() - 22.1).abs() < 0.000001);
    let index = initial[..initial.find("- [x]").unwrap()]
        .encode_utf16()
        .count();
    let paragraph = unsafe {
        storage.attribute_atIndex_effectiveRange(
            NSParagraphStyleAttributeName,
            index,
            std::ptr::null_mut(),
        )
    }
    .unwrap()
    .downcast::<NSParagraphStyle>()
    .unwrap();
    assert!(paragraph.headIndent() > 20.);
    assert_eq!(paragraph.firstLineHeadIndent(), 0.);
    let undo = view.undoManager().unwrap();
    undo.setGroupsByEvent(false);
    undo.beginUndoGrouping();
    unsafe {
        view.insertText_replacementRange(
            &NSString::from_str("!"),
            NSRange::new(initial.encode_utf16().count(), 0),
        );
    }
    undo.endUndoGrouping();
    assert!(undo.canUndo());
    let edited = view.string().to_string();
    doc.update(&edited);
    let selected = view.selectedRange();
    styles.apply(&storage, &doc, doc.restyled_range());
    assert_eq!(view.selectedRange(), selected);
    assert!(undo.canUndo());
    undo.undo();
    assert_eq!(view.string().to_string(), initial);
    undo.removeAllActions();
    view.setSelectedRange(selection);
    let visible = view.visibleRect();
    undo.beginUndoGrouping();
    assert!(editing::append(&view, initial, "extra"));
    undo.endUndoGrouping();
    assert_eq!(view.string().to_string(), format!("{initial}extra"));
    assert_eq!(view.selectedRange(), selection);
    assert_eq!(view.visibleRect(), visible);
    assert!(!editing::append(&view, "stale", "discarded"));
    assert_eq!(view.string().to_string(), format!("{initial}extra"));
    undo.undo();
    assert_eq!(view.string().to_string(), initial);
    undo.redo();
    assert_eq!(view.string().to_string(), format!("{initial}extra"));
    view.setSelectedRange(selection);
    undo.beginUndoGrouping();
    editing::replace(&view, "# replacement\n", false);
    undo.endUndoGrouping();
    assert_eq!(view.string().to_string(), "# replacement\n");
    assert_eq!(view.selectedRange(), selection);
    assert_eq!(view.visibleRect(), visible);
    undo.undo();
    assert_eq!(view.string().to_string(), format!("{initial}extra"));
    undo.undo();
    assert_eq!(view.string().to_string(), initial);
    editing::replace(&view, initial, true);
    assert!(!undo.canUndo());
    verify_source_release(mtm);
    verify_cross_window_host(mtm);
    println!(
        "heading_size={} hanging_indent={} selected_range_unchanged=true native_undo_preserved=true native_append_undo_redo=true replacement_preserves_history=true explicit_load_clears_history=true closed_source_released=true sibling_history_preserved=true cross_window_detach_focus=true cross_window_selection_undo_preserved=true",
        font.pointSize(),
        paragraph.headIndent()
    );
    window.close();
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("Native Markdown attribute verification requires macOS.");
}
