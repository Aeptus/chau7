//! Optional acceptance against the actual AppKit class and GPUI attachment.
//! Only the validated, fresh native runner calls this. Events are delivered
//! directly to this process's view; no OS input, general clipboard or providers
//! are used. Clipboard checks use only a uniquely named private pasteboard.
use super::*;
use crate::{
    pane::PaneItem,
    session_store::{SavedTab, SavedWindow},
    settings::Settings,
    workspace::Workspace,
};
use chau7_next_core::session_restore::SavedSplitNode;
use gpui::{AppContext, AsyncApp, Focusable, WindowHandle, WindowOptions};
use gpui_kit::{
    base::Root,
    component::{
        WindowExt,
        menu::{PopupMenu, PopupMenuItem},
    },
    test::TestWindowExt,
};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSEvent, NSEventType, NSPasteboard, NSView,
    NSWindow, NSWorkspace,
};
use objc2_foundation::{NSNotFound, NSString};
use std::os::unix::fs::PermissionsExt;

fn ensure(condition: bool, message: &str) -> Result<(), String> {
    if condition {
        Ok(())
    } else {
        Err(message.into())
    }
}
fn error(error: impl std::fmt::Display) -> String {
    error.to_string()
}
async fn settle(handle: WindowHandle<Root>, cx: &mut AsyncApp) -> Result<(), String> {
    // Two actual frames allow the pending editor delivery and attachment guard
    // to run. The common runner bounds each frame wait with a timeout.
    crate::native_parity_fixture::next_frame(handle.into(), cx).await?;
    crate::native_parity_fixture::next_frame(handle.into(), cx).await
}
fn attached(native: &NativeMarkdown) -> bool {
    !native.scroll.isHidden() && unsafe { native.scroll.superview() }.is_some()
}
fn fixture_bounds(layout: FixtureAttachDecision) -> Bounds<Pixels> {
    let [x, y, width, height] = layout.bounds;
    Bounds::new(
        gpui::point(gpui::px(x), gpui::px(y)),
        gpui::size(gpui::px(width), gpui::px(height)),
    )
}
fn fixture_frame_values(frame: NSRect) -> [f64; 4] {
    [
        frame.origin.x,
        frame.origin.y,
        frame.size.width,
        frame.size.height,
    ]
}
fn validate_layout(
    native: &NativeMarkdown,
    layout: FixtureAttachDecision,
    expected_bounds: [f32; 4],
    expected_branch: Option<(bool, bool, Option<bool>, bool)>,
) -> Result<(), String> {
    ensure(
        layout.bounds == expected_bounds,
        "native fixture attach used unexpected GPUI bounds",
    )?;
    let parent = unsafe { native.scroll.superview() }
        .ok_or("native fixture scroll view has no host after attach")?;
    let routed_host = native
        .shared
        .host
        .view()
        .ok_or("native fixture host route disappeared after attach")?;
    ensure(
        std::ptr::eq::<NSView>(&*parent, &*routed_host),
        "native fixture scroll view is attached to the wrong host",
    )?;
    let [x, y, width, height] = layout.bounds;
    let mut frame_y = f64::from(y);
    let frame_height = f64::from(height);
    if !parent.isFlipped() {
        frame_y = parent.bounds().size.height - frame_y - frame_height;
    }
    let expected_frame = [f64::from(x), frame_y, f64::from(width), frame_height];
    ensure(
        layout.actual_scroll_frame == expected_frame
            && fixture_frame_values(native.scroll.frame()) == expected_frame,
        "native fixture scroll frame did not match its attached bounds",
    )?;
    ensure(
        !native.scroll.isHidden(),
        "native fixture scroll view was not visible after attach",
    )?;
    if let Some(target_width) = layout.text_target_width {
        let content_width = native.scroll.contentView().bounds().size.width;
        ensure(
            layout.text_actual_width == Some(target_width)
                && target_width == content_width
                && native.text.frame().size.width == content_width,
            "word-wrapped source width did not match the current scroll content width",
        )?;
    }
    if let Some((needs_reparent, scroll_frame_set, text_frame_set, hidden_set)) = expected_branch {
        ensure(
            layout.needs_reparent == needs_reparent,
            "native fixture took an unexpected reparent branch",
        )?;
        ensure(
            layout.scroll_frame_set == scroll_frame_set,
            "native fixture took an unexpected scroll-frame setter branch",
        )?;
        if let Some(text_frame_set) = text_frame_set {
            ensure(
                layout.text_frame_set == text_frame_set,
                "native fixture took an unexpected text-frame setter branch",
            )?;
        }
        ensure(
            layout.hidden_set == hidden_set,
            "native fixture took an unexpected visibility setter branch",
        )?;
    }
    Ok(())
}
fn attach_fixture_bounds(
    handle: WindowHandle<Root>,
    native: &NativeMarkdown,
    bounds: Bounds<Pixels>,
    cx: &mut AsyncApp,
) -> Result<u64, String> {
    cx.update_window(handle.into(), |_, window, _| native.attach(window, bounds))
        .map_err(error)?
        .ok_or_else(|| "native fixture attach did not mount".into())
}
fn last_attach_decision(native: &NativeMarkdown) -> Result<FixtureAttachDecision, String> {
    native
        .fixture_attach_decision
        .get()
        .ok_or_else(|| "native fixture did not record an attach decision".into())
}
fn source_is_first_responder(native: &NativeMarkdown, window: &NSWindow) -> bool {
    window
        .firstResponder()
        .and_then(|responder| responder.downcast::<SourceTextView>().ok())
        .is_some_and(|source| std::ptr::eq(&*source, &*native.text))
}
fn host_is_first_responder(native: &NativeMarkdown, window: &NSWindow) -> bool {
    let Some(host) = native.shared.host.view() else {
        return false;
    };
    window
        .firstResponder()
        .and_then(|responder| responder.downcast::<NSView>().ok())
        .is_some_and(|view| std::ptr::eq(&*view, &*host))
}
fn source_mouse_event(
    native: &NativeMarkdown,
    window: &NSWindow,
    event_type: NSEventType,
) -> Result<objc2::rc::Retained<NSEvent>, String> {
    let bounds = native.text.bounds();
    let local = objc2_foundation::NSPoint::new(
        bounds.origin.x + bounds.size.width / 2.0,
        bounds.origin.y + bounds.size.height / 2.0,
    );
    // With a window number, AppKit interprets NSEvent's mouse location in
    // that window's base coordinates, so route the view center in-window.
    let in_window = native.text.convertPoint_toView(local, None);
    NSEvent::mouseEventWithType_location_modifierFlags_timestamp_windowNumber_context_eventNumber_clickCount_pressure(
        event_type,
        in_window,
        NSEventModifierFlags::empty(),
        0.0,
        window.windowNumber(),
        None,
        1,
        1,
        1.0,
    )
    .ok_or_else(|| "AppKit could not construct an owned source mouse event".into())
}
fn click_native_source(
    application: &NSApplication,
    native_window: &NSWindow,
    native: &NativeMarkdown,
    stage: &'static str,
) -> Result<(), String> {
    MainThreadMarker::new().ok_or("native source click is not on the main thread")?;
    if !(application.isActive() && native_window.isVisible() && native_window.isKeyWindow()) {
        let application_key_window = application.keyWindow();
        let application_main_window = application.mainWindow();
        let source_window = native.text.window();
        let frontmost_application = NSWorkspace::sharedWorkspace().frontmostApplication();
        let frontmost_application = frontmost_application.as_ref().map(|application| {
            serde_json::json!({
                "process_id": application.processIdentifier(),
                "bundle_identifier": application.bundleIdentifier().map(|id| id.to_string()),
            })
        });
        let current_event = application.currentEvent();
        let current_event = current_event.as_ref().map(|event| {
            serde_json::json!({
                "type": event.r#type().0,
                "timestamp": event.timestamp(),
                "window_number": event.windowNumber(),
            })
        });
        let snapshot = serde_json::json!({
            "stage": stage,
            "application_active": application.isActive(),
            "activation_policy": application.activationPolicy().0,
            "target_window_number": native_window.windowNumber(),
            "target_visible": native_window.isVisible(),
            "target_key": native_window.isKeyWindow(),
            "target_main": native_window.isMainWindow(),
            "target_miniaturized": native_window.isMiniaturized(),
            "target_can_become_key": native_window.canBecomeKeyWindow(),
            "target_occlusion_state": native_window.occlusionState().0,
            "application_key_window_number": application_key_window
                .as_ref()
                .map(|window| window.windowNumber()),
            "application_key_is_target": application_key_window
                .as_ref()
                .is_some_and(|window| std::ptr::eq::<NSWindow>(&**window, native_window)),
            "application_main_window_number": application_main_window
                .as_ref()
                .map(|window| window.windowNumber()),
            "application_main_is_target": application_main_window
                .as_ref()
                .is_some_and(|window| std::ptr::eq::<NSWindow>(&**window, native_window)),
            "source_window_number": source_window.as_ref().map(|window| window.windowNumber()),
            "source_window_is_target": source_window
                .as_ref()
                .is_some_and(|window| std::ptr::eq::<NSWindow>(&**window, native_window)),
            "source_first_responder": source_is_first_responder(native, native_window),
            "host_first_responder": host_is_first_responder(native, native_window),
            "frontmost_application": frontmost_application,
            "current_event": current_event,
        });
        eprintln!("native_editor_click_owner={snapshot}");
        return Err(format!(
            "native source click target is not the active owned window: {snapshot}"
        ));
    }
    let down = source_mouse_event(native, native_window, NSEventType::LeftMouseDown)?;
    let up = source_mouse_event(native, native_window, NSEventType::LeftMouseUp)?;
    // NSTextView may track a mouse-down synchronously until it consumes the
    // matching mouse-up. Queue it first so sendEvent(down) cannot block here.
    application.postEvent_atStart(&up, true);
    application.sendEvent(&down);
    ensure(
        source_is_first_responder(native, native_window),
        "an AppKit click on SourceTextView did not give it first-responder ownership",
    )
}
fn click_gpui_terminal(
    handle: WindowHandle<Root>,
    point: gpui::Point<Pixels>,
    cx: &mut AsyncApp,
) -> Result<(), String> {
    cx.update_window(handle.into(), |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                position: point,
                pressed_button: None,
                modifiers: Default::default(),
            }),
            cx,
        );
        window.render_frame(cx);
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                position: point,
                button: gpui::MouseButton::Left,
                modifiers: Default::default(),
                click_count: 1,
                first_mouse: false,
            }),
            cx,
        );
        window.render_frame(cx);
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                position: point,
                button: gpui::MouseButton::Left,
                modifiers: Default::default(),
                click_count: 1,
            }),
            cx,
        );
        window.render_frame(cx);
    })
    .map_err(error)
}
fn click_gpui_terminal_immediately(
    handle: WindowHandle<Root>,
    point: gpui::Point<Pixels>,
    cx: &mut AsyncApp,
) -> Result<(), String> {
    cx.update_window(handle.into(), |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                position: point,
                button: gpui::MouseButton::Left,
                modifiers: Default::default(),
                click_count: 1,
                first_mouse: false,
            }),
            cx,
        );
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                position: point,
                button: gpui::MouseButton::Left,
                modifiers: Default::default(),
                click_count: 1,
            }),
            cx,
        );
        window.render_frame(cx);
    })
    .map_err(error)
}
fn verify_rich_terminal_source(
    native: &NativeMarkdown,
    expected_source: &str,
    expected_block: &str,
    expected_literal: &str,
) -> Result<(), String> {
    let source = native.text.string().to_string();
    ensure(
        source == expected_source,
        "native rich Markdown insertion changed the literal source",
    )?;
    let document = native.shared.document.borrow();
    let block_start = source
        .find(expected_block)
        .ok_or("native rich Markdown block was not found in the surrounding document")?;
    ensure(
        source[block_start + expected_block.len()..]
            .find(expected_block)
            .is_none(),
        "native rich Markdown block appeared more than once",
    )?;
    let block = chau7_next_core::terminal_clipboard::parse_markdown_block(&source, block_start)
        .ok_or("native rich Markdown block did not parse")?;
    ensure(
        &source[block.body_range.clone()] == expected_literal,
        "native rich Markdown body did not preserve its exact literal characters",
    )?;
    ensure(
        document.hidden_terminal_ranges().len() == 2,
        "native rich Markdown did not identify its two wrapper lines",
    )?;

    let layout =
        unsafe { native.text.layoutManager() }.ok_or("native source has no NSLayoutManager")?;
    layout.ensureLayoutForCharacterRange(NSRange::new(0, source.encode_utf16().count()));
    for (index, range) in document.hidden_terminal_ranges().iter().enumerate() {
        let hidden_source = &source[range.clone()];
        ensure(
            if index == 0 {
                hidden_source.starts_with("```chau7-terminal-v1:")
            } else {
                hidden_source.trim() == "```"
            },
            "native metadata fence source was not preserved",
        )?;
        let mut sample_glyph = None;
        for (byte, character) in hidden_source.char_indices() {
            if matches!(character, '\r' | '\n') {
                continue;
            }
            let character_index = source[..range.start + byte].encode_utf16().count();
            let glyph_index = layout.glyphIndexForCharacterAtIndex(character_index);
            ensure(
                layout.isValidGlyphIndex(glyph_index)
                    && layout
                        .propertyForGlyphAtIndex(glyph_index)
                        .contains(objc2_app_kit::NSGlyphProperty::Null),
                "native wrapper glyph remained visible in TextKit",
            )?;
            sample_glyph.get_or_insert(glyph_index);
        }
        let sample_glyph = sample_glyph.ok_or("native wrapper has no content glyph")?;
        let sample_character_index = layout.characterIndexForGlyphAtIndex(sample_glyph);
        let mut line_glyph_range = NSRange::new(0, 0);
        let line_rect = unsafe {
            layout
                .lineFragmentRectForGlyphAtIndex_effectiveRange(sample_glyph, &mut line_glyph_range)
        };
        if line_rect.size.height != 0.0 {
            let line_character_range = unsafe {
                layout.characterRangeForGlyphRange_actualGlyphRange(
                    line_glyph_range,
                    std::ptr::null_mut(),
                )
            };
            let sample_character_is_null = layout
                .propertyForGlyphAtIndex(sample_glyph)
                .contains(objc2_app_kit::NSGlyphProperty::Null);
            return Err(format!(
                "native wrapper line retained vertical layout height: wrapper_index={index}, wrapper_utf8={range:?}, sample_utf16={sample_character_index}, sample_glyph={sample_glyph}, sample_glyph_is_null={sample_character_is_null}, line_glyph_range={}..{}, line_character_range={}..{}, line_rect=({}, {}, {}, {})",
                line_glyph_range.location,
                line_glyph_range.location + line_glyph_range.length,
                line_character_range.location,
                line_character_range.location + line_character_range.length,
                line_rect.origin.x,
                line_rect.origin.y,
                line_rect.size.width,
                line_rect.size.height,
            ));
        }
    }

    let body_visible_index = source[..block.body_range.start + 2].encode_utf16().count();
    let body_glyph = layout.glyphIndexForCharacterAtIndex(body_visible_index);
    ensure(
        layout.isValidGlyphIndex(body_glyph)
            && !layout
                .propertyForGlyphAtIndex(body_glyph)
                .contains(objc2_app_kit::NSGlyphProperty::Null),
        "native terminal body glyph was hidden with its metadata",
    )?;

    let storage = unsafe { native.text.textStorage() }
        .ok_or("native source has no NSTextStorage after rich insertion")?;
    let colored_run = document
        .runs()
        .iter()
        .find(|run| {
            matches!(
                run.kind,
                chau7_next_core::editor::live_markdown::Kind::TerminalSpan {
                    foreground: Some([230, 80, 20]),
                    ..
                }
            )
        })
        .ok_or("native source lost its terminal foreground metadata")?;
    let color_index = source[..colored_run.range.start].encode_utf16().count();
    let color = unsafe {
        storage.attribute_atIndex_effectiveRange(
            objc2_app_kit::NSForegroundColorAttributeName,
            color_index,
            std::ptr::null_mut(),
        )
    }
    .ok_or("native styled terminal text has no foreground attribute")?
    .downcast::<NSColor>()
    .map_err(|_| "native terminal foreground attribute is not an NSColor")?;
    ensure(
        (color.redComponent() - 230.0 / 255.0).abs() < 0.01
            && (color.greenComponent() - 80.0 / 255.0).abs() < 0.01
            && (color.blueComponent() - 20.0 / 255.0).abs() < 0.01,
        "native terminal foreground color changed during styling",
    )?;

    let (link_range, expected_link) = document
        .terminal_links()
        .first()
        .ok_or("native rich terminal body lost its link metadata")?;
    ensure(
        &source[link_range.clone()] == "é",
        "native terminal link text changed from the literal body",
    )?;
    let link_index = source[..link_range.start].encode_utf16().count();
    let background = unsafe {
        storage.attribute_atIndex_effectiveRange(
            objc2_app_kit::NSBackgroundColorAttributeName,
            link_index,
            std::ptr::null_mut(),
        )
    }
    .ok_or("native styled terminal text has no background attribute")?
    .downcast::<NSColor>()
    .map_err(|_| "native terminal background attribute is not an NSColor")?;
    ensure(
        (background.redComponent() - 18.0 / 255.0).abs() < 0.01
            && (background.greenComponent() - 52.0 / 255.0).abs() < 0.01
            && (background.blueComponent() - 86.0 / 255.0).abs() < 0.01,
        "native terminal background color changed during styling",
    )?;
    let link = unsafe {
        storage.attribute_atIndex_effectiveRange(
            objc2_app_kit::NSLinkAttributeName,
            link_index,
            std::ptr::null_mut(),
        )
    }
    .ok_or("native styled terminal link has no NSLink attribute")?
    .downcast::<objc2_foundation::NSURL>()
    .map_err(|_| "native terminal link attribute is not an NSURL")?;
    ensure(
        link.absoluteString()
            .is_some_and(|value| value.to_string() == *expected_link),
        "native terminal link target changed during styling",
    )
}
fn composition_phase(
    phase: &'static str,
    application: &NSApplication,
    window: &NSWindow,
    native: &NativeMarkdown,
) {
    let marked = native.text.markedRange();
    let snapshot = serde_json::json!({
        "phase": phase,
        "app_active": application.isActive(),
        "window_key": window.isKeyWindow(),
        "window_visible": window.isVisible(),
        "source_first_responder": source_is_first_responder(native, window),
        "has_marked_text": native.text.hasMarkedText(),
        "marked_location": marked.location,
        "marked_length": marked.length,
        "mount_generation": native.mount_generation.get(),
    });
    eprintln!("native_editor_composition_phase={snapshot}");
}
fn ordinary_keydown_phase(
    phase: &'static str,
    application: &NSApplication,
    window: &NSWindow,
    native: &NativeMarkdown,
    event: &NSEvent,
) {
    let selected = native.text.selectedRange();
    let current_event = application.currentEvent();
    let current_event_details = current_event.as_ref().map(|current| {
        serde_json::json!({
            "timestamp": current.timestamp(),
            "window_number": current.windowNumber(),
            "event_type": current.r#type().0,
        })
    });
    let snapshot = serde_json::json!({
        "phase": phase,
        "app_active": application.isActive(),
        "window_key": window.isKeyWindow(),
        "window_visible": window.isVisible(),
        "source_first_responder": source_is_first_responder(native, window),
        "source_input_context_present": native.text.inputContext().is_some(),
        "has_marked_text": native.text.hasMarkedText(),
        "selection_location": selected.location,
        "selection_length": selected.length,
        "event_key_code": event.keyCode(),
        "event_timestamp": event.timestamp(),
        "event_characters_ignoring_modifiers": event
            .charactersIgnoringModifiers()
            .map(|s| s.to_string()),
        "event_window_number": event.windowNumber(),
        "window_number": window.windowNumber(),
        "application_current_event": current_event_details,
        "source_text": native.text.string().to_string(),
    });
    eprintln!("native_editor_ordinary_keydown_phase={snapshot}");
}
fn fixture_native_drop_hit(
    handle: WindowHandle<Root>,
    position: gpui::Point<Pixels>,
    cx: &mut AsyncApp,
) -> Result<crate::platform::window_drop::NativeDropHit, String> {
    cx.update_window(handle.into(), |_, window, _| {
        crate::platform::window_drop::native_drop_hit_for_position(window, position)
    })
    .map_err(error)
}
fn fixture_eligible_drop_window(
    handle: WindowHandle<Root>,
    cx: &mut AsyncApp,
) -> Result<Option<isize>, String> {
    cx.update_window(handle.into(), |_, window, _| {
        crate::platform::window_drop::eligible_window_number(window)
    })
    .map_err(error)
}
async fn verify_native_drop_window_hits(
    owner_handle: WindowHandle<Root>,
    owner_window: &NSWindow,
    cx: &mut AsyncApp,
) -> Result<serde_json::Value, String> {
    use crate::platform::window_drop::NativeDropHit;

    MainThreadMarker::new().ok_or("native drop-window fixture is not on the main thread")?;
    // The second workspace is empty, so this fixture creates no extra shell
    // process. Both windows and all ordering changes belong to this runner.
    let (target_any_handle, _target_workspace) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    show: true,
                    focus: false,
                    ..Default::default()
                },
                cx,
                |window, cx| cx.new(|cx| Workspace::new_empty(window, cx)),
            )
        })
        .map_err(error)?;

    // Keep cleanup outside the Result-producing body. Every failure after the
    // second window is created still removes that GPUI window and restores the
    // editor window's ordering.
    let mut target_window_for_cleanup: Option<Retained<NSWindow>> = None;
    let result: Result<serde_json::Value, String> = async {
        let target_handle = target_any_handle
            .downcast::<Root>()
            .ok_or("native drop-window target lacks Root")?;
        settle(target_handle, cx).await?;
        let target_window = cx
            .update_window(target_handle.into(), |_, window, _| {
                raw_view(window)
                    .ok_or_else(|| "native drop-window target root view disappeared".to_string())?
                    .window()
                    .ok_or_else(|| "native drop-window target has no NSWindow".to_string())
            })
            .map_err(error)??;
        target_window_for_cleanup = Some(target_window.clone());

        // Place the two fixture windows at the same screen frame. The probe uses
        // a GPUI-local point and the production helper performs view→window→screen
        // conversion before asking AppKit for the actual frontmost window.
        let owner_frame = owner_window.frame();
        target_window.setFrame_display(owner_frame, true);
        settle(target_handle, cx).await?;
        ensure(
            fixture_frame_values(target_window.frame()) == fixture_frame_values(owner_frame),
            "native drop-window fixture windows did not overlap exactly",
        )?;
        let position = cx
            .update_window(target_handle.into(), |_, window, _| {
                let viewport = window.viewport_size();
                gpui::point(viewport.width / 2.0, viewport.height / 2.0)
            })
            .map_err(error)?;
        let source_number = owner_window.windowNumber();
        let target_number = target_window.windowNumber();
        ensure(
            source_number > 0 && target_number > 0 && source_number != target_number,
            "native drop-window fixture did not create two distinct native windows",
        )?;

        // A frontmost hit on the drag's own source is excluded from cross-window
        // candidates, so the existing drag contract falls back to local reorder.
        target_window.orderFrontRegardless();
        owner_window.orderFrontRegardless();
        settle(target_handle, cx).await?;
        settle(owner_handle, cx).await?;
        ensure(
            target_window.isVisible()
                && !target_window.isMiniaturized()
                && target_window.isOnActiveSpace()
                && fixture_eligible_drop_window(target_handle, cx)? == Some(target_number),
            "visible overlapping drop target was not eligible on the active Space",
        )?;
        let source_front_hit = fixture_native_drop_hit(target_handle, position, cx)?;
        ensure(
            source_front_hit == NativeDropHit::Window(source_number),
            "AppKit did not hit the source window when it was ordered above the target",
        )?;

        // Ordering the other fixture window in front makes it the only eligible
        // cross-window drop candidate at this point.
        target_window.orderFrontRegardless();
        settle(target_handle, cx).await?;
        let visible_target_hit = fixture_native_drop_hit(target_handle, position, cx)?;
        ensure(
            fixture_eligible_drop_window(target_handle, cx)? == Some(target_number)
                && visible_target_hit == NativeDropHit::Window(target_number),
            "frontmost visible target was not selected by native drop hit testing",
        )?;

        // A hidden or miniaturized target may retain stale GPUI bounds, but it is
        // never an eligible native target. These operations touch only the second
        // window created above; no system input events are synthesized.
        target_window.orderOut(None);
        owner_window.orderFrontRegardless();
        settle(owner_handle, cx).await?;
        let hidden_hit = fixture_native_drop_hit(target_handle, position, cx)?;
        ensure(
            fixture_eligible_drop_window(target_handle, cx)?.is_none()
                && hidden_hit != NativeDropHit::Window(target_number),
            "hidden target remained eligible for a cross-window drop",
        )?;

        target_window.makeKeyAndOrderFront(None);
        settle(target_handle, cx).await?;
        target_window.miniaturize(None);
        owner_window.orderFrontRegardless();
        let minimization_started = std::time::Instant::now();
        while !target_window.isMiniaturized() {
            if minimization_started.elapsed() >= std::time::Duration::from_secs(2) {
                return Err(
                    "owned drop target did not finish miniaturizing within two seconds".into(),
                );
            }
            cx.background_executor()
                .timer(std::time::Duration::from_millis(20))
                .await;
        }
        settle(owner_handle, cx).await?;
        let miniaturized_hit = fixture_native_drop_hit(target_handle, position, cx)?;
        ensure(
            target_window.isMiniaturized()
                && fixture_eligible_drop_window(target_handle, cx)?.is_none()
                && miniaturized_hit != NativeDropHit::Window(target_number),
            "miniaturized target remained eligible for a cross-window drop",
        )?;

        Ok(serde_json::json!({
            "source_front_hit_reorders_locally": true,
            "frontmost_visible_target_is_eligible": true,
            "hidden_target_rejected": true,
            "miniaturized_target_rejected": true,
            "fixture_synthesized_system_input": false
        }))
    }
    .await;

    if let Some(target_window) = target_window_for_cleanup.as_ref() {
        target_window.deminiaturize(None);
        target_window.orderOut(None);
    }
    owner_window.makeKeyAndOrderFront(None);
    let cleanup_result = target_any_handle
        .update(cx, |_, window, _| window.remove_window())
        .map_err(error);
    let restore_result = settle(owner_handle, cx).await;

    match (result, cleanup_result, restore_result) {
        (Err(failure), Ok(()), Ok(())) => Err(failure),
        (Err(failure), Err(cleanup), _) => Err(format!(
            "{failure}; fixture-window cleanup also failed: {cleanup}"
        )),
        (Err(failure), _, Err(restore)) => Err(format!(
            "{failure}; owner-window restore also failed: {restore}"
        )),
        (Ok(_), Err(cleanup), _) => Err(format!("fixture-window cleanup failed: {cleanup}")),
        (Ok(_), Ok(()), Err(restore)) => Err(format!("owner-window restore failed: {restore}")),
        (Ok(value), Ok(()), Ok(())) => Ok(value),
    }
}
async fn activate_owned_editor_window(
    application: &NSApplication,
    window: &NSWindow,
    stage: &'static str,
    cx: &mut AsyncApp,
) -> Result<(), String> {
    MainThreadMarker::new().ok_or("owned editor window setup is not on main thread")?;
    let started = std::time::Instant::now();
    if application.activationPolicy() != NSApplicationActivationPolicy::Regular {
        application.setActivationPolicy(NSApplicationActivationPolicy::Regular);
    }
    ensure(
        application.activationPolicy() == NSApplicationActivationPolicy::Regular,
        "owned editor fixture activation policy is not Regular",
    )?;
    // AppKit delegate callbacks can re-enter GPUI. Mutate this retained owned
    // window outside an App/entity borrow, on the verified foreground thread.
    window.makeKeyAndOrderFront(None);
    // SAFETY: verified main-thread application and the exact selector used by
    // GPUI's activate(true). Avoid an App borrow during its callbacks.
    unsafe {
        let _: () = objc2::msg_send![application, activateIgnoringOtherApps: true];
    }
    loop {
        MainThreadMarker::new().ok_or("owned editor window setup left main thread")?;
        if application.isActive() && window.isKeyWindow() && window.isVisible() {
            return Ok(());
        }
        if started.elapsed() >= std::time::Duration::from_secs(5) {
            let snapshot = serde_json::json!({
                "stage": stage,
                "app_active": application.isActive(),
                "activation_policy": application.activationPolicy().0,
                "window_key": window.isKeyWindow(),
                "window_visible": window.isVisible(),
                "can_become_key": window.canBecomeKeyWindow(),
            });
            eprintln!("native_editor_window_owner={snapshot}");
            return Err("owned editor input ownership setup exceeded five seconds".into());
        }
        cx.background_executor()
            .timer(std::time::Duration::from_millis(10))
            .await;
    }
}
async fn prepare_visible_owned_window(
    handle: WindowHandle<Root>,
    cx: &mut AsyncApp,
) -> Result<(), String> {
    let mtm = MainThreadMarker::new().ok_or("owned editor setup is not on main thread")?;
    let application = NSApplication::sharedApplication(mtm);
    // Retain the root through the production handle helper while borrowing
    // GPUI; all NSWindow operations below happen after that borrow ends.
    let view = cx
        .update_window(handle.into(), |_, window, _| raw_view(window))
        .map_err(error)?
        .ok_or("owned editor native root view disappeared")?;
    let window = view
        .window()
        .ok_or("owned editor native root lacks NSWindow")?;
    activate_owned_editor_window(&application, &window, "before_materialization", cx).await
}
async fn prepare_composition_owner(
    native: &NativeMarkdown,
    cx: &mut AsyncApp,
) -> Result<(Retained<NSApplication>, Retained<NSWindow>), String> {
    let mtm = MainThreadMarker::new().ok_or("owned composition setup is not on main thread")?;
    let application = NSApplication::sharedApplication(mtm);
    let window = native
        .text
        .window()
        .ok_or("composition source has no current host")?;
    let activated =
        activate_owned_editor_window(&application, &window, "before_composition", cx).await;
    if activated.is_err() {
        composition_phase("before_mark", &application, &window, native);
    }
    activated?;
    ensure(
        window.makeFirstResponder(Some(&native.text)),
        "composition source cannot own its local responder",
    )?;
    composition_phase("before_mark", &application, &window, native);
    ensure(
        application.isActive()
            && window.isKeyWindow()
            && window.isVisible()
            && source_is_first_responder(native, &window),
        "owned editor source lacks active key-window input ownership",
    )?;
    Ok((application, window))
}
fn event(
    native: &NativeMarkdown,
    chars: &str,
    modifiers: NSEventModifierFlags,
    code: u16,
) -> Result<Retained<NSEvent>, String> {
    let window = native
        .text
        .window()
        .ok_or("source text has no owned window")?;
    ensure(
        native
            .shared
            .host
            .view()
            .and_then(|view| view.window())
            .is_some_and(|host| std::ptr::eq(&*host, &*window)),
        "source shortcut did not belong to its currently mounted host",
    )?;
    ensure(
        window.makeFirstResponder(Some(&native.text)),
        "owned source could not become its window's first responder",
    )?;
    let chars = NSString::from_str(chars);
    NSEvent::keyEventWithType_location_modifierFlags_timestamp_windowNumber_context_characters_charactersIgnoringModifiers_isARepeat_keyCode(
        NSEventType::KeyDown, NSPoint::new(0.,0.), modifiers, 0., window.windowNumber(),
        None, &chars, &chars, false, code,
    ).ok_or_else(|| "AppKit could not construct owned keyboard event".into())
}
fn key(
    native: &NativeMarkdown,
    chars: &str,
    modifiers: NSEventModifierFlags,
    code: u16,
) -> Result<(), String> {
    let event = event(native, chars, modifiers, code)?;
    ensure(
        native.text.performKeyEquivalent(&event),
        "native shortcut was not consumed",
    )
}

