//! Opt-in native acceptance; dispatched before every ordinary integration.
use chau7_next_core::data_root::DataRoot;
use futures::{FutureExt, channel::oneshot, future::Either};
use gpui::{AnyWindowHandle, App, AppContext, AsyncApp};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// A real platform frame, never GPUI's deterministic test-frame helpers.
pub(crate) async fn next_frame(window: AnyWindowHandle, cx: &mut AsyncApp) -> Result<(), String> {
    let (send, receive) = oneshot::channel();
    cx.update_window(window, |_, window, _| {
        window.on_next_frame(move |_, _| {
            let _ = send.send(());
        });
        window.refresh();
    })
    .map_err(|error| error.to_string())?;
    let timer = cx.background_executor().timer(Duration::from_secs(5));
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

pub(crate) fn run_if_requested() -> Option<i32> {
    let args: Vec<_> = std::env::args().collect();
    let index = args
        .iter()
        .position(|arg| arg == "--native-parity-fixture")?;
    let requested = args.get(index + 1).cloned().unwrap_or_default();
    if std::env::var("CHAU7_NEXT_NATIVE_PARITY_FIXTURE").as_deref() != Ok("1") {
        eprintln!("native parity fixture requires explicit process-local opt-in");
        return Some(2);
    }
    if requested != "restore" {
        eprintln!("unknown native parity fixture: {requested}");
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
    let result = Arc::new(Mutex::new(None::<Result<Value, String>>));
    let completion = result.clone();
    let root = DataRoot::with_home(home.clone(), true);
    if let Err(error) = root.ensure_dirs() {
        eprintln!("{error}");
        let _ = std::fs::remove_dir_all(&home);
        return Some(2);
    }
    let platform = gpui_kit::platform::current_platform(false);
    let terminal_text_system = platform.text_system();
    let app = gpui::Application::with_platform(platform).with_assets(crate::assets::AppAssets);
    app.run(move |cx: &mut App| {
        crate::terminal::paint::init_cpu_text_system(terminal_text_system, cx);
        gpui_kit::init(cx);
        cx.set_app_identity(
            "com.chau7.next.native-parity-fixture",
            "Chau7 Next Native Fixture",
        );
        let mut settings = crate::settings::Settings::default();
        settings.proxy.enabled = false;
        settings.cto.mode = chau7_next_core::token_optimization::TokenOptimizationMode::Off;
        crate::settings::config_files::init(cx, root.config_file(), settings.clone());
        cx.set_global(settings);
        cx.set_global(crate::workspace::AppData::new(root));
        crate::observability::init(cx);
        cx.spawn(async move |cx| {
            let deadline = cx.background_executor().timer(Duration::from_secs(35));
            let verification = crate::workspace::verify_native_restore_fixture(cx).boxed_local();
            let outcome = match futures::future::select(verification, deadline).await {
                Either::Left((result, _)) => result,
                Either::Right(_) => Err("native acceptance deadline exceeded".into()),
            };
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
            let worker = cx.update(crate::observability::shutdown);
            cx.background_spawn(async move {
                if let Some(worker) = worker {
                    let _ = worker.join();
                }
            })
            .await;
            *completion.lock().unwrap() = Some(outcome);
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
    let outcome = result
        .lock()
        .unwrap()
        .take()
        .unwrap_or_else(|| Err("native application quit without an outcome".into()));
    let code = i32::from(outcome.is_err());
    let evidence = match outcome {
        Ok(details) => {
            json!({"case":requested,"passed":true,"details":details,"frames":"native on_next_frame","profile_isolated":true})
        }
        Err(error) => {
            json!({"case":requested,"passed":false,"error":error,"profile_isolated":true})
        }
    };
    println!("{evidence}");
    if let Err(error) = std::fs::remove_dir_all(&home) {
        eprintln!("owned fixture cleanup failed: {error}");
        return Some(1);
    }
    Some(code)
}
