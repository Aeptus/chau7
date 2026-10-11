//! Native model edits preserve the user's selection, viewport and edit history.
use objc2_app_kit::{NSTextInputClient, NSTextView};
use objc2_foundation::{NSRange, NSString};

fn restore_surface(view: &NSTextView, selection: NSRange, visible: objc2_foundation::NSRect) {
    if selection.location.saturating_add(selection.length) <= view.string().length() {
        view.setSelectedRange(selection);
    }
    view.scrollRectToVisible(visible);
}

/// Append only to the expected native document. A stale surface is left alone
/// so its owner can reconcile it through the ordinary mirror path.
pub(super) fn append(view: &NSTextView, expected: &str, addition: &str) -> bool {
    if view.string().to_string() != expected {
        return false;
    }
    let selection = view.selectedRange();
    let visible = view.visibleRect();
    view.breakUndoCoalescing();
    // SAFETY: NSTextInputClient's standard string insertion API. AppKit owns
    // selection/IME and registers the real native undo operation.
    unsafe {
        view.insertText_replacementRange(
            &NSString::from_str(addition),
            NSRange::new(expected.encode_utf16().count(), 0),
        );
    }
    view.breakUndoCoalescing();
    restore_surface(view, selection, visible);
    view.string().to_string() == format!("{expected}{addition}")
}

pub(super) fn replace(view: &NSTextView, text: &str, document_load: bool) {
    let selection = view.selectedRange();
    let visible = view.visibleRect();
    if document_load {
        view.setString(&NSString::from_str(text));
        if let Some(undo) = view.undoManager() {
            undo.removeAllActions();
        }
    } else {
        view.breakUndoCoalescing();
        // Programmatic edits participate in native undo; setting the entire
        // string and clearing history would discard preceding user insertions.
        unsafe {
            view.insertText_replacementRange(
                &NSString::from_str(text),
                NSRange::new(0, view.string().length()),
            );
        }
        view.breakUndoCoalescing();
        restore_surface(view, selection, visible);
    }
}
