//! Opt-in native acceptance; dispatched before every ordinary integration.
use chau7_next_core::data_root::DataRoot;
use futures::{FutureExt, channel::oneshot, future::Either};
use gpui::{AnyWindowHandle, App, AppContext, AsyncApp, ParentElement, Styled};
use objc2::{MainThreadMarker, rc::Retained};
use objc2_app_kit::{NSApplication, NSView, NSWindow};
use objc2_foundation::NSBundle;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicI32, Ordering},
};
use std::time::{Duration, Instant};

/// A real platform frame, never GPUI's deterministic test-frame helpers.
pub(crate) async fn next_frame(window: AnyWindowHandle, cx: &mut AsyncApp) -> Result<(), String> {
    next_frame_with_timeout(window, cx, Duration::from_secs(5)).await
}

/// Wait for one real platform frame within a caller's remaining bounded budget.
pub(crate) async fn next_frame_with_timeout(
    window: AnyWindowHandle,
    cx: &mut AsyncApp,
    timeout: Duration,
) -> Result<(), String> {
    let timeout = timeout.min(Duration::from_secs(5));
    if timeout.is_zero() {
        return Err("owned native platform frame deadline exceeded".into());
    }
    let (send, receive) = oneshot::channel();
    cx.update_window(window, |_, window, _| {
        window.on_next_frame(move |_, _| {
            let _ = send.send(());
        });
        window.refresh();
    })
    .map_err(|error| error.to_string())?;
    let timer = cx.background_executor().timer(timeout);
    match futures::future::select(receive, timer).await {
        Either::Left((Ok(()), _)) => Ok(()),
        Either::Left((Err(_), _)) => Err("owned native window closed before its frame".into()),
        Either::Right(_) => Err("owned native platform frame deadline exceeded".into()),
    }
}

fn fresh_home(path: &Path) -> Result<PathBuf, String> {
    let parent = path
        .parent()
        .ok_or("fixture home lacks parent")?
        .canonicalize()
        .map_err(|e| e.to_string())?;
    let temporary = std::env::temp_dir()
        .canonicalize()
        .map_err(|e| e.to_string())?;
    if parent != temporary
        || !path
            .file_name()
            .and_then(|s| s.to_str())
            .is_some_and(|s| s.starts_with("chau7-native-fixture-"))
    {
        return Err("fixture home must be a new chau7-native-fixture-* directory immediately under this process's temporary directory".into());
    }
    std::fs::create_dir(path).map_err(|e| format!("fixture home must not already exist: {e}"))?;
    path.canonicalize().map_err(|e| e.to_string())
}

fn supported_native_case(requested: &str) -> bool {
    matches!(
        requested,
        "restore"
            | "settings"
            | "editor"
            | "cache"
            | "accessibility"
            | "keyboard"
            | "focus-companion"
            | "multiwindow-restore"
    )
}

struct FocusCompanionView;

impl gpui::Render for FocusCompanionView {
    fn render(
        &mut self,
        _window: &mut gpui::Window,
        _cx: &mut gpui::Context<Self>,
    ) -> impl gpui::IntoElement {
        gpui::div()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .child("Owned fullscreen focus companion")
    }
}

fn focus_companion_native_window(
    handle: AnyWindowHandle,
    cx: &mut AsyncApp,
) -> Result<Retained<NSWindow>, String> {
    cx.update_window(handle, |_, window, _| {
        let raw = HasWindowHandle::window_handle(window).map_err(|error| error.to_string())?;
        let RawWindowHandle::AppKit(raw) = raw.as_raw() else {
            return Err("owned focus companion does not use AppKit".to_owned());
        };
        // SAFETY: GPUI owns the window view for the lifetime of this fixture.
        let view = unsafe { Retained::retain(raw.ns_view.cast::<NSView>().as_ptr()) }
            .ok_or_else(|| "owned focus companion view disappeared".to_owned())?;
        view.window()
            .ok_or_else(|| "owned focus companion view has no NSWindow".to_owned())
    })
    .map_err(|error| error.to_string())?
}

