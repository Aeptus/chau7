//! Rich terminal selection flavors on the macOS general pasteboard.
//!
//! GPUI's clipboard item is plain text only. This AppKit adapter writes that
//! text alongside standard HTML and a private, validated JSON flavor. Rich
//! targets can use HTML; Chau7's Markdown editor reads only the JSON's exact
//! plain text, matching the Swift editor's paste behavior.

use chau7_next_core::terminal_clipboard::StyledClipboardSelection;

pub const TERMINAL_SELECTION_TYPE: &str = "com.chau7.next.terminal-selection+json";

/// Write plain text, standard HTML, and Chau7's private rich-selection payload.
pub fn write_terminal_selection(selection: &StyledClipboardSelection) -> bool {
    if !selection.is_valid() {
        return false;
    }
    imp::write_terminal_selection(selection)
}

/// Read only Chau7's own private selection flavor. The caller validates JSON.
pub fn read_terminal_selection_json() -> Option<String> {
    imp::read_terminal_selection_json()
}

#[cfg(all(target_os = "macos", any(not(test), feature = "native-parity-fixture")))]
mod appkit {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSPasteboard;
    use objc2_foundation::{NSData, NSString};

    use super::{StyledClipboardSelection, TERMINAL_SELECTION_TYPE};

    const PLAIN_TEXT_TYPE: &str = "public.utf8-plain-text";
    const HTML_TYPE: &str = "public.html";
    const MAX_STYLED_SELECTION_BYTES: usize = 8 * 1024 * 1024;

    /// Shared implementation used by production and the private-board fixture.
    pub fn write_to(pasteboard: &NSPasteboard, selection: &StyledClipboardSelection) -> bool {
        if !selection.is_valid() {
            return false;
        }
        let Some(json) = selection.encode_json() else {
            return false;
        };
        let plain = NSString::from_str(&selection.plain_text);
        let plain_type = NSString::from_str(PLAIN_TEXT_TYPE);
        let html_type = NSString::from_str(HTML_TYPE);
        let private_type = NSString::from_str(TERMINAL_SELECTION_TYPE);
        let html = NSData::with_bytes(selection.html_fragment().as_bytes());
        let private = NSData::with_bytes(json.as_bytes());

        let _: isize = pasteboard.clearContents();
        let plain_ok = pasteboard.setString_forType(&plain, &plain_type);
        let html_ok = pasteboard.setData_forType(Some(&html), &html_type);
        let private_ok = pasteboard.setData_forType(Some(&private), &private_type);
        plain_ok && html_ok && private_ok
    }

    /// Read only Chau7's private flavor from the supplied board.
    pub fn read_from(pasteboard: &NSPasteboard) -> Option<String> {
        let kind = NSString::from_str(TERMINAL_SELECTION_TYPE);
        let data = pasteboard.dataForType(&kind)?;
        if data.length() > MAX_STYLED_SELECTION_BYTES {
            return None;
        }
        String::from_utf8(data.to_vec()).ok()
    }

    #[cfg(not(any(test, feature = "native-parity-fixture")))]
    pub fn write_general(selection: &StyledClipboardSelection) -> bool {
        let Some(_main_thread) = MainThreadMarker::new() else {
            return false;
        };
        let pasteboard = NSPasteboard::generalPasteboard();
        write_to(&pasteboard, selection)
    }

    #[cfg(not(any(test, feature = "native-parity-fixture")))]
    pub fn read_general() -> Option<String> {
        let _main_thread = MainThreadMarker::new()?;
        let pasteboard = NSPasteboard::generalPasteboard();
        read_from(&pasteboard)
    }

    #[cfg(feature = "native-parity-fixture")]
    pub fn write_fixture(pasteboard: &NSPasteboard, selection: &StyledClipboardSelection) -> bool {
        let Some(_main_thread) = MainThreadMarker::new() else {
            return false;
        };
        write_to(pasteboard, selection)
    }

    #[cfg(feature = "native-parity-fixture")]
    pub fn read_fixture(pasteboard: &NSPasteboard) -> Option<String> {
        let _main_thread = MainThreadMarker::new()?;
        read_from(pasteboard)
    }

    #[cfg(feature = "native-parity-fixture")]
    pub fn html_type() -> objc2::rc::Retained<NSString> {
        NSString::from_str(HTML_TYPE)
    }

    #[cfg(feature = "native-parity-fixture")]
    pub fn plain_text_type() -> objc2::rc::Retained<NSString> {
        NSString::from_str(PLAIN_TEXT_TYPE)
    }
}

#[cfg(all(target_os = "macos", not(any(test, feature = "native-parity-fixture"))))]
mod imp {
    use super::{StyledClipboardSelection, appkit};

    pub fn write_terminal_selection(selection: &StyledClipboardSelection) -> bool {
        appkit::write_general(selection)
    }

    pub fn read_terminal_selection_json() -> Option<String> {
        appkit::read_general()
    }
}

// Test and fixture platforms never read or mutate the user's general
// pasteboard, even when they execute on the AppKit main thread.
#[cfg(any(not(target_os = "macos"), test, feature = "native-parity-fixture"))]
mod imp {
    use super::StyledClipboardSelection;

    pub fn write_terminal_selection(_: &StyledClipboardSelection) -> bool {
        false
    }

    pub fn read_terminal_selection_json() -> Option<String> {
        None
    }
}

/// Access a caller-owned private NSPasteboard in the native acceptance fixture.
/// These wrappers never resolve the general pasteboard.
#[cfg(all(target_os = "macos", feature = "native-parity-fixture"))]
pub(crate) fn write_terminal_selection_to_fixture_pasteboard(
    pasteboard: &objc2_app_kit::NSPasteboard,
    selection: &StyledClipboardSelection,
) -> bool {
    appkit::write_fixture(pasteboard, selection)
}

#[cfg(all(target_os = "macos", feature = "native-parity-fixture"))]
pub(crate) fn read_terminal_selection_from_fixture_pasteboard(
    pasteboard: &objc2_app_kit::NSPasteboard,
) -> Option<String> {
    appkit::read_fixture(pasteboard)
}

#[cfg(all(target_os = "macos", feature = "native-parity-fixture"))]
pub(crate) fn fixture_plain_text_type() -> objc2::rc::Retained<objc2_foundation::NSString> {
    appkit::plain_text_type()
}

#[cfg(all(target_os = "macos", feature = "native-parity-fixture"))]
pub(crate) fn fixture_html_type() -> objc2::rc::Retained<objc2_foundation::NSString> {
    appkit::html_type()
}

#[cfg(test)]
mod tests {
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn unsupported_platform_does_not_claim_to_publish_rich_flavors() {
        let selection = chau7_next_core::terminal_clipboard::StyledClipboardSelection::new(
            "plain".into(),
            vec![chau7_next_core::terminal_clipboard::StyledClipboardRun {
                text: "plain".into(),
                ..Default::default()
            }],
        )
        .unwrap();
        assert!(!super::write_terminal_selection(&selection));
        assert_eq!(super::read_terminal_selection_json(), None);
    }
}
