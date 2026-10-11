//! Optional real AppKit verification, without activating or ordering a window.
//! Run: cargo run -p chau7_next --example markdown_native_attributes --release
//! Uses the production styler, not a duplicate font/layout implementation.
#[cfg(target_os = "macos")]
use chau7_next_core::editor::live_markdown::Document;
#[cfg(target_os = "macos")]
use objc2::{MainThreadMarker, MainThreadOnly};
#[cfg(target_os = "macos")]
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSBackingStoreType, NSFont, NSFontAttributeName,
    NSParagraphStyle, NSParagraphStyleAttributeName, NSTextInputClient, NSTextView, NSWindow,
    NSWindowStyleMask,
};
#[cfg(target_os = "macos")]
use objc2_foundation::{NSPoint, NSRange, NSRect, NSSize, NSString};
#[cfg(target_os = "macos")]
#[path = "../src/panes/editor/native_markdown/editing.rs"]
mod editing;
#[cfg(target_os = "macos")]
#[path = "../src/panes/editor/native_markdown/styles.rs"]
mod styles;
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
    println!(
        "heading_size={} hanging_indent={} selected_range_unchanged=true native_undo_preserved=true native_append_undo_redo=true replacement_preserves_history=true explicit_load_clears_history=true",
        font.pointSize(),
        paragraph.headIndent()
    );
    window.close();
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("Native Markdown attribute verification requires macOS.");
}