async fn run_focus_companion(
    handle: AnyWindowHandle,
    home: &Path,
    renderer: &str,
    cx: &mut AsyncApp,
) -> Result<Value, String> {
    let native = focus_companion_native_window(handle, cx)?;
    let application = NSApplication::sharedApplication(
        MainThreadMarker::new().ok_or("focus companion is not on the main thread")?,
    );
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    let bundle_path = executable
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .ok_or("focus companion executable is outside an app bundle")?
        .to_string_lossy()
        .into_owned();
    let bundle_identifier = NSBundle::mainBundle()
        .bundleIdentifier()
        .map(|value| value.to_string())
        .ok_or("focus companion has no bundle identifier")?;
    let executable_path = executable.to_string_lossy().into_owned();
    let ready_path = home.join("native-parity-focus-companion.ready");
    let stop_path = home.join("native-parity-focus-companion.stop");
    let ready_temporary_path = home.join("native-parity-focus-companion.ready.tmp");
    let deadline = Instant::now() + Duration::from_secs(40);
    let mut ready = false;

    loop {
        let app_active = application.isActive();
        let window_visible = native.isVisible();
        let window_key = native.isKeyWindow();
        if !ready && app_active && window_visible && window_key {
            let receipt = serde_json::json!({
                "pid": std::process::id(),
                "bundle_identifier": bundle_identifier,
                "bundle_path": bundle_path,
                "executable_path": executable_path,
                "app_active": app_active,
                "window_visible": window_visible,
                "window_key": window_key,
                "renderer": renderer,
            });
            let bytes = serde_json::to_vec(&receipt).map_err(|error| error.to_string())?;
            std::fs::write(&ready_temporary_path, bytes).map_err(|error| error.to_string())?;
            std::fs::rename(&ready_temporary_path, &ready_path)
                .map_err(|error| error.to_string())?;
            println!("native_focus_companion_ready={receipt}");
            std::io::stdout()
                .flush()
                .map_err(|error| error.to_string())?;
            ready = true;
        }

        if stop_path.exists() {
            if !ready {
                return Err(
                    "focus companion was stopped before it became foreground and key".into(),
                );
            }
            return Ok(serde_json::json!({
                "ready": true,
                "stopped_by": "owned_stop_file",
                "app_active_at_stop": application.isActive(),
                "window_visible_at_stop": native.isVisible(),
                "window_key_at_stop": native.isKeyWindow(),
            }));
        }
        if Instant::now() >= deadline {
            if !ready {
                return Err("focus companion did not become foreground and key before its 40 second deadline".into());
            }
            return Ok(serde_json::json!({
                "ready": true,
                "stopped_by": "40_second_deadline",
                "app_active_at_stop": application.isActive(),
                "window_visible_at_stop": native.isVisible(),
                "window_key_at_stop": native.isKeyWindow(),
            }));
        }
        cx.background_executor()
            .timer(Duration::from_millis(100))
            .await;
    }
}

