//! Real macOS accessibility export and actions in an isolated native fixture.
use std::collections::{HashSet, VecDeque};
use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowHandle, WindowOptions, px, size};
use gpui_kit::base::Root;
use objc2::{MainThreadMarker, rc::Retained, sel};
use objc2_app_kit::NSView;
use objc2_foundation::{NSArray, NSNumber, NSObject, NSString};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use serde_json::{Value, json};

use super::{AppData, Workspace};

const MAX_NATIVE_NODES: usize = 4096;

struct TabExpected {
    label: String,
    description: String,
    selected: bool,
}

struct NativeElement {
    object: Retained<NSObject>,
    role: String,
    label: Option<String>,
}

fn error(error: impl std::fmt::Display) -> String {
    error.to_string()
}

fn ensure(condition: bool, message: &str) -> Result<(), String> {
    if condition {
        Ok(())
    } else {
        Err(message.into())
    }
}

fn native_content_view(
    handle: WindowHandle<Root>,
    cx: &mut AsyncApp,
) -> Result<Retained<NSView>, String> {
    handle
        .update(cx, |_, window, _| -> Result<Retained<NSView>, String> {
            let raw = HasWindowHandle::window_handle(window).map_err(error)?;
            let RawWindowHandle::AppKit(raw) = raw.as_raw() else {
                return Err("owned accessibility window lacks AppKit handle".into());
            };
            // SAFETY: GPUI owns the view for this live window; retain it while
            // obtaining the content view that owns AccessKit's adapter.
            let view = unsafe { Retained::retain(raw.ns_view.cast::<NSView>().as_ptr()) }
                .ok_or("owned accessibility view disappeared")?;
            view.window()
                .ok_or("owned accessibility view lacks NSWindow")?
                .contentView()
                .ok_or_else(|| "owned accessibility NSWindow lacks content view".to_owned())
        })
        .map_err(error)?
}

fn native_accessibility_tree(view: &NSView) -> Result<Vec<NativeElement>, String> {
    let _main = MainThreadMarker::new().ok_or("accessibility query is not on the main thread")?;
    // The actual AccessKit subclass is installed on this owned content view.
    // Calling its documented NSAccessibility selector activates that adapter;
    // it does not consult AX trust or a system-wide accessibility setting.
    let root = unsafe {
        Retained::<NSObject>::retain((view as *const NSView).cast_mut().cast::<NSObject>())
    }
    .ok_or("could not retain owned accessibility content view")?;
    let roots: Option<Retained<NSArray<NSObject>>> =
        unsafe { objc2::msg_send![&*root, accessibilityChildren] };
    let roots = roots.ok_or("owned content view did not export accessibility children")?;
    let mut queue = VecDeque::new();
    for index in 0..roots.count() {
        queue.push_back(roots.objectAtIndex(index));
    }

    let mut seen = HashSet::new();
    let mut result = Vec::new();
    while let Some(object) = queue.pop_front() {
        let pointer = (&*object as *const NSObject) as usize;
        if !seen.insert(pointer) {
            continue;
        }
        if seen.len() > MAX_NATIVE_NODES {
            return Err("owned accessibility tree exceeded its node limit".into());
        }
        let role: Option<Retained<NSString>> =
            unsafe { objc2::msg_send![&*object, accessibilityRole] };
        let label: Option<Retained<NSString>> =
            unsafe { objc2::msg_send![&*object, accessibilityTitle] };
        let children: Option<Retained<NSArray<NSObject>>> =
            unsafe { objc2::msg_send![&*object, accessibilityChildren] };
        if let Some(children) = children {
            if result
                .len()
                .saturating_add(queue.len())
                .saturating_add(children.count())
                > MAX_NATIVE_NODES
            {
                return Err("owned accessibility tree exceeded its node limit".into());
            }
            for index in 0..children.count() {
                queue.push_back(children.objectAtIndex(index));
            }
        }
        result.push(NativeElement {
            object,
            role: role.map_or_else(String::new, |value| value.to_string()),
            label: label.map(|value| value.to_string()),
        });
    }
    Ok(result)
}

