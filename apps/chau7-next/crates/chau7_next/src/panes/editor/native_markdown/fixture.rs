//! Optional acceptance against the actual AppKit class and GPUI attachment.
//! Only the validated, fresh native runner calls this. Events are delivered
//! directly to this process's view; no OS input, clipboard or providers are used.
use super::*;
use crate::{
    pane::PaneItem,
    session_store::{SavedTab, SavedWindow},
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
};
use objc2_app_kit::{NSApplication, NSApplicationActivationPolicy, NSEventType, NSWindow};
use objc2_foundation::NSNotFound;

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

pub(in crate::panes::editor) async fn verify(
    cx: &mut AsyncApp,
) -> Result<serde_json::Value, String> {
    let home = std::env::var_os("CHAU7_NEXT_HOME_ROOT").ok_or("validated fixture home missing")?;
    let path = std::path::PathBuf::from(home).join("native-editor-owned.md");
    let initial = "# café😀\n";
    // This file belongs to the runner's newly-created home, never a user note.
    std::fs::write(&path, initial).map_err(error)?;
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
    let initial_layout_validation = last_attach_decision(&native)
        .and_then(|layout| validate_layout(&native, layout, layout.bounds, None).map(|()| layout));

    let (application, native_window) = prepare_composition_owner(&native, cx).await?;

    // Keep an old frame's actual lifetime guard across a forced remount.
    let stale_attachment = Attachment {
        native: native.clone(),
        generation: native.mount_generation.get(),
    };
    let previous_mount = stale_attachment.generation;
    // Exercise NSTextInputClient on the production SourceTextView and let an
    // actual GPUI frame/restyle pass while its text is still marked.
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
        "clipboard_access": false
    }))
}