pub(crate) fn run_if_requested() -> Option<i32> {
    let args: Vec<_> = std::env::args().collect();
    let Some(index) = args.iter().position(|arg| arg == "--native-parity-fixture") else {
        eprintln!("This optional acceptance binary requires --native-parity-fixture <case>");
        return Some(2);
    };
    let requested = args.get(index + 1).cloned().unwrap_or_default();
    if std::env::var("CHAU7_NEXT_NATIVE_PARITY_FIXTURE").as_deref() != Ok("1") {
        eprintln!("native parity fixture requires explicit process-local opt-in");
        return Some(2);
    }
    if !supported_native_case(&requested) {
        eprintln!("unknown native parity fixture: {requested}");
        return Some(2);
    }
    let locale_positions: Vec<_> = args
        .iter()
        .enumerate()
        .filter_map(|(index, arg)| (arg == "--fixture-locale").then_some(index))
        .collect();
    if locale_positions.len() > 1 {
        eprintln!("--fixture-locale may be supplied only once");
        return Some(2);
    }
    let fixture_locale = match locale_positions.first().copied() {
        Some(index) => match args.get(index + 1) {
            Some(value)
                if matches!(value.as_str(), "system" | "en" | "fr" | "es" | "ar" | "he") =>
            {
                value.clone()
            }
            _ => {
                eprintln!("--fixture-locale requires system/en/fr/es/ar/he");
                return Some(2);
            }
        },
        None => "system".to_owned(),
    };
    if !locale_positions.is_empty() && requested != "accessibility" {
        eprintln!("--fixture-locale is limited to --native-parity-fixture accessibility");
        return Some(2);
    }
    let home = match std::env::var_os(chau7_next_core::data_root::HOME_ROOT_ENV)
        .map(PathBuf::from)
        .ok_or_else(|| "fixture home missing".to_string())
        .and_then(|p| fresh_home(&p))
    {
        Ok(home) => home,
        Err(error) => {
            eprintln!("{error}");
            return Some(2);
        }
    };
    // SAFETY: dispatched at the first line of main, before application threads.
    unsafe {
        std::env::set_var(chau7_next_core::data_root::HOME_ROOT_ENV, &home);
        std::env::set_var(chau7_next_core::data_root::ISOLATED_TEST_MODE_ENV, "1");
    }
    let result = Arc::new(AtomicI32::new(1));
    let completion = result.clone();
    let root = DataRoot::with_home(home.clone(), true);
    if let Err(error) = root.ensure_dirs() {
        eprintln!("{error}");
        let _ = std::fs::remove_dir_all(&home);
        return Some(2);
    }
    if let Err(error) = std::env::set_current_dir(&home) {
        let code = report(
            &requested,
            &home,
            Err(format!("owned fixture cwd: {error}")),
        );
        return Some(code);
    }
    let owned_home = home.clone();
    let case = requested.clone();
    let selector = args
        .iter()
        .position(|arg| arg == "--window-renderer")
        .and_then(|index| args.get(index + 1))
        .map(String::as_str)
        .unwrap_or("auto");
    let requested_renderer = selector.to_owned();
    let (platform, backend) = match crate::window_backend::create_fixture(selector) {
        Ok(value) => value,
        Err(error) => return Some(report(&requested, &owned_home, Err(error))),
    };
    let terminal_text_system = platform.text_system();
    let app = gpui::Application::with_platform(platform).with_assets(crate::assets::AppAssets);
    app.run(move |cx: &mut App| {
        crate::window_backend::init(backend, cx);
        crate::terminal::paint::init_cpu_text_system(terminal_text_system, cx);
        gpui_kit::init(cx);
        if case == "focus-companion" {
            cx.set_app_identity(
                "com.chau7.next.native-parity-focus-companion",
                "Chau7 Next Native Focus Companion",
            );
        } else {
            cx.set_app_identity(
                "com.chau7.next.native-parity-fixture",
                "Chau7 Next Native Fixture",
            );
        }
        let mut settings = crate::settings::Settings::default();
        settings.proxy.enabled = false;
        // Workspace activation otherwise lazily creates this service and its
        // child probe, even when ordinary permission startup is skipped.
        settings.general.full_disk_access_guard_enabled = false;
        settings.cto.mode = chau7_next_core::token_optimization::TokenOptimizationMode::Off;
        if case == "accessibility" {
            settings.general.app_language =
                crate::settings::AppLanguage::from_id(&fixture_locale).unwrap_or_default();
        }
        crate::settings::config_files::init(cx, root.config_file(), settings.clone());
        cx.set_global(settings);
        cx.set_global(crate::workspace::AppData::new(root));
        if case == "accessibility" {
            crate::l10n::settings_applied(cx);
        }
        crate::observability::init(cx);
        if case == "multiwindow-restore" {
            crate::restore::writer::init(cx);
            cx.set_shutdown_timeout(None);
            cx.on_app_quit(move |cx| {
                // Production request_quit submits the final snapshot before
                // calling cx.quit. This fixture owns the normal writer drain.
                let restore_worker = crate::restore::writer::shutdown(cx);
                crate::terminal::session::terminate_all_for_quit();
                cx.background_spawn(async move {
                    if let Some(worker) = restore_worker
                        && let Err(error) = worker.join()
                    {
                        log::error!("native multiwindow fixture restore writer join: {error:?}");
                    }
                })
            })
            .detach();

            if let Err(error) =
                crate::workspace::prepare_native_multiwindow_restore_fixture(&owned_home, cx)
            {
                let evidence = json!({
                    "case": "multiwindow-restore",
                    "pid": std::process::id(),
                    "passed": false,
                    "error": error,
                    "phase": "prepare",
                });
                println!("{evidence}");
                let _ = std::io::stdout().flush();
                completion.store(1, Ordering::Release);
                cx.quit();
                return;
            }

            let case = case.clone();
            let completion = completion.clone();
            cx.spawn(async move |cx| {
                if let Err(error) =
                    crate::workspace::add_latest_native_restore_tab_and_request_quit(
                        cx,
                        completion.clone(),
                    )
                    .await
                {
                    let evidence = json!({
                        "case": case,
                        "pid": std::process::id(),
                        "passed": false,
                        "error": error,
                        "phase": "dispatch",
                    });
                    println!("{evidence}");
                    let _ = std::io::stdout().flush();
                    completion.store(1, Ordering::Release);
                    cx.update(|cx| cx.quit());
                }
                // On success the production quit path exits this app after the
                // registered writer drain. Python reads the profile afterward.
            })
            .detach();
            return;
        }
        if case == "restore" {
            // Restore acceptance exercises the same repository cache/probe
            // service that normal app startup installs before any workspace.
            // Its DataRoot is the fixture's private temporary profile.
            crate::repository::init(cx);
        }
        let focus_companion_window = if case == "focus-companion" {
            let bounds =
                gpui::Bounds::centered(None, gpui::size(gpui::px(360.0), gpui::px(220.0)), cx);
            let options = gpui::WindowOptions {
                window_bounds: Some(gpui::WindowBounds::Windowed(bounds)),
                show: true,
                focus: true,
                is_resizable: false,
                ..Default::default()
            };
            match cx.open_window(options, |window, cx| {
                window.set_window_title("Chau7 Native Fullscreen Focus Companion");
                cx.new(|_| FocusCompanionView)
            }) {
                Ok(handle) => {
                    cx.activate(true);
                    Some(Ok(handle))
                }
                Err(error) => Some(Err(error.to_string())),
            }
        } else {
            None
        };
        if case == "keyboard" {
            // Install the production keymap and native menu route only in this
            // focused case; the original fixture cases keep their old setup.
            crate::actions::bind_keys(cx);
            let input = crate::settings::Settings::get(cx).input.clone();
            crate::actions::bind_shortcut_settings(&input, cx);
            cx.on_keyboard_layout_change(|cx| {
                let input = crate::settings::Settings::get(cx).input.clone();
                crate::actions::bind_shortcut_settings(&input, cx);
            })
            .detach();
            crate::commands::bind_keys(cx);
            crate::panes::bind_keys(cx);
            crate::commands::register(cx);
            cx.set_menus(crate::actions::app_menus(&[]));
            crate::register_app_actions(cx);
        }
        cx.spawn(async move |cx| {
            let deadline_secs = if matches!(case.as_str(), "settings" | "accessibility" | "restore")
            {
                70
            } else if case == "focus-companion" {
                45
            } else {
                35
            };
            let deadline = cx
                .background_executor()
                .timer(Duration::from_secs(deadline_secs));
            let verification = async {
                if case == "focus-companion" {
                    let handle = focus_companion_window
                        .ok_or_else(|| "focus companion window was not created".to_owned())??;
                    cx.update(|cx| {
                        crate::window_backend::verify_fixture_selection(&requested_renderer, cx)
                    })?;
                    return run_focus_companion(
                        handle.into(),
                        &owned_home,
                        &requested_renderer,
                        cx,
                    )
                    .await;
                }
                let surface = if requested_renderer != "auto" {
                    Some(crate::window_backend::verify_native_surface(cx).await?)
                } else {
                    None
                };
                cx.update(|cx| {
                    crate::window_backend::verify_fixture_selection(&requested_renderer, cx)
                })?;
                let details = match case.as_str() {
                    "restore" => crate::workspace::verify_native_restore_fixture(cx).await,
                    "settings" => crate::settings_window::verify_native_fixture(cx).await,
                    "editor" => crate::panes::editor::verify_native_fixture(cx).await,
                    "cache" => crate::settings_window::verify_native_cache_fixture(cx).await,
                    "accessibility" => {
                        crate::workspace::verify_native_accessibility_fixture(cx).await
                    }
                    "keyboard" => crate::workspace::verify_native_keyboard_fixture(cx).await,
                    _ => Err("unknown native case".into()),
                }
                .map_err(|error| format!("existing {case} case: {error}"))?;
                let mut details = details;
                if let Some(object) = details.as_object_mut() {
                    object.insert(
                        "backend_native_surface".into(),
                        serde_json::to_value(surface).map_err(|error| error.to_string())?,
                    );
                }
                Ok(details)
            }
            .boxed_local();
            let outcome = match futures::future::select(verification, deadline).await {
                Either::Left((result, _)) => result,
                Either::Right(_) => Err("native acceptance deadline exceeded".into()),
            };
            let rendering = cx.update(|cx| crate::window_backend::diagnostics(cx));
            let outcome = outcome.map(|mut details| {
                if let Some(object) = details.as_object_mut() {
                    object.insert("window_renderer".into(), rendering);
                }
                details
            });
            let cleanup = crate::workspace::dispose_native_fixture(cx).await;
            let outcome = match (outcome, cleanup) {
                (Ok(details), Ok(_)) => Ok(details),
                (Err(error), Ok(_)) => Err(error),
                (_, Err(error)) => Err(format!("owned native cleanup failed: {error}")),
            };
            // This separate process contains only our owned fixture sessions.
            cx.update(|cx| {
                crate::terminal::session::terminate_all_for_quit();
                for window in cx.windows() {
                    let _ = cx.update_window(window, |_, window, _| window.remove_window());
                }
            });
            // `flush` is a no-op in cases that did not start the repository
            // service; Restore drains probes and identity writes before the
            // owned temporary profile is removed by report().
            cx.update(|cx| crate::repository::flush(cx));
            // All cases use this unconditional fixture-only teardown, including
            // timeout/early-error paths. No profile removal precedes guards,
            // background readers, queued writes and the final SQLite close.
            let snapshot_cleanup = crate::settings_window::shutdown_native_snapshots(cx).await;
            let history_cleanup = crate::history::shutdown_native_cache_fixture(cx).await;
            let owned_cache_closed = snapshot_cleanup.is_ok() && history_cleanup.is_ok();
            let outcome = match (outcome, snapshot_cleanup, history_cleanup) {
                (result, Ok(()), Ok(())) => result,
                (_, Err(error), _) | (_, _, Err(error)) => Err(error),
            };
            let memory_worker = cx.update(crate::memory_pressure::stop_native_fixture);
            let worker = cx.update(crate::observability::shutdown);
            cx.background_spawn(async move {
                if let Some(worker) = memory_worker {
                    let _ = worker.join();
                }
                if let Some(worker) = worker {
                    let _ = worker.join();
                }
            })
            .await;
            // NSApplication::terminate exits the process; it does not return
            // from Application::run. Evidence and cleanup must precede quit.
            let code = if owned_cache_closed {
                report(&case, &owned_home, outcome)
            } else {
                // Preserve the owned profile if resource closure was not
                // confirmed; a failed run must not delete a live database.
                let evidence = json!({"case":case,"pid":std::process::id(),"passed":false,
                    "error":outcome.err(),"profile_isolated":true,
                    "owned_profile_removed":false,"owned_resources_closed":false});
                println!("{evidence}");
                let _ = std::io::stdout().flush();
                1
            };
            completion.store(code, Ordering::Release);
            if code != 0 {
                // Every owned window/session and the journal are closed above.
                std::process::exit(code);
            }
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
    Some(result.load(Ordering::Acquire))
}

fn report(case: &str, home: &Path, outcome: Result<Value, String>) -> i32 {
    let cleanup = std::fs::remove_dir_all(home).map_err(|error| error.to_string());
    let cleaned = cleanup.is_ok() && !home.exists();
    let outcome = match (outcome, cleanup) {
        (result, Ok(())) => result,
        (_, Err(error)) => Err(format!("owned fixture profile cleanup failed: {error}")),
    };
    let code = i32::from(outcome.is_err() || !cleaned);
    let evidence = match outcome {
        Ok(details) => {
            json!({"case":case,"pid":std::process::id(),"passed":code==0,"details":details,"frames":"native on_next_frame","profile_isolated":true,"owned_profile_removed":cleaned,"owned_resources_closed":true})
        }
        Err(error) => {
            json!({"case":case,"pid":std::process::id(),"passed":false,"error":error,"profile_isolated":true,"owned_profile_removed":cleaned})
        }
    };
    println!("{evidence}");
    if std::io::stdout().flush().is_err() {
        return 1;
    }
    code
}

#[cfg(test)]
mod native_case_tests {
    use super::supported_native_case;

    #[test]
    fn keyboard_is_explicit_and_unknown_cases_are_rejected() {
        assert!(supported_native_case("keyboard"));
        assert!(supported_native_case("focus-companion"));
        assert!(supported_native_case("multiwindow-restore"));
        assert!(supported_native_case("restore"));
        assert!(!supported_native_case("all"));
        assert!(!supported_native_case("unknown"));
    }
}