fn native_find<'a>(
    elements: &'a [NativeElement],
    role: &str,
    label: &str,
) -> Option<&'a NativeElement> {
    elements
        .iter()
        .find(|element| element.role == role && element.label.as_deref() == Some(label))
}

fn native_radio_selected(elements: &[NativeElement], label: &str) -> Result<bool, String> {
    let _main =
        MainThreadMarker::new().ok_or("accessibility value query is not on the main thread")?;
    let matches: Vec<_> = elements
        .iter()
        .filter(|element| {
            element.role == "AXRadioButton" && element.label.as_deref() == Some(label)
        })
        .collect();
    ensure(
        matches.len() == 1,
        "native AppKit tree did not identify exactly one tab radio button by its localized title",
    )?;
    // AccessKit exposes a tab radio button's selected state as its AX value.
    let value: Option<Retained<NSNumber>> =
        unsafe { objc2::msg_send![&*matches[0].object, accessibilityValue] };
    value
        .map(|value| value.boolValue())
        .ok_or_else(|| "native AppKit tab radio button did not export a selected value".into())
}

fn tree_nodes_with_role<'a>(tree: &'a Value, role: &str) -> Vec<&'a Value> {
    tree.get("nodes")
        .and_then(Value::as_object)
        .map(|nodes| {
            nodes
                .values()
                .filter(|node| {
                    node.get("aria")
                        .and_then(|aria| aria.get("role"))
                        .and_then(Value::as_str)
                        == Some(role)
                })
                .collect()
        })
        .unwrap_or_default()
}

static JSON_NULL: Value = Value::Null;

fn tree_aria(node: &Value) -> &Value {
    node.get("aria").unwrap_or(&JSON_NULL)
}

fn read_tree(handle: WindowHandle<Root>, cx: &mut AsyncApp) -> Result<Value, String> {
    let raw = handle
        .update(cx, |_, window, _| {
            window
                .debug_a11y_tree_json()
                .ok_or("owned window has no rendered accessibility tree")
        })
        .map_err(error)??;
    serde_json::from_str(&raw).map_err(error)
}

fn frame_number(tree: &Value) -> Result<u64, String> {
    tree.get("frame")
        .and_then(|frame| frame.get("frame_number"))
        .and_then(Value::as_u64)
        .ok_or_else(|| "rendered accessibility tree lacks frame number".into())
}

fn validate_tabs(tree: &Value, expected: &[TabExpected]) -> Result<(usize, usize), String> {
    let nodes = tree_nodes_with_role(tree, "Tab");
    ensure(
        nodes.len() == expected.len(),
        "rendered tree did not export both fixture tabs",
    )?;
    for tab in expected {
        let found = nodes.iter().any(|node| {
            let aria = tree_aria(node);
            aria.get("label").and_then(Value::as_str) == Some(tab.label.as_str())
                && aria.get("description").and_then(Value::as_str) == Some(tab.description.as_str())
                && aria.get("selected").and_then(Value::as_bool) == Some(tab.selected)
        });
        ensure(
            found,
            "rendered tab label, description, or selection did not match production formatter",
        )?;
    }
    let selected = nodes
        .iter()
        .filter(|node| tree_aria(node).get("selected").and_then(Value::as_bool) == Some(true))
        .count();
    let unselected = nodes.len().saturating_sub(selected);
    ensure(
        selected == 1 && unselected == 1,
        "fixture must expose one selected and one unselected tab",
    )?;
    Ok((selected, unselected))
}

