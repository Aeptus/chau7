//! Weak native host routing follows the mounted window, without retaining it.
use objc2::rc::{Retained, Weak};
use objc2_app_kit::NSView;
use std::cell::RefCell;

pub(super) struct SourceHost(RefCell<Weak<NSView>>);
impl SourceHost {
    pub(super) fn new(view: &NSView) -> Self {
        Self(RefCell::new(Weak::new(view)))
    }
    pub(super) fn bind(&self, view: &NSView) {
        *self.0.borrow_mut() = Weak::new(view);
    }
    pub(super) fn view(&self) -> Option<Retained<NSView>> {
        self.0.borrow().load()
    }
    pub(super) fn return_focus(&self, surface: &NSView) {
        let Some(window) = surface.window() else {
            return;
        };
        let focused = window
            .firstResponder()
            .and_then(|r| r.downcast::<NSView>().ok())
            .is_some_and(|v| v.isDescendantOf(surface));
        if focused
            && let Some(host) = self.view()
            && host
                .window()
                .as_ref()
                .is_some_and(|w| std::ptr::eq(&**w, &*window))
        {
            window.makeFirstResponder(Some(&host));
        }
    }
}
