//! The menu bar item (NSStatusItem, StatusBar module): an icon or title in
//! the macOS menu bar, with either a menu or a click handler (the command
//! center popover opens a GPUI window under the item's frame).
//!
//! Main thread only. Clicks and chosen menu items arrive as
//! [`StatusItemEvent`]s: drain them with [`drain_events`] on the main thread.
//! The item disappears from the menu bar when its handle is dropped.

use super::{EventQueue, Result};

/// One line of the item's menu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuEntry {
    Item {
        /// Returned in [`StatusItemEvent::MenuItem`].
        id: u32,
        title: String,
        enabled: bool,
        /// Shows a checkmark.
        checked: bool,
    },
    Separator,
}

impl MenuEntry {
    /// An enabled, unchecked item.
    pub fn item(id: u32, title: impl Into<String>) -> Self {
        Self::Item {
            id,
            title: title.into(),
            enabled: true,
            checked: false,
        }
    }
}

/// A rectangle in screen coordinates (points, origin at the bottom left of
/// the main screen, as AppKit reports it).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScreenRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum StatusItemEvent {
    /// The item was clicked while it has no menu; `frame` is where it sits
    /// in the menu bar, to place a popover under it.
    Clicked {
        item: u32,
        frame: Option<ScreenRect>,
    },
    /// A menu entry was chosen.
    MenuItem { item: u32, id: u32 },
}

/// A menu bar item.
pub trait StatusItem {
    /// Identifies this item in [`StatusItemEvent`]s.
    fn id(&self) -> u32;
    /// SF Symbol icon (`bell`, `bell.badge.fill`), drawn as a template so it
    /// follows the menu bar's light or dark look. `description` is read by
    /// VoiceOver.
    fn set_symbol(&self, symbol: &str, description: &str) -> Result<()>;
    /// Icon from PNG bytes; `template` draws it in the menu bar color.
    fn set_image_png(&self, png: &[u8], template: bool) -> Result<()>;
    /// Text next to the icon (a count of waiting sessions), empty for none.
    fn set_title(&self, title: &str);
    fn set_tooltip(&self, tooltip: Option<&str>);
    /// The menu shown on click; `None` sends [`StatusItemEvent::Clicked`]
    /// instead.
    fn set_menu(&self, entries: Option<&[MenuEntry]>);
    fn set_visible(&self, visible: bool);
}

static EVENTS: EventQueue<StatusItemEvent> = EventQueue::new();

/// Every click and menu choice since the last call, oldest first.
pub fn drain_events() -> Vec<StatusItemEvent> {
    EVENTS.drain()
}

/// Adds an item to the menu bar.
pub fn create() -> Result<Box<dyn StatusItem>> {
    imp::create()
}