async fn wait_for_tab_selection_tree(
    window: WindowHandle<Root>,
    content_view: &NSView,
    cx: &mut AsyncApp,
    after_frame: u64,
    expected: &[TabExpected],
) -> Result<(Value, Vec<bool>), String> {
    const WAIT: Duration = Duration::from_secs(5);
    let deadline = Instant::now() + WAIT;
    let mut last_state = "no newer rendered tree was observed".to_owned();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!(
                "native tab press did not render the expected selection within five seconds: {last_state}"
            ));
        }
        crate::native_parity_fixture::next_frame_with_timeout(window.into(), cx, remaining).await?;
        let tree = read_tree(window, cx)?;
        if Instant::now() >= deadline {
            return Err(format!(
                "native tab press did not render the expected selection within five seconds: {last_state}"
            ));
        }
        let current_frame = frame_number(&tree)?;
        if current_frame <= after_frame {
            last_state =
                format!("rendered tree frame {current_frame} did not advance past {after_frame}");
            continue;
        }
        match validate_tabs(&tree, expected) {
            Ok(_) => {
                let native_states = native_accessibility_tree(content_view).and_then(|elements| {
                    expected
                        .iter()
                        .map(|tab| native_radio_selected(&elements, &tab.label))
                        .collect::<Result<Vec<_>, _>>()
                });
                match native_states {
                    Ok(states)
                        if states
                            .iter()
                            .zip(expected)
                            .all(|(selected, tab)| *selected == tab.selected) =>
                    {
                        if Instant::now() >= deadline {
                            return Err(format!(
                                "native tab press did not render the expected selection within five seconds: {last_state}"
                            ));
                        }
                        return Ok((tree, states));
                    }
                    Ok(_) => {
                        last_state =
                            "native AppKit radio-button values did not match rendered selection"
                                .to_owned();
                    }
                    Err(error) => last_state = error,
                }
            }
            Err(error) => last_state = error,
        }
    }
}

fn slider_value(tree: &Value) -> Result<f64, String> {
    let sliders = tree_nodes_with_role(tree, "Slider");
    ensure(
        sliders.len() == 1,
        "rendered tree did not export exactly one timeline slider",
    )?;
    tree_aria(sliders[0])
        .get("numeric_value")
        .and_then(Value::as_f64)
        .ok_or_else(|| "rendered timeline slider lacks a numeric value".into())
}

fn validate_slider(tree: &Value, expected_label: &str, expected_value: f64) -> Result<(), String> {
    let sliders = tree_nodes_with_role(tree, "Slider");
    ensure(
        sliders.len() == 1,
        "rendered tree did not export exactly one timeline slider",
    )?;
    let aria = tree_aria(sliders[0]);
    ensure(
        aria.get("label").and_then(Value::as_str) == Some(expected_label),
        "rendered timeline slider label did not match production formatter",
    )?;
    ensure(
        aria.get("numeric_value").and_then(Value::as_f64) == Some(expected_value),
        "timeline slider value did not change through its native action",
    )?;
    ensure(
        aria.get("min_numeric_value").and_then(Value::as_f64) == Some(0.0),
        "timeline slider minimum changed",
    )?;
    ensure(
        aria.get("max_numeric_value").and_then(Value::as_f64) == Some(100.0),
        "timeline slider maximum changed",
    )?;
    ensure(
        aria.get("numeric_value_step").and_then(Value::as_f64) == Some(5.0),
        "timeline slider step changed",
    )?;
    let actions = aria
        .get("on_action")
        .and_then(Value::as_array)
        .ok_or("rendered timeline slider lacks adjustable actions")?;
    ensure(
        actions
            .iter()
            .any(|action| action.as_str() == Some("Increment"))
            && actions
                .iter()
                .any(|action| action.as_str() == Some("Decrement")),
        "rendered timeline slider does not expose both adjustable actions",
    )
}

async fn wait_for_slider_tree(
    window: WindowHandle<Root>,
    cx: &mut AsyncApp,
    after_frame: u64,
    label: &str,
    expected_value: f64,
) -> Result<Value, String> {
    const WAIT: Duration = Duration::from_secs(5);
    let deadline = Instant::now() + WAIT;
    let mut last_state = "no newer rendered tree was observed".to_owned();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!(
                "native accessibility action did not render slider value {expected_value} within five seconds: {last_state}"
            ));
        }
        crate::native_parity_fixture::next_frame_with_timeout(window.into(), cx, remaining).await?;
        let tree = read_tree(window, cx)?;
        if Instant::now() >= deadline {
            return Err(format!(
                "native accessibility action did not render slider value {expected_value} within five seconds: {last_state}"
            ));
        }
        let current_frame = frame_number(&tree)?;
        if current_frame <= after_frame {
            last_state =
                format!("rendered tree frame {current_frame} did not advance past {after_frame}");
            continue;
        }
        match validate_slider(&tree, label, expected_value) {
            Ok(()) => return Ok(tree),
            Err(error) => last_state = error,
        }
    }
}

