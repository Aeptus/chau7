//! Whole-window startup selection, separate from terminal grid rendering.
//! No native window is retained by this global. Export only bounded categories
//! and measured CPU storage/submission values, never native driver error text.
use gpui::{App, Global, Platform};
use serde_json::{Value, json};
use std::rc::Rc;

pub struct BackendState {
    #[cfg(target_os = "macos")]
    context: gpui_macos::renderer::Context,
}
impl Global for BackendState {}

pub fn create(gpu_enabled: bool) -> (Rc<dyn Platform>, BackendState) {
    #[cfg(target_os = "macos")]
    {
        let policy = policy(gpu_enabled);
        let platform = Rc::new(gpui_macos::MacPlatform::with_backend_policy(false, policy));
        let state = BackendState {
            context: platform.renderer_context(),
        };
        (platform, state)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = gpu_enabled;
        (gpui_kit::platform::current_platform(false), BackendState {})
    }
}
pub fn init(state: BackendState, cx: &mut App) {
    cx.set_global(state);
}
pub fn software_selected(cx: &App) -> bool {
    #[cfg(target_os = "macos")]
    {
        cx.try_global::<BackendState>().is_some_and(|state| {
            state.context.status().selected == Some(gpui_macos::renderer::WindowBackend::Software)
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = cx;
        false
    }
}

pub fn diagnostics(cx: &App) -> Value {
    #[cfg(target_os = "macos")]
    let status=cx.try_global::<BackendState>().map(|state| {
        use gpui_macos::renderer::{BackendPolicy,WindowBackend};
        let status=state.context.status();
        json!({"policy":match status.policy {BackendPolicy::Auto=>"auto",BackendPolicy::Metal=>"metal",BackendPolicy::Software=>"software"},
            "selected":status.selected.map(|backend|match backend {WindowBackend::Metal=>"metal",WindowBackend::Software=>"software"}),
            "startup_failure_stage":status.startup_failure.map(|stage|match stage {gpui_macos::renderer::RendererInitStage::Device=>"device",gpui_macos::renderer::RendererInitStage::ShaderLibrary=>"shader_library",gpui_macos::renderer::RendererInitStage::ShaderEntry=>"shader_entry",gpui_macos::renderer::RendererInitStage::Pipeline=>"pipeline",gpui_macos::renderer::RendererInitStage::Resource=>"resource"}),
            "injected_failure":status.injected_failure,"immutable_after_first_preparation":true})
    });
    #[cfg(not(target_os = "macos"))]
    let status: Option<Value> = None;
    let samples: Vec<_>=cx.window_renderer_diagnostics().into_iter().map(|sample|sample.map(|sample|json!({
        "backend":sample.backend,"submitted_frames":sample.submitted_frames,"failed_frames":sample.failed_frames,
        "software_image_pixel_bytes":sample.software_image_pixel_bytes,"software_live_atlas_pixel_bytes":sample.software_live_atlas_pixel_bytes,
        "last_primitive_counts":sample.last_primitive_counts,"last_retired_sprite_batches":sample.last_retired_sprite_batches,
        "last_cpu_submit_microseconds":sample.last_cpu_submit_microseconds,
        "display_completion":Value::Null,"compositor_allocated_bytes":Value::Null,"gpu_allocated_bytes":Value::Null
    }))).collect();
    json!({"startup":status,"window_count":cx.windows().len(),"sample_limit":64,"windows":samples})
}

/// Only the explicitly compiled owned native runner can select an injected
/// startup failure. No environment variable in a normal build activates it.
#[cfg(all(target_os = "macos", feature = "native-parity-fixture"))]
pub fn create_fixture(selector: &str) -> Result<(Rc<dyn Platform>, BackendState), String> {
    use gpui_macos::renderer::BackendPolicy;
    let platform = Rc::new(match selector {
        "auto" => gpui_macos::MacPlatform::with_backend_policy(false, BackendPolicy::Auto),
        "metal" => gpui_macos::MacPlatform::with_backend_policy(false, BackendPolicy::Metal),
        "software" => gpui_macos::MacPlatform::with_backend_policy(false, BackendPolicy::Software),
        "auto-device-failure" => gpui_macos::MacPlatform::with_injected_device_failure(false),
        _ => return Err("unknown native whole-window renderer".into()),
    });
    let state = BackendState {
        context: platform.renderer_context(),
    };
    Ok((platform, state))
}

/// Validate the actual immutable selection only after a real window has
/// prepared its native resources. A requested fixture mode is not evidence.
#[cfg(all(target_os = "macos", feature = "native-parity-fixture"))]
pub fn verify_fixture_selection(selector: &str, cx: &App) -> Result<(), String> {
    let snapshot = diagnostics(cx);
    let status = &snapshot["startup"];
    let expected = match selector {
        "software" | "auto-device-failure" => "software",
        "metal" => "metal",
        "auto" => return Ok(()),
        _ => return Err("unknown native whole-window renderer".into()),
    };
    if status["selected"] != expected {
        return Err("requested native fixture backend was not actually selected".into());
    }
    if selector == "auto-device-failure"
        && (status["startup_failure_stage"] != "device" || status["injected_failure"] != true)
    {
        return Err(
            "automatic fallback did not report the actual injected startup device failure".into(),
        );
    }
    if selector == "software"
        && (!status["startup_failure_stage"].is_null() || status["injected_failure"] != false)
    {
        return Err("explicit software selection unexpectedly used a Metal failure path".into());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn policy(gpu_enabled: bool) -> gpui_macos::renderer::BackendPolicy {
    if gpu_enabled {
        gpui_macos::renderer::BackendPolicy::Auto
    } else {
        gpui_macos::renderer::BackendPolicy::Software
    }
}
#[cfg(all(test, target_os = "macos"))]
mod tests {
    #[gpui::test]
    fn absent_backend_and_unmeasured_window_storage_are_unknown(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| {
            let snapshot = super::diagnostics(cx);
            assert!(snapshot["startup"].is_null());
            assert_eq!(snapshot["window_count"], 0);
            assert_eq!(snapshot["windows"], serde_json::json!([]));
            assert!(!super::software_selected(cx));
        });
    }
    #[test]
    fn saved_cpu_setting_selects_entire_software_window_at_startup() {
        assert_eq!(
            super::policy(false),
            gpui_macos::renderer::BackendPolicy::Software
        );
        assert_eq!(
            super::policy(true),
            gpui_macos::renderer::BackendPolicy::Auto
        );
    }
}

#[cfg(all(target_os = "macos", feature = "native-parity-fixture"))]
mod native_fixture;
#[cfg(all(target_os = "macos", feature = "native-parity-fixture"))]
pub async fn verify_native_surface(cx: &mut gpui::AsyncApp) -> Result<Value, String> {
    native_fixture::verify(cx).await
}
