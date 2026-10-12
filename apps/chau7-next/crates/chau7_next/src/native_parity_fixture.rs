//! Opt-in native acceptance; dispatched before every ordinary integration.
use chau7_next_core::data_root::DataRoot;
use futures::{FutureExt, channel::oneshot, future::Either};
use gpui::{AnyWindowHandle, App, AppContext, AsyncApp};
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicI32, Ordering},
};
use std::time::Duration;

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
        "restore" | "settings" | "editor" | "cache" | "accessibility" | "keyboard"
    )
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
        cx.set_app_identity(
            "com.chau7.next.native-parity-fixture",
            "Chau7 Next Native Fixture",
        );
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
            let deadline_secs = if matches!(case.as_str(), "settings" | "accessibility") {
                70
            } else {
                35
            };
            let deadline = cx
                .background_executor()
                .timer(Duration::from_secs(deadline_secs));
            let verification = async {
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
        assert!(supported_native_case("restore"));
        assert!(!supported_native_case("all"));
        assert!(!supported_native_case("unknown"));
    }
}