pub(crate) async fn verify(cx: &mut AsyncApp) -> Result<Value, String> {
    let (home, locale) = cx.update(|cx| {
        (
            cx.global::<AppData>().root.home().to_path_buf(),
            crate::settings::Settings::get(cx)
                .general
                .app_language
                .id()
                .to_string(),
        )
    });
    let shell = home.join("fixture-shell");
    std::fs::write(
        &shell,
        r#"#!/bin/sh
/bin/stty -echo -icanon min 1 time 0 2>/dev/null || true
printf 'AX_ACCESSIBILITY_FIXTURE$ '
exec /bin/cat >/dev/null
"#,
    )
    .map_err(error)?;
    std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).map_err(error)?;
    cx.update(|cx| {
        cx.global_mut::<crate::settings::Settings>().terminal.shell =
            Some(shell.to_string_lossy().into_owned());
        crate::history::recorder::init(cx);
    });

    let recording_session = uuid::Uuid::new_v4().as_u128() as u64;
    crate::history::recorder::start(
        recording_session.max(1),
        "AX accessibility fixture",
        Some(home.to_string_lossy().into_owned()),
    );
    crate::history::recorder::command_start(recording_session.max(1), "echo AX fixture");
    crate::history::recorder::output(recording_session.max(1), b"AX fixture output\n");
    crate::history::recorder::command_end(recording_session.max(1), Some(0));
    let recording =
        crate::history::recorder::stop().ok_or("owned timeline recording did not finish")?;

    let (window, workspace) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    show: true,
                    focus: false,
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(0.), px(0.)),
                        size(px(1120.), px(720.)),
                    ))),
                    ..Default::default()
                },
                cx,
                |window, cx| cx.new(|cx| Workspace::new(None, window, cx)),
            )
        })
        .map_err(error)?;
    let window = window
        .downcast::<Root>()
        .ok_or("owned accessibility window lacks Root")?;
    cx.update(|cx| {
        workspace.update(cx, |workspace, _| {
            workspace.window_handle = Some(window.into())
        });
        cx.global_mut::<AppData>()
            .workspaces
            .push((window.into(), workspace.downgrade()));
    });
    window
        .update(cx, |_, native, cx| {
            workspace.update(cx, |workspace, cx| {
                workspace.new_tab_at(None, false, native, cx);
            });
        })
        .map_err(error)?;
    workspace
        .update(cx, |workspace, cx| -> Result<(), String> {
            let tab_ids = workspace
                .state
                .tabs()
                .iter()
                .map(|tab| tab.id)
                .collect::<Vec<_>>();
            ensure(
                tab_ids.len() == 2,
                "fixture did not create exactly two tabs before assigning test titles",
            )?;
            ensure(
                workspace.mcp_rename(tab_ids[0], "AX Fixture A", cx) == "AX Fixture A",
                "fixture could not assign its first unique tab title",
            )?;
            ensure(
                workspace.mcp_rename(tab_ids[1], "AX Fixture B", cx) == "AX Fixture B",
                "fixture could not assign its second unique tab title",
            )?;
            Ok(())
        })
        .map_err(error)??;

    crate::native_parity_fixture::next_frame(window.into(), cx).await?;
    let lang = chau7_next_core::l10n::current();
    let effective_locale = lang.code();
    let expected_tabs = cx.update(|cx| {
        let workspace = workspace.read(cx);
        workspace
            .state
            .tabs()
            .iter()
            .map(|tab| {
                let title = workspace.tab_title(tab.id, cx);
                let path = workspace.tab_path(tab.id, cx);
                TabExpected {
                    label: super::tab_bar_view::tab_accessibility_label(
                        lang,
                        &title,
                        path.as_deref(),
                    ),
                    description: super::tab_bar_view::tab_accessibility_description(
                        lang,
                        workspace.state.selected() == Some(tab.id),
                    ),
                    selected: workspace.state.selected() == Some(tab.id),
                }
            })
            .collect::<Vec<_>>()
    });
    ensure(
        expected_tabs.len() == 2,
        "fixture did not create exactly two tabs",
    )?;

    let content_view = native_content_view(window, cx)?;
    let _ = native_accessibility_tree(&content_view)?;
    crate::native_parity_fixture::next_frame(window.into(), cx).await?;
    let first_tree = read_tree(window, cx)?;
    let initial_frame = frame_number(&first_tree)?;
    let (selected_tab_count, unselected_tab_count) = validate_tabs(&first_tree, &expected_tabs)?;
    let native_tabs = native_accessibility_tree(&content_view)?;
    let expected_labels: Vec<_> = expected_tabs.iter().map(|tab| tab.label.as_str()).collect();
    let native_tab_labels_match = expected_labels
        .iter()
        .all(|label| native_find(&native_tabs, "AXRadioButton", label).is_some());
    ensure(
        native_tab_labels_match,
        "native AppKit accessibility export did not contain the rendered tab labels",
    )?;
    let native_tab_count = native_tabs
        .iter()
        .filter(|element| element.role == "AXRadioButton")
        .count();
    ensure(
        native_tab_count >= expected_tabs.len(),
        "native AppKit tree did not export both tabs",
    )?;

    let pressed_tab_label = expected_tabs
        .iter()
        .find(|tab| !tab.selected)
        .map(|tab| tab.label.clone())
        .ok_or("fixture did not identify one initially unselected tab")?;
    let previously_selected_tab_label = expected_tabs
        .iter()
        .find(|tab| tab.selected)
        .map(|tab| tab.label.clone())
        .ok_or("fixture did not identify one initially selected tab")?;
    let pressed_tab_index = expected_tabs
        .iter()
        .position(|tab| tab.label == pressed_tab_label)
        .ok_or("fixture lost the initially unselected tab identity")?;
    let previously_selected_tab_index = expected_tabs
        .iter()
        .position(|tab| tab.label == previously_selected_tab_label)
        .ok_or("fixture lost the initially selected tab identity")?;
    let native_pressed_tab_selected_before_press =
        native_radio_selected(&native_tabs, &pressed_tab_label)?;
    let native_previous_tab_selected_before_press =
        native_radio_selected(&native_tabs, &previously_selected_tab_label)?;
    ensure(
        !native_pressed_tab_selected_before_press && native_previous_tab_selected_before_press,
        "native AppKit tab values did not match the initial selected and unselected tabs",
    )?;
    let press_targets: Vec<_> = tree_nodes_with_role(&first_tree, "Tab")
        .into_iter()
        .filter(|node| {
            let aria = tree_aria(node);
            aria.get("label").and_then(Value::as_str) == Some(pressed_tab_label.as_str())
                && aria.get("selected").and_then(Value::as_bool) == Some(false)
        })
        .collect();
    ensure(
        press_targets.len() == 1,
        "rendered tree did not identify exactly one unselected localized target tab",
    )?;
    let click_actions = tree_aria(press_targets[0])
        .get("on_action")
        .and_then(Value::as_array);
    ensure(
        click_actions.is_some_and(|actions| {
            actions
                .iter()
                .any(|action| action.as_str() == Some("Click"))
        }),
        "rendered unselected tab did not advertise its AccessKit Click action",
    )?;

    let native_press_targets: Vec<_> = native_tabs
        .iter()
        .filter(|element| {
            element.role == "AXRadioButton"
                && element.label.as_deref() == Some(pressed_tab_label.as_str())
        })
        .collect();
    ensure(
        native_press_targets.len() == 1,
        "native AppKit tree did not identify exactly one matching AXRadioButton",
    )?;
    let native_press_target = native_press_targets[0];
    let native_ax_press_advertised: bool = unsafe {
        objc2::msg_send![
            &*native_press_target.object,
            isAccessibilitySelectorAllowed: sel!(accessibilityPerformPress)
        ]
    };
    ensure(
        native_ax_press_advertised,
        "native AppKit AXRadioButton did not advertise AXPress",
    )?;
    let native_ax_press_accepted: bool =
        unsafe { objc2::msg_send![&*native_press_target.object, accessibilityPerformPress] };
    ensure(
        native_ax_press_accepted,
        "native AppKit unselected AXRadioButton did not accept AXPress",
    )?;

    let expected_tabs_after_press = expected_tabs
        .iter()
        .map(|tab| {
            let selected = tab.label == pressed_tab_label;
            TabExpected {
                label: tab.label.clone(),
                description: super::tab_bar_view::tab_accessibility_description(lang, selected),
                selected,
            }
        })
        .collect::<Vec<_>>();
    let (selection_tree, native_tab_selected_values_after_press) = wait_for_tab_selection_tree(
        window,
        &content_view,
        cx,
        initial_frame,
        &expected_tabs_after_press,
    )
    .await?;
    let selection_frame = frame_number(&selection_tree)?;
    let (selected_tabs_after_press, unselected_tabs_after_press) =
        validate_tabs(&selection_tree, &expected_tabs_after_press)?;
    let selected_nodes_after_press = tree_nodes_with_role(&selection_tree, "Tab");
    let pressed_tab_selected_after_press = selected_nodes_after_press.iter().any(|node| {
        tree_aria(node).get("label").and_then(Value::as_str) == Some(pressed_tab_label.as_str())
            && tree_aria(node).get("selected").and_then(Value::as_bool) == Some(true)
    });
    let previously_selected_tab_deselected_after_press =
        selected_nodes_after_press.iter().any(|node| {
            tree_aria(node).get("label").and_then(Value::as_str)
                == Some(previously_selected_tab_label.as_str())
                && tree_aria(node).get("selected").and_then(Value::as_bool) == Some(false)
        });
    ensure(
        pressed_tab_selected_after_press
            && previously_selected_tab_deselected_after_press
            && selected_tabs_after_press == 1
            && unselected_tabs_after_press == 1,
        "native AXPress did not select the exact target tab and deselect the previous tab",
    )?;
    let native_pressed_tab_selected_after_press = native_tab_selected_values_after_press
        .get(pressed_tab_index)
        .copied()
        .ok_or("native accessibility result omitted the pressed tab selected value")?;
    let native_previous_tab_deselected_after_press = native_tab_selected_values_after_press
        .get(previously_selected_tab_index)
        .is_some_and(|selected| !selected);
    ensure(
        native_pressed_tab_selected_after_press && native_previous_tab_deselected_after_press,
        "native NSAccessibility values did not reflect the AXPress tab selection",
    )?;

    window
        .update(cx, |_, native, cx| {
            native.dispatch_action(Box::new(crate::actions::ShowSessionTimeline), cx);
        })
        .map_err(error)?;
    crate::native_parity_fixture::next_frame(window.into(), cx).await?;
    let open_tree = read_tree(window, cx)?;
    let open_label = super::timeline::timeline_open_label(lang);
    let open_nodes = tree_nodes_with_role(&open_tree, "Button");
    let open_count = open_nodes
        .iter()
        .filter(|node| {
            tree_aria(node).get("label").and_then(Value::as_str) == Some(open_label.as_str())
        })
        .count();
    let open_frame = frame_number(&open_tree)?;
    ensure(
        open_count == 1,
        "timeline fixture recording did not render one localized Open action",
    )?;
    let open_elements = native_accessibility_tree(&content_view)?;
    let open_button = native_find(&open_elements, "AXButton", &open_label)
        .ok_or("native AppKit export omitted the localized timeline Open button")?;
    let open_accepted: bool =
        unsafe { objc2::msg_send![&*open_button.object, accessibilityPerformPress] };
    ensure(
        open_accepted,
        "native AppKit timeline Open action was not accepted",
    )?;

    let scrubber_label = super::timeline::scrubber_accessibility_label(lang);
    let slider_tree = wait_for_slider_tree(window, cx, open_frame, &scrubber_label, 0.0).await?;
    let slider_initial_frame = frame_number(&slider_tree)?;
    let slider_initial_value = slider_value(&slider_tree)?;
    let slider_elements = native_accessibility_tree(&content_view)?;
    let slider = native_find(&slider_elements, "AXSlider", &scrubber_label)
        .ok_or("native AppKit export omitted the localized timeline slider")?;
    let increment_accepted: bool =
        unsafe { objc2::msg_send![&*slider.object, accessibilityPerformIncrement] };
    ensure(
        increment_accepted,
        "native AppKit timeline increment action was not accepted",
    )?;

    let increment_tree =
        wait_for_slider_tree(window, cx, slider_initial_frame, &scrubber_label, 5.0).await?;
    let increment_frame = frame_number(&increment_tree)?;
    let increment_value = slider_value(&increment_tree)?;
    let incremented_elements = native_accessibility_tree(&content_view)?;
    let incremented_slider = native_find(&incremented_elements, "AXSlider", &scrubber_label)
        .ok_or("native AppKit slider disappeared after increment")?;
    let decrement_accepted: bool =
        unsafe { objc2::msg_send![&*incremented_slider.object, accessibilityPerformDecrement] };
    ensure(
        decrement_accepted,
        "native AppKit timeline decrement action was not accepted",
    )?;

    let decrement_tree =
        wait_for_slider_tree(window, cx, increment_frame, &scrubber_label, 0.0).await?;
    let decrement_frame = frame_number(&decrement_tree)?;
    let decrement_value = slider_value(&decrement_tree)?;

    ensure(
        recording.frame_count >= 2,
        "fixture recording did not preserve enough timeline frames",
    )?;
    ensure(
        initial_frame < slider_initial_frame
            && slider_initial_frame < increment_frame
            && increment_frame < decrement_frame,
        "native accessibility actions did not produce successive rendered frames",
    )?;
    ensure(
        slider_initial_value == 0.0 && increment_value == 5.0 && decrement_value == 0.0,
        "timeline slider did not return to its baseline after native actions",
    )?;

    Ok(json!({
        "fixture_locale": locale,
        "effective_locale": effective_locale,
        "accessibility_active": native_tab_count >= 2,
        "rendered_tree_frame_number": initial_frame,
        "tab_count": expected_tabs.len(),
        "selected_tab_count": selected_tab_count,
        "unselected_tab_count": unselected_tab_count,
        "native_ax_tab_count": native_tab_count,
        "tab_labels_match_production_formatters": native_tab_labels_match,
        "native_ax_unselected_tab_press_advertised": native_ax_press_advertised,
        "native_ax_unselected_tab_press_accepted": native_ax_press_accepted,
        "native_ax_pressed_tab_selected_before_press": native_pressed_tab_selected_before_press,
        "native_ax_previous_tab_selected_before_press": native_previous_tab_selected_before_press,
        "native_ax_pressed_tab_selected_after_press": native_pressed_tab_selected_after_press,
        "native_ax_previous_tab_deselected_after_press": native_previous_tab_deselected_after_press,
        "pressed_tab_selected_after_press": pressed_tab_selected_after_press,
        "previously_selected_tab_deselected_after_press": previously_selected_tab_deselected_after_press,
        "selected_tab_count_after_press": selected_tabs_after_press,
        "unselected_tab_count_after_press": unselected_tabs_after_press,
        "tab_selection_frame_numbers": [initial_frame, selection_frame],
        "timeline_open_button_count": open_count,
        "native_ax_timeline_open_press_accepted": open_accepted,
        "timeline_slider_role": "Slider",
        "timeline_slider_label_matches_production_formatter": true,
        "timeline_slider_min": 0.0,
        "timeline_slider_max": 100.0,
        "timeline_slider_step": 5.0,
        "native_ax_slider_increment_accepted": increment_accepted,
        "native_ax_slider_decrement_accepted": decrement_accepted,
        "slider_values": [slider_initial_value, increment_value, decrement_value],
        "rendered_frame_numbers": [initial_frame, slider_initial_frame, increment_frame, decrement_frame],
        "recording_frame_count": recording.frame_count,
    }))
}