fn verify_private_terminal_pasteboard(
    native: &SourceTextView,
    selection: &chau7_next_core::terminal_clipboard::StyledClipboardSelection,
) -> Result<String, String> {
    use chau7_next_core::terminal_clipboard::StyledClipboardSelection;

    let _main_thread =
        objc2::MainThreadMarker::new().ok_or("private clipboard fixture is not on main thread")?;
    let pasteboard = NSPasteboard::pasteboardWithUniqueName();
    let mut undo_for_cleanup = None;
    let result: Result<String, String> = (|| {
        let rich_source = selection
            .markdown_source()
            .ok_or("native paste fixture could not create a rich Markdown block")?;
        let undo = native
            .undoManager()
            .ok_or("native paste fixture has no undo manager")?;
        undo_for_cleanup = Some((undo.clone(), undo.groupsByEvent()));

        ensure(
            crate::platform::rich_clipboard::write_terminal_selection_to_fixture_pasteboard(
                &pasteboard,
                selection,
            ),
            "private pasteboard adapter did not write all three flavors",
        )?;

        let plain_type = crate::platform::rich_clipboard::fixture_plain_text_type();
        let plain = pasteboard
            .stringForType(&plain_type)
            .ok_or("private pasteboard is missing plain text")?
            .to_string();
        ensure(
            plain == selection.plain_text,
            "private pasteboard plain text did not round-trip",
        )?;

        let html_type = crate::platform::rich_clipboard::fixture_html_type();
        let html_data = pasteboard
            .dataForType(&html_type)
            .ok_or("private pasteboard is missing HTML")?;
        ensure(
            html_data.length() <= 1024 * 1024,
            "fixture HTML payload exceeded its bound",
        )?;
        let html = String::from_utf8(html_data.to_vec())
            .map_err(|_| "private pasteboard HTML was not UTF-8")?;
        ensure(
            html.contains("color:#e65014")
                && html.contains(r#"href="https://example.test""#)
                && html.contains("&lt;")
                && html.contains("&amp;"),
            "private pasteboard HTML lost style, link, or escaping",
        )?;

        let json =
            crate::platform::rich_clipboard::read_terminal_selection_from_fixture_pasteboard(
                &pasteboard,
            )
            .ok_or("private pasteboard private flavor was missing or invalid UTF-8")?;
        let decoded = StyledClipboardSelection::decode_json(&json)
            .ok_or("private pasteboard JSON failed validation")?;
        ensure(
            &decoded == selection,
            "private pasteboard styled selection did not round-trip",
        )?;

        // Replace a two-unit emoji between surrounding text. The source view's
        // actual paste: selector reads only its injected private board and runs
        // the same JSON parser, block placement and NSTextView input API as the
        // production path.
        let original_document = "A🙂B";
        let selection_bytes = 1..5;
        let insertion = chau7_next_core::terminal_clipboard::place_markdown_block(
            original_document,
            selection_bytes.clone(),
            &rich_source,
        )
        .ok_or("native paste fixture could not place the rich Markdown block")?;
        let expected_document = format!(
            "{}{}{}",
            &original_document[..selection_bytes.start],
            insertion,
            &original_document[selection_bytes.end..],
        );
        native.setString(&NSString::from_str(original_document));
        ensure(
            native.string().to_string() == original_document,
            "native paste fixture could not seed its Unicode replacement target",
        )?;
        undo.removeAllActions();
        undo.setGroupsByEvent(false);
        native.setSelectedRange(NSRange::new(1, 2));
        undo.beginUndoGrouping();
        native.set_fixture_pasteboard(Some(pasteboard.clone()));
        let dispatch_result = {
            unsafe {
                let _: () = msg_send![native, paste: None::<&AnyObject>];
            }
            ensure(
                native.string().to_string() == expected_document,
                "paste: selector did not replace the Unicode range with exact rich Markdown",
            )
        };
        native.set_fixture_pasteboard(None);
        undo.endUndoGrouping();
        dispatch_result?;
        ensure(undo.canUndo(), "rich native paste did not register undo")?;
        undo.undo();
        ensure(
            native.string().to_string() == original_document,
            "undo did not restore the replaced Unicode selection",
        )?;
        ensure(undo.canRedo(), "rich native paste did not register redo")?;
        undo.redo();
        ensure(
            native.string().to_string() == expected_document,
            "redo did not restore the exact rich Markdown source",
        )?;
        Ok(expected_document)
    })();

    if let Some((undo, groups_by_event)) = undo_for_cleanup {
        undo.setGroupsByEvent(groups_by_event);
    }
    let _: isize = pasteboard.clearContents();
    result
}

pub(in crate::panes::editor) async fn verify(
    cx: &mut AsyncApp,
) -> Result<serde_json::Value, String> {
    let home = std::env::var_os("CHAU7_NEXT_HOME_ROOT").ok_or("validated fixture home missing")?;
    let path = std::path::PathBuf::from(home).join("native-editor-owned.md");
    let initial = "# café😀\n";
    // This file belongs to the runner's newly-created home, never a user note.
    std::fs::write(&path, initial).map_err(error)?;
    let fixture_shell = path.with_file_name("native-editor-focus-shell");
    std::fs::write(&fixture_shell, "#!/bin/sh\nexec /bin/cat >/dev/null\n").map_err(error)?;
    std::fs::set_permissions(&fixture_shell, std::fs::Permissions::from_mode(0o700))
        .map_err(error)?;
    cx.update(|cx| {
        cx.global_mut::<Settings>().terminal.shell =
            Some(fixture_shell.to_string_lossy().into_owned());
    });
    let saved = SavedWindow {
        tabs: vec![SavedTab {
            layout: Some(SavedSplitNode::Editor { id: 1, path: None }),
            ..Default::default()
        }],
        ..Default::default()
    };
    let (handle, workspace) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    show: true,
                    focus: false,
                    ..Default::default()
                },
                cx,
                |window, cx| cx.new(|cx| Workspace::new(Some(saved), window, cx)),
            )
        })
        .map_err(error)?;
    let handle = handle
        .downcast::<Root>()
        .ok_or("owned editor window lacks Root")?;
    // Deferred production panes require actual visibility, including occlusion.
    // Establish this owned app/window's foreground state before awaiting that
    // guard; source input ownership is still revalidated before marked text.
    prepare_visible_owned_window(handle, cx).await?;
    // The production restored pane is deferred until its real window is
    // visible. Wait for that path rather than reading the placeholder layout.
    let started = std::time::Instant::now();
    let editor = loop {
        if let Some(editor) = cx.update(|cx| {
            workspace.read(cx).selected_panes().and_then(|panes| {
                panes
                    .read(cx)
                    .leaves()
                    .into_iter()
                    .find_map(|pane| match pane {
                        PaneItem::Editor(editor) => Some(editor),
                        _ => None,
                    })
            })
        }) {
            break editor;
        }
        if started.elapsed() >= std::time::Duration::from_secs(5) {
            return Err("visible restored editor-only layout did not materialize an editor".into());
        }
        settle(handle, cx).await?;
        cx.background_executor()
            .timer(std::time::Duration::from_millis(10))
            .await;
    };
    cx.update_window(handle.into(), |_, window, cx| {
        editor.update(cx, |editor, cx| {
            editor.path = Some(path.clone());
            editor.language =
                chau7_next_core::editor::language::EditorLanguage::detect("native-editor-owned.md");
            editor.autosave = false;
            editor
                .state
                .update(cx, |state, cx| state.set_value(initial, window, cx));
            editor.install_highlighter(cx);
            window.focus(&editor.focus_handle, cx);
            cx.notify();
        });
    })
    .map_err(error)?;
    settle(handle, cx).await?;
    let native = cx
        .update(|cx| editor.read(cx).native_markdown.clone())
        .ok_or("actual SourceTextView was not created")?;
    cx.update(|_| ensure(attached(&native), "actual NativeElement never attached"))
        .map_err(error)?;
    let (terminal, session) = cx
        .update_window(handle.into(), |_, window, cx| {
            let panes = workspace
                .read(cx)
                .selected_panes()
                .ok_or("owned editor workspace has no selected pane tree")?;
            panes.update(cx, |tree, cx| {
                tree.split(gpui::Axis::Horizontal, window, cx)
            });
            let terminal = panes
                .read(cx)
                .views()
                .into_iter()
                .last()
                .ok_or("owned editor focus fixture did not create a terminal")?;
            let session = terminal.read(cx).session.clone();
            Ok::<_, String>((terminal, session))
        })
        .map_err(error)??;
    settle(handle, cx).await?;
    cx.update_window(handle.into(), |_, window, cx| {
        let panes = workspace
            .read(cx)
            .selected_panes()
            .ok_or("selected pane tree disappeared")?;
        ensure(
            terminal.read(cx).focus_handle(cx).is_focused(window)
                && panes
                    .read(cx)
                    .focused_item()
                    .is_some_and(|item| item.entity_id() == terminal.entity_id()),
            "new native focus regression terminal was not initially focused",
        )
    })
    .map_err(error)??;
    let initial_layout_validation = last_attach_decision(&native)
        .and_then(|layout| validate_layout(&native, layout, layout.bounds, None).map(|()| layout));

    // The GPUI terminal starts focused while the AppKit source is not the
    // first responder. A real AppKit click must synchronize both focus trees.
    let (application, native_window) =
        prepare_visible_owned_window(handle, cx)
            .await
            .and_then(|()| {
                let mtm = MainThreadMarker::new().ok_or("native focus fixture left main thread")?;
                let application = NSApplication::sharedApplication(mtm);
                let native_window = native
                    .text
                    .window()
                    .ok_or("native focus source has no owned window")?;
                ensure(
                    !source_is_first_responder(&native, &native_window),
                    "native focus fixture unexpectedly started with the source as first responder",
                )?;
                Ok((application, native_window))
            })?;
    click_native_source(
        &application,
        &native_window,
        &native,
        "initial_editor_click",
    )?;
    settle(handle, cx).await?;
    cx.update_window(handle.into(), |_, window, cx| {
        let panes = workspace
            .read(cx)
            .selected_panes()
            .ok_or("selected pane tree disappeared")?;
        ensure(
            editor.read(cx).focus_handle.is_focused(window)
                && panes
                    .read(cx)
                    .focused_item()
                    .is_some_and(|item| item.entity_id() == editor.entity_id())
                && source_is_first_responder(&native, &native_window),
            "native NSTextView click did not synchronize GPUI focus to EditorPane",
        )
    })
    .map_err(error)??;

    let terminal_point = cx
        .update_window(handle.into(), |_, window, cx| {
            window.render_frame(cx);
            let size = window.viewport_size();
            gpui::point(size.width * 0.75, size.height / 2.0)
        })
        .map_err(error)?;
    click_gpui_terminal(handle, terminal_point, cx)?;
    settle(handle, cx).await?;
    cx.update_window(handle.into(), |_, window, cx| {
        let panes = workspace
            .read(cx)
            .selected_panes()
            .ok_or("selected pane tree disappeared")?;
        ensure(
            terminal.read(cx).focus_handle(cx).is_focused(window)
                && panes
                    .read(cx)
                    .focused_item()
                    .is_some_and(|item| item.entity_id() == terminal.entity_id())
                && !source_is_first_responder(&native, &native_window)
                && host_is_first_responder(&native, &native_window)
                && attached(&native),
            "terminal click did not move GPUI and AppKit focus off the native source",
        )?;
        let before_input = session.read(cx).input_revision();
        window.input("native-editor focus regression probe", cx);
        ensure(
            session.read(cx).input_revision() > before_input,
            "focused terminal did not receive input after native editor focus",
        )
    })
    .map_err(error)??;

    // Exercise the delivery race: an AppKit source click queues GPUI focus
    // delivery, then the terminal is clicked before that async delivery gets
    // a frame. The late source-focus message must not steal focus back.
    click_native_source(&application, &native_window, &native, "pending_focus_race")?;
    click_gpui_terminal_immediately(handle, terminal_point, cx)?;
    settle(handle, cx).await?;
    cx.update_window(handle.into(), |_, window, cx| {
        let panes = workspace
            .read(cx)
            .selected_panes()
            .ok_or("selected pane tree disappeared")?;
        ensure(
            terminal.read(cx).focus_handle(cx).is_focused(window)
                && panes
                    .read(cx)
                    .focused_item()
                    .is_some_and(|item| item.entity_id() == terminal.entity_id())
                && host_is_first_responder(&native, &native_window)
                && !source_is_first_responder(&native, &native_window),
            "late native editor focus delivery stole focus from the clicked terminal",
        )?;
        let before_input = session.read(cx).input_revision();
        window.input("pending-focus race regression probe", cx);
        ensure(
            session.read(cx).input_revision() > before_input,
            "terminal rejected input after the native-focus delivery race",
        )
    })
    .map_err(error)??;

    // Recreate the split-brain state from the user bug: GPUI still believes
    // the terminal owns focus, but AppKit has made the text view first
    // responder directly. A second GPUI click must explicitly reclaim the
    // native responder even though `window.focus` sees no GPUI transition.
    cx.update_window(handle.into(), |_, window, cx| {
        ensure(
            terminal.read(cx).focus_handle(cx).is_focused(window),
            "native focus desynchronization fixture lost GPUI terminal focus",
        )?;
        ensure(
            native_window.makeFirstResponder(Some(&native.text)),
            "AppKit could not create the desynchronized native source focus",
        )?;
        ensure(
            terminal.read(cx).focus_handle(cx).is_focused(window)
                && source_is_first_responder(&native, &native_window),
            "native focus desynchronization setup changed the wrong focus owner",
        )
    })
    .map_err(error)??;
    click_gpui_terminal(handle, terminal_point, cx)?;
    settle(handle, cx).await?;
    cx.update_window(handle.into(), |_, window, cx| {
        let panes = workspace
            .read(cx)
            .selected_panes()
            .ok_or("selected pane tree disappeared")?;
        ensure(
            terminal.read(cx).focus_handle(cx).is_focused(window)
                && panes
                    .read(cx)
                    .focused_item()
                    .is_some_and(|item| item.entity_id() == terminal.entity_id())
                && host_is_first_responder(&native, &native_window)
                && !source_is_first_responder(&native, &native_window),
            "terminal click did not reclaim AppKit first-responder ownership when GPUI focus was unchanged",
        )?;
        let before_input = session.read(cx).input_revision();
        window.input("desynchronized native-focus regression probe", cx);
        ensure(
            session.read(cx).input_revision() > before_input,
            "terminal rejected input after reclaiming desynchronized native focus",
        )
    })
    .map_err(error)??;

    // All focus, race, desynchronization, and terminal-input assertions above
    // are complete. Foreground ownership can change while the fake PTY probes
    // settle, so reacquire the owned key window before the independent
    // composition and keyboard scenario.
    if !(application.isActive() && native_window.isVisible() && native_window.isKeyWindow()) {
        let frontmost_application = NSWorkspace::sharedWorkspace().frontmostApplication();
        eprintln!(
            "native_editor_restore_foreground_before={}",
            serde_json::json!({
                "application_active": application.isActive(),
                "window_number": native_window.windowNumber(),
                "window_visible": native_window.isVisible(),
                "window_key": native_window.isKeyWindow(),
                "application_key_window_number": application
                    .keyWindow()
                    .map(|window| window.windowNumber()),
                "frontmost_application": frontmost_application.as_ref().map(|application| {
                    serde_json::json!({
                        "process_id": application.processIdentifier(),
                        "bundle_identifier": application
                            .bundleIdentifier()
                            .map(|id| id.to_string()),
                    })
                }),
            })
        );
    }
    prepare_visible_owned_window(handle, cx).await?;
    click_native_source(
        &application,
        &native_window,
        &native,
        "restore_editor_click",
    )?;
    settle(handle, cx).await?;
    cx.update_window(handle.into(), |_, window, cx| {
        ensure(
            editor.read(cx).focus_handle.is_focused(window)
                && source_is_first_responder(&native, &native_window),
            "native source focus could not be restored after terminal input",
        )
    })
    .map_err(error)??;
    let _ = prepare_composition_owner(&native, cx).await?;

    // Keep an old frame's actual lifetime guard across a forced remount.
    let stale_attachment = Attachment {
        native: native.clone(),
        generation: native.mount_generation.get(),
    };
    let previous_mount = stale_attachment.generation;
    // Exercise NSTextInputClient on the production SourceTextView and let an
    // actual GPUI frame/restyle pass while its text is still marked.
    let _storage_edit_observer = cx
        .update(|_| FixtureStorageObserver::register(&native.text))
        .map_err(error)?;
    native
        .shared
        .fixture_trace
        .begin(&native.text, "fixture.before_mark");
    cx.update(|_| {
        native
            .shared
            .fixture_trace
            .record(&native.text, "fixture.set_selection.before", None);
        native
            .text
            .setSelectedRange(NSRange::new(initial.encode_utf16().count(), 0));
        native
            .shared
            .fixture_trace
            .record(&native.text, "fixture.set_selection.after", None);
        native
            .shared
            .fixture_trace
            .record(&native.text, "fixture.setMarkedText.before", None);
        unsafe {
            native.text.setMarkedText_selectedRange_replacementRange(
                &NSString::from_str("に"),
                NSRange::new(1, 0),
                NSRange::new(NSNotFound as usize, 0),
            );
        }
        native
            .shared
            .fixture_trace
            .record(&native.text, "fixture.setMarkedText.after", None);
        composition_phase("after_mark", &application, &native_window, &native);
        ensure(
            native.text.hasMarkedText(),
            "AppKit did not enter marked-text composition",
        )?;
        // Force the production text-change and mirror paths while marked.
        // Neither styling nor a stale mirror is allowed to remove composition.
        native
            .shared
            .fixture_trace
            .record(&native.text, "fixture.shared_changed.before", None);
        native.shared.changed(&native.text, true);
        native
            .shared
            .fixture_trace
            .record(&native.text, "fixture.shared_changed.after", None);
        let config = native.shared.config.borrow().clone();
        native
            .shared
            .fixture_trace
            .record(&native.text, "fixture.sync.before", None);
        native.sync(initial, &config);
        native
            .shared
            .fixture_trace
            .record(&native.text, "fixture.sync.after", None);
        ensure(
            native.text.hasMarkedText(),
            "text-change/mirror stripped marked text",
        )
    })
    .map_err(error)?;
    cx.update(|cx| editor.update(cx, |_, cx| cx.notify()));
    // Preserve exactly the two real settle frames and their existing deadlines,
    // recording the native state after each without an extra frame or retry.
    cx.update(|_| {
        native
            .shared
            .fixture_trace
            .record(&native.text, "fixture.frame_one.before", None)
    });
    crate::native_parity_fixture::next_frame(handle.into(), cx).await?;
    MainThreadMarker::new().ok_or("owned composition frame left main thread")?;
    native.shared.fixture_trace.record(
        &native.text,
        "fixture.frame_one.next_frame_completed",
        None,
    );
    composition_phase("after_frame_one", &application, &native_window, &native);
    native
        .shared
        .fixture_trace
        .record(&native.text, "fixture.frame_one.after", None);
    cx.update(|_| {
        native
            .shared
            .fixture_trace
            .record(&native.text, "fixture.frame_two.before", None)
    });
    crate::native_parity_fixture::next_frame(handle.into(), cx).await?;
    MainThreadMarker::new().ok_or("owned composition frame left main thread")?;
    native.shared.fixture_trace.record(
        &native.text,
        "fixture.frame_two.next_frame_completed",
        None,
    );
    composition_phase("after_frame_two", &application, &native_window, &native);
    native
        .shared
        .fixture_trace
        .record(&native.text, "fixture.frame_two.after", None);
    cx.update(|_| {
        ensure(native.mount_generation.get() != previous_mount,
            "owned native source did not actually remount")?;
        drop(stale_attachment);
        ensure(attached(&native), "old frame guard detached the current source")?;
        let composition_survived = native.text.hasMarkedText();
        native.shared.fixture_trace.finish(!composition_survived);
        ensure(
            composition_survived,
            &format!(
                "restyling/repaint discarded marked composition (attached={}, native_matches={}, document_matches={}, pending_text={})",
                attached(&native),
                native.text.string().to_string() == format!("{initial}に"),
                native.shared.document.borrow().text() == format!("{initial}に"),
                native.has_pending_edits(),
            ),
        )?;
        ensure(
            native.text.string().to_string() == format!("{initial}に"),
            "composition text drifted",
        )?;
        unsafe {
            native.text.setMarkedText_selectedRange_replacementRange(
                &NSString::from_str("日本"),
                NSRange::new(2, 0),
                NSRange::new(NSNotFound as usize, 0),
            );
            native.text.insertText_replacementRange(
                &NSString::from_str("日本"),
                NSRange::new(NSNotFound as usize, 0),
            );
        }
        ensure(!native.text.hasMarkedText(), "composition did not commit")?;
        ensure(
            native.text.string().to_string() == format!("{initial}日本"),
            "committed text is incorrect",
        )
    })
    .map_err(error)?;
    settle(handle, cx).await?;
    cx.update(|cx| {
        ensure(
            editor.read(cx).state.read(cx).value() == format!("{initial}日本"),
            "committed composition did not reach actual GPUI buffer",
        )
    })
    .map_err(error)?;

    // Send the same window-targeted native key event through AppKit's normal
    // NSApplication -> NSWindow -> first-responder route, outside the GPUI App
    // borrow so AppKit may safely re-enter the host during event delivery.
    MainThreadMarker::new().ok_or("ordinary source key dispatch is not on main thread")?;
    let undo = native
        .text
        .undoManager()
        .ok_or("owned history unavailable")?;
    undo.removeAllActions();
    undo.setGroupsByEvent(false);
    undo.beginUndoGrouping();
    native
        .text
        .setSelectedRange(NSRange::new(native.text.string().length(), 0));
    let typed = event(&native, "x", NSEventModifierFlags::empty(), 7)?;
    ordinary_keydown_phase("before", &application, &native_window, &native, &typed);
    application.sendEvent(&typed);
    ordinary_keydown_phase("after", &application, &native_window, &native, &typed);
    cx.update(|_| {
        ensure(
            native.text.string().to_string() == format!("{initial}日本x"),
            "ordinary keyDown did not reach the actual source text",
        )?;
        undo.endUndoGrouping();
        ensure(undo.canUndo(), "actual source edit has no undo history")?;
        key(&native, "z", NSEventModifierFlags::Command, 6)?;
        ensure(
            native.text.string().to_string() == format!("{initial}日本"),
            "Cmd+Z did not undo the source edit",
        )?;
        key(
            &native,
            "z",
            NSEventModifierFlags::Command | NSEventModifierFlags::Shift,
            6,
        )?;
        ensure(
            native.text.string().to_string() == format!("{initial}日本x"),
            "Cmd+Shift+Z did not redo",
        )?;
        key(&native, "s", NSEventModifierFlags::Command, 1)
    })
    .map_err(error)?;
    settle(handle, cx).await?;
    // Saving is asynchronous and is bounded by the same owned runner timeout.
    for _ in 0..20 {
        if std::fs::read_to_string(&path).map_err(error)? == format!("{initial}日本x") {
            break;
        }
        settle(handle, cx).await?;
    }
    ensure(
        std::fs::read_to_string(&path).map_err(error)? == format!("{initial}日本x"),
        "actual Cmd+S delivery did not save the owned file",
    )?;

    cx.update(|cx| {
        ensure(
            editor
                .read(cx)
                .native_fixture_header_progress
                .get()
                .is_none(),
            "task-free source painted a progress counter",
        )
    })
    .map_err(error)?;
    // Earlier deterministic Undo/Redo disables event grouping. Restore the
    // production manager policy before further input delivered in real frames.
    cx.update(|_| {
        native
            .text
            .undoManager()
            .ok_or("owned history missing")
            .map(|undo| undo.setGroupsByEvent(true))
    })
    .map_err(error)?;
    let tasks = "\n- [x] done\n- [ ] pending\n```\n- [x] fenced example\n```\n";
    cx.update(|_| unsafe {
        native.text.insertText_replacementRange(
            &NSString::from_str(tasks),
            NSRange::new(native.text.string().length(), 0),
        );
    });
    settle(handle, cx).await?;
    cx.update(|cx| {
        ensure(
            editor.read(cx).native_fixture_header_progress.get() == Some((1, 2)),
            "actual painted header did not show 1/2 or counted a fenced example",
        )
    })
    .map_err(error)?;
    cx.update(|_| {
        let text = native.text.string().to_string();
        let start = text.find("[ ]").ok_or("owned pending task missing")?;
        unsafe {
            native.text.insertText_replacementRange(
                &NSString::from_str("[x]"),
                NSRange::new(text[..start].encode_utf16().count(), 3),
            );
        }
        Ok::<_, String>(())
    })
    .map_err(error)?;
    settle(handle, cx).await?;
    cx.update(|cx| {
        ensure(
            editor.read(cx).native_fixture_header_progress.get() == Some((2, 2)),
            "actual painted header did not update to 2/2 after native input",
        )
    })
    .map_err(error)?;

    cx.update_window(handle.into(), |_, window, cx| {
        window.open_dialog(cx, |dialog, _, _| dialog.title("Owned editor fixture"))
    })
    .map_err(error)?;
    settle(handle, cx).await?;
    cx.update(|_| {
        ensure(
            !attached(&native) && native.scroll.window().is_none(),
            "real GPUI dialog failed to detach the native editor",
        )
    })
    .map_err(error)?;
    cx.update_window(handle.into(), |_, window, cx| window.close_all_dialogs(cx))
        .map_err(error)?;
    settle(handle, cx).await?;
    cx.update(|_| {
        ensure(
            attached(&native),
            "source did not remount after dialog close",
        )
    })
    .map_err(error)?;
    cx.update_window(handle.into(), |_, window, cx| {
        window.open_sheet(cx, |sheet, _, _| sheet.title("Owned editor fixture"))
    })
    .map_err(error)?;
    settle(handle, cx).await?;
    cx.update(|_| {
        ensure(
            !attached(&native),
            "real GPUI sheet failed to detach source",
        )
    })
    .map_err(error)?;
    cx.update_window(handle.into(), |_, window, cx| window.close_sheet(cx))
        .map_err(error)?;
    settle(handle, cx).await?;

    // Render and focus a real PopupMenu; this exercises the actual dispatch
    // context consulted by NativeElement::prepaint and the focus-out observer.
    let popup = cx
        .update_window(handle.into(), |_, window, cx| {
            let popup = PopupMenu::build(window, cx, |menu, _, _| {
                menu.item(PopupMenuItem::Label("Owned menu".into()))
            });
            editor.update(cx, |editor, cx| {
                editor.native_fixture_popup = Some(popup.clone());
                cx.notify();
            });
            popup
        })
        .map_err(error)?;
    settle(handle, cx).await?;
    cx.update_window(handle.into(), |_, window, cx| {
        window.focus(&popup.read(cx).focus_handle(cx), cx);
        window.refresh();
    })
    .map_err(error)?;
    settle(handle, cx).await?;
    cx.update_window(handle.into(), |_, window, _| {
        ensure(
            window
                .context_stack()
                .iter()
                .any(|context| context.contains("PopupMenu")),
            "real popup did not enter its dispatch context",
        )
    })
    .map_err(error)??;
    cx.update(|_| {
        ensure(
            !attached(&native),
            "real focused PopupMenu failed to detach native editor",
        )
    })
    .map_err(error)?;
    cx.update_window(handle.into(), |_, window, cx| {
        editor.update(cx, |editor, cx| {
            editor.native_fixture_popup = None;
            window.focus(&editor.focus_handle, cx);
            cx.notify();
        });
    })
    .map_err(error)?;
    settle(handle, cx).await?;
    cx.update(|_| {
        ensure(
            attached(&native),
            "source did not remount after popup dismissal",
        )
    })
    .map_err(error)?;
    cx.update(|_| {
        key(
            &native,
            "p",
            NSEventModifierFlags::Command | NSEventModifierFlags::Shift,
            35,
        )
    })
    .map_err(error)?;
    settle(handle, cx).await?;
    cx.update(|cx| {
        ensure(
            editor.read(cx).markdown_mode,
            "native preview binding did not route to current GPUI pane",
        )?;
        ensure(
            !attached(&native),
            "preview retained native surface ownership",
        )
    })
    .map_err(error)?;
    cx.update_window(handle.into(), |_, window, cx| {
        editor.update(cx, |editor, cx| {
            editor.markdown_mode = false;
            cx.notify();
        });
        window.refresh();
    })
    .map_err(error)?;
    settle(handle, cx).await?;
    cx.update(|_| ensure(attached(&native), "source did not remount after preview"))
        .map_err(error)?;

    // Check layout reconciliation only after the marked-text frames, commit,
    // input, history and save assertions have completed. These direct attach
    // calls use the production host and bounds without changing the NSWindow.
    MainThreadMarker::new().ok_or("native layout fixture is not on main thread")?;
    initial_layout_validation?;
    let baseline_layout = last_attach_decision(&native)?;
    validate_layout(&native, baseline_layout, baseline_layout.bounds, None)?;

    let previous_generation = native.mount_generation.get();
    let same_generation =
        attach_fixture_bounds(handle, &native, fixture_bounds(baseline_layout), cx)?;
    ensure(
        same_generation == previous_generation.wrapping_add(1)
            && native.mount_generation.get() == same_generation,
        "same-bounds native attach did not advance its mount generation",
    )?;
    validate_layout(
        &native,
        last_attach_decision(&native)?,
        baseline_layout.bounds,
        Some((false, false, Some(false), false)),
    )?;

    let [x, y, width, height] = baseline_layout.bounds;
    ensure(
        width > 1.0,
        "native fixture source is too narrow to resize safely",
    )?;
    let narrower_bounds = Bounds::new(
        gpui::point(gpui::px(x), gpui::px(y)),
        gpui::size(gpui::px(width - 1.0), gpui::px(height)),
    );
    attach_fixture_bounds(handle, &native, narrower_bounds, cx)?;
    validate_layout(
        &native,
        last_attach_decision(&native)?,
        [x, y, width - 1.0, height],
        Some((false, true, None, false)),
    )?;

    attach_fixture_bounds(handle, &native, fixture_bounds(baseline_layout), cx)?;
    validate_layout(
        &native,
        last_attach_decision(&native)?,
        baseline_layout.bounds,
        Some((false, true, None, false)),
    )?;

    native.detach();
    ensure(
        native.scroll.isHidden() && unsafe { native.scroll.superview() }.is_none(),
        "native fixture detach did not remove and hide the scroll view",
    )?;
    attach_fixture_bounds(handle, &native, fixture_bounds(baseline_layout), cx)?;
    validate_layout(
        &native,
        last_attach_decision(&native)?,
        baseline_layout.bounds,
        Some((true, true, None, true)),
    )?;
    settle(handle, cx).await?;
    ensure(
        attached(&native),
        "normal GPUI render did not retain the reattached native source",
    )?;
    validate_layout(
        &native,
        last_attach_decision(&native)?,
        baseline_layout.bounds,
        None,
    )?;

    // Exercise the actual AppKit glyph delegate and all clipboard flavors.
    // The clipboard check uses a unique private board, never the general one.
    let literal = "  if x < y && z > 0\n\t\"é\"";
    let selection = chau7_next_core::terminal_clipboard::StyledClipboardSelection::new(
        literal.to_string(),
        vec![
            chau7_next_core::terminal_clipboard::StyledClipboardRun {
                text: "  if x < y && z > 0\n\t".into(),
                bold: true,
                foreground: Some([230, 80, 20]),
                ..Default::default()
            },
            chau7_next_core::terminal_clipboard::StyledClipboardRun {
                text: "\"".into(),
                ..Default::default()
            },
            chau7_next_core::terminal_clipboard::StyledClipboardRun {
                text: "é".into(),
                italic: true,
                underline: true,
                background: Some([18, 52, 86]),
                link: Some("https://example.test".into()),
                ..Default::default()
            },
            chau7_next_core::terminal_clipboard::StyledClipboardRun {
                text: "\"".into(),
                ..Default::default()
            },
        ],
    )
    .ok_or("native glyph fixture selection was invalid")?;
    let rich_block = selection
        .markdown_source()
        .ok_or("native paste fixture could not create the rich Markdown block")?;
    let pasted_document = verify_private_terminal_pasteboard(&native.text, &selection)?;
    settle(handle, cx).await?;
    verify_rich_terminal_source(&native, &pasted_document, &rich_block, literal)?;
    let native_drop_window_hits =
        verify_native_drop_window_hits(handle, &native_window, cx).await?;

    cx.update(|cx| session.update(cx, |session, _| session.close()));
    cx.update_window(handle.into(), |_, window, _| window.remove_window())
        .map_err(error)?;
    cx.update(|_| {
        ensure(
            native.scroll.window().is_none(),
            "closed GPUI owner retained native surface",
        )
    })
    .map_err(error)?;
    Ok(serde_json::json!({
        "production_source_class": "Chau7NextMarkdownSourceTextView",
        "native_click_synchronizes_gpui_editor_focus": true,
        "terminal_click_returns_appkit_first_responder_to_host": true,
        "terminal_accepts_input_after_native_editor_focus": true,
        "terminal_metadata_glyphs_hidden_without_source_rewrite": true,
        "terminal_body_literal_colors_and_links_preserved": true,
        "native_cross_window_drop_hits": native_drop_window_hits,
        "marked_text_survives_actual_frame": true,
        "stale_attachment_preserves_remounted_composition": true,
        "composition_commit_reaches_gpui_buffer": true,
        "ordinary_keydown_current_source": true,
        "native_undo_redo_key_equivalents": true,
        "save_delivery_owned_file": true,
        "painted_task_progress_updates_after_native_input": true,
        "task_progress_excludes_code_fences": true,
        "actual_gpui_dialog_detach": true,
        "actual_gpui_sheet_detach": true,
        "actual_gpui_popup_context_detach": true,
        "preview_binding_and_remount": true,
        "closed_window_surface_detach": true,
        "native_initial_frame_matches_gpui_bounds": true,
        "same_bounds_attach_skips_frame_and_unhide_setters": true,
        "same_bounds_attach_skips_text_frame_setter": true,
        "changed_bounds_reconciles_scroll_frame": true,
        "detached_source_reattaches_to_same_host": true,
        "os_ime_input_source_automation": false,
        "general_clipboard_access": false,
        "private_test_pasteboard": true,
        "terminal_clipboard_three_flavors_roundtrip": true
    }))
}