fn next_id() -> u32 {
    use std::sync::atomic::{AtomicU32, Ordering};
    static NEXT: AtomicU32 = AtomicU32::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, NSObject};
    use objc2::{
        AnyThread, DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, sel,
    };
    use objc2_app_kit::{
        NSImage, NSMenu, NSMenuItem, NSStatusBar, NSStatusBarButton, NSStatusItem,
        NSVariableStatusItemLength, NSView,
    };
    use objc2_foundation::{NSData, NSObjectProtocol, NSString};

    use super::{EVENTS, MenuEntry, ScreenRect, StatusItemEvent, next_id};
    use crate::platform::{PlatformError, Result, main_thread};

    struct TargetIvars {
        item: u32,
    }

    define_class!(
        // SAFETY:
        // - NSObject has no subclassing requirements.
        // - `Target` does not implement `Drop`.
        #[unsafe(super(NSObject))]
        #[thread_kind = MainThreadOnly]
        #[ivars = TargetIvars]
        struct Target;

        impl Target {
            // SAFETY: action method signature `- (void)action:(id)sender`.
            #[unsafe(method(buttonClicked:))]
            fn button_clicked(&self, sender: Option<&NSView>) {
                let frame = sender.and_then(|view| view.window()).map(|window| {
                    let rect = window.frame();
                    ScreenRect {
                        x: rect.origin.x,
                        y: rect.origin.y,
                        width: rect.size.width,
                        height: rect.size.height,
                    }
                });
                EVENTS.push(StatusItemEvent::Clicked {
                    item: self.ivars().item,
                    frame,
                });
            }

            // SAFETY: action method signature `- (void)action:(id)sender`.
            #[unsafe(method(menuItemSelected:))]
            fn menu_item_selected(&self, sender: Option<&NSMenuItem>) {
                if let Some(entry) = sender {
                    EVENTS.push(StatusItemEvent::MenuItem {
                        item: self.ivars().item,
                        id: entry.tag() as u32,
                    });
                }
            }
        }

        // SAFETY: NSObjectProtocol has no safety requirements.
        unsafe impl NSObjectProtocol for Target {}
    );

    impl Target {
        fn new(mtm: MainThreadMarker, item: u32) -> Retained<Self> {
            let this = Self::alloc(mtm).set_ivars(TargetIvars { item });
            // SAFETY: NSObject's `init` has this signature.
            unsafe { msg_send![super(this), init] }
        }
    }

    pub struct MacStatusItem {
        id: u32,
        mtm: MainThreadMarker,
        item: Retained<NSStatusItem>,
        target: Retained<Target>,
    }

    pub fn create() -> Result<Box<dyn super::StatusItem>> {
        let mtm = main_thread()?;
        let id = next_id();
        let item = NSStatusBar::systemStatusBar().statusItemWithLength(NSVariableStatusItemLength);
        let target = Target::new(mtm, id);
        let this = MacStatusItem {
            id,
            mtm,
            item,
            target,
        };
        let button = this
            .button()
            .ok_or_else(|| PlatformError::Failed("status item has no button".into()))?;
        let target: &AnyObject = &this.target;
        // SAFETY: the target is kept alive by `MacStatusItem` as long as the
        // button exists, and implements the action selector.
        unsafe {
            button.setTarget(Some(target));
            button.setAction(Some(sel!(buttonClicked:)));
        }
        Ok(Box::new(this))
    }

    impl MacStatusItem {
        fn button(&self) -> Option<Retained<NSStatusBarButton>> {
            self.item.button(self.mtm)
        }

        fn set_image(&self, image: &NSImage) -> Result<()> {
            let button = self
                .button()
                .ok_or_else(|| PlatformError::Failed("status item has no button".into()))?;
            button.setImage(Some(image));
            Ok(())
        }
    }

    impl super::StatusItem for MacStatusItem {
        fn id(&self) -> u32 {
            self.id
        }

        fn set_symbol(&self, symbol: &str, description: &str) -> Result<()> {
            let image = NSImage::imageWithSystemSymbolName_accessibilityDescription(
                &NSString::from_str(symbol),
                Some(&*NSString::from_str(description)),
            )
            .ok_or_else(|| PlatformError::Failed(format!("no SF Symbol named {symbol}")))?;
            image.setTemplate(true);
            self.set_image(&image)
        }

        fn set_image_png(&self, png: &[u8], template: bool) -> Result<()> {
            let data = NSData::with_bytes(png);
            let image = NSImage::initWithData(NSImage::alloc(), &data)
                .ok_or_else(|| PlatformError::Failed("invalid status item image".into()))?;
            image.setTemplate(template);
            self.set_image(&image)
        }

        fn set_title(&self, title: &str) {
            if let Some(button) = self.button() {
                button.setTitle(&NSString::from_str(title));
            }
        }

        fn set_tooltip(&self, tooltip: Option<&str>) {
            if let Some(button) = self.button() {
                let tooltip = tooltip.map(NSString::from_str);
                button.setToolTip(tooltip.as_deref());
            }
        }

        fn set_menu(&self, entries: Option<&[MenuEntry]>) {
            let Some(entries) = entries else {
                self.item.setMenu(None);
                return;
            };
            let menu = NSMenu::new(self.mtm);
            menu.setAutoenablesItems(false);
            let target: &AnyObject = &self.target;
            for entry in entries {
                match entry {
                    MenuEntry::Separator => menu.addItem(&NSMenuItem::separatorItem(self.mtm)),
                    MenuEntry::Item {
                        id,
                        title,
                        enabled,
                        checked,
                    } => {
                        // SAFETY: `menuItemSelected:` is implemented by the
                        // target, which outlives the menu (both are owned
                        // by this item).
                        let menu_item = unsafe {
                            let menu_item = NSMenuItem::initWithTitle_action_keyEquivalent(
                                NSMenuItem::alloc(self.mtm),
                                &NSString::from_str(title),
                                Some(sel!(menuItemSelected:)),
                                &NSString::from_str(""),
                            );
                            menu_item.setTarget(Some(target));
                            menu_item
                        };
                        menu_item.setTag(*id as isize);
                        menu_item.setEnabled(*enabled);
                        menu_item.setState(if *checked { 1 } else { 0 });
                        menu.addItem(&menu_item);
                    }
                }
            }
            self.item.setMenu(Some(&menu));
        }

        fn set_visible(&self, visible: bool) {
            self.item.setVisible(visible);
        }
    }

    impl Drop for MacStatusItem {
        fn drop(&mut self) {
            NSStatusBar::systemStatusBar().removeStatusItem(&self.item);
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use crate::platform::{Result, unsupported};

    pub fn create() -> Result<Box<dyn super::StatusItem>> {
        unsupported("menu bar item")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique() {
        let a = next_id();
        let b = next_id();
        assert_ne!(a, b);
    }

    #[test]
    fn menu_entry_helper() {
        assert_eq!(
            MenuEntry::item(3, "Quit"),
            MenuEntry::Item {
                id: 3,
                title: "Quit".into(),
                enabled: true,
                checked: false
            }
        );
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn stub_is_unsupported() {
        assert!(create().is_err());
        assert!(drain_events().is_empty());
    }
}
